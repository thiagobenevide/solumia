"""Tempos de palavra precisos por alinhamento forçado: o Whisper diz O QUE foi dito; o alinhamento (CTC, `ia/
alinhar_ctc.py` no `.venv-img`) diz ONDE, com erro de ~20–40 ms contra 100–300 ms do Whisper. Usado só pelas
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
from esteira.projeto import RAIZ

PY_IMG = RAIZ / ".venv-img" / "bin" / "python"
MODELO = "jonatasgrosman/wav2vec2-large-xlsr-53-portuguese"
DESVIO_MAX = 0.6  # s: tempo alinhado mais longe que isto do Whisper é erro do alinhamento; fica o do Whisper


def ligado(cfg):
    return cfg.get("cortes", {}).get("alinhamento", True) and PY_IMG.exists()


def _assinatura(audio, palavras):
    st = Path(audio).stat()
    h = hashlib.sha1(json.dumps([str(audio), st.st_size, st.st_mtime_ns, palavras]).encode()).hexdigest()
    return h[:16]


def refinar(audio, palavras, cache=None, cfg=None):
    """palavras [[ini, fim, texto]] → mesma lista com ini/fim do alinhamento forçado onde ele deu certo."""
    if not palavras or (cfg is not None and not ligado(cfg)) or not PY_IMG.exists():
        return palavras
    chave = _assinatura(audio, palavras)
    if cache and Path(cache).exists():
        d = json.loads(Path(cache).read_text())
        if d.get("chave") == chave:
            return d["palavras"]
    try:
        tempos = _rodar(audio, palavras)
    except (subprocess.CalledProcessError, OSError, ValueError) as e:
        erro = (getattr(e, "stderr", None) or str(e)).strip()[-200:]
        events.warning(f"alinhamento forçado falhou ({erro}); bordas pelo tempo do Whisper")
        return palavras
    saida = combinar(palavras, tempos)
    if cache:
        Path(cache).write_text(json.dumps({"chave": chave, "palavras": saida}, ensure_ascii=False))
    return saida


def combinar(palavras, tempos):
    """Aplica os tempos alinhados (None = não alinhou) sem deixar uma palavra passar por cima da vizinha."""
    saida = []
    for (ini, fim, t), al in zip(palavras, tempos, strict=True):
        if al and abs(al[0] - ini) <= DESVIO_MAX and abs(al[1] - fim) <= DESVIO_MAX and al[1] > al[0]:
            ini, fim = al
        saida.append([ini, fim, t])
    for a, b in zip(saida, saida[1:]):
        if a[1] > b[0]:
            a[1] = max(a[0] + 0.01, b[0])
    return saida


def _rodar(audio, palavras):
    from esteira.ia.local import liberar_gpu
    from esteira.transcrever import _decodificar
    liberar_gpu()
    with tempfile.TemporaryDirectory() as tmp:
        cru = Path(tmp) / "audio.f32"
        _decodificar(audio).tofile(cru)
        pedido = Path(tmp) / "pedido.json"
        pedido.write_text(json.dumps({"audio": str(cru), "palavras": palavras, "modelo": MODELO}))
        r = subprocess.run([str(PY_IMG), "-I", str(RAIZ / "esteira/ia/alinhar_ctc.py"), str(pedido)],
                           capture_output=True, text=True, check=True)
    tempos = json.loads(r.stdout.strip().splitlines()[-1])
    if len(tempos) != len(palavras):
        raise ValueError("alinhamento devolveu outro número de palavras")
    return tempos
