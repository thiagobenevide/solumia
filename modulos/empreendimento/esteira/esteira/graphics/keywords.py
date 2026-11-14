"""Palavras-chave animadas: 1–2 palavras de impacto por frase entram na tela no instante em que são DITAS
(tempo de palavra do alinhamento), com "pop" de escala, e a cena leva um soco de zoom no mesmo instante.

O LLM local escolhe as palavras em lotes de frases (só palavras que estão na frase); Python acha o tempo de
cada uma na fala e agenda: nunca sobre um gráfico da V4, com folga entre uma e outra. Números ficam de fora
(viram gráfico de número). Saída: `chaves.json` [{texto, inicio, dur, pos, cor}], lido pelo montar.
"""
import re

from pydantic import BaseModel, Field

from esteira.core import events
from esteira.cuts import norm

BATCH = 20          # frases por pergunta ao LLM
DURATION = (1.3, 2.2)   # s na tela (mínimo, máximo)
SLACK = 0.9        # s entre o fim de uma palavra-chave e a próxima
SLACK_GRAPHIC = 0.5   # s de distância dos gráficos da V4
STOP = set("""a o as os um uma uns umas de da do das dos e ou em no na nos nas com por para pra que se não
mais muito muita isso esse essa este esta aquele aquela ele ela eles elas você eu nós a gente tem ter é são foi
ser está estão como quando onde qual quais quem porque mas então já também só ainda sobre entre até""".split())


class Item(BaseModel):
    frase: int
    palavras: list[str] = Field(default_factory=list, max_length=2)


class Choice(BaseModel):
    itens: list[Item]


def _heuristica(texto):
    """Sem LLM: a palavra de conteúdo mais longa (≥ 7 letras)."""
    cands = [w.strip(".,;:!?\"'()*") for w in texto.split()]
    cands = [w for w in cands if len(w) >= 7 and w.lower() not in STOP and not re.search(r"\d", w)
             and not w.lower().endswith("mente")]  # advérbio ("realmente") não é palavra-chave
    return [max(cands, key=len)] if cands else []


def choose(frases):
    """{índice da frase: [palavras-chave]}."""
    from esteira.ai import local
    output = {}
    for a in range(0, len(frases), BATCH):
        block = frases[a:a + BATCH]
        items = "\n".join(f"{a + k}: {f['texto']}" for k, f in enumerate(block))
        r = local.ask(local.prompt("chaves", frases=items), Choice, max_tokens=1500, operation="graphics")
        given = {i.frase: i.palavras for i in r.itens} if r else {}
        for k, f in enumerate(block):
            output[a + k] = [p for p in given.get(a + k, []) if p.strip()] or _heuristica(f["texto"])
        events.progress(min(a + BATCH, len(frases)), len(frases), "palavras-chave")
    return output


def _find(chave, palavras, t0, t1):
    """(início, fim) da sequência de palavras `chave` dita entre t0 e t1 (comparação sem acento/pontuação)."""
    target = [norm(w) for w in chave.split() if norm(w)]
    if not target:
        return None
    window = [(k, w) for k, w in enumerate(palavras) if t0 - 0.5 <= w["ini"] <= t1 + 0.5]
    for n, (k, w) in enumerate(window):
        seq = [norm(x["p"]) for x in palavras[k:k + len(target)]]
        if len(seq) == len(target) and all(s[:5] == a[:5] for s, a in zip(seq, target)):
            return w["ini"], palavras[k + len(target) - 1]["fim"]
    return None


def plan(project, graphics, refazer=False):
    file = project.caminho("chaves.json")
    if file.exists() and not refazer:
        return project.carregar_json("chaves.json")
    sentences = project.carregar_json("frases.json")
    words = (project.carregar_json("alinhamento.json") if project.caminho("alinhamento.json").exists()
                else project.carregar_json("transcricao.json")["palavras"])
    choices = choose(sentences)
    busy = [(g["inicio"] - SLACK_GRAPHIC, g["inicio"] + g["dur"] + SLACK_GRAPHIC) for g in graphics]
    found = []
    for k, f in enumerate(sentences):
        if f["ini"] is None:
            continue
        for key in choices.get(k, []):
            t = _find(key, words, f["ini"], f.get("fim") or f["ini"] + 15)
            if t:
                found.append({"texto": key.strip(".,;:!?\"'*").upper(), "inicio": round(max(t[0] - 0.08, 0), 2),
                                "dita_ate": t[1]})
    output, free = [], 0.0
    for c in sorted(found, key=lambda c: c["inicio"]):
        if c["inicio"] < free or any(a < c["inicio"] + DURATION[0] and c["inicio"] < b for a, b in busy):
            continue
        prox = next((g for g, _ in sorted(busy) if g > c["inicio"]), 1e9)
        duration = min(DURATION[1], max(DURATION[0], c["dita_ate"] - c["inicio"] + 0.9), prox - c["inicio"])
        if duration < DURATION[0]:
            continue
        n = len(output)
        output.append({"texto": c["texto"], "inicio": c["inicio"], "dur": round(duration, 2),
                      "pos": ("baixo", "centro", "baixo", "alto")[n % 4], "cor": "destaque" if n % 3 == 0 else "branco"})
        free = c["inicio"] + duration + SLACK
    project.salvar_json("chaves.json", output)
    print(f"  {len(output)} palavras-chave animadas ({len(found)} escolhidas e achadas na fala)")
    return output
