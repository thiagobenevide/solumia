"""Tempos de palavra precisos por alinhamento forçado: o Whisper diz O QUE foi dito; o alinhamento (CTC, `ai/
ctc_align.py` no `.venv-img`) diz ONDE, com erro de ~20–40 ms contra 100–300 ms do Whisper. Usado só pelas
bordas dos cortes (`cortes._intervalos`, `estudio/corte.analisar`).

Sem `.venv-img`, sem o modelo ou com erro: fica o tempo do Whisper (o núcleo de `bordas.py` ainda corrige pelo som)
e um aviso. Desligar em `config.toml`: `[cortes] alinhamento = false`. Cache por assinatura do áudio + palavras.
"""
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path

from esteira.core import events
from esteira.project import ROOT

PY_IMG = ROOT / ".venv-img" / "bin" / "python"
MODEL = "jonatasgrosman/wav2vec2-large-xlsr-53-portuguese"
DEVIATION_MAX = 0.6  # s: tempo alinhado mais longe que isto do Whisper é erro do alinhamento; fica o do Whisper


def enabled(cfg):
    return cfg.get("cortes", {}).get("alinhamento", True) and PY_IMG.exists()


def _signature(audio, words):
    st = Path(audio).stat()
    h = hashlib.sha1(json.dumps([str(audio), st.st_size, st.st_mtime_ns, words]).encode()).hexdigest()
    return h[:16]


def refine(audio, words, cache=None, cfg=None):
    """palavras [[ini, fim, texto]] → mesma lista com ini/fim do alinhamento forçado onde ele deu certo."""
    if not words or (cfg is not None and not enabled(cfg)) or not PY_IMG.exists():
        return words
    key = _signature(audio, words)
    if cache and Path(cache).exists():
        d = json.loads(Path(cache).read_text())
        if d.get("chave") == key:
            return d["palavras"]
    try:
        times = _run(audio, words)
    except (subprocess.CalledProcessError, OSError, ValueError) as e:
        error = (getattr(e, "stderr", None) or str(e)).strip()[-200:]
        events.warning(f"alinhamento forçado falhou ({error}); bordas pelo tempo do Whisper")
        return words
    output = combine(words, times)
    if cache:
        Path(cache).write_text(json.dumps({"chave": key, "palavras": output}, ensure_ascii=False))
    return output


def combine(words, times):
    """Aplica os tempos alinhados (None = não alinhou) sem deixar uma palavra passar por cima da vizinha."""
    output = []
    for (start, end, t), al in zip(words, times, strict=True):
        if al and abs(al[0] - start) <= DEVIATION_MAX and abs(al[1] - end) <= DEVIATION_MAX and al[1] > al[0]:
            start, end = al
        output.append([start, end, t])
    for a, b in zip(output, output[1:]):
        if a[1] > b[0]:
            a[1] = max(a[0] + 0.01, b[0])
    return output


def _run(audio, words):
    from esteira.ai.local import free_gpu
    from esteira.transcribe import _decode
    free_gpu()
    with tempfile.TemporaryDirectory() as tmp:
        raw = Path(tmp) / "audio.f32"
        _decode(audio).tofile(raw)
        request = Path(tmp) / "pedido.json"
        request.write_text(json.dumps({"audio": str(raw), "words": words, "model": MODEL}))
        r = subprocess.run([str(PY_IMG), "-I", str(ROOT / "esteira/ai/ctc_align.py"), str(request)],
                           capture_output=True, text=True, check=True)
    times = json.loads(r.stdout.strip().splitlines()[-1])
    if len(times) != len(words):
        raise ValueError("alinhamento devolveu outro número de palavras")
    return times
