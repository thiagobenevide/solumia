"""Moldes N1 da fábrica (`pecas/_ec/moldes.json`): esqueletos testados por tipo de peça. O código escolhe o molde
pela ficha, liga os encaixes da ficha aos lugares (`$nome`) do molde e entrega à LLM local um rascunho que já
compila e passa no portão: ela só adapta (textos fixos, cores, tempos, variantes dos botões). Montar a peça do zero
era o que a LLM local não conseguia (0 de 71 aprovadas pelo Claude).

Também decide o que NÃO vai para a LLM local (`inviavel`): o que o N1 não desenha (foto, curva, perspectiva, 3D)."""
import copy
import json
import re

from esteira.studio import piece as P

FILE = P.FOLDER / "_ec" / "moldes.json"
# peças do kit têm o contrato universal titulo + valores (o dado vai escondido nos pares): por ele o molde certo não
# liga (contador, anel e riscado caíam em `barras`). O mapa dá a cada uma os encaixes reais e o molde dela.
KIT = P.FOLDER / "_ec" / "kit_porte.json"
LISTS = ("itens", "pares")
TEXTUAL = ("texto", "numero", "tematico", "icone")
SPEED = {"lenta", "normal", "rapida"}

# o que o N1 por caixas não desenha: a LLM improvisa (elipse no lugar de foto, linhas retas no lugar de onda) e o
# Claude reprova sempre. Procurado no que a peça comunica, nos encaixes e no conceito da ideia.
NAO_DRAWS = (
    (r"\bfotos?\b|fotogr|\bimage[mn]s?\b|retrato|ilustra|recorte de jornal", "foto ou imagem"),
    (r"\bondas?\b|senoid|\bcurvas?\b|sinuos|gr[áa]fico de linha|linhas? que (sobe|desce)", "curva ou onda"),
    (r"perspectiva|horizonte|ponto de fuga|\bpiso\b|estrada|t[úu]nel|c[âa]mera (avan|atravess)", "perspectiva"),
    (r"\b3d\b|extrus|\bcubos?\b|prisma|paralaxe|isom[ée]tric", "3D ou paralaxe"),
    (r"\bmapas?\b|\bglobo\b|planeta|[óo]rbita", "mapa ou órbita"),
    (r"[íi]cone|silhueta|logotipo|\blogo\b", "ícone ou desenho"),
    (r"trajet[óo]ria|\brotas?\b|caminho (que|entre)", "trajetória livre"),
)


def load() -> list[dict]:
    return json.loads(FILE.read_text())


def kit(ficha: dict) -> dict | None:
    """{molde, encaixes} da peça do kit no mapa; None se não é do kit ou não tem molde próprio."""
    if ficha.get("origem") != "kit":
        return None
    return json.loads(KIT.read_text()).get(ficha.get("id")) if KIT.exists() else None


def card_size(ficha: dict) -> dict:
    """Ficha de partida do porte: a do kit troca titulo + valores pelos encaixes do mapa; as outras ficam iguais."""
    k = kit(ficha)
    return {**ficha, "encaixes": copy.deepcopy(k["encaixes"])} if k else ficha


def unfeasible(ficha: dict, concept: str = "") -> str:
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
    text = " ".join([ficha.get("comunica", ""), concept or "", *(e.get("descricao", "") for e in encs)]).lower()
    for default, o_que in NAO_DRAWS:
        if m := re.search(default, text):
            return f"pede {o_que} ('{m.group(0)}'), que o N1 não desenha"
    if not choose(ficha)[0]:
        return "nenhum molde serve aos encaixes da ficha"
    return _draft_broken(ficha)


def _draft_broken(ficha: dict) -> str:
    """O rascunho do molde já reprova no portão estrutural (ex.: encaixes que sobram espremidos no rodapé): a LLM
    partiria de algo quebrado e a última rodada (o próprio rascunho) também cairia."""
    from esteira.studio import ec as EC
    from esteira.n1 import effectcraft as N1
    try:
        f = P.Card.model_validate({"id": "triagem", **ficha})
    except ValueError:
        return ""
    mid, n1 = draft(ficha)
    if errors := EC.check_structure(N1.Piece.model_validate(n1), f):
        return f"o molde {mid!r} não comporta a ficha ({errors[0][:120]})"
    return ""


def _percent(ficha: dict) -> bool:
    for e in ficha.get("encaixes") or []:
        if e.get("tipo") in ("numero", "pares") and "%" in json.dumps(e.get("exemplo", ""), ensure_ascii=False):
            return True
        if e.get("tipo") == "numero" and "percent" in f"{e.get('nome', '')} {e.get('descricao', '')}".lower():
            return True
    return False


def _hint(slot: dict, enc: dict) -> bool:
    name = enc["nome"].lower()
    return any(d == name or d in name.split("_") or (len(d) > 3 and d in name) for d in slot.get("dicas", []))


def _enable(mold: dict, encaixes: list[dict]) -> dict | None:
    """lugar do molde → encaixe da ficha (tipo + dica do nome). None se falta encaixe para um lugar obrigatório.
    Ordem: obrigatórios; opcionais cuja dica bate; opcionais que sobram, pelo tipo."""
    livres, mapping = list(encaixes), {}
    slots = mold["slots"]
    obrig = [s for s in slots if s.get("obrigatorio")]
    opc = [s for s in slots if not s.get("obrigatorio")]
    for step in ("obrig", "dica", "tipo"):
        for s in (obrig if step == "obrig" else opc):
            if s["nome"] in mapping:
                continue
            cands = [e for e in livres if e.get("tipo") in s["tipos"]]
            if step == "dica":
                cands = [e for e in cands if _hint(s, e)]
            if not cands:
                if step == "obrig":
                    return None
                continue
            e = max(cands, key=lambda e: (_hint(s, e) * 10 + e.get("obrigatorio", True) * 2
                                          + (e.get("max_car", 40) / 100 if s["nome"] == "frase" else 0)))
            mapping[s["nome"]] = e
            livres.remove(e)
    return mapping


def choose(ficha: dict) -> tuple[dict | None, dict | None]:
    """O molde que mais serve à ficha (intenções, encaixes ligados, nada de lista sobrando) e a ligação."""
    encs = [e for e in ficha.get("encaixes") or [] if e.get("tipo") not in ("imagem", "pagina")]
    inten = ficha.get("intencoes") or []
    best = (None, None, None)
    forcado = (kit(ficha) or {}).get("molde")
    for k, m in enumerate(load()):
        if forcado and m["id"] != forcado:
            continue
        if m.get("condicao") == "percentual" and not _percent(ficha):
            continue
        mapping = _enable(m, encs)
        if mapping is None:
            continue
        leftover = [e for e in encs if all(e is not x for x in mapping.values())]
        note = (3 * len(set(m["intencoes"]) & set(inten)) + 2 * bool(inten and inten[0] in m["intencoes"])
                + len(mapping) - 2 * len(leftover)
                - sum((6 if e.get("obrigatorio", True) else 1) for e in leftover if e.get("tipo") in LISTS)
                + m.get("bonus", 0), -k)
        if best[0] is None or note > best[0]:
            best = (note, m, mapping)
    return best[1], best[2]


def _refs(el: dict) -> set[str]:
    """Lugares `$x` usados direto pelo elemento (não pelos filhos)."""
    refs = set(re.findall(r"\{\{\$(\w+)", el.get("conteudo", "")))
    return refs | {v[1:] for k in ("encaixe", "ativos") if isinstance(v := el.get(k), str) and v.startswith("$")}


def fill(mold: dict, mapping: dict, ficha: dict) -> dict:
    """Rascunho N1 da ficha: tira o que usa lugar sem encaixe, liga os nomes, põe os encaixes que sobraram em
    textos de apoio, `se` nos opcionais, `maximo` da ficha e o botão de velocidade."""
    doc = copy.deepcopy(mold["n1"])
    names = {s: e["nome"] for s, e in mapping.items()}
    opcionais = {s for s, e in mapping.items() if not e.get("obrigatorio", True)}
    outside: set[str] = set()

    def podar(els):
        output = []
        for el in els:
            refs = _refs(el)
            if refs - set(names):
                outside.add(el["nome"])
                continue
            if el["tipo"] == "caixa":
                el["filhos"] = podar(el["filhos"])
                if not el["filhos"]:
                    outside.add(el["nome"])
                    continue
            if el["tipo"] == "repetir":
                el["elementos"] = podar(el["elementos"])
                if not el["elementos"]:
                    outside.add(el["nome"])
                    continue
                if (s := (el.get("encaixe") or "")[1:]) in mapping:
                    el["maximo"] = mapping[s].get("max_itens", el.get("maximo", 8))
                el["animacoes"] = [a for a in el.get("animacoes", []) if a["alvo"] not in outside]
            if (opc := sorted(refs & opcionais)) and "se" not in el:
                el["se"] = {"encaixe": f"${opc[0]}"}
            output.append(el)
        return output

    doc["elementos"] = podar(doc["elementos"])
    doc["animacoes"] = [a for a in doc.get("animacoes", []) if a["alvo"] not in outside]
    leftover = [e for e in ficha.get("encaixes") or []
             if all(e is not x for x in mapping.values()) and e.get("tipo") in (*TEXTUAL, *LISTS)]
    if leftover:
        _support(doc, leftover)
    for b in ficha.get("botoes") or []:
        if len(SPEED & {str(v) for v in b.get("valores", [])}) >= 2:
            doc["botao_velocidade"] = b["nome"]
            break
    txt = json.dumps(doc, ensure_ascii=False)
    txt = re.sub(r"\{\{\$(\w+)", lambda m: "{{" + names[m.group(1)], txt)
    txt = re.sub(r'"\$(\w+)"', lambda m: json.dumps(names[m.group(1)]), txt)
    return json.loads(txt)


def _support(doc: dict, leftover: list[dict]):
    """Encaixes que o molde não tem lugar: textos (ou lista em linha) na base; com esquerda/direita (que descem
    até a base), no topo."""
    boxes = {c["nome"]: c for c in doc["elementos"] if c["tipo"] == "caixa"}
    regions = {c.get("regiao", "tela") for c in boxes.values()}
    if "Base" in boxes:
        target = boxes["Base"]
    elif regions & {"esquerda", "direita"}:
        target = boxes.get("Topo") or {"tipo": "caixa", "nome": "Topo", "regiao": "topo", "filhos": []}
    else:
        target = {"tipo": "caixa", "nome": "Base", "regiao": "base", "filhos": []}
    if target not in doc["elementos"]:
        doc["elementos"].append(target)
    target["disposicao"] = "coluna"
    for e in leftover:
        name = f"Apoio_{e['nome']}"
        if e["tipo"] in LISTS:
            field = "{{item.rotulo}} {{item.valor}}" if e["tipo"] == "pares" else "{{item}}"
            el = {"tipo": "caixa", "nome": name, "disposicao": "linha", "filhos": [
                {"tipo": "repetir", "nome": f"{name}_itens", "encaixe": e["nome"], "maximo": e.get("max_itens", 6),
                 "elementos": [{"tipo": "texto", "nome": f"{name}_item", "conteudo": field, "nivel": "rotulo"}]}]}
        else:
            el = {"tipo": "texto", "nome": name, "conteudo": "{{" + e["nome"] + "}}", "nivel": "rotulo",
                  "cor": "apoio"}
            doc.setdefault("animacoes", []).append(
                {"anim": "entrar", "alvo": name, "de": "aparecer", "t": 1.2, "dur": "0.5v"})
        if not e.get("obrigatorio", True):
            el["se"] = {"encaixe": e["nome"]}
        target["filhos"].append(el)


def draft(ficha: dict) -> tuple[str, dict] | None:
    """(id do molde, N1 pronto para a ficha) ou None se nenhum molde serve."""
    m, mapping = choose(ficha)
    return (m["id"], fill(m, mapping, ficha)) if m else None
