"""Moldes N1 da fábrica (`pecas/_ec/moldes.json`): esqueletos testados por tipo de peça. O código escolhe o molde
pela ficha, liga os encaixes da ficha aos lugares (`$nome`) do molde e entrega à LLM local um rascunho que já
compila e passa no portão: ela só adapta (textos fixos, cores, tempos, variantes dos botões). Montar a peça do zero
era o que a LLM local não conseguia (0 de 71 aprovadas pelo Claude).

Também decide o que NÃO vai para a LLM local (`inviavel`): o que o N1 não desenha (foto, curva, perspectiva, 3D)."""
import copy
import json
import re

from esteira.estudio import peca as P

ARQ = P.PASTA / "_ec" / "moldes.json"
# peças do kit têm o contrato universal titulo + valores (o dado vai escondido nos pares): por ele o molde certo não
# liga (contador, anel e riscado caíam em `barras`). O mapa dá a cada uma os encaixes reais e o molde dela.
KIT = P.PASTA / "_ec" / "kit_porte.json"
LISTAS = ("itens", "pares")
TEXTUAIS = ("texto", "numero", "tematico", "icone")
VELOCIDADE = {"lenta", "normal", "rapida"}

# o que o N1 por caixas não desenha: a LLM improvisa (elipse no lugar de foto, linhas retas no lugar de onda) e o
# Claude reprova sempre. Procurado no que a peça comunica, nos encaixes e no conceito da ideia.
NAO_DESENHA = (
    (r"\bfotos?\b|fotogr|\bimage[mn]s?\b|retrato|ilustra|recorte de jornal", "foto ou imagem"),
    (r"\bondas?\b|senoid|\bcurvas?\b|sinuos|gr[áa]fico de linha|linhas? que (sobe|desce)", "curva ou onda"),
    (r"perspectiva|horizonte|ponto de fuga|\bpiso\b|estrada|t[úu]nel|c[âa]mera (avan|atravess)", "perspectiva"),
    (r"\b3d\b|extrus|\bcubos?\b|prisma|paralaxe|isom[ée]tric", "3D ou paralaxe"),
    (r"\bmapas?\b|\bglobo\b|planeta|[óo]rbita", "mapa ou órbita"),
    (r"[íi]cone|silhueta|logotipo|\blogo\b", "ícone ou desenho"),
    (r"trajet[óo]ria|\brotas?\b|caminho (que|entre)", "trajetória livre"),
)


def carregar() -> list[dict]:
    return json.loads(ARQ.read_text())


def kit(ficha: dict) -> dict | None:
    """{molde, encaixes} da peça do kit no mapa; None se não é do kit ou não tem molde próprio."""
    if ficha.get("origem") != "kit":
        return None
    return json.loads(KIT.read_text()).get(ficha.get("id")) if KIT.exists() else None


def ficha_porte(ficha: dict) -> dict:
    """Ficha de partida do porte: a do kit troca titulo + valores pelos encaixes do mapa; as outras ficam iguais."""
    k = kit(ficha)
    return {**ficha, "encaixes": copy.deepcopy(k["encaixes"])} if k else ficha


def inviavel(ficha: dict, conceito: str = "") -> str:
    """Motivo de a peça não ir para a LLM local (o N1 não a desenha), ou "" se dá."""
    if ficha.get("origem") == "kit" and not kit(ficha):
        return "peça do kit sem molde próprio (o contrato titulo + valores não diz o que desenhar)"
    encs = ficha.get("encaixes") or []
    if t := sorted({e.get("tipo") for e in encs if e.get("tipo") in ("imagem", "pagina")}):
        return f"encaixe de {'/'.join(t)} (o N1 não mostra imagem)"
    if [e["nome"] for e in encs if e.get("tipo") == "icone" and e.get("obrigatorio", True)]:
        return "encaixe de ícone obrigatório (o N1 não desenha ícone)"
    if ficha.get("peso") in ("3d", "midia"):
        return f"peso {ficha['peso']} (o N1 é 2D)"
    if set(ficha.get("intencoes") or []) <= {"fundo", "transicao"}:
        return "fundo ou transição decorativa (sem conteúdo para os moldes)"
    texto = " ".join([ficha.get("comunica", ""), conceito or "", *(e.get("descricao", "") for e in encs)]).lower()
    for padrao, o_que in NAO_DESENHA:
        if m := re.search(padrao, texto):
            return f"pede {o_que} ('{m.group(0)}'), que o N1 não desenha"
    if not escolher(ficha)[0]:
        return "nenhum molde serve aos encaixes da ficha"
    return _rascunho_quebrado(ficha)


def _rascunho_quebrado(ficha: dict) -> str:
    """O rascunho do molde já reprova no portão estrutural (ex.: encaixes que sobram espremidos no rodapé): a LLM
    partiria de algo quebrado e a última rodada (o próprio rascunho) também cairia."""
    from esteira.estudio import ec as EC
    from esteira.n1 import effectcraft as N1
    try:
        f = P.Ficha.model_validate({"id": "triagem", **ficha})
    except ValueError:
        return ""
    mid, n1 = rascunho(ficha)
    if erros := EC.checar_estrutura(N1.Peca.model_validate(n1), f):
        return f"o molde {mid!r} não comporta a ficha ({erros[0][:120]})"
    return ""


def _percentual(ficha: dict) -> bool:
    for e in ficha.get("encaixes") or []:
        if e.get("tipo") in ("numero", "pares") and "%" in json.dumps(e.get("exemplo", ""), ensure_ascii=False):
            return True
        if e.get("tipo") == "numero" and "percent" in f"{e.get('nome', '')} {e.get('descricao', '')}".lower():
            return True
    return False


def _dica(slot: dict, enc: dict) -> bool:
    nome = enc["nome"].lower()
    return any(d == nome or d in nome.split("_") or (len(d) > 3 and d in nome) for d in slot.get("dicas", []))


def _ligar(molde: dict, encaixes: list[dict]) -> dict | None:
    """lugar do molde → encaixe da ficha (tipo + dica do nome). None se falta encaixe para um lugar obrigatório.
    Ordem: obrigatórios; opcionais cuja dica bate; opcionais que sobram, pelo tipo."""
    livres, mapa = list(encaixes), {}
    slots = molde["slots"]
    obrig = [s for s in slots if s.get("obrigatorio")]
    opc = [s for s in slots if not s.get("obrigatorio")]
    for passo in ("obrig", "dica", "tipo"):
        for s in (obrig if passo == "obrig" else opc):
            if s["nome"] in mapa:
                continue
            cands = [e for e in livres if e.get("tipo") in s["tipos"]]
            if passo == "dica":
                cands = [e for e in cands if _dica(s, e)]
            if not cands:
                if passo == "obrig":
                    return None
                continue
            e = max(cands, key=lambda e: (_dica(s, e) * 10 + e.get("obrigatorio", True) * 2
                                          + (e.get("max_car", 40) / 100 if s["nome"] == "frase" else 0)))
            mapa[s["nome"]] = e
            livres.remove(e)
    return mapa


def escolher(ficha: dict) -> tuple[dict | None, dict | None]:
    """O molde que mais serve à ficha (intenções, encaixes ligados, nada de lista sobrando) e a ligação."""
    encs = [e for e in ficha.get("encaixes") or [] if e.get("tipo") not in ("imagem", "pagina")]
    inten = ficha.get("intencoes") or []
    melhor = (None, None, None)
    forcado = (kit(ficha) or {}).get("molde")
    for k, m in enumerate(carregar()):
        if forcado and m["id"] != forcado:
            continue
        if m.get("condicao") == "percentual" and not _percentual(ficha):
            continue
        mapa = _ligar(m, encs)
        if mapa is None:
            continue
        sobra = [e for e in encs if all(e is not x for x in mapa.values())]
        nota = (3 * len(set(m["intencoes"]) & set(inten)) + 2 * bool(inten and inten[0] in m["intencoes"])
                + len(mapa) - 2 * len(sobra)
                - sum((6 if e.get("obrigatorio", True) else 1) for e in sobra if e.get("tipo") in LISTAS)
                + m.get("bonus", 0), -k)
        if melhor[0] is None or nota > melhor[0]:
            melhor = (nota, m, mapa)
    return melhor[1], melhor[2]


def _refs(el: dict) -> set[str]:
    """Lugares `$x` usados direto pelo elemento (não pelos filhos)."""
    refs = set(re.findall(r"\{\{\$(\w+)", el.get("conteudo", "")))
    return refs | {v[1:] for k in ("encaixe", "ativos") if isinstance(v := el.get(k), str) and v.startswith("$")}


def preencher(molde: dict, mapa: dict, ficha: dict) -> dict:
    """Rascunho N1 da ficha: tira o que usa lugar sem encaixe, liga os nomes, põe os encaixes que sobraram em
    textos de apoio, `se` nos opcionais, `maximo` da ficha e o botão de velocidade."""
    doc = copy.deepcopy(molde["n1"])
    nomes = {s: e["nome"] for s, e in mapa.items()}
    opcionais = {s for s, e in mapa.items() if not e.get("obrigatorio", True)}
    fora: set[str] = set()

    def podar(els):
        saida = []
        for el in els:
            refs = _refs(el)
            if refs - set(nomes):
                fora.add(el["nome"])
                continue
            if el["tipo"] == "caixa":
                el["filhos"] = podar(el["filhos"])
                if not el["filhos"]:
                    fora.add(el["nome"])
                    continue
            if el["tipo"] == "repetir":
                el["elementos"] = podar(el["elementos"])
                if not el["elementos"]:
                    fora.add(el["nome"])
                    continue
                if (s := (el.get("encaixe") or "")[1:]) in mapa:
                    el["maximo"] = mapa[s].get("max_itens", el.get("maximo", 8))
                el["animacoes"] = [a for a in el.get("animacoes", []) if a["alvo"] not in fora]
            if (opc := sorted(refs & opcionais)) and "se" not in el:
                el["se"] = {"encaixe": f"${opc[0]}"}
            saida.append(el)
        return saida

    doc["elementos"] = podar(doc["elementos"])
    doc["animacoes"] = [a for a in doc.get("animacoes", []) if a["alvo"] not in fora]
    sobra = [e for e in ficha.get("encaixes") or []
             if all(e is not x for x in mapa.values()) and e.get("tipo") in (*TEXTUAIS, *LISTAS)]
    if sobra:
        _apoio(doc, sobra)
    for b in ficha.get("botoes") or []:
        if len(VELOCIDADE & {str(v) for v in b.get("valores", [])}) >= 2:
            doc["botao_velocidade"] = b["nome"]
            break
    txt = json.dumps(doc, ensure_ascii=False)
    txt = re.sub(r"\{\{\$(\w+)", lambda m: "{{" + nomes[m.group(1)], txt)
    txt = re.sub(r'"\$(\w+)"', lambda m: json.dumps(nomes[m.group(1)]), txt)
    return json.loads(txt)


def _apoio(doc: dict, sobra: list[dict]):
    """Encaixes que o molde não tem lugar: textos (ou lista em linha) na base; com esquerda/direita (que descem
    até a base), no topo."""
    caixas = {c["nome"]: c for c in doc["elementos"] if c["tipo"] == "caixa"}
    regioes = {c.get("regiao", "tela") for c in caixas.values()}
    if "Base" in caixas:
        alvo = caixas["Base"]
    elif regioes & {"esquerda", "direita"}:
        alvo = caixas.get("Topo") or {"tipo": "caixa", "nome": "Topo", "regiao": "topo", "filhos": []}
    else:
        alvo = {"tipo": "caixa", "nome": "Base", "regiao": "base", "filhos": []}
    if alvo not in doc["elementos"]:
        doc["elementos"].append(alvo)
    alvo["disposicao"] = "coluna"
    for e in sobra:
        nome = f"Apoio_{e['nome']}"
        if e["tipo"] in LISTAS:
            campo = "{{item.rotulo}} {{item.valor}}" if e["tipo"] == "pares" else "{{item}}"
            el = {"tipo": "caixa", "nome": nome, "disposicao": "linha", "filhos": [
                {"tipo": "repetir", "nome": f"{nome}_itens", "encaixe": e["nome"], "maximo": e.get("max_itens", 6),
                 "elementos": [{"tipo": "texto", "nome": f"{nome}_item", "conteudo": campo, "nivel": "rotulo"}]}]}
        else:
            el = {"tipo": "texto", "nome": nome, "conteudo": "{{" + e["nome"] + "}}", "nivel": "rotulo",
                  "cor": "apoio"}
            doc.setdefault("animacoes", []).append(
                {"anim": "entrar", "alvo": nome, "de": "aparecer", "t": 1.2, "dur": "0.5v"})
        if not e.get("obrigatorio", True):
            el["se"] = {"encaixe": e["nome"]}
        alvo["filhos"].append(el)


def rascunho(ficha: dict) -> tuple[str, dict] | None:
    """(id do molde, N1 pronto para a ficha) ou None se nenhum molde serve."""
    m, mapa = escolher(ficha)
    return (m["id"], preencher(m, mapa, ficha)) if m else None
