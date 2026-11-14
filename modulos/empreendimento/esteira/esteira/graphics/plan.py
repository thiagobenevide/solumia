"""Etapa graficos: decide que gráfico entra, quando e com que dados (graficos.json) e renderiza os .mov.

Candidatos vêm do código (capítulos do roteiro, frases com números, menções a estudos, *destaques*) e das
notas de cena do roteiro. O LLM local escreve o conteúdo e dá o impacto de cada um; o agendador escolhe
pelos pontos sem sobrepor e sem passar da densidade máxima. Citações usam a página real do PDF quando ele
é achado (vault ou acesso aberto); sem PDF, viram tarja de fonte.
"""
import hashlib
import json
import re
from pathlib import Path
from typing import Optional

from pydantic import BaseModel, Field

from esteira.core import events
from esteira.graphics import articles, pieces, render
from esteira.ai import local

DURATION = {"caixas": 4.0, "capitulo": 3.2, "numero": 4.6, "comparacao": 7.0, "frase": 3.0, "fonte": 5.0}
WEIGHT = {"capitulo": 10, "citacao": 8, "nota": 5, "numero": 3, "frase": 2, "fonte": 1}
RE_NUM = re.compile(r"\d[\d.,]*\s*(%|por cento|mil\b|milh|bilh|vezes|anos?\b|meses|reais)|R\$\s*\d", re.I)
RE_STUDY = re.compile(r"estud|pesquis|artigo|publica|economist|cientist|autores|revista|universidade", re.I)


class Number(BaseModel):
    usar: bool
    numero: str = Field("", max_length=16)
    legenda: str = Field("", max_length=90)
    rotulo: str = Field("", max_length=40)
    fonte: int = -1
    impacto: int = Field(3, ge=1, le=5)


Short = Field("", max_length=80)


class Item(BaseModel):
    titulo: str = Field(max_length=40)
    valor: str = Field("", max_length=16)
    detalhe: str = Field("", max_length=60)


class Note(BaseModel):
    tipo: str = Field(pattern="^(lista|numero|comparacao|frase|fonte|nenhum)$")
    impacto: int = Field(3, ge=1, le=5)
    titulo: str = Short
    rotulo: str = Short
    itens: list[Item] = Field([], max_length=4)
    numero: str = Field("", max_length=16)
    legenda: str = Short
    texto: str = Short
    nome_a: str = Field("", max_length=30)
    itens_a: list[str] = Field([], max_length=3)
    nome_b: str = Field("", max_length=30)
    itens_b: list[str] = Field([], max_length=3)
    linha1: str = Short
    linha2: str = Short


class Span(BaseModel):
    indice: int
    traducao: str = Field("", max_length=260)


class Terms(BaseModel):
    termos: list[str] = Field(max_length=6)


def _speech_to_sentence(script_txt):
    """Índice da 1ª frase (ler_roteiro) de cada fala (linha) do roteiro.txt."""
    output, k = [], 0
    for line in script_txt.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        output.append(k)
        k += len([f for f in re.split(r"(?<=[.!?…])\s+", line) if f.strip()])
    return output


def _texts(items):
    """O LLM às vezes devolve objetos (JSON ou dict do Python) dentro da lista de textos: vira "valor título"."""
    import ast
    output = []
    for it in items:
        d = None
        if it.strip().startswith("{"):
            for read in (json.loads, ast.literal_eval):
                try:
                    d = read(it)
                    break
                except (ValueError, SyntaxError):
                    pass
            # {titulo: 'x', valor: 'y'}: chaves sem aspas
            d = d or dict(re.findall(r"(\w+)\s*:\s*['\"]([^'\"]*)['\"]", it)) or None
        output.append(" ".join(str(v) for v in (d.get("valor"), d.get("titulo")) if v) if isinstance(d, dict) else it)
    return [s for s in output if s][:3]


def _digits(s):
    return re.sub(r"[^\d]", "", s)


def _number_in_speech(number, speech):
    """O número do card tem de estar na fala (o LLM às vezes arredonda: "400%" para "436%")."""
    d = _digits(number)
    return bool(d) and "/" not in number and any(d == _digits(m) for m in re.findall(r"\d[\d.,]*", speech))


RE_NUMBER = re.compile(r"(R\$\s*)?\d[\d.,]*(?:\s*(%|por cento|mil(?:hões|hão)?\b|bilh(?:ões|ão)|vezes|anos?\b|"
                       r"meses|reais))?", re.I)


def _numbers_of_sentence(text):
    """[(número como vai na tela, legenda)] de cada número com unidade da frase ("48%", "24 milhões",
    "R$ 400"); a legenda são as palavras que vêm depois dele (até 7, sem passar da pontuação nem do próximo
    número)."""
    output = []
    for m in RE_NUMBER.finditer(text):
        if not (m.group(1) or m.group(2)):
            continue  # número sem unidade (ano, "3 motivos"): fica para o LLM
        number = re.sub(r"\s+", " ", m.group(0)).strip().replace("por cento", "%").replace(" %", "%")
        rest = re.split(r"[.;:!?]|\s(?=R\$|\d)", text[m.end():])[0].strip(" ,")  # até a pontuação ou o próximo número
        output.append((number, " ".join(rest.split()[:7])))
    return output


ANTICIPATES = 0.35   # s: o gráfico de número começa isto antes da fala (o contador sai do zero quando o número é dito)


def _instant_number(number, words, t0, t1, near=None):
    """Instante (narração editada) em que `numero` é falado entre t0 e t1, ou None; com `perto`, a ocorrência mais
    próxima desse instante (senão a primeira). O Whisper parte números ("12", ",5", "%"): junta a palavra com o
    pedaço decimal seguinte antes de comparar."""
    m = re.search(r"\d[\d.,]*", number)
    target = _digits(m.group()) if m else ""
    if not target:
        return None
    found = []
    for k, w in enumerate(words):
        if not t0 <= w["ini"] <= t1:
            continue
        d = _digits(w["p"])
        if not d:
            continue
        j = k + 1
        while j < len(words) and re.match(r"^[.,]\d", words[j]["p"].strip()) and len(d) < len(target):
            d += _digits(words[j]["p"])
            j += 1
        if d == target:
            if near is None:
                return w["ini"]
            found.append(w["ini"])
    return min(found, key=lambda x: abs(x - near)) if found else None


def _anchor(c, t, anticipates=ANTICIPATES):
    c["inicio"], c["ancora"] = round(max(t - anticipates, 0), 2), round(t, 2)


def _ref(f):
    return f"{f['autores']} ({f['ano']}), {f['revista']}".strip(", ")


def _source_quoted(text, sources):
    """Índice da fonte mencionada na frase (sobrenome do 1º autor, revista ou ano + palavra de estudo)."""
    best, note_max = None, 0
    for k, f in enumerate(sources):
        surname = re.split(r"[ ,]", f["autores"])[0]
        note = 3 * (len(surname) > 2 and surname.lower() in text.lower())
        note += 3 * bool(f["revista"] and f["revista"].lower() in text.lower())
        note += 1 * bool(f["ano"][:4] in text and RE_STUDY.search(text))
        if note > note_max:
            best, note_max = k, note
    return best if note_max >= 3 or (note_max == 1 and sum(f["ano"][:4] in text for f in sources) == 1) else None


def candidates(project):
    cfg = project.cfg
    rot = json.loads(project.path_of("roteiro.json").read_text()) if project.path_of("roteiro.json").exists() else {}
    sentences = project.load_json("frases.json")
    transc = project.load_json("transcricao.json")
    duration, words = transc["duracao"], transc["palavras"]
    sources = rot.get("fontes", [])
    mapping = _speech_to_sentence(project.script_path().read_text())

    def t_speech(k):
        """Instante da 1ª frase com tempo a partir da fala k."""
        for i in range(mapping[min(k, len(mapping) - 1)] if mapping else 0, len(sentences)):
            if sentences[i]["ini"] is not None:
                return sentences[i]["ini"]
        return None

    c = []
    title = rot.get("titulo")
    if title and cfg["edicao"].get("titulo_inicio", True):
        c.append({"modelo": "capitulo", "inicio": 0.4, "dados": {"nome": title, "rotulo": ""}, "impacto": 5,
                  "origem": "titulo"})
    for cap in rot.get("capitulos", []):
        t = t_speech(cap["fala"])
        if cap["parte"] >= 2 and t is not None and cfg.get("graficos", {}).get("capitulos", True):
            c.append({"modelo": "capitulo", "inicio": max(t - 0.3, 0), "origem": "capitulo", "impacto": 4,
                      "dados": {"nome": cap["nome"], "rotulo": f"PARTE {cap['parte']}"}})

    # Citações marcadas no roteiro ([!cite]): PDF, página e trecho já conferidos no vault, sem LLM
    quoted = set()
    for cit in rot.get("citacoes", []):
        t = t_speech(max(cit["fala"], 0))
        if not cit.get("ok") or t is None:
            continue
        k = _source_quoted(f"{cit.get('autores', '')} {cit.get('revista', '')}", sources)
        if k is not None:
            quoted.add(k)
        f = sources[k] if k is not None else {}
        c.append({"modelo": "citacao", "inicio": t, "origem": "citacao", "impacto": 7, "roteiro": True,
                  "dados": {"arquivo": cit["arquivo"], "trecho": cit["en"], "pagina": cit["pagina"] - 1,
                            "titulo": cit.get("titulo") or f.get("titulo", ""),
                            "autores": f.get("autores") or cit.get("autores", ""),
                            "revista": cit.get("revista") or f.get("revista", ""),
                            "ano": (cit.get("ano") or f.get("ano", ""))[:4], "citacao": cit.get("pt", "")}})

    # Citações automáticas: 1ª menção de cada fonte que o roteiro não marcou
    for i, f in enumerate(sentences):
        if f["ini"] is None:
            continue
        k = _source_quoted(f["texto"], sources)
        if k is None or k in quoted:
            continue
        quoted.add(k)
        c.append({"modelo": "citacao", "inicio": f["ini"], "origem": "citacao", "impacto": 5, "fonte": k,
                  "fala": " ".join(x["texto"] for x in sentences[i:i + 3])})

    # Números
    for i, f in enumerate(sentences):
        if f["ini"] is None or not RE_NUM.search(f["texto"]):
            continue
        ctx = " ".join(x["texto"] for x in sentences[max(i - 1, 0):i + 2])
        r = local.ask(local.prompt("graphic_number", fala=f["texto"], contexto=ctx,
                                         fontes="; ".join(f"{k}: {_ref(x)}" for k, x in enumerate(sources)) or "nenhuma"),
                            Number)
        if r and r.usar and r.numero and _number_in_speech(r.numero, f["texto"]):
            source = _ref(sources[r.fonte]) if 0 <= r.fonte < len(sources) else ""
            c.append({"modelo": "numero", "inicio": f["ini"], "origem": "numero", "impacto": r.impacto,
                      "dados": {"texto": r.numero, "legenda": r.legenda, "fonte": source, "rotulo": r.rotulo}})
            # entra quando o número é DITO, não no começo da frase
            t = _instant_number(r.numero, words, f["ini"] - 2, (f.get("fim") or f["ini"] + 20) + 3)
            if t is not None:
                _anchor(c[-1], t)
            else:
                events.debug("gráfico de número sem a fala do número", numero=r.numero, frase=f["texto"][:80])
        # todo número dito aparece: os que o LLM não escolheu (ou o 2º número da frase) viram gráfico simples
        done = {_digits(c[-1]["dados"]["texto"])} if r and r.usar and c and c[-1]["origem"] == "numero" else set()
        for number, caption in _numbers_of_sentence(f["texto"]):
            if _digits(number) in done:
                continue
            done.add(_digits(number))
            t = _instant_number(number, words, f["ini"] - 2, (f.get("fim") or f["ini"] + 20) + 3)
            if t is None:
                continue
            c.append({"modelo": "numero", "inicio": f["ini"], "origem": "numero", "impacto": 3,
                      "dados": {"texto": number, "legenda": caption, "fonte": "", "rotulo": ""}})
            _anchor(c[-1], t)

    # Notas de cena do roteiro
    for note in rot.get("notas", []):
        t = t_speech(note["antes_da_fala"])
        if t is None:
            continue
        k0 = mapping[min(note["antes_da_fala"], len(mapping) - 1)] if mapping else 0
        speeches = " ".join(x["texto"] for x in sentences[k0:k0 + 3])
        r = local.ask(local.prompt("graphic_note", nota=note["texto"], falas=speeches), Note)
        if not r or r.tipo not in ("lista", "numero", "comparacao", "frase", "fonte"):
            continue
        d = {"lista": lambda: {"itens": [i.model_dump() for i in r.itens], "titulo": r.titulo, "rotulo": r.rotulo},
             "numero": lambda: {"texto": r.numero, "legenda": r.legenda, "rotulo": r.rotulo},
             "comparacao": lambda: {"nome_a": r.nome_a, "itens_a": _texts(r.itens_a), "nome_b": r.nome_b,
                                    "itens_b": _texts(r.itens_b)},
             "frase": lambda: {"texto": r.texto},
             "fonte": lambda: {"linha1": r.linha1, "linha2": r.linha2}}[r.tipo]()
        if r.tipo == "lista" and len(d["itens"]) < 2 or r.tipo == "numero" and not re.search(r"\d", r.numero):
            continue
        if r.tipo == "fonte" and any(re.split(r"[ ,]", sources[k]["autores"])[0].lower() in r.linha1.lower()
                                     for k in quoted):
            continue  # a fonte já tem citação própria
        c.append({"modelo": r.tipo, "inicio": t, "origem": "nota", "impacto": r.impacto, "dados": d,
                  "nota": note["texto"][:120]})
        if r.tipo == "numero":
            tn = _instant_number(r.numero, words, t - 20, t + 25, near=t)  # a nota pode vir depois da fala
            if tn is not None:
                _anchor(c[-1], tn)
        elif r.tipo == "lista":
            _sync_list(c[-1], words, t)

    # *Destaques* do roteiro → frase cinética
    for f in sentences:
        for d in f.get("destaques", []):
            if f["ini"] is not None and len(d.split()) >= 2:
                c.append({"modelo": "frase", "inicio": f["ini"], "origem": "destaque", "impacto": 2,
                          "dados": {"texto": f"*{d}*"}})
    return c, sources, duration


def _sync_list(c, words, t):
    """Lista de dados "em fila": cada cartão entra quando o valor dele é falado (`tempos`, s desde o início da
    peça). Itens sem valor achado na fala ficam entre os vizinhos."""
    speeches, since = [], t - 5
    for it in c["dados"]["itens"]:
        ti = _instant_number(it.get("valor", ""), words, since, t + 60) if it.get("valor") else None
        speeches.append(ti)
        if ti is not None:
            since = ti
    if not any(x is not None for x in speeches):
        return
    known = [k for k, x in enumerate(speeches) if x is not None]
    for k in range(len(speeches)):
        if speeches[k] is None:
            ant = max((j for j in known if j < k), default=None)
            prox = min((j for j in known if j > k), default=None)
            speeches[k] = (speeches[ant] + 1.5 if ant is not None else speeches[prox] - 1.5)
    _anchor(c, speeches[0], 0.6)
    c["dados"]["tempos"] = [round(max(x - c["inicio"] - 0.15, 0.3), 2) for x in speeches]
    c["dur_min"] = round(c["dados"]["tempos"][-1] + 3.2, 2)


def _prepare_quote(cand, sources, project):
    """Acha PDF + trecho; sem isso, vira tarja de fonte."""
    f = sources[cand["fonte"]]
    strip = {"modelo": "fonte", "dados": {"linha1": f"{f['autores']} ({f['ano']})",
                                          "linha2": f"{f['revista']} {f.get('detalhes', '')}".strip(),
                                          "rotulo": "Estudo"}}
    pdf = articles.find_pdf(f, project.cfg["fontes"].get("artigos"))
    if not pdf:
        return strip
    cands = articles.candidates_span(pdf, cand["fala"])
    if len(cands) < 2:
        r = local.ask(local.prompt("terms_en", fala=cand["fala"]), Terms)
        if r:
            cands = articles.candidates_span(pdf, cand["fala"], r.termos)
    if not cands:
        return strip
    items = "\n".join(f"{k}. {t[2][:300]}" for k, t in enumerate(cands))
    r = local.ask(local.prompt("graphic_quote", fala=cand["fala"], estudo=_ref(f), trechos=items), Span)
    if not r or not 0 <= r.indice < len(cands):
        return strip
    _, page, span = cands[r.indice]
    return {"modelo": "citacao", "dados": {"arquivo": str(pdf), "trecho": span, "pagina": page,
                                           "titulo": f["titulo"], "autores": f["autores"],
                                           "revista": f"{f['revista']} · {f.get('detalhes', '')}".strip(" ·"),
                                           "ano": f["ano"][:4], "citacao": r.traducao}}


READING = 3.0  # palavras por segundo que dá para ler na tela (EN + PT da citação)


def _duration(c):
    if c["modelo"] == "citacao":
        # tempo de ler o trecho original (EN) e a tradução (PT) com calma, depois da câmera chegar no trecho
        d = c.get("dados") or {}
        words = len((d.get("trecho") or "").split()) + len((d.get("citacao") or "").split())
        return round(min(max(6.5 + words / READING, 13.0), 26.0), 1) if words else 15.0
    if c["modelo"] == "lista":
        return max(2.4 + 1.1 * len(c["dados"]["itens"]), c.get("dur_min", 0))
    return DURATION[c["modelo"]]


POSTPONE = {"citacao": 12.0, "nota": 5.0, "numero": 3.0}  # s que um gráfico pode atrasar para não colidir
QUEUE, DURATION_MIN = 0.3, 2.2  # números seguidos: folga entre eles e o mínimo que o anterior fica na tela


def schedule(cands, duration, interval=1.5, coverage_max=0.4, fixos=()):
    """Escolhe por pontos (tipo + impacto), sem sobrepor (com folga) e até `cobertura_max` do vídeo.
    Em colisão, o gráfico mais fraco é adiado até ADIAR s (continua perto da fala); depois disso, sai.
    `fixos`: gráficos editados à mão no painel; ficam onde estão e os automáticos desviam deles."""
    for c in cands:
        c["dur"] = _duration(c)
        c["pontos"] = WEIGHT.get(c["origem"], WEIGHT.get(c["modelo"], 1)) + c.get("impacto", 3)
    chosen, used = list(fixos), sum(c["dur"] for c in fixos)
    slack = lambda a, b: QUEUE if a.get("ancora") and b.get("ancora") else interval
    for c in sorted(cands, key=lambda c: -c["pontos"]):
        start, end = c["inicio"], min(c["inicio"] + c["dur"], duration - 0.2)
        # capítulo e número dito sempre entram (o número tem de aparecer quando é falado)
        if end - start < 2.0 or used + (end - start) > coverage_max * duration and c["origem"] != "capitulo" \
                and not (c["modelo"] == "numero" and c.get("ancora")):
            continue
        # ancorado na fala (número dito): quase não pode atrasar; quem cede é a duração dos vizinhos
        limit = start + (0.6 if c.get("ancora") else POSTPONE.get(c["origem"], 0))
        while True:
            clash = [e for e in chosen if start < e["inicio"] + e["dur"] + slack(c, e) and e["inicio"] < end + slack(c, e)]
            if c.get("ancora") and clash:
                for e in clash:  # dados em fila: o anterior sai mais cedo para o próximo entrar na hora certa
                    if not e.get("ancora") or e.get("manual"):
                        continue
                    if e["inicio"] < start and start - QUEUE - e["inicio"] >= DURATION_MIN:
                        used -= e["dur"] - (start - QUEUE - e["inicio"])
                        e["dur"] = round(start - QUEUE - e["inicio"], 2)
                    elif e["inicio"] > start and e["inicio"] - QUEUE - start >= DURATION_MIN:
                        end = min(end, e["inicio"] - QUEUE)
                clash = [e for e in chosen if start < e["inicio"] + e["dur"] + slack(c, e) and e["inicio"] < end + slack(c, e)]
            if not clash:
                break
            start = max(e["inicio"] + e["dur"] + interval for e in clash)
            end = min(start + c["dur"], duration - 0.2)
            if start > limit:
                break
        if clash:
            continue
        c["inicio"] = round(start, 2)
        c["dur"] = round(end - start, 2)
        chosen.append(c)
        used += end - start
    return sorted(chosen, key=lambda c: c["inicio"])


def plan(project):
    cands, sources, duration = candidates(project)
    events.debug("gráficos: candidatos", n=len(cands))
    old = project.load_json("graficos.json") if project.path_of("graficos.json").exists() else []
    fixed = [c for c in old if c.get("manual")]
    plan = schedule(cands, duration, fixos=fixed, **project.cfg.get("graficos", {}).get("agenda", {}))
    if fixed:
        print(f"  {len(fixed)} gráficos editados à mão mantidos")
    for n, c in enumerate(plan, 1):
        events.progress(n, len(plan), f"{c['modelo']} {c['inicio']:.0f}s")
        if c["modelo"] == "citacao" and not c.get("roteiro") and not c.get("manual"):
            c.update(_prepare_quote(c, sources, project))
    project.save_json("graficos.json", plan)
    by_kind = {}
    for c in plan:
        by_kind[c["modelo"]] = by_kind.get(c["modelo"], 0) + 1
    print(f"  {len(plan)} gráficos de {len(cands)} candidatos: {by_kind}")
    return plan


def _key(c, color, w, h):
    extra = [c.get("efeito"), c.get("caixas")] if c.get("efeito") or c.get("caixas") else []
    return hashlib.sha1(json.dumps([c["modelo"], c["dados"], c["dur"], color] + ([w, h] if h > w else []) + extra,
                                   sort_keys=True, ensure_ascii=False).encode()).hexdigest()[:10]


def piece(c, folder, w, h, pag=None):
    """(modelo, dados) de um item do graficos.json, com efeito e caixas; None se a citação não achar o trecho.
    `pag`: PNG da página do PDF (citação)."""
    d = dict(c["dados"])
    if c["modelo"] == "citacao":
        p = pieces.quote(d.pop("arquivo"), d.pop("trecho"), pag or folder / "pag_previa.png",
                          pagina=d.pop("pagina"), vertical=h > w, **d)
    else:
        p = getattr(pieces, c["modelo"])(**d)
    if not p:
        return None
    return p[0], dict(p[1], efeito=c.get("efeito"), caixas=c.get("caixas"))


def render_graphics(project):
    """Renderiza o graficos.json. Motor `[graficos] motor`: "effectcraft" (padrão: cada peça também vira um
    `.ecproj` editável) ou "html" (Chromium). Um `.ecproj` salvo à mão no EffectCraft (mais novo que a geração)
    é renderizado como está e a peça vira `manual` (o replanejamento a mantém)."""
    from esteira.graphics import effectcraft
    plan = project.load_json("graficos.json")
    g = project.cfg.get("graficos", {})
    color = g.get("cor", "#ffd400")
    w, h = project.cfg["video"]["largura"], project.cfg["video"]["altura"]
    fps = project.cfg["video"]["fps"]
    engine = g.get("motor", "effectcraft")
    if engine == "effectcraft" and not effectcraft.available():
        events.warning("effectcraft-cli não encontrado: gráficos pelo Chromium (HTML)")
        engine = "html"
    folder = project.path_of("graficos")
    folder.mkdir(exist_ok=True)
    rel = lambda a: str(Path(a).relative_to(project.folder_path))
    edited = 0
    for n, c in enumerate(plan, 1):
        events.progress(n, len(plan), f"{c['modelo']} {c['inicio']:.0f}s")
        ecp = project.folder_path / c["ecproj"] if c.get("ecproj") else None
        if engine == "effectcraft" and ecp and ecp.exists() and ecp.stat().st_mtime > c.get("ec_gerado", 0) + 1:
            # editado à mão no EffectCraft: renderiza o projeto como está, com outro nome (o .mov antigo fica)
            mt = ecp.stat().st_mtime
            mov = ecp.with_name(f"{ecp.stem.split('_ec')[0]}_ec{int(mt)}.mov")
            effectcraft.render(ecp, mov, w=w, h=h)
            c.update(arquivo=rel(mov), ec_gerado=mt, manual=True, manual_ec=True)
            edited += 1
            continue
        if c.get("manual_ec") and c.get("arquivo") and (project.folder_path / c["arquivo"]).exists():
            continue
        file = folder / f"{c['modelo']}_{_key(c, color, w, h)}.mov"
        c["arquivo"] = rel(file)
        ecp = file.with_suffix(".ecproj")
        needs_ec = engine == "effectcraft" and not ecp.exists()
        if file.exists() and not needs_ec:
            continue
        pc = piece(c, folder, w, h, folder / f"pag_{file.stem}.png")
        if not pc:
            events.warning(f"citação em {c['inicio']:.0f}s: trecho não achado no PDF; gráfico pulado")
            c["arquivo"] = None
            continue
        if engine == "effectcraft":
            effectcraft.build(*pc, c["dur"], ecp, w, h, color, fps)
            if not file.exists():  # um .mov já feito (ex.: pelo HTML) não é refeito só para ganhar o .ecproj
                effectcraft.render(ecp, file, w=w, h=h)
            c.update(ecproj=rel(ecp), ec_gerado=ecp.stat().st_mtime)
        else:
            render.render(*pc, c["dur"], file, cor=color, paralelo=g.get("paralelo", 6), w=w, h=h, fps=fps)
    project.save_json("graficos.json", plan)
    if edited:
        print(f"  {edited} gráficos editados à mão no EffectCraft renderizados")
    print(f"  {sum(1 for c in plan if c.get('arquivo'))} gráficos renderizados em graficos/ ({engine})")
