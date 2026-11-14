"""Corte pelo som (fase 2; motor de `skill-vertical-main/corte/scripts/3-corte.py`): a esteira já escolheu as tomadas
pelo texto (`cortes.aplicar` → `narracao.wav`); aqui o som decide o resto.

1. fala pelo SOM (`esteira/bordas.py`): voz OU fricção colada a voz (s, x, f, t finais), acima do ruído de fundo
   local; respiração isolada e ruído de boca saem, finais de palavra ficam (TAIL);
2. vícios ("éé", "hum", conjunção esticada) achados pelo Whisper com um prompt cheio deles viram silêncio;
3. palavra real que o detector comeu (quase nada na máscara, mas audível) volta — o bruto nunca perde palavra; e a
   regra de ouro (`bordas.validar`): nenhuma borda cai dentro do núcleo de uma palavra mantida;
4. fim de frase ganha um respiro curto (silêncio digital), as outras pausas ficam em `PAUSA`;
5. cada buraco tirado vira uma EMENDA na tela do portão 1, com reversão (a emenda revertida fica como estava).

Saída em `<ep>/estudio/corte/`: `corte.json` (segmentos, emendas, revertidas, conferência), `narracao.wav` e o cache
`vicios.json`. O resto do Estúdio lê os tempos remapeados por `palavras`, `frases` e `novo` (sem corte = identidade).
"""
import difflib
import json
import re
import subprocess
import unicodedata

import numpy as np

from esteira import bordas
from esteira.core import events

SR, HOP, WIN = 16000, 160, 480            # quadros de 10 ms, janela de análise de 30 ms
LEAD, TAIL = 0.06, 0.14                   # antes do 1º / depois do último quadro de fala
HOLE, ISLAND = 0.20, 0.07                 # fecha buracos < HOLE; descarta ilhas de "fala" < ISLAND
RESPIRO = 0.15                            # silêncio extra no fim de frase (. ? ! :)
PAUSA = 0.06                              # entre palavras dentro da frase: sem isso a emenda soa como salto
EMENDA_MIN = 0.15                         # buraco menor que isto não aparece na tela
ENCURTOU = 0.4                            # palavra que durou menos que 60% do original no áudio final: conferir
PROMPT_VICIOS = "Éé, então, ããã, hum, é... tipo, éé, eh, ah, né, ããã, hum. Umm, éé."
NUMEROS = {"zero", "um", "uma", "dois", "duas", "tres", "quatro", "cinco", "seis", "sete", "oito", "nove", "dez", "cem",
           "mil", "vinte", "trinta", "quarenta", "cinquenta", "por", "cento"}
PURAS = {"aa", "aaa", "ee", "eee", "eh", "ah", "hum", "hm", "uh", "umm", "mm"}


def pasta(projeto):
    return projeto.pasta / "estudio" / "corte"


def _nz(s):
    return "".join(c for c in unicodedata.normalize("NFD", s.lower()) if c.isalnum())


def _assinatura(arq):
    st = arq.stat()
    return [st.st_size, st.st_mtime_ns]


def _sinal(arq, sr=SR, canais=1):
    bruto = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(arq), "-ac", str(canais), "-ar", str(sr),
                            "-f", "f32le", "-"], capture_output=True, check=True).stdout
    x = np.frombuffer(bruto, np.float32)
    return x.reshape(-1, canais) if canais > 1 else x


def fala(x):
    """Máscara de fala por quadro de 10 ms e o volume (dB) de cada quadro (`bordas.analise`)."""
    a = bordas.analise(x)
    return a["fala"], a["db"]


def mantidas(palavras, cortes):
    """(ini, fim) das palavras que ficam: com texto e sem metade ou mais coberta por um corte de vício."""
    out = []
    for s0, e0, t in palavras:
        cob = sum(max(0.0, min(e0, c1) - max(s0, c0)) for c0, c1, _ in cortes)
        if _nz(t) and cob < 0.5 * max(e0 - s0, 1e-3):
            out.append((s0, e0))
    return out


def _whisper(projeto):
    from esteira.ia.local import liberar_gpu
    from esteira.transcrever import _carregar_libs_cuda
    liberar_gpu()
    _carregar_libs_cuda()
    import ctranslate2
    from faster_whisper import WhisperModel
    c = projeto.cfg["transcricao"]
    disp = c["dispositivo"]
    if disp == "auto":
        disp = "cuda" if ctranslate2.get_cuda_device_count() > 0 else "cpu"
    return WhisperModel(c["modelo"], device=disp, compute_type="float16" if disp == "cuda" else "int8")


def _transcrever(modelo, x, prompt=None, idioma="pt"):
    segs, _ = modelo.transcribe(x, language=idioma, word_timestamps=True, vad_filter=True, beam_size=5,
                                condition_on_previous_text=False, initial_prompt=prompt)
    return [[round(w.start, 3), round(w.end, 3), w.word.strip()] for s in segs for w in s.words if w.word.strip()]


def vicios(palavras, tempos=None):
    """Hesitação pura sai inteira; conjunção esticada ("e", "é", "a", "um", "o" com 0,45–1,6 s) fica só com o começo.
    A detecção usa a duração do Whisper (`palavras`); o corte, os tempos alinhados (`tempos`, mesma ordem), e a
    palavra seguinte é protegida pela regra de ouro (`bordas.validar`)."""
    cortes = []
    for k, (s0, e0, t) in enumerate(palavras):
        tt, d = _nz(t), e0 - s0
        a0, a1 = (tempos[k][0], tempos[k][1]) if tempos else (s0, e0)
        if tt in PURAS or (len(tt) > 1 and len(set(tt)) == 1):
            cortes.append([a0, a1, t])
        elif tt in ("e", "a", "um", "o") and 0.45 < d < 1.6:
            cortes.append([min(a0 + 0.14, a1), a1, t + " (esticado)"])
    return [c for c in cortes if c[1] > c[0]]


def _runs(mask):
    lim = np.flatnonzero(np.diff(np.concatenate([[0], mask.astype(np.int8), [0]])))
    return list(zip(lim[::2], lim[1::2], strict=True))


def segmentos(sp, palavras, cortes, revertidas=(), dur=None, db=None, som=None):
    """Máscara + vícios + palavras → segmentos mantidos [ini, fim, respiro] e emendas (buracos tirados).
    `som` (`bordas.analise`) dá o núcleo de cada palavra mantida; sem ele vale o tempo do Whisper."""
    sp = sp.copy()
    n = len(sp)
    dur = dur or n / 100
    for s0, e0, _ in cortes:
        sp[max(0, int(s0 * 100)):min(n, int(e0 * 100))] = False
    corte_vicio = {(s0, e0) for s0, e0, _ in cortes}
    protegidas = []
    ref = np.percentile(db[db > -60], 90) if db is not None and (db > -60).any() else None
    # palavra que o detector comeu (quase nada dela na máscara, mas com som) volta: os quadros audíveis dela
    # (o Whisper estica o começo da 1ª palavra da frase por cima do silêncio, então não basta "metade fora")
    for s0, e0, t in palavras:
        if (s0, e0) in corte_vicio or any(abs(s0 - c0) < 0.05 for c0, _, _ in cortes) or not _nz(t):
            continue
        i0, i1 = max(0, int(s0 * 100)), min(n, int(e0 * 100))
        if i1 <= i0 or sp[i0:i1].mean() >= 0.1:
            continue
        if ref is None:
            sp[i0:i1] = True
        elif db[i0:i1].max() > ref - 20:
            sp[i0:i1] |= db[i0:i1] > ref - 24
        else:
            continue
        protegidas.append([s0, e0, t])
    merged = []
    for s0, e0 in _runs(sp):
        vicio = merged and any(merged[-1][1] * 0.01 <= c[0] + 0.02 and c[1] - 0.02 <= s0 * 0.01 for c in cortes)
        if merged and (s0 - merged[-1][1]) * 0.01 < HOLE and not vicio:
            merged[-1][1] = e0
        else:
            merged.append([s0, e0])
    segs = []
    for s0, e0 in merged:
        if (e0 - s0) * 0.01 < ISLAND:
            continue
        a, b = max(0.0, s0 * 0.01 - LEAD), min(dur, e0 * 0.01 + TAIL)
        if segs and a - segs[-1][1] < 0.08:
            segs[-1][1] = max(segs[-1][1], b)
        else:
            segs.append([a, b])
    todas = [(s0, e0) for s0, e0, _ in palavras]
    segs = bordas.validar(segs, bordas.nucleos(mantidas(palavras, cortes), som, todas), dur)
    fim_frase = [e0 for s0, e0, t in palavras if re.search(r"[.?!:…]$", t)]
    emendas, saida = [], []
    for k, (a, b) in enumerate(segs):
        prox = segs[k + 1][0] if k + 1 < len(segs) else None
        rev = prox is not None and any(x0 < prox and x1 > b for x0, x1 in revertidas)
        if prox is not None and prox - b >= EMENDA_MIN:
            dentro = [t for s0, e0, t in cortes if s0 < prox and e0 > b]
            emendas.append({"de": round(b, 3), "ate": round(prox, 3), "tipo": "vicio" if dentro else "pausa",
                            "texto": " ".join(dentro), "revertida": rev})
        if saida and saida[-1][2] is None:  # o buraco anterior foi revertido: este segmento continua o anterior
            saida[-1][1] = round(b, 3)
        else:
            saida.append([round(a, 3), round(b, 3), None])
        if not rev:
            fim = prox is not None and any(b - 0.4 <= f <= prox for f in fim_frase)
            saida[-1][2] = RESPIRO if fim else PAUSA
    return saida, emendas, protegidas


def _mapa(segs):
    """[[ini, fim, out]] dos segmentos na narração cortada."""
    out, t = [], 0.0
    for a, b, r in segs:
        out.append([a, b, round(t, 3)])
        t += (b - a) + r
    return out, t


def _novo(mapa, t):
    for a, b, o in mapa:
        if t < a:
            return o  # caiu num buraco: vai para o começo do segmento seguinte
        if t <= b:
            return round(o + t - a, 3)
    return round(mapa[-1][2] + mapa[-1][1] - mapa[-1][0], 3) if mapa else t


def carregar(projeto):
    arq = pasta(projeto) / "corte.json"
    return json.loads(arq.read_text()) if arq.exists() else None


def novo(projeto):
    """Função tempo da narração editada → tempo da narração cortada pelo som (identidade sem corte)."""
    c = carregar(projeto)
    return (lambda t: _novo(c["mapa"], t)) if c and c.get("mapa") else (lambda t: t)


def palavras(projeto):
    """Palavras da narração (transcricao.json) nos tempos do corte; as que caíram num buraco (vícios) saem."""
    ws = json.loads((projeto.pasta / "transcricao.json").read_text())["palavras"]
    c = carregar(projeto)
    if not c or not c.get("mapa"):
        return ws
    m = c["mapa"]
    # sai só a palavra que quase não toca o que ficou (vício); o Whisper estica o começo da palavra por cima da
    # pausa cortada, então o meio dela pode cair no buraco
    vivas = [w for w in ws if sum(max(0.0, min(b, w["fim"]) - max(a, w["ini"])) for a, b, _ in m) >= 0.06]
    return [{**w, "ini": _novo(m, w["ini"]), "fim": max(_novo(m, w["fim"]), _novo(m, w["ini"]) + 0.02)} for w in vivas]


def frases(projeto):
    fs = json.loads((projeto.pasta / "frases.json").read_text())
    f = novo(projeto)
    return [{**x, "ini": f(x["ini"]), "fim": f(x["fim"])} for x in fs]


def audio(projeto):
    """A narração que o Estúdio usa: a cortada pelo som, se houver; senão a editada da esteira."""
    a = pasta(projeto) / "narracao.wav"
    return a if a.exists() and carregar(projeto) else projeto.pasta / "narracao.wav"


def _renderizar(origem, segs, destino):
    """48 kHz estéreo; fade de 8 ms na entrada e 12 ms na saída (40 ms se a voz ainda soa); respiro = silêncio digital."""
    sr = 48000
    x = _sinal(origem, sr, 2)
    fi, fo, fo_voz = int(0.008 * sr), int(0.012 * sr), int(0.04 * sr)
    partes = []
    for a, b, r in segs:
        p = x[int(round(a * sr)):int(round(b * sr))].copy()
        if len(p) > fi + fo:
            p[:fi] *= np.linspace(0, 1, fi)[:, None]
            f = fo_voz if len(p) > fi + fo_voz and np.sqrt((p[-fo_voz:] ** 2).mean()) > 0.02 else fo  # corte em voz cheia
            p[-f:] *= np.linspace(1, 0, f)[:, None]
        partes += [p, np.zeros((int(r * sr), 2), np.float32)]
    dados = np.concatenate(partes).astype(np.float32) if partes else np.zeros((0, 2), np.float32)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", str(sr), "-ac", "2", "-i", "-", str(destino)],
                   input=dados.tobytes(), check=True)


def _pausas(arq, minimo=0.45):
    r = subprocess.run(["ffmpeg", "-hide_banner", "-i", str(arq), "-af", f"silencedetect=noise=-38dB:d={minimo}",
                        "-f", "null", "-"], capture_output=True, text=True, errors="replace").stderr
    return [float(m) for m in re.findall(r"silence_end: ([\d.]+)", r)]


def conferir(origem, cortadas, emendas, protegidas, pausas, cortadas_geo=()):
    """Conferência do corte: palavras que sumiram (texto da narração × texto do corte), palavras encurtadas (a
    mesma palavra durou bem menos no áudio final: o Whisper "completa" "ca…" como "casa", então o texto não basta),
    palavras cortadas pela geometria (`bordas.perdas`, travam o portão), repetições coladas, pausas longas que
    sobraram e o texto em volta de cada emenda."""
    a = [(_nz(t), s0, t, e0) for s0, e0, t in origem if _nz(t) and _nz(t) not in PURAS]
    b = [(_nz(t), s0, t, e0) for s0, e0, t in cortadas if _nz(t)]
    sm = difflib.SequenceMatcher(None, [x[0] for x in a], [x[0] for x in b], autojunk=False)

    def grafia(i, j, k, m):  # "por que"/"porque", "oito"/"8": o Whisper escreveu diferente, não sumiu
        sa, sb = "".join(x[0] for x in a[i:j]), "".join(x[0] for x in b[k:m])
        return sa == sb or (sb.isdigit() and all(x[0] in NUMEROS for x in a[i:j]))
    sumidas = [{"t": a[i][1], "texto": " ".join(x[2] for x in a[i:j])}
               for op, i, j, k, m in sm.get_opcodes()
               if op in ("delete", "replace") and 0 < j - i <= 6 and not (op == "replace" and grafia(i, j, k, m))]
    encurtadas = []
    for op, i, j, k, _m in sm.get_opcodes():
        if op != "equal":
            continue
        for x, y in zip(a[i:j], b[k:k + j - i], strict=True):
            antes, depois = x[3] - x[1], y[3] - y[1]
            if antes >= 0.15 and depois < antes * (1 - ENCURTOU) and antes - depois > 0.1:
                encurtadas.append({"t": y[1], "texto": y[2], "antes": round(antes, 2), "depois": round(depois, 2)})
    toks = [x[0] for x in b]
    rep = []
    for k in range(1, 5):
        for i in range(len(toks) - 2 * k + 1):
            if toks[i:i + k] == toks[i + k:i + 2 * k] and any(len(x) > 2 for x in toks[i:i + k]):
                rep.append({"t": b[i][1], "texto": " ".join(x[2] for x in b[i:i + 2 * k])})
    for e in emendas:
        e["janela"] = " ".join(t for s0, _, t in cortadas if e["out"] - 2 <= s0 <= e["out"] + 2)
    return {"sumidas": sumidas, "encurtadas": encurtadas, "cortadas": list(cortadas_geo), "repeticoes": rep,
            "pausas": pausas, "protegidas": protegidas, "nota": round(sm.ratio(), 3)}


def analisar(projeto):
    """Corte pelo som da narração editada, com as reversões já marcadas; grava corte.json e narracao.wav."""
    p = pasta(projeto)
    p.mkdir(parents=True, exist_ok=True)
    origem = projeto.pasta / "narracao.wav"
    if not origem.exists():
        raise SystemExit("corte pelo som precisa da narracao.wav (rode o limpar da esteira)")
    anterior = carregar(projeto) or {}
    revertidas = anterior.get("revertidas", [])
    assinatura = _assinatura(origem)
    if anterior.get("assinatura") != assinatura:
        revertidas = []  # narração nova: as reversões antigas não valem mais
    cache = p / "vicios.json"
    dados = json.loads(cache.read_text()) if cache.exists() else {}
    modelo = None
    idioma = projeto.cfg["transcricao"]["idioma"]
    x = _sinal(origem)
    if dados.get("assinatura") != assinatura:
        events.progress(1, 4, "transcrevendo com o prompt de vícios")
        modelo = _whisper(projeto)
        dados = {"assinatura": assinatura, "palavras": _transcrever(modelo, x, PROMPT_VICIOS, idioma)}
        cache.write_text(json.dumps(dados, ensure_ascii=False))
    from esteira import alinhamento
    whisper = dados["palavras"]
    ws = alinhamento.refinar(origem, whisper, p / "alinhamento.json", projeto.cfg)  # tempos certos para as bordas
    cortes = vicios(whisper, ws)
    events.progress(2, 4, "detectando a fala pelo som")
    an = bordas.analise(x)
    segs, emendas, protegidas = segmentos(an["fala"], ws, cortes, revertidas, len(x) / SR, an["db"], an["som"])
    fica = mantidas(ws, cortes)
    chave = set(fica)
    # palavra que o alinhamento não moveu (número, desvio grande) tem o tempo do Whisper, que estica sobre o
    # silêncio: confere-se pelo núcleo do som dela, o mesmo que `bordas.validar` protege
    alinhadas = {(a[0], a[1]) for a, b in zip(ws, whisper, strict=True) if a[:2] != b[:2]}
    medir = [w if w in alinhadas else bordas.nucleo(*w, an["som"]) or w for w in fica]
    geo = bordas.perdas(medir, [s[:2] for s in segs], [t for s0, e0, t in ws if (s0, e0) in chave])
    mapa, total = _mapa(segs)
    for n, e in enumerate(emendas):
        e["id"] = n
        e["out"] = _novo(mapa, e["ate"])
        e["dur"] = round(e["ate"] - e["de"], 3)
    events.progress(3, 4, "renderizando a narração cortada")
    destino = p / "narracao.wav"
    _renderizar(origem, segs, destino)
    events.progress(4, 4, "conferindo o corte")
    modelo = modelo or _whisper(projeto)
    cortadas = _transcrever(modelo, _sinal(destino), None, idioma)
    conf = conferir(whisper, cortadas, emendas, protegidas, _pausas(destino), geo)
    r = {"assinatura": assinatura, "duracao_antes": round(len(x) / SR, 3), "duracao": round(total, 3),
         "segmentos": segs, "mapa": mapa, "emendas": emendas, "revertidas": revertidas,
         "aplicadas": revertidas, "vicios": len(cortes), "conferencia": conf}
    (p / "corte.json").write_text(json.dumps(r, ensure_ascii=False, indent=1))
    print(f"  corte pelo som: {r['duracao_antes']:.1f} s → {total:.1f} s · {len(emendas)} emendas "
          f"({sum(e['tipo'] == 'vicio' for e in emendas)} com vício) · {len(protegidas)} palavras protegidas · "
          f"{len(conf['sumidas'])} trechos a conferir · {len(conf['encurtadas'])} palavras encurtadas · "
          f"{len(geo)} cortadas")
    return r


def reverter(projeto, de, ate, reverter=True):
    """Marca (ou desmarca) a faixa [de, ate] da narração editada como revertida; vale no próximo `analisar`."""
    c = carregar(projeto)
    if not c:
        raise ValueError("corte pelo som ainda não foi feito")
    rev = [r for r in c["revertidas"] if not (r[0] < ate and r[1] > de)]
    if reverter:
        rev.append([de, ate])
    c["revertidas"] = sorted(rev)
    (pasta(projeto) / "corte.json").write_text(json.dumps(c, ensure_ascii=False, indent=1))
    return c


def estado(projeto):
    """Resumo para o app: feito, atualizado (narração e reversões batem), números da conferência."""
    c = carregar(projeto)
    if not c:
        return {"feito": False}
    origem = projeto.pasta / "narracao.wav"
    atual = origem.exists() and c["assinatura"] == _assinatura(origem) and c["revertidas"] == c["aplicadas"]
    conf = c["conferencia"]
    return {"feito": True, "atualizado": atual, "duracao_antes": c["duracao_antes"], "duracao": c["duracao"],
            "emendas": len(c["emendas"]), "revertidas": len(c["revertidas"]), "vicios": c["vicios"],
            "sumidas": len(conf["sumidas"]), "repeticoes": len(conf["repeticoes"]), "pausas": len(conf["pausas"]),
            "protegidas": len(conf["protegidas"]), "nota": conf["nota"],
            "encurtadas": len(conf.get("encurtadas", [])), "cortadas": len(conf.get("cortadas", []))}
