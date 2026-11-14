"""Worker voice: transcription with faster-whisper (GPU if available) and speech with XTTS-v2
(fallbacks: Kokoro, Piper and espeak-ng).

faster-whisper is an optional dependency (`uv sync --extra voz`, + `--extra voz-gpu` for the GPU);
the model loads on the first transcription and stays in memory."""

import asyncio
import base64
import contextlib
import ctypes
import glob
import json
import logging
import os
import re
import shutil
import site
import subprocess
import tempfile
import threading
import wave
from pathlib import Path
from typing import Any

from shared.speech_text import align_word_times
from worker.core.config import WorkerSettings
from worker.pronunciation import Pronunciation

logger = logging.getLogger(__name__)

TASKS = ("transcrever", "falar", "falar_marcado", "avaliar_leitura")

# Guided reading (Studies › Language): Kokoro voice and language code per studied language.
VOICES_KOKORO = {
    "en": ("af_heart", "en-us"),
    "es": ("ef_dora", "es"),
    "fr": ("ff_siwis", "fr-fr"),
    "pt": ("pf_dora", "pt-br"),
}

_XTTS_DIR = Path(__file__).resolve().parents[2] / "xtts"
_XTTS_PYTHON = _XTTS_DIR / ".venv" / "bin" / "python"

# Phrases Whisper makes up on silence or noise (YouTube captions in its training).
_HALLUCINATIONS = re.compile(
    r"legendas? (pela|por)|amara\.org|inscreva-se|obrigado por assistir|tchau,? tchau|"
    r"thanks? (you )?for watching|subscribe to|subtitles by|"
    r"^(obrigad[oa]|tchau|thank you|bye|you|\.+|…)[.!]?$",
    re.IGNORECASE,
)

# Initial context per language: a Portuguese prompt would pull English speech into Portuguese.
_PROMPT_EN = "Conversation in English with a personal assistant about schedule, tasks and code."


def choose_language(
    probabilidades: list[tuple[str, float]], aceitos: list[str], default: str
) -> str:
    """The most likely language among the accepted ones: unconstrained Whisper confuses Brazilian
    Portuguese with Galician or Spanish and drifts into translation."""
    melhores = {i: p for i, p in probabilidades if i in aceitos}
    return max(melhores, key=lambda i: melhores[i]) if melhores else default


def _load_libs_cuda() -> None:
    # The CUDA libs come from the nvidia-* pip packages (voz-gpu extra); ctranslate2 only finds
    # them preloaded.
    for base in site.getsitepackages():
        for default in ("nvidia/cublas/lib/libcublas*.so.*", "nvidia/cudnn/lib/libcudnn*.so.*"):
            for lib in sorted(glob.glob(os.path.join(base, default))):
                with contextlib.suppress(OSError):
                    ctypes.CDLL(lib, mode=ctypes.RTLD_GLOBAL)


_ORDINALS = (
    "Primeiro", "Segundo", "Terceiro", "Quarto", "Quinto",
    "Sexto", "Sétimo", "Oitavo", "Nono", "Décimo",
)  # fmt: skip
_MONTHS = (
    "janeiro", "fevereiro", "março", "abril", "maio", "junho",
    "julho", "agosto", "setembro", "outubro", "novembro", "dezembro",
)  # fmt: skip
_ABBREVIATIONS = {
    r"\bp\. ?ex\.": "por exemplo",
    r"\bex\.:?": "por exemplo",
    r"\bobs\.:?": "observação:",
    r"\betc\.?": "etcétera",
    r"\bvs\.?": "versus",
    r"\bn[ºo°]\s*(?=\d)": "número ",
}
_EMOJIS = re.compile("[\U0001f000-\U0001faff☀-➿⬀-⯿️‍]")


def _ordinal(n: int) -> str:
    return _ORDINALS[n - 1] if 1 <= n <= len(_ORDINALS) else f"Item {n}"


def _lines_spoken(t: str) -> list[str]:
    """Markdown structure as didactic speech: headings become "Tópico 1, …" (when there is more than
    one) and list items become "Primeiro, …", "Segundo, …" (sub-items just the text)."""
    lines = t.split("\n")
    titulos = sum(1 for line in lines if re.match(r"\s*#+\s+\S", line))
    output: list[str] = []
    n_title = n_item = 0
    for line in lines:
        if not line.strip():
            n_item = 0  # a blank line ends the list
            continue
        if m := re.match(r"\s*#+\s+(.*)", line):
            n_title += 1
            n_item = 0
            output.append(f"Tópico {n_title}, {m.group(1)}" if titulos > 1 else m.group(1))
            continue
        if m := re.match(r"( *)(?:[-*+•]|(\d+)[.)])\s+(.*)", line):
            if len(m.group(1)) >= 2:  # sub-item
                output.append(m.group(3))
                continue
            n_item = int(m.group(2)) if m.group(2) else n_item + 1
            output.append(f"{_ordinal(n_item)}, {m.group(3)}")
            continue
        n_item = 0
        output.append(line.strip())
    return output


def _score(line: str) -> str:
    line = re.sub(r"(\.{2,}|…)$", "", line.strip()).strip(" ,;:")
    if not line:
        return ""
    return line if line[-1] in ".!?" else line + "."


def _data(m: re.Match[str]) -> str:
    day, month, year = int(m[1]), int(m[2]), m[3]
    if not 1 <= month <= 12:
        return m[0].replace("/", " de ")
    return f"{day} de {_MONTHS[month - 1]}" + (f" de {year}" if year else "")


def text_to_speech(text: str, limite: int) -> str:
    """Text the synthesizer reads without saying "ponto", "asterisco" etc.: strips markdown, links
    and
    emojis, turns lists and headings into didactic speech, spells out times, dates and symbols and
    only lets letters, digits and . , ! ? through. Long text is cut at the end of a sentence."""
    t = re.sub(r"```.*?```", " ", text, flags=re.DOTALL)
    t = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", t)  # [text](link) → text
    t = re.sub(r"\[\[([^\]|]+)(\|([^\]]+))?\]\]", lambda m: m.group(3) or m.group(1), t)
    t = re.sub(r"https?://\S+|www\.\S+", " ", t)
    t = re.sub(r"\*\*|__|~~|`", "", t)
    t = _EMOJIS.sub(" ", t)
    t = re.sub(r"^\s*>\s?", "", t, flags=re.MULTILINE)
    t = re.sub(r"^\s*\|?[\s:|-]*-[\s:|-]*\|?\s*$", "", t, flags=re.MULTILINE)  # table row
    t = " ".join(_score(line) for line in _lines_spoken(t))
    for default, swap in _ABBREVIATIONS.items():
        t = re.sub(default, swap, t, flags=re.IGNORECASE)
    # Times, dates and symbols spelled out (otherwise they become "dois pontos", "barra", "cifrão").
    t = re.sub(r"\b(\d{1,2})[:h](\d{2})\b", lambda m: f"{int(m[1])} e {m[2]}", t)
    t = re.sub(r"\b(\d{1,2})h\b", lambda m: f"{m[1]} {'hora' if m[1] == '1' else 'horas'}", t)
    t = re.sub(r"\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b", _data, t)
    t = re.sub(r"R\$\s*(\d[\d.]*(?:,\d\d)?)", lambda m: m[1].removesuffix(",00") + " reais", t)
    t = re.sub(r"(\d)\s*%", r"\1 por cento", t)
    t = re.sub(r"(\d)\s*\+\s*(\d)", r"\1 mais \2", t)
    t = re.sub(r"(\d)\s*[x×]\s*(\d)", r"\1 vezes \2", t)
    t = re.sub(r"\s&\s", " e ", t)
    t = re.sub(r"\be/ou\b", "e ou", t)
    # Pauses: ellipses, dashes, semicolons, parentheses and colons become commas.
    t = re.sub(r"\.{2,}|…|\s[–—-]\s|[;()\[\]{}]", ", ", t)
    t = re.sub(r":(?=\s|$)", ",", t)
    # Allow list: the model would read any other symbol aloud.
    t = re.sub(r"[^\w\s.,!?]|_", " ", t)
    t = re.sub(r"(\d)([.,])(\d)", lambda m: m[1] + {".": "\x01", ",": "\x02"}[m[2]] + m[3], t)
    t = re.sub(r"\s+([.,!?])", r"\1", t)
    t = re.sub(r"([.,!?])(?=[^\W\d])", r"\1 ", t)
    t = re.sub(r"[.,!?\s]*([.!?])[.,!?\s]*", r"\1 ", t)  # "., ." → "."
    t = re.sub(r"[,\s]*,[,\s]*", ", ", t)
    t = re.sub(r"\s{2,}", " ", t).strip(" ,").replace("\x01", ".").replace("\x02", ",")
    if len(t) > limite:
        cut = max(t.rfind(p, 0, limite) for p in (". ", "! ", "? "))
        t = t[: cut + 1] if cut > limite // 3 else t[:limite].rsplit(" ", 1)[0] + "."
    return t


def divide_spans(text: str, tamanho: int = 260) -> list[str]:
    """Chunks to play while the next one is synthesized: the first is a single sentence (the voice
    starts right away); the others join sentences up to ~size characters."""
    spans: list[str] = []
    for sentence in re.split(r"(?<=[.!?])\s+", text):
        if not sentence.strip():
            continue
        if len(spans) == 1 and len(spans[0]) < 40:  # first sentence too short
            spans[0] += " " + sentence
        elif len(spans) > 1 and len(spans[-1]) + len(sentence) < tamanho:
            spans[-1] += " " + sentence
        else:
            spans.append(sentence)
    return spans


def compress(wav: bytes) -> tuple[bytes, str]:
    """WAV → AAC (.m4a, plays on every device and is ~10x smaller) through ffmpeg; without it, the
    WAV."""
    if not shutil.which("ffmpeg"):
        return wav, "audio/wav"
    with tempfile.TemporaryDirectory() as tmp:
        output = Path(tmp) / "fala.m4a"
        try:
            subprocess.run(
                [
                    "ffmpeg",
                    "-loglevel",
                    "error",
                    "-f",
                    "wav",
                    "-i",
                    "pipe:0",
                    "-c:a",
                    "aac",
                    "-b:a",
                    "64k",
                    "-movflags",
                    "+faststart",
                    str(output),
                ],
                input=wav,
                capture_output=True,
                check=True,
                timeout=60,
            )
            return output.read_bytes(), "audio/mp4"
        except (subprocess.SubprocessError, OSError) as e:
            logger.warning("ffmpeg não comprimiu a fala (%s); mandando WAV", e)
            return wav, "audio/wav"


class Voice:
    def __init__(self, settings: WorkerSettings) -> None:
        self._s = settings
        self._model: Any = None
        self._tts: Any = None
        self._xtts_process: subprocess.Popen[str] | None = None
        self._xtts_failed = False
        self._xtts_lock = threading.Lock()
        self._pronunciation = Pronunciation(settings.pronuncia_python)

    async def executar(self, task: str, payload: dict[str, Any]) -> dict[str, Any]:
        if task == "transcrever":
            audio = base64.b64decode(payload["audio_b64"])
            text, language = await asyncio.to_thread(
                self._transcribe, audio, payload.get("mime", ""), str(payload.get("idioma") or "")
            )
            return {"texto": text, "idioma": language}
        if task == "falar":
            span = payload.get("trecho")
            wav = await asyncio.to_thread(
                self._speak, str(payload["texto"]), None if span is None else int(span)
            )
            return {"audio_b64": base64.b64encode(wav).decode(), "mime": "audio/wav"}
        if task == "falar_marcado":
            return await asyncio.to_thread(
                self._speak_marcado,
                str(payload["texto"]),
                str(payload.get("idioma") or "en"),
                float(payload.get("velocidade") or 1.0),
            )
        if task == "avaliar_leitura":
            return await asyncio.to_thread(
                self._evaluate_reading,
                base64.b64decode(payload["audio_b64"]),
                str(payload.get("mime") or ""),
                str(payload.get("idioma") or "en"),
                str(payload.get("referencia") or ""),
            )
        raise ValueError(f"Tarefa desconhecida: {task}")

    def _words_whisper(
        self, caminho: str, language: str, dica: str | None = None, vad: bool = False
    ) -> list[dict[str, Any]]:
        """Words heard with each one's timing (s) and Whisper's confidence."""
        segments, _ = self._whisper().transcribe(
            caminho,
            language=language,
            beam_size=self._s.whisper_beam,
            word_timestamps=True,
            condition_on_previous_text=False,
            vad_filter=vad,
            initial_prompt=dica,
        )
        return [
            {"palavra": w.word.strip(), "inicio": w.start, "fim": w.end, "prob": w.probability}
            for s in segments
            for w in s.words or []
        ]

    def _speak_marcado(self, text: str, language: str, speed: float) -> dict[str, Any]:
        """Guided reading: the speech of the text in its language and each word's timing. Whisper
        listens to its own speech (with the text as a hint) and `align_word_times` matches it to
        the text words; without Whisper, timing is proportional to word length."""
        tts = self._kokoro()
        if tts is None:
            raise RuntimeError("Leitura guiada indisponível: o Kokoro não carregou no worker.")
        voice, lang = VOICES_KOKORO.get(language, VOICES_KOKORO["en"])
        wav = self._speak_kokoro(tts, text, voice, lang, min(max(speed, 0.5), 2.0))
        with tempfile.NamedTemporaryFile(suffix=".wav") as f:
            f.write(wav)
            f.flush()
            with wave.open(f.name) as w:
                duration = w.getnframes() / w.getframerate()
            spoken: list[dict[str, Any]] = []
            try:
                spoken = self._words_whisper(f.name, language, dica=text)
            except (RuntimeError, ValueError) as e:
                logger.info("Leitura guiada sem Whisper (%s): tempo proporcional", e)
        audio, mime = compress(wav)
        return {
            "audio_b64": base64.b64encode(audio).decode(),
            "mime": mime,
            "duracao": round(duration, 3),
            "palavras": align_word_times(text, spoken, duration),
        }

    def _evaluate_reading(
        self, audio: bytes, mime: str, language: str, reference: str
    ) -> dict[str, Any]:
        """Reading aloud: what Whisper heard (word, time, confidence) and, with the phonetic model,
        the pronunciation accuracy of each word of the reference."""
        from faster_whisper import decode_audio

        suffix = {"audio/wav": ".wav", "audio/mp4": ".m4a", "audio/ogg": ".ogg"}.get(mime, ".audio")
        with tempfile.NamedTemporaryFile(suffix=suffix) as f:
            f.write(audio)
            f.flush()
            spoken = self._words_whisper(f.name, language, vad=True)
            pronunciation = self._pronunciation.evaluate(decode_audio(f.name), reference, language)
        warning = ""
        if pronunciation is None:
            warning = "Pronúncia por fonema indisponível no worker."
        return {"palavras": spoken, "pronuncia": pronunciation, "aviso": warning}

    def _whisper(self) -> Any:
        if self._model is None:
            try:
                from faster_whisper import WhisperModel
            except ImportError as e:
                raise RuntimeError(
                    "Transcrição indisponível: instale o extra de voz do worker "
                    "(uv sync --extra voz)."
                ) from e
            dispositivo = self._s.whisper_dispositivo
            if dispositivo in ("auto", "cuda"):
                _load_libs_cuda()
                try:
                    model = self._s.whisper_modelo or "large-v3-turbo"
                    self._model = WhisperModel(model, device="cuda", compute_type="int8_float16")
                    logger.info("Whisper %s na GPU", model)
                    return self._model
                except (RuntimeError, ValueError) as e:
                    if dispositivo == "cuda":
                        raise
                    logger.warning("Whisper sem GPU (%s); usando a CPU", e)
            model = self._s.whisper_modelo or "small"
            self._model = WhisperModel(model, device="cpu", compute_type="int8")
            logger.info("Whisper %s na CPU", model)
        return self._model

    async def aquecer(self) -> None:
        """Loads the model when the worker starts: the first speech does not wait for the load
        (10–30 s)."""
        try:
            await asyncio.to_thread(self._whisper)
        except Exception as e:  # without the voice extra the worker runs with the LLM only
            logger.info("Whisper não pré-carregado: %s", e)
        await asyncio.to_thread(self._aquecer_xtts)

    def _aquecer_xtts(self) -> None:
        with self._xtts_lock:
            self._xtts()

    def _language(self, modelo: Any, caminho: str, request: str) -> str:
        aceitos = [i.strip() for i in self._s.voz_idiomas.split(",") if i.strip()]
        if request in aceitos:
            return request
        if len(aceitos) < 2:
            return aceitos[0] if aceitos else self._s.voz_idioma
        try:
            from faster_whisper import decode_audio

            # The first 30 s are enough to detect; restricts to pt/en instead of the 99 languages.
            sample = decode_audio(caminho)[: 16000 * 30]
            _, _, probabilidades = modelo.detect_language(sample)
        except (ImportError, ValueError, RuntimeError) as e:
            logger.warning("Detecção de idioma falhou (%s); usando %s", e, self._s.voz_idioma)
            return self._s.voz_idioma
        return choose_language(probabilidades, aceitos, self._s.voz_idioma)

    def _transcribe(self, audio: bytes, mime: str, language: str = "") -> tuple[str, str]:
        suffix = {"audio/wav": ".wav", "audio/mp4": ".m4a", "audio/ogg": ".ogg"}.get(mime, ".audio")
        with tempfile.NamedTemporaryFile(suffix=suffix) as f:
            f.write(audio)
            f.flush()
            model = self._whisper()
            language = self._language(model, f.name, language)
            prompt = {"pt": self._s.whisper_prompt, "en": _PROMPT_EN}.get(language, "")
            segments, _ = model.transcribe(
                f.name,
                language=language,
                # Greedy search: on large-v3-turbo the accuracy difference is minimal and it is 2–3x
                # faster than beam 5 (which matters in voice conversations).
                beam_size=self._s.whisper_beam,
                vad_filter=True,
                vad_parameters={"min_silence_duration_ms": 500},
                condition_on_previous_text=False,
                without_timestamps=True,
                initial_prompt=prompt or None,
            )
            parts = [
                s.text.strip()
                for s in segments
                if not (s.no_speech_prob > 0.6 and s.avg_logprob < -1.0)
                and not _HALLUCINATIONS.search(s.text.strip())
            ]
            # Empty becomes "não entendi" on the server, instead of an answer to made-up audio.
            return " ".join(p for p in parts if p).strip(), language

    def _kokoro(self) -> Any:
        """Kokoro loaded once; None (and no retry) without the package or the files."""
        if self._tts is None:
            self._tts = False
            model = Path(self._s.kokoro_modelo).expanduser()
            voices = Path(self._s.kokoro_vozes).expanduser()
            if model.is_file() and voices.is_file():
                try:
                    from kokoro_onnx import Kokoro

                    self._tts = Kokoro(str(model), str(voices))
                    logger.info("Fala com Kokoro (%s)", self._s.kokoro_voz)
                except Exception as e:  # missing package or invalid model: fall back to Piper
                    logger.warning("Kokoro indisponível (%s); usando o Piper", e)
        return self._tts or None

    def _speak_kokoro(
        self,
        tts: Any,
        text: str,
        voice: str | None = None,
        lang: str = "pt-br",
        speed: float | None = None,
    ) -> bytes:
        import io

        import numpy as np

        audio, rate = tts.create(
            text,
            voice=voice or self._s.kokoro_voz,
            speed=speed or self._s.kokoro_velocidade,
            lang=lang,
        )
        pcm = (np.clip(audio, -1.0, 1.0) * 32767).astype("<i2").tobytes()
        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(rate)
            w.writeframes(pcm)
        return buf.getvalue()

    def _xtts(self) -> subprocess.Popen[str] | None:
        """XTTS process with the model loaded; None without the venv or if it does not start."""
        if self._xtts_process is not None and self._xtts_process.poll() is None:
            return self._xtts_process
        if self._xtts_failed:
            return None
        python = Path(self._s.xtts_python).expanduser() if self._s.xtts_python else _XTTS_PYTHON
        if not python.is_file():
            self._xtts_failed = True
            return None
        process = subprocess.Popen(
            [
                str(python),
                str(_XTTS_DIR / "servidor.py"),
                self._s.xtts_voz,
                "pt",
                str(Path(self._s.xtts_referencia).expanduser()),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        assert process.stdout is not None
        if '"pronto"' not in process.stdout.readline():  # empty line = it died while loading
            process.kill()
            self._xtts_failed = True
            logger.warning("XTTS não subiu; usando o Kokoro")
            return None
        logger.info("Fala com XTTS-v2 (%s)", self._s.xtts_voz)
        self._xtts_process = process
        return process

    def _speak_xtts(self, process: subprocess.Popen[str], text: str) -> bytes | None:
        assert process.stdin is not None and process.stdout is not None
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "fala.wav"
            process.stdin.write(json.dumps({"texto": text, "saida": str(output)}) + "\n")
            process.stdin.flush()
            answer = json.loads(process.stdout.readline() or '{"erro": "processo encerrado"}')
            if "erro" in answer:
                logger.warning("XTTS falhou (%s); usando o Kokoro", answer["erro"])
                return None
            return output.read_bytes()

    def _speak(self, text: str, span: int | None = None) -> bytes:
        """WAV of the whole text or only of chunk n; a chunk past the end = empty,
        the app plays one while it requests the next."""
        text = text_to_speech(text, self._s.fala_max_caracteres) or "Pronto."
        if span is not None:
            spans = divide_spans(text)
            if span >= len(spans):
                return b""
            text = spans[span]
        with self._xtts_lock:  # one request at a time in the same process
            process = self._xtts()
            wav = self._speak_xtts(process, text) if process else None
        if wav:
            return wav
        tts = self._kokoro()
        if tts is not None:
            return self._speak_kokoro(tts, text)
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "fala.wav"
            if self._s.piper_modelo and shutil.which(self._s.piper_bin):
                cmd = [
                    self._s.piper_bin,
                    "--model",
                    self._s.piper_modelo,
                    "--length-scale",
                    str(self._s.piper_lentidao),
                    "--output_file",
                    str(output),
                ]
                subprocess.run(
                    cmd, input=text.encode(), check=True, capture_output=True, timeout=120
                )
            elif shutil.which(self._s.espeak_bin):
                cmd = [self._s.espeak_bin, "-v", self._s.espeak_voz, "-w", str(output), text]
                subprocess.run(cmd, check=True, capture_output=True, timeout=120)
            else:
                raise RuntimeError(
                    "Fala indisponível: instale o Piper (com uma voz pt_BR) ou o espeak-ng."
                )
            return output.read_bytes()
