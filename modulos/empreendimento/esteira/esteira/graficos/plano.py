"""Etapa graficos: decide que gráfico entra, quando e com que dados (graficos.json) e renderiza os .mov.

Candidatos vêm do código (capítulos do roteiro, frases com números, menções a estudos, *destaques*) e das
notas de cena do roteiro. O LLM local escreve o conteúdo e dá o impacto de cada um; o agendador escolhe
pelos pontos sem sobrepor e sem passar da densidade máxima. Citações usam a página real do PDF quando ele
é achado (vault ou acesso aberto); sem PDF, viram tarja de fonte.
"""
import hashlib
import json
from pathlib import Path
import re
from typing import Optional

from pydantic import BaseModel, Field

from esteira.graficos import artigos, pecas, render
from esteira.ia import local
from esteira.nucleo import eventos

DUR = {"caixas": 4.0, "capitulo": 3.2, "numero": 4.6, "comparacao": 7.0, "frase": 3.0, "fonte": 5.0}
PESO = {"capitulo": 10, "citacao": 8, "nota": 5, "numero": 3, "frase": 2, "fonte": 1}
RE_NUM = re.compile(r"\d[\d.,]*\s*(%|por cento|mil\b|milh|bilh|vezes|anos?\b|meses|reais)|R\$\s*\d", re.I)
RE_ESTUDO = re.compile(r"estud|pesquis|artigo|publica|economist|cientist|autores|revista|universidade", re.I)


class Numero(BaseModel):
    usar: bool
    numero: str = Field("", max_length=16)
    legenda: str = Field("", max_length=90)
    rotulo: str = Field("", max_length=40)
    fonte: int = -1
    impacto: int = Field(3, ge=1, le=5)


Curto = Field("", max_length=80)


class Item(BaseModel):
    titulo: str = Field(max_length=40)
    valor: str = Field("", max_length=16)
    detalhe: str = Field("", max_length=60)


class Nota(BaseModel):
    tipo: str = Field(pattern="^(lista|numero|comparacao|frase|fonte|nenhum)$")
    impacto: int = Field(3, ge=1, le=5)
    titulo: str = Curto
    rotulo: str = Curto
    itens: list[Item] = Field([], max_length=4)
    numero: str = Field("", max_length=16)
    legenda: str = Curto
    texto: str = Curto
    nome_a: str = Field("", max_length=30)
    itens_a: list[str] = Field([], max_length=3)
    nome_b: str = Field("", max_length=30)
    itens_b: list[str] = Field([], max_length=3)
    linha1: str = Curto
    linha2: str = Curto


class Trecho(BaseModel):
    indice: int
    traducao: str = Field("", max_length=260)


class Termos(BaseModel):
    termos: list[str] = Field(max_length=6)


def _fala_para_frase(roteiro_txt):
    """Índice da 1ª frase (ler_roteiro) de cada fala (linha) do roteiro.txt."""
    saida, k = [], 0
    for linha in roteiro_txt.splitlines():
        linha = linha.strip()
        if not linha or linha.startswith("#"):
            continue
        saida.append(k)
        k += len([f for f in re.split(r"(?<=[.!?…])\s+", linha) if f.strip()])
    return saida


def _textos(itens):
    """O LLM às vezes devolve objetos (JSON ou dict do Python) dentro da lista de textos: vira "valor título"."""
    import ast
    saida = []
    for it in itens:
        d = None
        if it.strip().startswith("{"):
            for ler in (json.loads, ast.literal_eval):
                try:
                    d = ler(it)
                    break
                except (ValueError, SyntaxError):
                    pass
            # {titulo: 'x', valor: 'y'}: chaves sem aspas
            d = d or dict(re.findall(r"(\w+)\s*:\s*['\"]([^'\"]*)['\"]", it)) or None
        saida.append(" ".join(str(v) for v in (d.get("valor"), d.get("titulo")) if v) if isinstance(d, dict) else it)
    return [s for s in saida if s][:3]


def _digitos(s):
    return re.sub(r"[^\d]", "", s)


def _numero_na_fala(numero, fala):
    """O número do card tem de estar na fala (o LLM às vezes arredonda: "400%" para "436%")."""
    d = _digitos(numero)
    return bool(d) and "/" not in numero and any(d == _digitos(m) for m in re.findall(r"\d[\d.,]*", fala))


RE_NUMERO = re.compile(r"(R\$\s*)?\d[\d.,]*(?:\s*(%|por cento|mil(?:hões|hão)?\b|bilh(?:ões|ão)|vezes|anos?\b|"
                       r"meses|reais))?", re.I)


def _numeros_da_frase(texto):
    """[(número como vai na tela, legenda)] de cada número com unidade da frase ("48%", "24 milhões",
    "R$ 400"); a legenda são as palavras que vêm depois dele (até 7, sem passar da pontuação nem do próximo
    número)."""
    saida = []
    for m in RE_NUMERO.finditer(texto):
        if not (m.group(1) or m.group(2)):
            continue  # número sem unidade (ano, "3 motivos"): fica para o LLM
        numero = re.sub(r"\s+", " ", m.group(0)).strip().replace("por cento", "%").replace(" %", "%")
        resto = re.split(r"[.;:!?]|\s(?=R\$|\d)", texto[m.end():])[0].strip(" ,")  # até a pontuação ou o próximo número
        saida.append((numero, " ".join(resto.split()[:7])))
    return saida


ANTECIPA = 0.35   # s: o gráfico de número começa isto antes da fala (o contador sai do zero quando o número é dito)


def _instante_numero(numero, palavras, t0, t1, perto=None):
    """Instante (narração editada) em que `numero` é falado entre t0 e t1, ou None; com `perto`, a ocorrência mais
    próxima desse instante (senão a primeira). O Whisper parte números ("12", ",5", "%"): junta a palavra com o
    pedaço decimal seguinte antes de comparar."""
    m = re.search(r"\d[\d.,]*", numero)
    alvo = _digitos(m.group()) if m else ""
    if not alvo:
        return None
    achados = []
    for k, w in enumerate(palavras):
        if not t0 <= w["ini"] <= t1:
            continue
        d = _digitos(w["p"])
        if not d:
            continue
        j = k + 1
        while j < len(palavras) and re.match(r"^[.,]\d", palavras[j]["p"].strip()) and len(d) < len(alvo):
            d += _digitos(palavras[j]["p"])
            j += 1
        if d == alvo:
            if perto is None:
                return w["ini"]
            achados.append(w["ini"])
    return min(achados, key=lambda x: abs(x - perto)) if achados else None


def _ancorar(c, t, antecipa=ANTECIPA):
    c["inicio"], c["ancora"] = round(max(t - antecipa, 0), 2), round(t, 2)


def _ref(f):
    return f"{f['autores']} ({f['ano']}), {f['revista']}".strip(", ")


def _fonte_citada(texto, fontes):
    """Índice da fonte mencionada na frase (sobrenome do 1º autor, revista ou ano + palavra de estudo)."""
    melhor, nota_max = None, 0
    for k, f in enumerate(fontes):
        sobrenome = re.split(r"[ ,]", f["autores"])[0]
        nota = 3 * (len(sobrenome) > 2 and sobrenome.lower() in texto.lower())
        nota += 3 * bool(f["revista"] and f["revista"].lower() in texto.lower())
        nota += 1 * bool(f["ano"][:4] in texto and RE_ESTUDO.search(texto))
        if nota > nota_max:
            melhor, nota_max = k, nota
    return melhor if nota_max >= 3 or (nota_max == 1 and sum(f["ano"][:4] in texto for f in fontes) == 1) else None


def candidatos(projeto):
    cfg = projeto.cfg
    rot = json.loads(projeto.caminho("roteiro.json").read_text()) if projeto.caminho("roteiro.json").exists() else {}
    frases = projeto.carregar_json("frases.json")
    transc = projeto.carregar_json("transcricao.json")
    duracao, palavras = transc["duracao"], transc["palavras"]
    fontes = rot.get("fontes", [])
    mapa = _fala_para_frase(projeto.roteiro().read_text())

    def t_fala(k):
        """Instante da 1ª frase com tempo a partir da fala k."""
        for i in range(mapa[min(k, len(mapa) - 1)] if mapa else 0, len(frases)):
            if frases[i]["ini"] is not None:
                return frases[i]["ini"]
        return None

    c = []
    titulo = rot.get("titulo")
    if titulo and cfg["edicao"].get("titulo_inicio", True):
        c.append({"modelo": "capitulo", "inicio": 0.4, "dados": {"nome": titulo, "rotulo": ""}, "impacto": 5,
                  "origem": "titulo"})
    for cap in rot.get("capitulos", []):
        t = t_fala(cap["fala"])
        if cap["parte"] >= 2 and t is not None and cfg.get("graficos", {}).get("capitulos", True):
            c.append({"modelo": "capitulo", "inicio": max(t - 0.3, 0), "origem": "capitulo", "impacto": 4,
                      "dados": {"nome": cap["nome"], "rotulo": f"PARTE {cap['parte']}"}})

    # Citações marcadas no roteiro ([!cite]): PDF, página e trecho já conferidos no vault, sem LLM
    citadas = set()
    for cit in rot.get("citacoes", []):
        t = t_fala(max(cit["fala"], 0))
        if not cit.get("ok") or t is None:
            continue
        k = _fonte_citada(f"{cit.get('autores', '')} {cit.get('revista', '')}", fontes)
        if k is not None:
            citadas.add(k)
        f = fontes[k] if k is not None else {}
        c.append({"modelo": "citacao", "inicio": t, "origem": "citacao", "impacto": 7, "roteiro": True,
                  "dados": {"arquivo": cit["arquivo"], "trecho": cit["en"], "pagina": cit["pagina"] - 1,
                            "titulo": cit.get("titulo") or f.get("titulo", ""),
                            "autores": f.get("autores") or cit.get("autores", ""),
                            "revista": cit.get("revista") or f.get("revista", ""),
                            "ano": (cit.get("ano") or f.get("ano", ""))[:4], "citacao": cit.get("pt", "")}})

    # Citações automáticas: 1ª menção de cada fonte que o roteiro não marcou
    for i, f in enumerate(frases):
        if f["ini"] is None:
            continue
        k = _fonte_citada(f["texto"], fontes)
        if k is None or k in citadas:
            continue
        citadas.add(k)
        c.append({"modelo": "citacao", "inicio": f["ini"], "origem": "citacao", "impacto": 5, "fonte": k,
                  "fala": " ".join(x["texto"] for x in frases[i:i + 3])})

    # Números
    for i, f in enumerate(frases):
        if f["ini"] is None or not RE_NUM.search(f["texto"]):
            continue
        ctx = " ".join(x["texto"] for x in frases[max(i - 1, 0):i + 2])
        r = local.perguntar(local.prompt("grafico_numero", fala=f["texto"], contexto=ctx,
                                         fontes="; ".join(f"{k}: {_ref(x)}" for k, x in enumerate(fontes)) or "nenhuma"),
                            Numero)
        if r and r.usar and r.numero and _numero_na_fala(r.numero, f["texto"]):
            fonte = _ref(fontes[r.fonte]) if 0 <= r.fonte < len(fontes) else ""
            c.append({"modelo": "numero", "inicio": f["ini"], "origem": "numero", "impacto": r.impacto,
                      "dados": {"texto": r.numero, "legenda": r.legenda, "fonte": fonte, "rotulo": r.rotulo}})
            # entra quando o número é DITO, não no começo da frase
            t = _instante_numero(r.numero, palavras, f["ini"] - 2, (f.get("fim") or f["ini"] + 20) + 3)
            if t is not None:
                _ancorar(c[-1], t)
            else:
                eventos.debug("gráfico de número sem a fala do número", numero=r.numero, frase=f["texto"][:80])
        # todo número dito aparece: os que o LLM não escolheu (ou o 2º número da frase) viram gráfico simples
        feitos = {_digitos(c[-1]["dados"]["texto"])} if r and r.usar and c and c[-1]["origem"] == "numero" else set()
        for numero, legenda in _numeros_da_frase(f["texto"]):
            if _digitos(numero) in feitos:
                continue
            feitos.add(_digitos(numero))
            t = _instante_numero(numero, palavras, f["ini"] - 2, (f.get("fim") or f["ini"] + 20) + 3)
            if t is None:
                continue
            c.append({"modelo": "numero", "inicio": f["ini"], "origem": "numero", "impacto": 3,
                      "dados": {"texto": numero, "legenda": legenda, "fonte": "", "rotulo": ""}})
            _ancorar(c[-1], t)

    # Notas de cena do roteiro
    for nota in rot.get("notas", []):
        t = t_fala(nota["antes_da_fala"])
        if t is None:
            continue
        k0 = mapa[min(nota["antes_da_fala"], len(mapa) - 1)] if mapa else 0
        falas = " ".join(x["texto"] for x in frases[k0:k0 + 3])
        r = local.perguntar(local.prompt("grafico_nota", nota=nota["texto"], falas=falas), Nota)
        if not r or r.tipo not in ("lista", "numero", "comparacao", "frase", "fonte"):
            continue
        d = {"lista": lambda: {"itens": [i.model_dump() for i in r.itens], "titulo": r.titulo, "rotulo": r.rotulo},
             "numero": lambda: {"texto": r.numero, "legenda": r.legenda, "rotulo": r.rotulo},
             "comparacao": lambda: {"nome_a": r.nome_a, "itens_a": _textos(r.itens_a), "nome_b": r.nome_b,
                                    "itens_b": _textos(r.itens_b)},
             "frase": lambda: {"texto": r.texto},
             "fonte": lambda: {"linha1": r.linha1, "linha2": r.linha2}}[r.tipo]()
        if r.tipo == "lista" and len(d["itens"]) < 2 or r.tipo == "numero" and not re.search(r"\d", r.numero):
            continue
        if r.tipo == "fonte" and any(re.split(r"[ ,]", fontes[k]["autores"])[0].lower() in r.linha1.lower()
                                     for k in citadas):
            continue  # a fonte já tem citação própria
        c.append({"modelo": r.tipo, "inicio": t, "origem": "nota", "impacto": r.impacto, "dados": d,
                  "nota": nota["texto"][:120]})
        if r.tipo == "numero":
            tn = _instante_numero(r.numero, palavras, t - 20, t + 25, perto=t)  # a nota pode vir depois da fala
            if tn is not None:
                _ancorar(c[-1], tn)
        elif r.tipo == "lista":
            _sincronizar_lista(c[-1], palavras, t)

    # *Destaques* do roteiro → frase cinética
    for f in frases:
        for d in f.get("destaques", []):
            if f["ini"] is not None and len(d.split()) >= 2:
                c.append({"modelo": "frase", "inicio": f["ini"], "origem": "destaque", "impacto": 2,
                          "dados": {"texto": f"*{d}*"}})
    return c, fontes, duracao


def _sincronizar_lista(c, palavras, t):
    """Lista de dados "em fila": cada cartão entra quando o valor dele é falado (`tempos`, s desde o início da
    peça). Itens sem valor achado na fala ficam entre os vizinhos."""
    falas, desde = [], t - 5
    for it in c["dados"]["itens"]:
        ti = _instante_numero(it.get("valor", ""), palavras, desde, t + 60) if it.get("valor") else None
        falas.append(ti)
        if ti is not None:
            desde = ti
    if not any(x is not None for x in falas):
        return
    conhecidos = [k for k, x in enumerate(falas) if x is not None]
    for k in range(len(falas)):
        if falas[k] is None:
            ant = max((j for j in conhecidos if j < k), default=None)
            prox = min((j for j in conhecidos if j > k), default=None)
            falas[k] = (falas[ant] + 1.5 if ant is not None else falas[prox] - 1.5)
    _ancorar(c, falas[0], 0.6)
    c["dados"]["tempos"] = [round(max(x - c["inicio"] - 0.15, 0.3), 2) for x in falas]
    c["dur_min"] = round(c["dados"]["tempos"][-1] + 3.2, 2)


def _preparar_citacao(cand, fontes, projeto):
    """Acha PDF + trecho; sem isso, vira tarja de fonte."""
    f = fontes[cand["fonte"]]
    tarja = {"modelo": "fonte", "dados": {"linha1": f"{f['autores']} ({f['ano']})",
                                          "linha2": f"{f['revista']} {f.get('detalhes', '')}".strip(),
                                          "rotulo": "Estudo"}}
    pdf = artigos.achar_pdf(f, projeto.cfg["fontes"].get("artigos"))
    if not pdf:
        return tarja
    cands = artigos.candidatos_trecho(pdf, cand["fala"])
    if len(cands) < 2:
        r = local.perguntar(local.prompt("termos_en", fala=cand["fala"]), Termos)
        if r:
            cands = artigos.candidatos_trecho(pdf, cand["fala"], r.termos)
    if not cands:
        return tarja
    lista = "\n".join(f"{k}. {t[2][:300]}" for k, t in enumerate(cands))
    r = local.perguntar(local.prompt("grafico_citacao", fala=cand["fala"], estudo=_ref(f), trechos=lista), Trecho)
    if not r or not 0 <= r.indice < len(cands):
        return tarja
    _, pagina, trecho = cands[r.indice]
    return {"modelo": "citacao", "dados": {"arquivo": str(pdf), "trecho": trecho, "pagina": pagina,
                                           "titulo": f["titulo"], "autores": f["autores"],
                                           "revista": f"{f['revista']} · {f.get('detalhes', '')}".strip(" ·"),
                                           "ano": f["ano"][:4], "citacao": r.traducao}}


LEITURA = 3.0  # palavras por segundo que dá para ler na tela (EN + PT da citação)


def _duracao(c):
    if c["modelo"] == "citacao":
        # tempo de ler o trecho original (EN) e a tradução (PT) com calma, depois da câmera chegar no trecho
        d = c.get("dados") or {}
        palavras = len((d.get("trecho") or "").split()) + len((d.get("citacao") or "").split())
        return round(min(max(6.5 + palavras / LEITURA, 13.0), 26.0), 1) if palavras else 15.0
    if c["modelo"] == "lista":
        return max(2.4 + 1.1 * len(c["dados"]["itens"]), c.get("dur_min", 0))
    return DUR[c["modelo"]]


ADIAR = {"citacao": 12.0, "nota": 5.0, "numero": 3.0}  # s que um gráfico pode atrasar para não colidir
FILA, DUR_MIN = 0.3, 2.2  # números seguidos: folga entre eles e o mínimo que o anterior fica na tela


def agendar(cands, duracao, intervalo=1.5, cobertura_max=0.4, fixos=()):
    """Escolhe por pontos (tipo + impacto), sem sobrepor (com folga) e até `cobertura_max` do vídeo.
    Em colisão, o gráfico mais fraco é adiado até ADIAR s (continua perto da fala); depois disso, sai.
    `fixos`: gráficos editados à mão no painel; ficam onde estão e os automáticos desviam deles."""
    for c in cands:
        c["dur"] = _duracao(c)
        c["pontos"] = PESO.get(c["origem"], PESO.get(c["modelo"], 1)) + c.get("impacto", 3)
    escolhidos, usado = list(fixos), sum(c["dur"] for c in fixos)
    folga = lambda a, b: FILA if a.get("ancora") and b.get("ancora") else intervalo
    for c in sorted(cands, key=lambda c: -c["pontos"]):
        ini, fim = c["inicio"], min(c["inicio"] + c["dur"], duracao - 0.2)
        # capítulo e número dito sempre entram (o número tem de aparecer quando é falado)
        if fim - ini < 2.0 or usado + (fim - ini) > cobertura_max * duracao and c["origem"] != "capitulo" \
                and not (c["modelo"] == "numero" and c.get("ancora")):
            continue
        # ancorado na fala (número dito): quase não pode atrasar; quem cede é a duração dos vizinhos
        limite = ini + (0.6 if c.get("ancora") else ADIAR.get(c["origem"], 0))
        while True:
            choque = [e for e in escolhidos if ini < e["inicio"] + e["dur"] + folga(c, e) and e["inicio"] < fim + folga(c, e)]
            if c.get("ancora") and choque:
                for e in choque:  # dados em fila: o anterior sai mais cedo para o próximo entrar na hora certa
                    if not e.get("ancora") or e.get("manual"):
                        continue
                    if e["inicio"] < ini and ini - FILA - e["inicio"] >= DUR_MIN:
                        usado -= e["dur"] - (ini - FILA - e["inicio"])
                        e["dur"] = round(ini - FILA - e["inicio"], 2)
                    elif e["inicio"] > ini and e["inicio"] - FILA - ini >= DUR_MIN:
                        fim = min(fim, e["inicio"] - FILA)
                choque = [e for e in escolhidos if ini < e["inicio"] + e["dur"] + folga(c, e) and e["inicio"] < fim + folga(c, e)]
            if not choque:
                break
            ini = max(e["inicio"] + e["dur"] + intervalo for e in choque)
            fim = min(ini + c["dur"], duracao - 0.2)
            if ini > limite:
                break
        if choque:
            continue
        c["inicio"] = round(ini, 2)
        c["dur"] = round(fim - ini, 2)
        escolhidos.append(c)
        usado += fim - ini
    return sorted(escolhidos, key=lambda c: c["inicio"])


def planejar(projeto):
    cands, fontes, duracao = candidatos(projeto)
    eventos.debug("gráficos: candidatos", n=len(cands))
    antigos = projeto.carregar_json("graficos.json") if projeto.caminho("graficos.json").exists() else []
    fixos = [c for c in antigos if c.get("manual")]
    plano = agendar(cands, duracao, fixos=fixos, **projeto.cfg.get("graficos", {}).get("agenda", {}))
    if fixos:
        print(f"  {len(fixos)} gráficos editados à mão mantidos")
    for n, c in enumerate(plano, 1):
        eventos.progresso(n, len(plano), f"{c['modelo']} {c['inicio']:.0f}s")
        if c["modelo"] == "citacao" and not c.get("roteiro") and not c.get("manual"):
            c.update(_preparar_citacao(c, fontes, projeto))
    projeto.salvar_json("graficos.json", plano)
    por_tipo = {}
    for c in plano:
        por_tipo[c["modelo"]] = por_tipo.get(c["modelo"], 0) + 1
    print(f"  {len(plano)} gráficos de {len(cands)} candidatos: {por_tipo}")
    return plano


def _chave(c, cor, w, h):
    extra = [c.get("efeito"), c.get("caixas")] if c.get("efeito") or c.get("caixas") else []
    return hashlib.sha1(json.dumps([c["modelo"], c["dados"], c["dur"], cor] + ([w, h] if h > w else []) + extra,
                                   sort_keys=True, ensure_ascii=False).encode()).hexdigest()[:10]


def peca(c, pasta, w, h, pag=None):
    """(modelo, dados) de um item do graficos.json, com efeito e caixas; None se a citação não achar o trecho.
    `pag`: PNG da página do PDF (citação)."""
    d = dict(c["dados"])
    if c["modelo"] == "citacao":
        p = pecas.citacao(d.pop("arquivo"), d.pop("trecho"), pag or pasta / "pag_previa.png",
                          pagina=d.pop("pagina"), vertical=h > w, **d)
    else:
        p = getattr(pecas, c["modelo"])(**d)
    if not p:
        return None
    return p[0], dict(p[1], efeito=c.get("efeito"), caixas=c.get("caixas"))


def renderizar(projeto):
    """Renderiza o graficos.json. Motor `[graficos] motor`: "effectcraft" (padrão: cada peça também vira um
    `.ecproj` editável) ou "html" (Chromium). Um `.ecproj` salvo à mão no EffectCraft (mais novo que a geração)
    é renderizado como está e a peça vira `manual` (o replanejamento a mantém)."""
    from esteira.graficos import effectcraft
    plano = projeto.carregar_json("graficos.json")
    g = projeto.cfg.get("graficos", {})
    cor = g.get("cor", "#ffd400")
    w, h = projeto.cfg["video"]["largura"], projeto.cfg["video"]["altura"]
    fps = projeto.cfg["video"]["fps"]
    motor = g.get("motor", "effectcraft")
    if motor == "effectcraft" and not effectcraft.disponivel():
        eventos.aviso("effectcraft-cli não encontrado: gráficos pelo Chromium (HTML)")
        motor = "html"
    pasta = projeto.caminho("graficos")
    pasta.mkdir(exist_ok=True)
    rel = lambda a: str(Path(a).relative_to(projeto.pasta))
    editados = 0
    for n, c in enumerate(plano, 1):
        eventos.progresso(n, len(plano), f"{c['modelo']} {c['inicio']:.0f}s")
        ecp = projeto.pasta / c["ecproj"] if c.get("ecproj") else None
        if motor == "effectcraft" and ecp and ecp.exists() and ecp.stat().st_mtime > c.get("ec_gerado", 0) + 1:
            # editado à mão no EffectCraft: renderiza o projeto como está, com outro nome (o .mov antigo fica)
            mt = ecp.stat().st_mtime
            mov = ecp.with_name(f"{ecp.stem.split('_ec')[0]}_ec{int(mt)}.mov")
            effectcraft.renderizar(ecp, mov, w=w, h=h)
            c.update(arquivo=rel(mov), ec_gerado=mt, manual=True, manual_ec=True)
            editados += 1
            continue
        if c.get("manual_ec") and c.get("arquivo") and (projeto.pasta / c["arquivo"]).exists():
            continue
        arq = pasta / f"{c['modelo']}_{_chave(c, cor, w, h)}.mov"
        c["arquivo"] = rel(arq)
        ecp = arq.with_suffix(".ecproj")
        precisa_ec = motor == "effectcraft" and not ecp.exists()
        if arq.exists() and not precisa_ec:
            continue
        pc = peca(c, pasta, w, h, pasta / f"pag_{arq.stem}.png")
        if not pc:
            eventos.aviso(f"citação em {c['inicio']:.0f}s: trecho não achado no PDF; gráfico pulado")
            c["arquivo"] = None
            continue
        if motor == "effectcraft":
            effectcraft.construir(*pc, c["dur"], ecp, w, h, cor, fps)
            if not arq.exists():  # um .mov já feito (ex.: pelo HTML) não é refeito só para ganhar o .ecproj
                effectcraft.renderizar(ecp, arq, w=w, h=h)
            c.update(ecproj=rel(ecp), ec_gerado=ecp.stat().st_mtime)
        else:
            render.renderizar(*pc, c["dur"], arq, cor=cor, paralelo=g.get("paralelo", 6), w=w, h=h, fps=fps)
    projeto.salvar_json("graficos.json", plano)
    if editados:
        print(f"  {editados} gráficos editados à mão no EffectCraft renderizados")
    print(f"  {sum(1 for c in plano if c.get('arquivo'))} gráficos renderizados em graficos/ ({motor})")
