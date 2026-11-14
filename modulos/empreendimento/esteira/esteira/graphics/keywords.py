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

LOTE = 20          # frases por pergunta ao LLM
DUR = (1.3, 2.2)   # s na tela (mínimo, máximo)
FOLGA = 0.9        # s entre o fim de uma palavra-chave e a próxima
FOLGA_GRAF = 0.5   # s de distância dos gráficos da V4
PARADA = set("""a o as os um uma uns umas de da do das dos e ou em no na nos nas com por para pra que se não
mais muito muita isso esse essa este esta aquele aquela ele ela eles elas você eu nós a gente tem ter é são foi
ser está estão como quando onde qual quais quem porque mas então já também só ainda sobre entre até""".split())


class Item(BaseModel):
    frase: int
    palavras: list[str] = Field(default_factory=list, max_length=2)


class Escolha(BaseModel):
    itens: list[Item]


def _heuristica(texto):
    """Sem LLM: a palavra de conteúdo mais longa (≥ 7 letras)."""
    cands = [w.strip(".,;:!?\"'()*") for w in texto.split()]
    cands = [w for w in cands if len(w) >= 7 and w.lower() not in PARADA and not re.search(r"\d", w)
             and not w.lower().endswith("mente")]  # advérbio ("realmente") não é palavra-chave
    return [max(cands, key=len)] if cands else []


def escolher(frases):
    """{índice da frase: [palavras-chave]}."""
    from esteira.ai import local
    saida = {}
    for a in range(0, len(frases), LOTE):
        bloco = frases[a:a + LOTE]
        lista = "\n".join(f"{a + k}: {f['texto']}" for k, f in enumerate(bloco))
        r = local.ask(local.prompt("chaves", frases=lista), Escolha, max_tokens=1500, operation="graphics")
        dadas = {i.frase: i.palavras for i in r.itens} if r else {}
        for k, f in enumerate(bloco):
            saida[a + k] = [p for p in dadas.get(a + k, []) if p.strip()] or _heuristica(f["texto"])
        events.progress(min(a + LOTE, len(frases)), len(frases), "palavras-chave")
    return saida


def _achar(chave, palavras, t0, t1):
    """(início, fim) da sequência de palavras `chave` dita entre t0 e t1 (comparação sem acento/pontuação)."""
    alvo = [norm(w) for w in chave.split() if norm(w)]
    if not alvo:
        return None
    janela = [(k, w) for k, w in enumerate(palavras) if t0 - 0.5 <= w["ini"] <= t1 + 0.5]
    for n, (k, w) in enumerate(janela):
        seq = [norm(x["p"]) for x in palavras[k:k + len(alvo)]]
        if len(seq) == len(alvo) and all(s[:5] == a[:5] for s, a in zip(seq, alvo)):
            return w["ini"], palavras[k + len(alvo) - 1]["fim"]
    return None


def planejar(projeto, graficos, refazer=False):
    arq = projeto.caminho("chaves.json")
    if arq.exists() and not refazer:
        return projeto.carregar_json("chaves.json")
    frases = projeto.carregar_json("frases.json")
    palavras = (projeto.carregar_json("alinhamento.json") if projeto.caminho("alinhamento.json").exists()
                else projeto.carregar_json("transcricao.json")["palavras"])
    escolhas = escolher(frases)
    ocupado = [(g["inicio"] - FOLGA_GRAF, g["inicio"] + g["dur"] + FOLGA_GRAF) for g in graficos]
    achadas = []
    for k, f in enumerate(frases):
        if f["ini"] is None:
            continue
        for chave in escolhas.get(k, []):
            t = _achar(chave, palavras, f["ini"], f.get("fim") or f["ini"] + 15)
            if t:
                achadas.append({"texto": chave.strip(".,;:!?\"'*").upper(), "inicio": round(max(t[0] - 0.08, 0), 2),
                                "dita_ate": t[1]})
    saida, livre = [], 0.0
    for c in sorted(achadas, key=lambda c: c["inicio"]):
        if c["inicio"] < livre or any(a < c["inicio"] + DUR[0] and c["inicio"] < b for a, b in ocupado):
            continue
        prox = next((g for g, _ in sorted(ocupado) if g > c["inicio"]), 1e9)
        dur = min(DUR[1], max(DUR[0], c["dita_ate"] - c["inicio"] + 0.9), prox - c["inicio"])
        if dur < DUR[0]:
            continue
        n = len(saida)
        saida.append({"texto": c["texto"], "inicio": c["inicio"], "dur": round(dur, 2),
                      "pos": ("baixo", "centro", "baixo", "alto")[n % 4], "cor": "destaque" if n % 3 == 0 else "branco"})
        livre = c["inicio"] + dur + FOLGA
    projeto.salvar_json("chaves.json", saida)
    print(f"  {len(saida)} palavras-chave animadas ({len(achadas)} escolhidas e achadas na fala)")
    return saida
