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


def problems(frase, r: Scene, permitidas):
    erros = []
    if r.cena not in permitidas:
        erros.append(f"a cena '{r.cena}' não está no cardápio deste estilo")
    if r.cena != "midia" and not (r.ancora.strip() and normalize(r.ancora) in normalize(frase)):
        erros.append(f"a âncora '{r.ancora}' não está escrita na frase; copie palavras exatas dela")
    inventados = set().union(*[numbers(v.valor) for v in r.valores], numbers(r.titulo)) - numbers(frase)
    if inventados:
        erros.append(f"números que não foram ditos: {', '.join(sorted(inventados))}")
    if r.cena in NUMERIC and numbers(frase) and not r.valores:
        erros.append("cena numérica sem os valores ditos na frase")
    return erros


def rule(frase, permitidas):
    """Plano B sem LLM: número → contador, pergunta → pergunta, resto → mídia."""
    ns = re.findall(r"(?:R\$\s*)?\d[\d.,]*\s*%?", frase)
    if ns and "contador" in permitidas:
        return Scene(cena="contador", ancora=ns[0].strip(), titulo=" ".join(frase.split()[:5])[:60],
                    valores=[{"rotulo": "", "valor": ns[0].strip()[:20]}])
    if frase.strip().endswith("?") and "pergunta_destaque" in permitidas:
        return Scene(cena="pergunta_destaque", ancora=frase.split()[0], titulo=frase[:60], valores=[])
    return Scene(cena="midia", ancora="", titulo="", valores=[])


def _examples(estilo):
    """Exemplos aprovados + os exemplos dos gatilhos do estilo (o guia que a IA local segue nas frases sem gatilho)."""
    linhas = [f'- "{e.frase}" → {e.cena}' + (f' ("{e.titulo}")' if e.titulo else "") for e in estilo.exemplos]
    linhas += [f'- "{x}" → {g.peca} (gatilho {g.nome})' for g in getattr(estilo, "gatilhos", []) if g.ativo and g.peca
               for x in g.exemplos[:2]]
    return "\n".join(linhas) or "(nenhum)"


def _marked(frase, cena, r):
    """Cena fixada no apontamento: usa o que a IA preencheu se veio na cena certa; senão o mínimo pela frase."""
    if r and r.cena == cena:
        return r
    palavras = frase.split()
    return Scene(cena=cena, ancora=" ".join(palavras[:2])[:60], titulo=" ".join(palavras[:8])[:60], valores=[])


def choose(frases, estilo, marcas=None, gat=None):
    """[(i, Cena, por)] para cada frase com tempo suficiente. `marcas`: {i: cena} do apontamento; `gat`: {i: detecção}
    dos gatilhos (`gatilhos.aplicar`) — a peça do gatilho vale como marca, com `por: "gatilho"`."""
    from esteira.studio.marking import NONE
    marcas = marcas or {}
    gat = gat or {}
    permitidas = estilo.regras.cardapio()
    catalogo = "\n".join(f"- {k}: {SCENES[k]}" for k in permitidas)
    escolhas, falhas = [], []
    for i, f in enumerate(frases):
        events.progress(i + 1, len(frases), f["texto"][:40])
        cena = marcas.get(i)
        por_fixo = "voce"
        g = gat[i]["gatilho"] if i in gat else None
        # sem peça: no apresentador fica na câmera/B-roll; no dark a IA escolhe como antes
        if not cena and g and (g.peca or estilo.modo == "apresentador"):
            if not g.peca or g.peca not in SCENES or g.peca == "midia":
                escolhas.append((i, Scene(cena="midia", ancora="", titulo="", valores=[]), "gatilho"))
                continue
            cena, por_fixo = g.peca, "gatilho"
        if cena == NONE:
            escolhas.append((i, Scene(cena="midia", ancora="", titulo="", valores=[]), "voce"))
            continue
        antes = frases[i - 1]["texto"] if i else ""
        base = local.prompt("estudio_cena", frase=f["texto"], antes=antes, catalogo=catalogo, guia=estilo.guia,
                            exemplos=_examples(estilo))
        if cena:
            base = local.Prompt(f"{base}\n\nA cena deste trecho já foi escolhida pela pessoa: {cena} ({SCENES[cena]}). "
                                "Responda com essa cena e preencha só a âncora, o título e os valores ditos.")
            base.nome = "estudio_cena"
            perm = permitidas + [cena]
            r = local.ask(base, Scene, max_tokens=400, operation="studio_scene")
            ok = r and not problems(f["texto"], r, perm)
            escolhas.append((i, _marked(f["texto"], cena, r if ok else None), por_fixo))
            continue
        r = local.ask(base, Scene, max_tokens=400, operation="studio_scene")
        erros = problems(f["texto"], r, permitidas) if r else ["sem resposta"]
        if erros and r:
            texto = local.Prompt(f"{base}\n\nSua resposta anterior foi recusada: {'; '.join(erros)}. Corrija.")
            texto.nome = "estudio_cena"
            r = local.ask(texto, Scene, max_tokens=400, operation="studio_scene")
            erros = problems(f["texto"], r, permitidas) if r else ["sem resposta"]
        if erros:
            falhas.append(i)
            escolhas.append((i, None, None))
        else:
            escolhas.append((i, r, "local"))
    if falhas:
        from esteira.core import options
        resolvidas = _escalate(frases, falhas, permitidas, catalogo, estilo) if options.read()["claude_fallback"] else {}
        escolhas = [(i, *(resolvidas.get(i) or (rule(frases[i]["texto"], permitidas), "regra")))
                    if r is None else (i, r, por) for i, r, por in escolhas]
    return escolhas


class _Batch(BaseModel):
    cenas: list[Scene]


def _escalate(frases, falhas, permitidas, catalogo, estilo):
    """Uma chamada ao Claude com as frases que a IA local errou duas vezes (até CLAUDE_MAX do total)."""
    teto = max(1, int(len(frases) * CLAUDE_MAX))
    if not falhas or len(falhas) > teto * 3:
        return {}
    from esteira.ai import claude
    alvo = falhas[:teto]
    dossie = (f"Guia do canal: {estilo.guia}\nCenas permitidas:\n{catalogo}\n\nPara cada frase, escolha a cena, a âncora "
              "(palavras exatas da frase), um título curto e só números ditos. Responda na mesma ordem.\n"
              + "\n".join(f"{n + 1}. {frases[i]['texto']}" for n, i in enumerate(alvo)))
    r = claude.query(dossie, _Batch, {"claude": {}}, "estudio", "estudio_cena")
    if not r or len(r.cenas) != len(alvo):
        return {}
    return {i: (c, "claude") for i, c in zip(alvo, r.cenas, strict=True)
            if not problems(frases[i]["texto"], c, permitidas)}


def _start(frase, ancora, palavras):
    """Instante da 1ª palavra da âncora dentro da frase (cai no início da frase se não achar)."""
    dentro = [p for p in palavras if frase["ini"] - 0.05 <= p["ini"] < frase["fim"]]
    alvo = normalize(ancora).split()
    if alvo:
        norm = [normalize(p["p"]) for p in dentro]
        for k in range(len(norm)):
            # 1ª e 2ª palavra batem (o Whisper às vezes parte números, então não exige a âncora inteira)
            if norm[k] == alvo[0] and norm[k + 1:k + 2] == alvo[1:2]:
                return dentro[k]["ini"]
    return frase["ini"]


def time(frases, escolhas, palavras, estilo, duracao, gat=None):
    """Tempos de cada cena + orçamento de takeover + variedade; devolve a lista do mapa. `gat`: detecções dos
    gatilhos — gravam `gatilho`, `cor` e `layout_pedido` (B-roll pedido fica como cena de mídia)."""
    from esteira.studio.triggers import LAYOUTS
    rg = estilo.regras
    gat = gat or {}
    cenas = []
    for i, r, por in escolhas:
        f = frases[i]
        d = gat.get(i)
        lay = LAYOUTS.get(d["gatilho"].layout) if d else None
        if r is None or (r.cena == "midia" and not r.titulo and lay != "broll"):
            continue
        if f["fim"] - f["ini"] < rg.dur_min * 0.6 and not numbers(f["texto"]) and por != "voce":
            continue  # frase curta demais: a cena anterior segue
        t = max(0.0, _start(f, r.ancora, palavras) - 0.08)
        cenas.append({"frase_i": i, "frase": f["texto"], "cena": r.cena, "t": round(t, 3),
                      "ate": round(f["fim"] + 0.4, 3), "titulo": r.titulo, "ancora": r.ancora,
                      "valores": [v.model_dump() for v in r.valores], "por": por})
        if d:
            cenas[-1].update({"gatilho": d["gatilho"].id, "cor": d["cor"], "layout_pedido": lay})
    cenas.sort(key=lambda c: c["t"])
    for a, b in zip(cenas, cenas[1:] + [None], strict=True):
        if b:
            a["ate"] = round(min(a["ate"], b["t"] - 0.05), 3)
        a["ate"] = round(min(a["ate"], duracao), 3)
        teto = rg.takeover_max_s if a["cena"] in TAKEOVER else rg.sobreposicao_max_s
        a["ate"] = round(min(a["ate"], a["t"] + teto), 3)
    cenas = [c for c in cenas if c["ate"] - c["t"] >= rg.dur_min * 0.75 or c["por"] == "voce"]
    # a mesma cena com o mesmo título em trechos seguidos é uma cena só (a primeira se estende)
    juntas = []
    for c in cenas:
        a = juntas[-1] if juntas else None
        if a and a["cena"] == c["cena"] and a["titulo"] == c["titulo"] and c["t"] - a["ate"] < 1.0:
            teto = rg.takeover_max_s if a["cena"] in TAKEOVER else rg.sobreposicao_max_s
            a["ate"] = round(min(c["ate"], a["t"] + teto), 3)
        else:
            juntas.append(c)
    cenas = juntas
    # variedade: a mesma cena de sobreposição 3× seguidas → a do meio vira só mídia (respiro)
    for a, b, c in zip(cenas, cenas[1:], cenas[2:], strict=False):
        if a["cena"] == b["cena"] == c["cena"] and b["cena"] not in TAKEOVER and b["por"] != "voce":
            b["cena"] = "midia"
    cenas = [c for c in cenas if c["cena"] != "midia" or c.get("layout_pedido") == "broll"]
    # orçamento: takeover passa do teto → perguntas e capítulos viram frase de impacto sobre a mídia
    def tempo_tk():
        return sum(c["ate"] - c["t"] for c in cenas if c["cena"] in TAKEOVER)
    for c in sorted(cenas, key=lambda c: c["cena"] not in ("pergunta_destaque", "titulo_capitulo")):
        if tempo_tk() <= rg.takeover_max * duracao:
            break
        if c["cena"] in TAKEOVER and c["por"] != "voce":
            c["cena"] = "frase_destaque" if c["cena"] in ("pergunta_destaque", "titulo_capitulo") else c["cena"]
    for n, c in enumerate(cenas):
        c["id"] = n
        c["takeover"] = c["cena"] in TAKEOVER
    return cenas


def spans(frases, palavras, max_s):
    """Frases longas viram trechos nas pausas de pontuação (vírgula, ponto e vírgula, dois-pontos), cada um com o
    seu tempo pelas palavras faladas; pedaço com menos de 4 palavras cola no vizinho."""
    saida = []
    for f in frases:
        partes = [x for x in re.split(r"(?<=[,;:])\s+", f["texto"]) if x.strip()]
        if f["fim"] - f["ini"] <= max_s or len(partes) < 2:
            saida.append({"texto": f["texto"], "ini": f["ini"], "fim": f["fim"]})
            continue
        juntas = []
        for x in partes:
            if juntas and (len(juntas[-1].split()) < 4 or len(x.split()) < 4):
                juntas[-1] += " " + x
            else:
                juntas.append(x)
        ditas = [p for p in palavras if f["ini"] - 0.05 <= p["ini"] < f["fim"]]
        k = 0
        for n, x in enumerate(juntas):
            qtd = len(x.split())
            grupo = ditas[k:k + qtd] if n < len(juntas) - 1 else ditas[k:]
            k += qtd
            ini = grupo[0]["ini"] if grupo else f["ini"]
            fim = grupo[-1]["fim"] if grupo else f["fim"]
            saida.append({"texto": x, "ini": ini, "fim": max(fim, ini + 0.3)})
    return saida


def _media_times(projeto):
    """[{ini}] das trocas de mídia do plano no tempo do corte (para a conferência de ritmo)."""
    arq = projeto.pasta / "plano.json"
    if not arq.exists():
        return []
    from esteira.studio import cut
    novo = cut.new(projeto)
    return [{"ini": novo(c["inicio"])} for c in json.loads(arq.read_text())["cenas"] if c.get("midia")]


def pace(cenas, frases, estilo, perfil, midia, duracao):
    """Perfil de ritmo no mapa: sem capítulos (curto), anti-repetição, gancho e conferência. → (cenas, avisos)."""
    from esteira.studio import rhythm
    cardapio = set(estilo.regras.cardapio())
    trocas = {k: v for k, v in rhythm.SWAPS.items() if v in cardapio}
    cenas = rhythm.without_chapters(cenas, perfil)
    cenas = rhythm.anti_repetition(cenas, perfil, trocas)
    cenas = [c for c in cenas if c["cena"] != "midia" or c.get("layout_pedido") == "broll"]
    cenas = rhythm.hook(cenas, perfil, frases)
    for n, c in enumerate(cenas):
        c["id"] = n
        c["takeover"] = c["cena"] in TAKEOVER
    return cenas, rhythm.cross_check(cenas, midia, duracao, perfil)


def direct(projeto, estilo, perfil=None):
    """Escreve `<ep>/estudio/mapa.json`; devolve o mapa. `perfil`: ritmo do vídeo (padrão: o do roteiro/formato)."""
    from esteira.studio import rhythm
    perfil = perfil or rhythm.profile_of(projeto)
    pasta = projeto.pasta / "estudio"
    pasta.mkdir(exist_ok=True)
    from esteira.studio import cut
    frases, palavras = cut.sentences(projeto), cut.words(projeto)
    duracao = frases[-1]["fim"] + 1.0 if frases else 0
    frases = spans(frases, palavras, estilo.regras.trecho_max_s)
    arq = pasta / "mapa.json"
    manuais = [c for c in json.loads(arq.read_text())["cenas"] if c.get("manual")] if arq.exists() else []
    from esteira.studio import marking, triggers
    gat = triggers.aplicar(frases, estilo.gatilhos)
    escolhas = choose(frases, estilo, marking.marks(projeto, frases), gat)
    cenas = time(frases, escolhas, palavras, estilo, duracao, gat)
    if manuais:  # o que foi ajustado à mão fica; a cena automática da mesma frase sai
        fixas = {c["frase_i"] for c in manuais}
        cenas = sorted([c for c in cenas if c["frase_i"] not in fixas] + manuais, key=lambda c: c["t"])
        for n, c in enumerate(cenas):
            c["id"] = n
    cenas, avisos = pace(cenas, frases, estilo, perfil, _media_times(projeto), duracao)
    por = {k: sum(1 for _, r, p in escolhas if p == k) for k in ("voce", "gatilho", "local", "claude", "regra")}
    por["ritmo"] = sum(1 for c in cenas if c.get("por") == "ritmo" or c.get("repeticao"))
    mapa = {"estilo": estilo.id, "versao": estilo.versao, "duracao": duracao, "decisoes": por, "cenas": cenas,
            "ritmo": {"perfil": perfil.id, "avisos": avisos}}
    arq.write_text(json.dumps(mapa, ensure_ascii=False, indent=1))
    tk = sum(c["ate"] - c["t"] for c in cenas if c["takeover"])
    print(f"  mapa: {len(cenas)} cenas · takeover {tk / max(duracao, 1):.0%} do tempo · decisões {por} · "
          f"ritmo {perfil.id} ({len(avisos)} aviso(s))")
    return mapa
