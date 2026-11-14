"""Pronúncia por fonema da leitura em voz alta: o IPA esperado de cada palavra vem do espeak-ng
(o mesmo que o Kokoro usa) e o que foi dito, do wav2vec2 fonético no processo de
`pronuncia/servidor.py` (venv com torch). Sem esse venv, devolve None e a avaliação fica só nas
palavras."""

import json
import logging
import subprocess
import tempfile
import threading
from pathlib import Path
from typing import Any

from shared.speech_text import split_words

logger = logging.getLogger(__name__)

_DIR = Path(__file__).resolve().parents[2] / "pronuncia"
_XTTS_PYTHON = Path(__file__).resolve().parents[2] / "xtts" / ".venv" / "bin" / "python"
ESPEAK = {"en": "en-us", "es": "es", "fr": "fr-fr", "pt": "pt-br"}


def ipa(lista: list[str], idioma: str) -> list[str]:
    """IPA de cada palavra, sem marcas de tônica."""
    import espeakng_loader
    from phonemizer import phonemize
    from phonemizer.backend.espeak.wrapper import EspeakWrapper

    EspeakWrapper.set_library(espeakng_loader.get_library_path())
    EspeakWrapper.set_data_path(espeakng_loader.get_data_path())
    saida = phonemize(
        lista,
        language=ESPEAK.get(idioma, "en-us"),
        backend="espeak",
        strip=True,
        with_stress=False,
        njobs=1,
    )
    return [str(s).replace(" ", "") for s in saida]


class Pronuncia:
    def __init__(self, python: str = "") -> None:
        self._python = Path(python).expanduser() if python else _XTTS_PYTHON
        self._proc: subprocess.Popen[str] | None = None
        self._falhou = False
        self._trava = threading.Lock()

    def _processo(self) -> subprocess.Popen[str] | None:
        if self._proc is not None and self._proc.poll() is None:
            return self._proc
        if self._falhou or not self._python.is_file():
            return None
        proc = subprocess.Popen(
            [str(self._python), str(_DIR / "servidor.py")],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        assert proc.stdout is not None
        if '"pronto"' not in proc.stdout.readline():
            proc.kill()
            self._falhou = True
            logger.warning("Modelo de pronúncia não subiu; leitura avaliada só por palavras")
            return None
        self._proc = proc
        return proc

    def avaliar(self, audio_16k: Any, referencia: str, idioma: str) -> list[dict[str, Any]] | None:
        """Acerto de cada palavra da [referencia] (na ordem de `palavras`), ou None sem o modelo."""
        import numpy as np

        lista = [p for p, _, _ in split_words(referencia)]
        if not lista:
            return []
        try:
            esperado = ipa(lista, idioma)
        except Exception as e:  # espeak ausente
            logger.warning("Sem IPA de referência (%s)", e)
            return None
        with self._trava, tempfile.TemporaryDirectory() as tmp:
            proc = self._processo()
            if proc is None:
                return None
            assert proc.stdin is not None and proc.stdout is not None
            caminho = Path(tmp) / "audio.npy"
            np.save(caminho, np.asarray(audio_16k, dtype=np.float32))
            proc.stdin.write(json.dumps({"audio": str(caminho), "ipa": esperado}) + "\n")
            proc.stdin.flush()
            resposta = json.loads(proc.stdout.readline() or '{"erro": "processo encerrado"}')
        if "erro" in resposta:
            logger.warning("Pronúncia falhou: %s", resposta["erro"])
            return None
        return [{"indice": k, **p} for k, p in enumerate(resposta["palavras"])]
