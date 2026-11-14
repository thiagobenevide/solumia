"""Corte pelo som (fase 2; motor de `skill-vertical-main/corte/scripts/3-corte.py`): a esteira já escolheu as tomadas
pelo texto (`cortes.aplicar` → `narracao.wav`); aqui o som decide o resto.

1. fala pelo SOM (`esteira/edges.py`): voz OU fricção colada a voz (s, x, f, t finais), acima do ruído de fundo
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

from esteira import edges
from esteira.core import events

SR, HOP, WIN = 16000, 160, 480            # quadros de 10 ms, janela de análise de 30 ms
LEAD, TAIL = 0.06, 0.14                   # antes do 1º / depois do último quadro de fala
HOLE, ISLAND = 0.20, 0.07                 # fecha buracos < HOLE; descarta ilhas de "fala" < ISLAND
BREATH = 0.15                            # silêncio extra no fim de frase (. ? ! :)
PAUSE = 0.06                              # entre palavras dentro da frase: sem isso a emenda soa como salto
SPLICE_MIN = 0.15                         # buraco menor que isto não aparece na tela
SHORTENED = 0.4                            # palavra que durou menos que 60% do original no áudio final: conferir
PROMPT_FILLERS = "Éé, então, ããã, hum, é... tipo, éé, eh, ah, né, ããã, hum. Umm, éé."
NUMBERS = {"zero", "um", "uma", "dois", "duas", "tres", "quatro", "cinco", "seis", "sete", "oito", "nove", "dez", "cem",
           "mil", "vinte", "trinta", "quarenta", "cinquenta", "por", "cento"}
PURE = {"aa", "aaa", "ee", "eee", "eh", "ah", "hum", "hm", "uh", "umm", "mm"}


def folder(project):
    return project.pasta / "estudio" / "corte"


def _nz(s):
    return "".join(c for c in unicodedata.normalize("NFD", s.lower()) if c.isalnum())


def _signature(file):
    st = file.stat()
    return [st.st_size, st.st_mtime_ns]


def _signal(file, sr=SR, channels=1):
    raw = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(file), "-ac", str(channels), "-ar", str(sr),
                            "-f", "f32le", "-"], capture_output=True, check=True).stdout
    x = np.frombuffer(raw, np.float32)
    return x.reshape(-1, channels) if channels > 1 else x


def speech(x):
    """Máscara de fala por quadro de 10 ms e o volume (dB) de cada quadro (`bordas.analise`)."""
    a = edges.analysis(x)
    return a["fala"], a["db"]


def kept(palavras, cuts):
    """(ini, fim) das palavras que ficam: com texto e sem metade ou mais coberta por um corte de vício."""
    out = []
    for s0, e0, t in palavras:
        cob = sum(max(0.0, min(e0, c1) - max(s0, c0)) for c0, c1, _ in cuts)
        if _nz(t) and cob < 0.5 * max(e0 - s0, 1e-3):
            out.append((s0, e0))
    return out


def _whisper(project):
    from esteira.ai.local import free_gpu
    from esteira.transcribe import _load_libs_cuda
    free_gpu()
    _load_libs_cuda()
    import ctranslate2
    from faster_whisper import WhisperModel
    c = project.cfg["transcricao"]
    disp = c["dispositivo"]
    if disp == "auto":
        disp = "cuda" if ctranslate2.get_cuda_device_count() > 0 else "cpu"
    return WhisperModel(c["modelo"], device=disp, compute_type="float16" if disp == "cuda" else "int8")


def _transcribe(model, x, prompt=None, language="pt"):
    segs, _ = model.transcribe(x, language=language, word_timestamps=True, vad_filter=True, beam_size=5,
                                condition_on_previous_text=False, initial_prompt=prompt)
    return [[round(w.start, 3), round(w.end, 3), w.word.strip()] for s in segs for w in s.words if w.word.strip()]


def fillers(palavras, tempos=None):
    """Hesitação pura sai inteira; conjunção esticada ("e", "é", "a", "um", "o" com 0,45–1,6 s) fica só com o começo.
    A detecção usa a duração do Whisper (`palavras`); o corte, os tempos alinhados (`tempos`, mesma ordem), e a
    palavra seguinte é protegida pela regra de ouro (`bordas.validar`)."""
    cuts = []
    for k, (s0, e0, t) in enumerate(palavras):
        tt, d = _nz(t), e0 - s0
        a0, a1 = (tempos[k][0], tempos[k][1]) if tempos else (s0, e0)
        if tt in PURE or (len(tt) > 1 and len(set(tt)) == 1):
            cuts.append([a0, a1, t])
        elif tt in ("e", "a", "um", "o") and 0.45 < d < 1.6:
            cuts.append([min(a0 + 0.14, a1), a1, t + " (esticado)"])
    return [c for c in cuts if c[1] > c[0]]


def _runs(mask):
    limit = np.flatnonzero(np.diff(np.concatenate([[0], mask.astype(np.int8), [0]])))
    return list(zip(limit[::2], limit[1::2], strict=True))


def segments(sp, palavras, cuts, reverted=(), dur=None, db=None, sound=None):
    """Máscara + vícios + palavras → segmentos mantidos [ini, fim, respiro] e emendas (buracos tirados).
    `som` (`bordas.analise`) dá o núcleo de cada palavra mantida; sem ele vale o tempo do Whisper."""
    sp = sp.copy()
    n = len(sp)
    dur = dur or n / 100
    for s0, e0, _ in cuts:
        sp[max(0, int(s0 * 100)):min(n, int(e0 * 100))] = False
    cut_filler = {(s0, e0) for s0, e0, _ in cuts}
    protected = []
    ref = np.percentile(db[db > -60], 90) if db is not None and (db > -60).any() else None
    # palavra que o detector comeu (quase nada dela na máscara, mas com som) volta: os quadros audíveis dela
    # (o Whisper estica o começo da 1ª palavra da frase por cima do silêncio, então não basta "metade fora")
    for s0, e0, t in palavras:
        if (s0, e0) in cut_filler or any(abs(s0 - c0) < 0.05 for c0, _, _ in cuts) or not _nz(t):
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
        protected.append([s0, e0, t])
    merged = []
    for s0, e0 in _runs(sp):
        filler = merged and any(merged[-1][1] * 0.01 <= c[0] + 0.02 and c[1] - 0.02 <= s0 * 0.01 for c in cuts)
        if merged and (s0 - merged[-1][1]) * 0.01 < HOLE and not filler:
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
    everything = [(s0, e0) for s0, e0, _ in palavras]
    segs = edges.validate(segs, edges.cores(kept(palavras, cuts), sound, everything), dur)
    end_sentence = [e0 for s0, e0, t in palavras if re.search(r"[.?!:…]$", t)]
    emendas, output = [], []
    for k, (a, b) in enumerate(segs):
        prox = segs[k + 1][0] if k + 1 < len(segs) else None
        rev = prox is not None and any(x0 < prox and x1 > b for x0, x1 in reverted)
        if prox is not None and prox - b >= SPLICE_MIN:
            inside = [t for s0, e0, t in cuts if s0 < prox and e0 > b]
            emendas.append({"de": round(b, 3), "ate": round(prox, 3), "tipo": "vicio" if inside else "pausa",
                            "texto": " ".join(inside), "revertida": rev})
        if output and output[-1][2] is None:  # o buraco anterior foi revertido: este segmento continua o anterior
            output[-1][1] = round(b, 3)
        else:
            output.append([round(a, 3), round(b, 3), None])
        if not rev:
            end = prox is not None and any(b - 0.4 <= f <= prox for f in end_sentence)
            output[-1][2] = BREATH if end else PAUSE
    return output, emendas, protected


def _map(segs):
    """[[ini, fim, out]] dos segmentos na narração cortada."""
    out, t = [], 0.0
    for a, b, r in segs:
        out.append([a, b, round(t, 3)])
        t += (b - a) + r
    return out, t


def _new(mapping, t):
    for a, b, o in mapping:
        if t < a:
            return o  # caiu num buraco: vai para o começo do segmento seguinte
        if t <= b:
            return round(o + t - a, 3)
    return round(mapping[-1][2] + mapping[-1][1] - mapping[-1][0], 3) if mapping else t


def load(project):
    file = folder(project) / "corte.json"
    return json.loads(file.read_text()) if file.exists() else None


def new(project):
    """Função tempo da narração editada → tempo da narração cortada pelo som (identidade sem corte)."""
    c = load(project)
    return (lambda t: _new(c["mapa"], t)) if c and c.get("mapa") else (lambda t: t)


def words(project):
    """Palavras da narração (transcricao.json) nos tempos do corte; as que caíram num buraco (vícios) saem."""
    ws = json.loads((project.pasta / "transcricao.json").read_text())["palavras"]
    c = load(project)
    if not c or not c.get("mapa"):
        return ws
    m = c["mapa"]
    # sai só a palavra que quase não toca o que ficou (vício); o Whisper estica o começo da palavra por cima da
    # pausa cortada, então o meio dela pode cair no buraco
    live = [w for w in ws if sum(max(0.0, min(b, w["fim"]) - max(a, w["ini"])) for a, b, _ in m) >= 0.06]
    return [{**w, "ini": _new(m, w["ini"]), "fim": max(_new(m, w["fim"]), _new(m, w["ini"]) + 0.02)} for w in live]


def sentences(project):
    fs = json.loads((project.pasta / "frases.json").read_text())
    f = new(project)
    return [{**x, "ini": f(x["ini"]), "fim": f(x["fim"])} for x in fs]


def audio(project):
    """A narração que o Estúdio usa: a cortada pelo som, se houver; senão a editada da esteira."""
    a = folder(project) / "narracao.wav"
    return a if a.exists() and load(project) else project.pasta / "narracao.wav"


def _render(origem, segs, destino):
    """48 kHz estéreo; fade de 8 ms na entrada e 12 ms na saída (40 ms se a voz ainda soa); respiro = silêncio digital."""
    sr = 48000
    x = _signal(origem, sr, 2)
    fi, fo, fo_voice = int(0.008 * sr), int(0.012 * sr), int(0.04 * sr)
    parts = []
    for a, b, r in segs:
        p = x[int(round(a * sr)):int(round(b * sr))].copy()
        if len(p) > fi + fo:
            p[:fi] *= np.linspace(0, 1, fi)[:, None]
            f = fo_voice if len(p) > fi + fo_voice and np.sqrt((p[-fo_voice:] ** 2).mean()) > 0.02 else fo  # corte em voz cheia
            p[-f:] *= np.linspace(1, 0, f)[:, None]
        parts += [p, np.zeros((int(r * sr), 2), np.float32)]
    data = np.concatenate(parts).astype(np.float32) if parts else np.zeros((0, 2), np.float32)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", str(sr), "-ac", "2", "-i", "-", str(destino)],
                   input=data.tobytes(), check=True)


def _pauses(file, minimum=0.45):
    r = subprocess.run(["ffmpeg", "-hide_banner", "-i", str(file), "-af", f"silencedetect=noise=-38dB:d={minimum}",
                        "-f", "null", "-"], capture_output=True, text=True, errors="replace").stderr
    return [float(m) for m in re.findall(r"silence_end: ([\d.]+)", r)]


def cross_check(origem, cut, emendas, protected, pauses, cut_geo=()):
    """Conferência do corte: palavras que sumiram (texto da narração × texto do corte), palavras encurtadas (a
    mesma palavra durou bem menos no áudio final: o Whisper "completa" "ca…" como "casa", então o texto não basta),
    palavras cortadas pela geometria (`bordas.perdas`, travam o portão), repetições coladas, pausas longas que
    sobraram e o texto em volta de cada emenda."""
    a = [(_nz(t), s0, t, e0) for s0, e0, t in origem if _nz(t) and _nz(t) not in PURE]
    b = [(_nz(t), s0, t, e0) for s0, e0, t in cut if _nz(t)]
    sm = difflib.SequenceMatcher(None, [x[0] for x in a], [x[0] for x in b], autojunk=False)

    def grafia(i, j, k, m):  # "por que"/"porque", "oito"/"8": o Whisper escreveu diferente, não sumiu
        sa, sb = "".join(x[0] for x in a[i:j]), "".join(x[0] for x in b[k:m])
        return sa == sb or (sb.isdigit() and all(x[0] in NUMBERS for x in a[i:j]))
    sumidas = [{"t": a[i][1], "texto": " ".join(x[2] for x in a[i:j])}
               for op, i, j, k, m in sm.get_opcodes()
               if op in ("delete", "replace") and 0 < j - i <= 6 and not (op == "replace" and grafia(i, j, k, m))]
    encurtadas = []
    for op, i, j, k, _m in sm.get_opcodes():
        if op != "equal":
            continue
        for x, y in zip(a[i:j], b[k:k + j - i], strict=True):
            before, after = x[3] - x[1], y[3] - y[1]
            if before >= 0.15 and after < before * (1 - SHORTENED) and before - after > 0.1:
                encurtadas.append({"t": y[1], "texto": y[2], "antes": round(before, 2), "depois": round(after, 2)})
    toks = [x[0] for x in b]
    rep = []
    for k in range(1, 5):
        for i in range(len(toks) - 2 * k + 1):
            if toks[i:i + k] == toks[i + k:i + 2 * k] and any(len(x) > 2 for x in toks[i:i + k]):
                rep.append({"t": b[i][1], "texto": " ".join(x[2] for x in b[i:i + 2 * k])})
    for e in emendas:
        e["janela"] = " ".join(t for s0, _, t in cut if e["out"] - 2 <= s0 <= e["out"] + 2)
    return {"sumidas": sumidas, "encurtadas": encurtadas, "cortadas": list(cut_geo), "repeticoes": rep,
            "pausas": pauses, "protegidas": protected, "nota": round(sm.ratio(), 3)}


def analyze(project):
    """Corte pelo som da narração editada, com as reversões já marcadas; grava corte.json e narracao.wav."""
    p = folder(project)
    p.mkdir(parents=True, exist_ok=True)
    origin = project.pasta / "narracao.wav"
    if not origin.exists():
        raise SystemExit("corte pelo som precisa da narracao.wav (rode o limpar da esteira)")
    previous = load(project) or {}
    reverted = previous.get("revertidas", [])
    signature = _signature(origin)
    if previous.get("assinatura") != signature:
        reverted = []  # narração nova: as reversões antigas não valem mais
    cache = p / "vicios.json"
    data = json.loads(cache.read_text()) if cache.exists() else {}
    model = None
    language = project.cfg["transcricao"]["idioma"]
    x = _signal(origin)
    if data.get("assinatura") != signature:
        events.progress(1, 4, "transcrevendo com o prompt de vícios")
        model = _whisper(project)
        data = {"assinatura": signature, "palavras": _transcribe(model, x, PROMPT_FILLERS, language)}
        cache.write_text(json.dumps(data, ensure_ascii=False))
    from esteira import alignment
    whisper = data["palavras"]
    ws = alignment.refine(origin, whisper, p / "alinhamento.json", project.cfg)  # tempos certos para as bordas
    cuts = fillers(whisper, ws)
    events.progress(2, 4, "detectando a fala pelo som")
    an = edges.analysis(x)
    segs, emendas, protected = segments(an["fala"], ws, cuts, reverted, len(x) / SR, an["db"], an["som"])
    stays = kept(ws, cuts)
    key = set(stays)
    # palavra que o alinhamento não moveu (número, desvio grande) tem o tempo do Whisper, que estica sobre o
    # silêncio: confere-se pelo núcleo do som dela, o mesmo que `bordas.validar` protege
    aligned = {(a[0], a[1]) for a, b in zip(ws, whisper, strict=True) if a[:2] != b[:2]}
    measure = [w if w in aligned else edges.core(*w, an["som"]) or w for w in stays]
    geo = edges.losses(measure, [s[:2] for s in segs], [t for s0, e0, t in ws if (s0, e0) in key])
    mapping, total = _map(segs)
    for n, e in enumerate(emendas):
        e["id"] = n
        e["out"] = _new(mapping, e["ate"])
        e["dur"] = round(e["ate"] - e["de"], 3)
    events.progress(3, 4, "renderizando a narração cortada")
    destination = p / "narracao.wav"
    _render(origin, segs, destination)
    events.progress(4, 4, "conferindo o corte")
    model = model or _whisper(project)
    cut = _transcribe(model, _signal(destination), None, language)
    conf = cross_check(whisper, cut, emendas, protected, _pauses(destination), geo)
    r = {"assinatura": signature, "duracao_antes": round(len(x) / SR, 3), "duracao": round(total, 3),
         "segmentos": segs, "mapa": mapping, "emendas": emendas, "revertidas": reverted,
         "aplicadas": reverted, "vicios": len(cuts), "conferencia": conf}
    (p / "corte.json").write_text(json.dumps(r, ensure_ascii=False, indent=1))
    print(f"  corte pelo som: {r['duracao_antes']:.1f} s → {total:.1f} s · {len(emendas)} emendas "
          f"({sum(e['tipo'] == 'vicio' for e in emendas)} com vício) · {len(protected)} palavras protegidas · "
          f"{len(conf['sumidas'])} trechos a conferir · {len(conf['encurtadas'])} palavras encurtadas · "
          f"{len(geo)} cortadas")
    return r


def revert(project, de, ate, revert=True):
    """Marca (ou desmarca) a faixa [de, ate] da narração editada como revertida; vale no próximo `analisar`."""
    c = load(project)
    if not c:
        raise ValueError("corte pelo som ainda não foi feito")
    rev = [r for r in c["revertidas"] if not (r[0] < ate and r[1] > de)]
    if revert:
        rev.append([de, ate])
    c["revertidas"] = sorted(rev)
    (folder(project) / "corte.json").write_text(json.dumps(c, ensure_ascii=False, indent=1))
    return c


def state(project):
    """Resumo para o app: feito, atualizado (narração e reversões batem), números da conferência."""
    c = load(project)
    if not c:
        return {"feito": False}
    origin = project.pasta / "narracao.wav"
    current = origin.exists() and c["assinatura"] == _signature(origin) and c["revertidas"] == c["aplicadas"]
    conf = c["conferencia"]
    return {"feito": True, "atualizado": current, "duracao_antes": c["duracao_antes"], "duracao": c["duracao"],
            "emendas": len(c["emendas"]), "revertidas": len(c["revertidas"]), "vicios": c["vicios"],
            "sumidas": len(conf["sumidas"]), "repeticoes": len(conf["repeticoes"]), "pausas": len(conf["pausas"]),
            "protegidas": len(conf["protegidas"]), "nota": conf["nota"],
            "encurtadas": len(conf.get("encurtadas", [])), "cortadas": len(conf.get("cortadas", []))}
