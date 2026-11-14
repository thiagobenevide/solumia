"""Per-phoneme pronunciation of reading aloud: the expected IPA of each word comes from espeak-ng
(the same one Kokoro uses) and what was said, from the phonetic wav2vec2 in the
`pronuncia/servidor.py` process (venv with torch). Without that venv, it returns None and the
assessment stays at the word level."""

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


def ipa(items: list[str], language: str) -> list[str]:
    """IPA of each word, without stress marks."""
    import espeakng_loader
    from phonemizer import phonemize
    from phonemizer.backend.espeak.wrapper import EspeakWrapper

    EspeakWrapper.set_library(espeakng_loader.get_library_path())
    EspeakWrapper.set_data_path(espeakng_loader.get_data_path())
    output = phonemize(
        items,
        language=ESPEAK.get(language, "en-us"),
        backend="espeak",
        strip=True,
        with_stress=False,
        njobs=1,
    )
    return [str(s).replace(" ", "") for s in output]


class Pronunciation:
    def __init__(self, python: str = "") -> None:
        self._python = Path(python).expanduser() if python else _XTTS_PYTHON
        self._process: subprocess.Popen[str] | None = None
        self._failed = False
        self._lock = threading.Lock()

    def _processo(self) -> subprocess.Popen[str] | None:
        if self._process is not None and self._process.poll() is None:
            return self._process
        if self._failed or not self._python.is_file():
            return None
        process = subprocess.Popen(
            [str(self._python), str(_DIR / "servidor.py")],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        assert process.stdout is not None
        if '"pronto"' not in process.stdout.readline():
            process.kill()
            self._failed = True
            logger.warning("Modelo de pronúncia não subiu; leitura avaliada só por palavras")
            return None
        self._process = process
        return process

    def evaluate(
        self, audio_16k: Any, reference: str, language: str
    ) -> list[dict[str, Any]] | None:
        """Accuracy of each word of the reference (in `palavras` order), or None without the
        model."""
        import numpy as np

        items = [p for p, _, _ in split_words(reference)]
        if not items:
            return []
        try:
            expected = ipa(items, language)
        except Exception as e:  # espeak ausente
            logger.warning("Sem IPA de referência (%s)", e)
            return None
        with self._lock, tempfile.TemporaryDirectory() as tmp:
            process = self._processo()
            if process is None:
                return None
            assert process.stdin is not None and process.stdout is not None
            path = Path(tmp) / "audio.npy"
            np.save(path, np.asarray(audio_16k, dtype=np.float32))
            process.stdin.write(json.dumps({"audio": str(path), "ipa": expected}) + "\n")
            process.stdin.flush()
            answer = json.loads(process.stdout.readline() or '{"erro": "processo encerrado"}')
        if "erro" in answer:
            logger.warning("Pronúncia falhou: %s", answer["erro"])
            return None
        return [{"indice": k, **p} for k, p in enumerate(answer["palavras"])]
