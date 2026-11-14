"""Diretor: cada frase da narração → cena do cardápio do estilo, no instante em que a palavra-âncora é dita.

A IA local escolhe (prompt `estudio_cena`, esquema `bancada.Cena`); o código valida (cena permitida, âncora
dentro da frase, nenhum número inventado) e devolve o erro ao modelo uma vez. O que falhar duas vezes cai na regra
fixa; só com "socorro do Claude" ligado nas Opções vai antes ao Claude em UMA chamada em lote (teto: `CLAUDE_MAX`). Depois, o
código cuida do tempo (âncora → início, fim da frase → saída), do orçamento de takeover e da variedade.
Saída: `<ep>/estudio/mapa.json` (o mesmo mapa serve aos dois formatos). Cenas `manual: true` são mantidas.
Trechos com apontamento (`apontamento.py`) têm a cena fixada pela pessoa: a IA local só preenche âncora, título e
valores, e as regras de variedade/orçamento não trocam essa cena (`por: "voce"`).
"""
import json
import re

from pydantic import BaseModel

from esteira.bench import SCENES, NUMERIC, Scene, normalize, numbers
from esteira.core import events
from esteira.ai import local

# cenas só de motion (fundo próprio, cobrem a mídia); as outras ficam sobre a mídia
TAKEOVER = {"contador", "barras_comparacao", "versus", "linha_do_tempo", "pergunta_destaque", "titulo_capitulo",
            "anel_percentual", "grade_proporcao", "equacao", "grafico_linha", "ranking", "lettering"}
CLAUDE_MAX = 0.2  # fração das frases que pode ir ao Claude


def problems(sentence, r: Scene, permitidas):
    errors = []
    if r.cena not in permitidas:
        errors.append(f"a cena '{r.cena}' não está no cardápio deste estilo")
    if r.cena != "midia" and not (r.ancora.strip() and normalize(r.ancora) in normalize(sentence)):
        errors.append(f"a âncora '{r.ancora}' não está escrita na frase; copie palavras exatas dela")
    invented = set().union(*[numbers(v.valor) for v in r.valores], numbers(r.titulo)) - numbers(sentence)
    if invented:
        errors.append(f"números que não foram ditos: {', '.join(sorted(invented))}")
    if r.cena in NUMERIC and numbers(sentence) and not r.valores:
        errors.append("cena numérica sem os valores ditos na frase")
    return errors


def rule(sentence, permitidas):
    """Plano B sem LLM: número → contador, pergunta → pergunta, resto → mídia."""
    ns = re.findall(r"(?:R\$\s*)?\d[\d.,]*\s*%?", sentence)
    if ns and "contador" in permitidas:
        return Scene(cena="contador", ancora=ns[0].strip(), titulo=" ".join(sentence.split()[:5])[:60],
                    valores=[{"rotulo": "", "valor": ns[0].strip()[:20]}])
    if sentence.strip().endswith("?") and "pergunta_destaque" in permitidas:
        return Scene(cena="pergunta_destaque", ancora=sentence.split()[0], titulo=sentence[:60], valores=[])
    return Scene(cena="midia", ancora="", titulo="", valores=[])


def _examples(style):
    """Exemplos aprovados + os exemplos dos gatilhos do estilo (o guia que a IA local segue nas frases sem gatilho)."""
    lines = [f'- "{e.frase}" → {e.cena}' + (f' ("{e.titulo}")' if e.titulo else "") for e in style.exemplos]
    lines += [f'- "{x}" → {g.peca} (gatilho {g.nome})' for g in getattr(style, "gatilhos", []) if g.ativo and g.peca
               for x in g.exemplos[:2]]
    return "\n".join(lines) or "(nenhum)"


def _marked(sentence, scene, r):
    """Cena fixada no apontamento: usa o que a IA preencheu se veio na cena certa; senão o mínimo pela frase."""
    if r and r.cena == scene:
        return r
    words = sentence.split()
    return Scene(cena=scene, ancora=" ".join(words[:2])[:60], titulo=" ".join(words[:8])[:60], valores=[])


def choose(sentences, style, marks=None, gat=None):
    """[(i, Cena, por)] para cada frase com tempo suficiente. `marcas`: {i: cena} do apontamento; `gat`: {i: detecção}
    dos gatilhos (`gatilhos.aplicar`) — a peça do gatilho vale como marca, com `por: "gatilho"`."""
    from esteira.studio.marking import NONE
    marks = marks or {}
    gat = gat or {}
    permitidas = style.regras.cardapio()
    catalog = "\n".join(f"- {k}: {SCENES[k]}" for k in permitidas)
    choices, failures = [], []
    for i, f in enumerate(sentences):
        events.progress(i + 1, len(sentences), f["texto"][:40])
        scene = marks.get(i)
        by_fixo = "voce"
        g = gat[i]["gatilho"] if i in gat else None
        # sem peça: no apresentador fica na câmera/B-roll; no dark a IA escolhe como antes
        if not scene and g and (g.peca or style.modo == "apresentador"):
            if not g.peca or g.peca not in SCENES or g.peca == "midia":
                choices.append((i, Scene(cena="midia", ancora="", titulo="", valores=[]), "gatilho"))
                continue
            scene, by_fixo = g.peca, "gatilho"
        if scene == NONE:
            choices.append((i, Scene(cena="midia", ancora="", titulo="", valores=[]), "voce"))
            continue
        before = sentences[i - 1]["texto"] if i else ""
        base = local.prompt("studio_scene", frase=f["texto"], antes=before, catalogo=catalog, guia=style.guia,
                            exemplos=_examples(style))
        if scene:
            base = local.Prompt(f"{base}\n\nThe scene for this segment was already chosen by the person: {scene} "
                                f"({SCENES[scene]}). Respond with this scene and fill in only the anchor, the title and "
                                "the numbers said.")
            base.name = "studio_scene"
            perm = permitidas + [scene]
            r = local.ask(base, Scene, max_tokens=400, operation="studio_scene")
            ok = r and not problems(f["texto"], r, perm)
            choices.append((i, _marked(f["texto"], scene, r if ok else None), by_fixo))
            continue
        r = local.ask(base, Scene, max_tokens=400, operation="studio_scene")
        errors = problems(f["texto"], r, permitidas) if r else ["sem resposta"]
        if errors and r:
            text = local.Prompt(f"{base}\n\nYour previous answer was rejected: {'; '.join(errors)}. Fix it.")
            text.name = "studio_scene"
            r = local.ask(text, Scene, max_tokens=400, operation="studio_scene")
            errors = problems(f["texto"], r, permitidas) if r else ["sem resposta"]
        if errors:
            failures.append(i)
            choices.append((i, None, None))
        else:
            choices.append((i, r, "local"))
    if failures:
        from esteira.core import options
        resolvidas = _escalate(sentences, failures, permitidas, catalog, style) if options.read()["claude_fallback"] else {}
        choices = [(i, *(resolvidas.get(i) or (rule(sentences[i]["texto"], permitidas), "regra")))
                    if r is None else (i, r, by_choice) for i, r, by_choice in choices]
    return choices


class _Batch(BaseModel):
    cenas: list[Scene]


def _escalate(sentences, failures, permitidas, catalog, style):
    """Uma chamada ao Claude com as frases que a IA local errou duas vezes (até CLAUDE_MAX do total)."""
    cap = max(1, int(len(sentences) * CLAUDE_MAX))
    if not failures or len(failures) > cap * 3:
        return {}
    from esteira.ai import claude
    target = failures[:cap]
    dossier = (f"Channel guide: {style.guia}\nAllowed scenes:\n{catalog}\n\nFor each sentence (in Brazilian "
              "Portuguese), choose the scene, the anchor (exact words of the sentence), a short title in Brazilian "
              "Portuguese and only the numbers said. Respond in the same order.\n"
              + "\n".join(f"{n + 1}. {sentences[i]['texto']}" for n, i in enumerate(target)))
    r = claude.query(dossier, _Batch, {"claude": {}}, "estudio", "estudio_cena")
    if not r or len(r.cenas) != len(target):
        return {}
    return {i: (c, "claude") for i, c in zip(target, r.cenas, strict=True)
            if not problems(sentences[i]["texto"], c, permitidas)}


def _start(sentence, ancora, words):
    """Instante da 1ª palavra da âncora dentro da frase (cai no início da frase se não achar)."""
    inside = [p for p in words if sentence["ini"] - 0.05 <= p["ini"] < sentence["fim"]]
    target = normalize(ancora).split()
    if target:
        norm = [normalize(p["p"]) for p in inside]
        for k in range(len(norm)):
            # 1ª e 2ª palavra batem (o Whisper às vezes parte números, então não exige a âncora inteira)
            if norm[k] == target[0] and norm[k + 1:k + 2] == target[1:2]:
                return inside[k]["ini"]
    return sentence["ini"]


def time(sentences, choices, words, style, duration, gat=None):
    """Tempos de cada cena + orçamento de takeover + variedade; devolve a lista do mapa. `gat`: detecções dos
    gatilhos — gravam `gatilho`, `cor` e `layout_pedido` (B-roll pedido fica como cena de mídia)."""
    from esteira.studio.triggers import LAYOUTS
    rg = style.regras
    gat = gat or {}
    scenes = []
    for i, r, by_choice in choices:
        f = sentences[i]
        d = gat.get(i)
        lay = LAYOUTS.get(d["gatilho"].layout) if d else None
        if r is None or (r.cena == "midia" and not r.titulo and lay != "broll"):
            continue
        if f["fim"] - f["ini"] < rg.dur_min * 0.6 and not numbers(f["texto"]) and by_choice != "voce":
            continue  # frase curta demais: a cena anterior segue
        t = max(0.0, _start(f, r.ancora, words) - 0.08)
        scenes.append({"frase_i": i, "frase": f["texto"], "cena": r.cena, "t": round(t, 3),
                      "ate": round(f["fim"] + 0.4, 3), "titulo": r.titulo, "ancora": r.ancora,
                      "valores": [v.model_dump() for v in r.valores], "por": by_choice})
        if d:
            scenes[-1].update({"gatilho": d["gatilho"].id, "cor": d["cor"], "layout_pedido": lay})
    scenes.sort(key=lambda c: c["t"])
    for a, b in zip(scenes, scenes[1:] + [None], strict=True):
        if b:
            a["ate"] = round(min(a["ate"], b["t"] - 0.05), 3)
        a["ate"] = round(min(a["ate"], duration), 3)
        cap = rg.takeover_max_s if a["cena"] in TAKEOVER else rg.sobreposicao_max_s
        a["ate"] = round(min(a["ate"], a["t"] + cap), 3)
    scenes = [c for c in scenes if c["ate"] - c["t"] >= rg.dur_min * 0.75 or c["por"] == "voce"]
    # a mesma cena com o mesmo título em trechos seguidos é uma cena só (a primeira se estende)
    joined = []
    for c in scenes:
        a = joined[-1] if joined else None
        if a and a["cena"] == c["cena"] and a["titulo"] == c["titulo"] and c["t"] - a["ate"] < 1.0:
            cap = rg.takeover_max_s if a["cena"] in TAKEOVER else rg.sobreposicao_max_s
            a["ate"] = round(min(c["ate"], a["t"] + cap), 3)
        else:
            joined.append(c)
    scenes = joined
    # variedade: a mesma cena de sobreposição 3× seguidas → a do meio vira só mídia (respiro)
    for a, b, c in zip(scenes, scenes[1:], scenes[2:], strict=False):
        if a["cena"] == b["cena"] == c["cena"] and b["cena"] not in TAKEOVER and b["por"] != "voce":
            b["cena"] = "midia"
    scenes = [c for c in scenes if c["cena"] != "midia" or c.get("layout_pedido") == "broll"]
    # orçamento: takeover passa do teto → perguntas e capítulos viram frase de impacto sobre a mídia
    def time_tk():
        return sum(c["ate"] - c["t"] for c in scenes if c["cena"] in TAKEOVER)
    for c in sorted(scenes, key=lambda c: c["cena"] not in ("pergunta_destaque", "titulo_capitulo")):
        if time_tk() <= rg.takeover_max * duration:
            break
        if c["cena"] in TAKEOVER and c["por"] != "voce":
            c["cena"] = "frase_destaque" if c["cena"] in ("pergunta_destaque", "titulo_capitulo") else c["cena"]
    for n, c in enumerate(scenes):
        c["id"] = n
        c["takeover"] = c["cena"] in TAKEOVER
    return scenes


def spans(sentences, words, max_s):
    """Frases longas viram trechos nas pausas de pontuação (vírgula, ponto e vírgula, dois-pontos), cada um com o
    seu tempo pelas palavras faladas; pedaço com menos de 4 palavras cola no vizinho."""
    output = []
    for f in sentences:
        parts = [x for x in re.split(r"(?<=[,;:])\s+", f["texto"]) if x.strip()]
        if f["fim"] - f["ini"] <= max_s or len(parts) < 2:
            output.append({"texto": f["texto"], "ini": f["ini"], "fim": f["fim"]})
            continue
        joined = []
        for x in parts:
            if joined and (len(joined[-1].split()) < 4 or len(x.split()) < 4):
                joined[-1] += " " + x
            else:
                joined.append(x)
        spoken = [p for p in words if f["ini"] - 0.05 <= p["ini"] < f["fim"]]
        k = 0
        for n, x in enumerate(joined):
            qtd = len(x.split())
            group = spoken[k:k + qtd] if n < len(joined) - 1 else spoken[k:]
            k += qtd
            start = group[0]["ini"] if group else f["ini"]
            end = group[-1]["fim"] if group else f["fim"]
            output.append({"texto": x, "ini": start, "fim": max(end, start + 0.3)})
    return output


def _media_times(project):
    """[{ini}] das trocas de mídia do plano no tempo do corte (para a conferência de ritmo)."""
    file = project.folder_path / "plano.json"
    if not file.exists():
        return []
    from esteira.studio import cut
    new = cut.new(project)
    return [{"ini": new(c["inicio"])} for c in json.loads(file.read_text())["cenas"] if c.get("midia")]


def pace(scenes, sentences, style, profile, media, duration):
    """Perfil de ritmo no mapa: sem capítulos (curto), anti-repetição, gancho e conferência. → (cenas, avisos)."""
    from esteira.studio import rhythm
    cardapio = set(style.regras.cardapio())
    swaps = {k: v for k, v in rhythm.SWAPS.items() if v in cardapio}
    scenes = rhythm.without_chapters(scenes, profile)
    scenes = rhythm.anti_repetition(scenes, profile, swaps)
    scenes = [c for c in scenes if c["cena"] != "midia" or c.get("layout_pedido") == "broll"]
    scenes = rhythm.hook(scenes, profile, sentences)
    for n, c in enumerate(scenes):
        c["id"] = n
        c["takeover"] = c["cena"] in TAKEOVER
    return scenes, rhythm.cross_check(scenes, media, duration, profile)


def direct(project, style, profile=None):
    """Escreve `<ep>/estudio/mapa.json`; devolve o mapa. `perfil`: ritmo do vídeo (padrão: o do roteiro/formato)."""
    from esteira.studio import rhythm
    profile = profile or rhythm.profile_of(project)
    folder = project.folder_path / "estudio"
    folder.mkdir(exist_ok=True)
    from esteira.studio import cut
    sentences, words = cut.sentences(project), cut.words(project)
    duration = sentences[-1]["fim"] + 1.0 if sentences else 0
    sentences = spans(sentences, words, style.regras.trecho_max_s)
    file = folder / "mapa.json"
    manuais = [c for c in json.loads(file.read_text())["cenas"] if c.get("manual")] if file.exists() else []
    from esteira.studio import marking, triggers
    gat = triggers.apply(sentences, style.gatilhos)
    choices = choose(sentences, style, marking.marks(project, sentences), gat)
    scenes = time(sentences, choices, words, style, duration, gat)
    if manuais:  # o que foi ajustado à mão fica; a cena automática da mesma frase sai
        fixas = {c["frase_i"] for c in manuais}
        scenes = sorted([c for c in scenes if c["frase_i"] not in fixas] + manuais, key=lambda c: c["t"])
        for n, c in enumerate(scenes):
            c["id"] = n
    scenes, warnings = pace(scenes, sentences, style, profile, _media_times(project), duration)
    by_choice = {k: sum(1 for _, r, p in choices if p == k) for k in ("voce", "gatilho", "local", "claude", "regra")}
    by_choice["ritmo"] = sum(1 for c in scenes if c.get("por") == "ritmo" or c.get("repeticao"))
    mapping = {"estilo": style.id, "versao": style.versao, "duracao": duration, "decisoes": by_choice, "cenas": scenes,
            "ritmo": {"perfil": profile.id, "avisos": warnings}}
    file.write_text(json.dumps(mapping, ensure_ascii=False, indent=1))
    tk = sum(c["ate"] - c["t"] for c in scenes if c["takeover"])
    print(f"  mapa: {len(scenes)} cenas · takeover {tk / max(duration, 1):.0%} do tempo · decisões {by_choice} · "
          f"ritmo {profile.id} ({len(warnings)} aviso(s))")
    return mapping
