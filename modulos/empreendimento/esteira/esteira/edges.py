"""Bordas dos cortes de áudio: onde a tesoura pode entrar (`docs/PLANO-ACERVO.md`, "Corte do áudio").

Usado pelos dois cortadores (`cortes.py`, na gravação bruta, e `studio/cut.py`, na narração editada):
- **regra de ouro:** nenhuma borda cai dentro de `[ini − ANTES, fim + DEPOIS]` de uma palavra mantida. Os intervalos
  mantidos são unidos às zonas das palavras mantidas, então a borda só pode ir para fora (sobra som, nunca come
  sílaba); sem vão entre duas palavras, não há corte;
- **detector de fala** que enxerga consoante surda (s, x, f, ch, t, k, p): fala = voz (graves) OU fricção (3–8 kHz)
  acima do ruído de fundo medido em janela móvel (~10 s), não por percentil do arquivo inteiro;
- **núcleo da palavra:** o tempo do Whisper erra 0,1–0,3 s e estica a palavra por cima da pausa; o núcleo é o
  som contínuo em volta do tempo dado (com alinhamento forçado, `alinhamento.py`, o tempo já vem certo), que é o
  que a regra de ouro protege;
- **conferência por duração:** palavra mantida que perdeu mais de PERDA_MAX do núcleo no áudio final vira alerta.
"""
import bisect

import numpy as np

SR, HOP, WIN = 16000, 160, 480            # quadros de 10 ms, janela de análise de 30 ms
Q = HOP / SR
BEFORE, AFTER = 0.03, 0.04                # zona protegida em volta de cada palavra mantida
WINDOW_FLOOR = 10.0                        # s: janela do ruído de fundo local
VOICE_DB, FRIC_DB, STRONG_DB, SOUND_DB = 10.0, 9.0, 22.0, 6.0  # dB acima do piso local
NEIGHBOR_VOICE = 0.15                        # s: fricção só é fala se estiver colada a voz (respiração isolada não é)
EXTENDS = 0.25                            # s: o núcleo pode passar isto do tempo do Whisper
NEIGHBOR_CUT = 0.05                    # s: quanto o núcleo pode entrar no tempo de uma vizinha que sai
LOSS_MAX = 0.25                          # fração do núcleo que pode sumir antes de virar alerta
DIGITAL = -90.0                           # dB: silêncio digital do noise gate fica fora do piso


def floor(v, pct=10, janela=WINDOW_FLOOR, validos=None):
    """Percentil `pct` de `v` numa janela móvel de `janela` s (calculado a cada 1 s), um valor por quadro."""
    n = len(v)
    if n == 0:
        return np.zeros(0)
    passo, meia = int(1 / Q), int(janela / Q / 2)
    validos = np.ones(n, bool) if validos is None else validos
    geral = np.percentile(v[validos], pct) if validos.any() else float(np.min(v))
    centros = np.arange(0, n, passo)
    vals = []
    for c in centros:
        a, b = max(0, c - meia), min(n, c + meia)
        w = v[a:b][validos[a:b]]
        vals.append(np.percentile(w, pct) if len(w) > 20 else geral)
    return np.repeat(np.array(vals), passo)[:n]


def _runs(mask):
    lim = np.flatnonzero(np.diff(np.concatenate([[0], mask.astype(np.int8), [0]])))
    return list(zip(lim[::2], lim[1::2], strict=True))


def analysis(x):
    """Sinal 16 kHz mono → {"fala", "som", "db"} por quadro de 10 ms. `fala`: voz ou fricção colada a voz;
    `som`: qualquer coisa audível acima do ruído local (usado no núcleo das palavras)."""
    n = max(0, (len(x) - WIN) // HOP + 1)
    if n == 0:
        z = np.zeros(0)
        return {"fala": z.astype(bool), "som": z.astype(bool), "db": z}
    quadros = np.lib.stride_tricks.sliding_window_view(x, WIN)[::HOP][:n]
    db = 20 * np.log10(np.sqrt((quadros ** 2).mean(1)) + 1e-9)
    f = np.fft.rfftfreq(WIN, 1 / SR)
    X = np.abs(np.fft.rfft(quadros * np.hanning(WIN), axis=1)) ** 2
    voz = 10 * np.log10(X[:, (f > 80) & (f < 900)].sum(1) + 1e-12)
    fric = 10 * np.log10(X[:, (f >= 3000) & (f <= 8000)].sum(1) + 1e-12)
    validos = db > DIGITAL
    p_db, p_voz, p_fric = (floor(v, validos=validos) for v in (db, voz, fric))
    sonoro = ((voz > p_voz + VOICE_DB) & (db > p_db + SOUND_DB)) | (db > p_db + STRONG_DB)
    friccao = (fric > p_fric + FRIC_DB) & validos
    perto = np.convolve(sonoro.astype(float), np.ones(2 * int(NEIGHBOR_VOICE / Q) + 1), "same") > 0
    fala = sonoro.copy()
    for a, b in _runs(friccao):
        if perto[a:b].any():
            fala[a:b] = True
    return {"fala": fala, "som": (db > p_db + SOUND_DB) & validos, "db": db}


def core(ini, fim, som, lo=None, hi=None):
    """Trecho com som da palavra [ini, fim]: o som dentro da zona dela, estendido enquanto o som continua (o fim
    fraco de "casa" que o Whisper deu como pausa), até ESTENDE s e nunca além de [lo, hi] (meio das vizinhas).
    None se não há som nenhum (palavra que o Whisper inventou sobre a pausa)."""
    if som is None:
        return ini, fim
    lo = max(ini - EXTENDS, 0.0 if lo is None else lo)
    hi = min(fim + EXTENDS, len(som) * Q if hi is None else hi)
    a, b = max(0, int(lo / Q)), min(len(som), int(np.ceil(hi / Q)))
    s = som[a:b]
    i0 = min(len(s), max(0, int((ini - BEFORE) / Q) - a))
    i1 = min(len(s), max(0, int(np.ceil((fim + AFTER) / Q)) - a))
    idx = np.flatnonzero(s[i0:i1])
    if not len(idx):
        return None
    p, u = i0 + idx[0], i0 + idx[-1]
    while p > 0 and s[p - 1]:
        p -= 1
    while u < len(s) - 1 and s[u + 1]:
        u += 1
    return (a + p) * Q, (a + u + 1) * Q


def cores(mantidas, som, todas=()):
    """[(ini, fim)] das palavras mantidas → núcleos (as sem som nenhum saem). `todas` (todas as palavras, mantidas
    ou não) limita a extensão: até o meio da vizinha mantida e no máximo VIZINHA_CORTADA s para dentro da que
    sai, então o núcleo não engole o retake colado."""
    todas = sorted(set(map(tuple, todas)))
    fica = set(map(tuple, mantidas))
    inis = [w[0] for w in todas]
    out = []
    for a, b in mantidas:
        k = bisect.bisect_left(inis, a)
        ant = todas[k - 1] if k > 0 else None
        prox = next((todas[j] for j in range(k, len(todas)) if todas[j][0] > a), None)
        lo = None if not ant else (ant[0] + ant[1]) / 2 if ant in fica else ant[1] - NEIGHBOR_CUT
        hi = None if not prox else (prox[0] + prox[1]) / 2 if prox in fica else prox[0] + NEIGHBOR_CUT
        n = core(a, b, som, lo, hi)
        if n:
            out.append(n)
    return out


def zones(palavras):
    """Zonas protegidas (unidas) das palavras mantidas."""
    out = []
    for a, b in sorted(palavras):
        a, b = max(0.0, a - BEFORE), b + AFTER
        if out and a <= out[-1][1]:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return out


def validate(intervalos, palavras, dur=None, juntar=0.02):
    """Intervalos mantidos ∪ zonas das palavras mantidas: nenhuma borda fica dentro de palavra mantida e nenhuma
    palavra mantida fica de fora. Intervalos a menos de `juntar` s viram um só."""
    out = []
    for a, b in sorted([list(i) for i in intervalos] + zones(palavras)):
        a = max(0.0, a)
        b = min(b, dur) if dur else b
        if b <= a:
            continue
        if out and a <= out[-1][1] + juntar:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return out


def inside(t, zs):
    """True se o instante t cai no interior de alguma zona (lista ordenada de [a, b])."""
    k = bisect.bisect_right([z[0] for z in zs], t) - 1
    return k >= 0 and zs[k][0] < t < zs[k][1]


def losses(palavras, intervalos, textos=None):
    """Conferência por duração: palavras mantidas [(ini, fim)] cujo trecho ficou mais de PERDA_MAX fora dos
    intervalos mantidos → [{"t", "texto", "perdeu"}]."""
    ivs = sorted(intervalos)
    inis = [i[0] for i in ivs]
    alertas = []
    for n, (a, b) in enumerate(palavras):
        if b - a <= 0:
            continue
        k = max(0, bisect.bisect_right(inis, a) - 1)
        dentro_s = 0.0
        while k < len(ivs) and ivs[k][0] < b:
            dentro_s += max(0.0, min(b, ivs[k][1]) - max(a, ivs[k][0]))
            k += 1
        perdeu = 1 - dentro_s / (b - a)
        if perdeu > LOSS_MAX:
            alertas.append({"t": round(a, 3), "texto": textos[n] if textos else "", "perdeu": round(perdeu, 2)})
    return alertas
