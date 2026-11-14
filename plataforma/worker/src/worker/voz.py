"""Voz do Worker: transcrição com faster-whisper (GPU se houver) e fala com XTTS-v2 (reservas:
Kokoro, Piper e espeak-ng).

O faster-whisper é dependência opcional (`uv sync --extra voz`, + `--extra voz-gpu` para a GPU); o
modelo carrega na primeira transcrição e fica na memória."""

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
from worker.pronuncia import Pronuncia

logger = logging.getLogger(__name__)

TAREFAS = ("transcrever", "falar", "falar_marcado", "avaliar_leitura")

# Leitura guiada (Estudos › Linguagem): voz e código de idioma do Kokoro por idioma estudado.
VOZES_KOKORO = {
    "en": ("af_heart", "en-us"),
    "es": ("ef_dora", "es"),
    "fr": ("ff_siwis", "fr-fr"),
    "pt": ("pf_dora", "pt-br"),
}

_XTTS_DIR = Path(__file__).resolve().parents[2] / "xtts"
_XTTS_PYTHON = _XTTS_DIR / ".venv" / "bin" / "python"

# Frases que o Whisper inventa em silêncio ou ruído (legendas do YouTube no treino).
_ALUCINACOES = re.compile(
    r"legendas? (pela|por)|amara\.org|inscreva-se|obrigado por assistir|tchau,? tchau|"
    r"thanks? (you )?for watching|subscribe to|subtitles by|"
    r"^(obrigad[oa]|tchau|thank you|bye|you|\.+|…)[.!]?$",
    re.IGNORECASE,
)

# Contexto inicial por idioma: o prompt em português puxaria a fala em inglês para o português.
_PROMPT_EN = "Conversation in English with a personal assistant about schedule, tasks and code."


def escolher_idioma(
    probabilidades: list[tuple[str, float]], aceitos: list[str], padrao: str
) -> str:
    """O idioma mais provável entre os [aceitos]: o Whisper solto confunde o português do Brasil
    com galego ou espanhol e viaja na tradução."""
    melhores = {i: p for i, p in probabilidades if i in aceitos}
    return max(melhores, key=lambda i: melhores[i]) if melhores else padrao


def _carregar_libs_cuda() -> None:
    # As libs CUDA vêm dos pacotes pip nvidia-* (extra voz-gpu); o ctranslate2 só as acha
    # pré-carregadas.
    for base in site.getsitepackages():
        for padrao in ("nvidia/cublas/lib/libcublas*.so.*", "nvidia/cudnn/lib/libcudnn*.so.*"):
            for lib in sorted(glob.glob(os.path.join(base, padrao))):
                with contextlib.suppress(OSError):
                    ctypes.CDLL(lib, mode=ctypes.RTLD_GLOBAL)


_ORDINAIS = (
    "Primeiro", "Segundo", "Terceiro", "Quarto", "Quinto",
    "Sexto", "Sétimo", "Oitavo", "Nono", "Décimo",
)  # fmt: skip
_MESES = (
    "janeiro", "fevereiro", "março", "abril", "maio", "junho",
    "julho", "agosto", "setembro", "outubro", "novembro", "dezembro",
)  # fmt: skip
_ABREVIACOES = {
    r"\bp\. ?ex\.": "por exemplo",
    r"\bex\.:?": "por exemplo",
    r"\bobs\.:?": "observação:",
    r"\betc\.?": "etcétera",
    r"\bvs\.?": "versus",
    r"\bn[ºo°]\s*(?=\d)": "número ",
}
_EMOJIS = re.compile("[\U0001f000-\U0001faff☀-➿⬀-⯿️‍]")


def _ordinal(n: int) -> str:
    return _ORDINAIS[n - 1] if 1 <= n <= len(_ORDINAIS) else f"Item {n}"


def _linhas_faladas(t: str) -> list[str]:
    """Estrutura do markdown em fala didática: títulos viram "Tópico 1, …" (havendo mais de um) e
    itens de lista viram "Primeiro, …", "Segundo, …" (sub-itens só o texto)."""
    linhas = t.split("\n")
    titulos = sum(1 for linha in linhas if re.match(r"\s*#+\s+\S", linha))
    saida: list[str] = []
    n_titulo = n_item = 0
    for linha in linhas:
        if not linha.strip():
            n_item = 0  # linha em branco encerra a lista
            continue
        if m := re.match(r"\s*#+\s+(.*)", linha):
            n_titulo += 1
            n_item = 0
            saida.append(f"Tópico {n_titulo}, {m.group(1)}" if titulos > 1 else m.group(1))
            continue
        if m := re.match(r"( *)(?:[-*+•]|(\d+)[.)])\s+(.*)", linha):
            if len(m.group(1)) >= 2:  # sub-item
                saida.append(m.group(3))
                continue
            n_item = int(m.group(2)) if m.group(2) else n_item + 1
            saida.append(f"{_ordinal(n_item)}, {m.group(3)}")
            continue
        n_item = 0
        saida.append(linha.strip())
    return saida


def _pontuar(linha: str) -> str:
    linha = re.sub(r"(\.{2,}|…)$", "", linha.strip()).strip(" ,;:")
    if not linha:
        return ""
    return linha if linha[-1] in ".!?" else linha + "."


def _data(m: re.Match[str]) -> str:
    dia, mes, ano = int(m[1]), int(m[2]), m[3]
    if not 1 <= mes <= 12:
        return m[0].replace("/", " de ")
    return f"{dia} de {_MESES[mes - 1]}" + (f" de {ano}" if ano else "")


def texto_para_fala(texto: str, limite: int) -> str:
    """Texto que o sintetizador lê sem dizer "ponto", "asterisco" etc.: tira markdown, links e
    emojis, transforma listas e títulos em fala didática, escreve por extenso horários, datas e
    símbolos e só deixa passar letras, números e . , ! ?. Texto longo é cortado no fim de frase."""
    t = re.sub(r"```.*?```", " ", texto, flags=re.DOTALL)
    t = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", t)  # [texto](link) → texto
    t = re.sub(r"\[\[([^\]|]+)(\|([^\]]+))?\]\]", lambda m: m.group(3) or m.group(1), t)
    t = re.sub(r"https?://\S+|www\.\S+", " ", t)
    t = re.sub(r"\*\*|__|~~|`", "", t)
    t = _EMOJIS.sub(" ", t)
    t = re.sub(r"^\s*>\s?", "", t, flags=re.MULTILINE)
    t = re.sub(r"^\s*\|?[\s:|-]*-[\s:|-]*\|?\s*$", "", t, flags=re.MULTILINE)  # linha de tabela
    t = " ".join(_pontuar(linha) for linha in _linhas_faladas(t))
    for padrao, troca in _ABREVIACOES.items():
        t = re.sub(padrao, troca, t, flags=re.IGNORECASE)
    # Horários, datas e símbolos por extenso (senão vira "dois pontos", "barra", "cifrão").
    t = re.sub(r"\b(\d{1,2})[:h](\d{2})\b", lambda m: f"{int(m[1])} e {m[2]}", t)
    t = re.sub(r"\b(\d{1,2})h\b", lambda m: f"{m[1]} {'hora' if m[1] == '1' else 'horas'}", t)
    t = re.sub(r"\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b", _data, t)
    t = re.sub(r"R\$\s*(\d[\d.]*(?:,\d\d)?)", lambda m: m[1].removesuffix(",00") + " reais", t)
    t = re.sub(r"(\d)\s*%", r"\1 por cento", t)
    t = re.sub(r"(\d)\s*\+\s*(\d)", r"\1 mais \2", t)
    t = re.sub(r"(\d)\s*[x×]\s*(\d)", r"\1 vezes \2", t)
    t = re.sub(r"\s&\s", " e ", t)
    t = re.sub(r"\be/ou\b", "e ou", t)
    # Pausas: reticências, travessões, ponto e vírgula, parênteses e dois pontos viram vírgula.
    t = re.sub(r"\.{2,}|…|\s[–—-]\s|[;()\[\]{}]", ", ", t)
    t = re.sub(r":(?=\s|$)", ",", t)
    # Lista branca: qualquer outro símbolo o modelo leria em voz alta.
    t = re.sub(r"[^\w\s.,!?]|_", " ", t)
    t = re.sub(r"(\d)([.,])(\d)", lambda m: m[1] + {".": "\x01", ",": "\x02"}[m[2]] + m[3], t)
    t = re.sub(r"\s+([.,!?])", r"\1", t)
    t = re.sub(r"([.,!?])(?=[^\W\d])", r"\1 ", t)
    t = re.sub(r"[.,!?\s]*([.!?])[.,!?\s]*", r"\1 ", t)  # "., ." → "."
    t = re.sub(r"[,\s]*,[,\s]*", ", ", t)
    t = re.sub(r"\s{2,}", " ", t).strip(" ,").replace("\x01", ".").replace("\x02", ",")
    if len(t) > limite:
        corte = max(t.rfind(p, 0, limite) for p in (". ", "! ", "? "))
        t = t[: corte + 1] if corte > limite // 3 else t[:limite].rsplit(" ", 1)[0] + "."
    return t


def dividir_trechos(texto: str, tamanho: int = 260) -> list[str]:
    """Trechos para tocar enquanto o próximo é sintetizado: o primeiro é uma frase só (a voz
    começa logo); os outros juntam frases até ~[tamanho] caracteres."""
    trechos: list[str] = []
    for frase in re.split(r"(?<=[.!?])\s+", texto):
        if not frase.strip():
            continue
        if len(trechos) == 1 and len(trechos[0]) < 40:  # primeira frase curta demais
            trechos[0] += " " + frase
        elif len(trechos) > 1 and len(trechos[-1]) + len(frase) < tamanho:
            trechos[-1] += " " + frase
        else:
            trechos.append(frase)
    return trechos


def comprimir(wav: bytes) -> tuple[bytes, str]:
    """WAV → AAC (.m4a, toca em todo aparelho e é ~10x menor) pelo ffmpeg; sem ele, o WAV."""
    if not shutil.which("ffmpeg"):
        return wav, "audio/wav"
    with tempfile.TemporaryDirectory() as tmp:
        saida = Path(tmp) / "fala.m4a"
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
                    str(saida),
                ],
                input=wav,
                capture_output=True,
                check=True,
                timeout=60,
            )
            return saida.read_bytes(), "audio/mp4"
        except (subprocess.SubprocessError, OSError) as e:
            logger.warning("ffmpeg não comprimiu a fala (%s); mandando WAV", e)
            return wav, "audio/wav"


class Voz:
    def __init__(self, settings: WorkerSettings) -> None:
        self._s = settings
        self._modelo: Any = None
        self._tts: Any = None
        self._xtts_proc: subprocess.Popen[str] | None = None
        self._xtts_falhou = False
        self._xtts_trava = threading.Lock()
        self._pronuncia = Pronuncia(settings.pronuncia_python)

    async def executar(self, tarefa: str, payload: dict[str, Any]) -> dict[str, Any]:
        if tarefa == "transcrever":
            audio = base64.b64decode(payload["audio_b64"])
            texto, idioma = await asyncio.to_thread(
                self._transcrever, audio, payload.get("mime", ""), str(payload.get("idioma") or "")
            )
            return {"texto": texto, "idioma": idioma}
        if tarefa == "falar":
            trecho = payload.get("trecho")
            wav = await asyncio.to_thread(
                self._falar, str(payload["texto"]), None if trecho is None else int(trecho)
            )
            return {"audio_b64": base64.b64encode(wav).decode(), "mime": "audio/wav"}
        if tarefa == "falar_marcado":
            return await asyncio.to_thread(
                self._falar_marcado,
                str(payload["texto"]),
                str(payload.get("idioma") or "en"),
                float(payload.get("velocidade") or 1.0),
            )
        if tarefa == "avaliar_leitura":
            return await asyncio.to_thread(
                self._avaliar_leitura,
                base64.b64decode(payload["audio_b64"]),
                str(payload.get("mime") or ""),
                str(payload.get("idioma") or "en"),
                str(payload.get("referencia") or ""),
            )
        raise ValueError(f"Tarefa desconhecida: {tarefa}")

    def _palavras_whisper(
        self, caminho: str, idioma: str, dica: str | None = None, vad: bool = False
    ) -> list[dict[str, Any]]:
        """Palavras ouvidas com o tempo de cada uma (s) e a confiança do Whisper."""
        segmentos, _ = self._whisper().transcribe(
            caminho,
            language=idioma,
            beam_size=self._s.whisper_beam,
            word_timestamps=True,
            condition_on_previous_text=False,
            vad_filter=vad,
            initial_prompt=dica,
        )
        return [
            {"palavra": w.word.strip(), "inicio": w.start, "fim": w.end, "prob": w.probability}
            for s in segmentos
            for w in s.words or []
        ]

    def _falar_marcado(self, texto: str, idioma: str, velocidade: float) -> dict[str, Any]:
        """Leitura guiada: a fala do texto no idioma dele e o tempo de cada palavra. O Whisper
        ouve a própria fala (com o texto de dica) e `align_word_times` casa com as palavras do
        texto; sem Whisper, o tempo sai proporcional ao tamanho das palavras."""
        tts = self._kokoro()
        if tts is None:
            raise RuntimeError("Leitura guiada indisponível: o Kokoro não carregou no worker.")
        voz, lang = VOZES_KOKORO.get(idioma, VOZES_KOKORO["en"])
        wav = self._falar_kokoro(tts, texto, voz, lang, min(max(velocidade, 0.5), 2.0))
        with tempfile.NamedTemporaryFile(suffix=".wav") as f:
            f.write(wav)
            f.flush()
            with wave.open(f.name) as w:
                duracao = w.getnframes() / w.getframerate()
            ditas: list[dict[str, Any]] = []
            try:
                ditas = self._palavras_whisper(f.name, idioma, dica=texto)
            except (RuntimeError, ValueError) as e:
                logger.info("Leitura guiada sem Whisper (%s): tempo proporcional", e)
        audio, mime = comprimir(wav)
        return {
            "audio_b64": base64.b64encode(audio).decode(),
            "mime": mime,
            "duracao": round(duracao, 3),
            "palavras": align_word_times(texto, ditas, duracao),
        }

    def _avaliar_leitura(
        self, audio: bytes, mime: str, idioma: str, referencia: str
    ) -> dict[str, Any]:
        """Leitura em voz alta: o que o Whisper ouviu (palavra, tempo, confiança) e, com o modelo
        fonético, o acerto de pronúncia de cada palavra da [referencia]."""
        from faster_whisper import decode_audio

        sufixo = {"audio/wav": ".wav", "audio/mp4": ".m4a", "audio/ogg": ".ogg"}.get(mime, ".audio")
        with tempfile.NamedTemporaryFile(suffix=sufixo) as f:
            f.write(audio)
            f.flush()
            ditas = self._palavras_whisper(f.name, idioma, vad=True)
            pronuncia = self._pronuncia.avaliar(decode_audio(f.name), referencia, idioma)
        aviso = "" if pronuncia is not None else "Pronúncia por fonema indisponível no worker."
        return {"palavras": ditas, "pronuncia": pronuncia, "aviso": aviso}

    def _whisper(self) -> Any:
        if self._modelo is None:
            try:
                from faster_whisper import WhisperModel
            except ImportError as e:
                raise RuntimeError(
                    "Transcrição indisponível: instale o extra de voz do worker "
                    "(uv sync --extra voz)."
                ) from e
            dispositivo = self._s.whisper_dispositivo
            if dispositivo in ("auto", "cuda"):
                _carregar_libs_cuda()
                try:
                    modelo = self._s.whisper_modelo or "large-v3-turbo"
                    self._modelo = WhisperModel(modelo, device="cuda", compute_type="int8_float16")
                    logger.info("Whisper %s na GPU", modelo)
                    return self._modelo
                except (RuntimeError, ValueError) as e:
                    if dispositivo == "cuda":
                        raise
                    logger.warning("Whisper sem GPU (%s); usando a CPU", e)
            modelo = self._s.whisper_modelo or "small"
            self._modelo = WhisperModel(modelo, device="cpu", compute_type="int8")
            logger.info("Whisper %s na CPU", modelo)
        return self._modelo

    async def aquecer(self) -> None:
        """Carrega o modelo ao ligar o worker: a primeira fala não espera o load (10–30 s)."""
        try:
            await asyncio.to_thread(self._whisper)
        except Exception as e:  # sem o extra de voz o worker segue só com o LLM
            logger.info("Whisper não pré-carregado: %s", e)
        await asyncio.to_thread(self._aquecer_xtts)

    def _aquecer_xtts(self) -> None:
        with self._xtts_trava:
            self._xtts()

    def _idioma(self, modelo: Any, caminho: str, pedido: str) -> str:
        aceitos = [i.strip() for i in self._s.voz_idiomas.split(",") if i.strip()]
        if pedido in aceitos:
            return pedido
        if len(aceitos) < 2:
            return aceitos[0] if aceitos else self._s.voz_idioma
        try:
            from faster_whisper import decode_audio

            # Os primeiros 30 s bastam para detectar; restringe a pt/en em vez das 99 línguas.
            amostra = decode_audio(caminho)[: 16000 * 30]
            _, _, probabilidades = modelo.detect_language(amostra)
        except (ImportError, ValueError, RuntimeError) as e:
            logger.warning("Detecção de idioma falhou (%s); usando %s", e, self._s.voz_idioma)
            return self._s.voz_idioma
        return escolher_idioma(probabilidades, aceitos, self._s.voz_idioma)

    def _transcrever(self, audio: bytes, mime: str, idioma: str = "") -> tuple[str, str]:
        sufixo = {"audio/wav": ".wav", "audio/mp4": ".m4a", "audio/ogg": ".ogg"}.get(mime, ".audio")
        with tempfile.NamedTemporaryFile(suffix=sufixo) as f:
            f.write(audio)
            f.flush()
            modelo = self._whisper()
            idioma = self._idioma(modelo, f.name, idioma)
            prompt = {"pt": self._s.whisper_prompt, "en": _PROMPT_EN}.get(idioma, "")
            segmentos, _ = modelo.transcribe(
                f.name,
                language=idioma,
                # Busca gulosa: no large-v3-turbo a diferença de acerto é mínima e sai 2–3x mais
                # rápido que beam 5 (o que pesa na conversa por voz).
                beam_size=self._s.whisper_beam,
                vad_filter=True,
                vad_parameters={"min_silence_duration_ms": 500},
                condition_on_previous_text=False,
                without_timestamps=True,
                initial_prompt=prompt or None,
            )
            partes = [
                s.text.strip()
                for s in segmentos
                if not (s.no_speech_prob > 0.6 and s.avg_logprob < -1.0)
                and not _ALUCINACOES.search(s.text.strip())
            ]
            # Vazio vira "não entendi" no servidor, em vez de uma resposta a um áudio inventado.
            return " ".join(p for p in partes if p).strip(), idioma

    def _kokoro(self) -> Any:
        """Kokoro carregado uma vez; None (e não tenta de novo) sem o pacote ou os arquivos."""
        if self._tts is None:
            self._tts = False
            modelo = Path(self._s.kokoro_modelo).expanduser()
            vozes = Path(self._s.kokoro_vozes).expanduser()
            if modelo.is_file() and vozes.is_file():
                try:
                    from kokoro_onnx import Kokoro

                    self._tts = Kokoro(str(modelo), str(vozes))
                    logger.info("Fala com Kokoro (%s)", self._s.kokoro_voz)
                except Exception as e:  # pacote ausente ou modelo inválido: cai no Piper
                    logger.warning("Kokoro indisponível (%s); usando o Piper", e)
        return self._tts or None

    def _falar_kokoro(
        self,
        tts: Any,
        texto: str,
        voz: str | None = None,
        lang: str = "pt-br",
        velocidade: float | None = None,
    ) -> bytes:
        import io

        import numpy as np

        audio, taxa = tts.create(
            texto,
            voice=voz or self._s.kokoro_voz,
            speed=velocidade or self._s.kokoro_velocidade,
            lang=lang,
        )
        pcm = (np.clip(audio, -1.0, 1.0) * 32767).astype("<i2").tobytes()
        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(taxa)
            w.writeframes(pcm)
        return buf.getvalue()

    def _xtts(self) -> subprocess.Popen[str] | None:
        """Processo do XTTS com o modelo carregado; None sem o venv ou se não subir."""
        if self._xtts_proc is not None and self._xtts_proc.poll() is None:
            return self._xtts_proc
        if self._xtts_falhou:
            return None
        python = Path(self._s.xtts_python).expanduser() if self._s.xtts_python else _XTTS_PYTHON
        if not python.is_file():
            self._xtts_falhou = True
            return None
        proc = subprocess.Popen(
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
        assert proc.stdout is not None
        if '"pronto"' not in proc.stdout.readline():  # linha vazia = morreu ao carregar
            proc.kill()
            self._xtts_falhou = True
            logger.warning("XTTS não subiu; usando o Kokoro")
            return None
        logger.info("Fala com XTTS-v2 (%s)", self._s.xtts_voz)
        self._xtts_proc = proc
        return proc

    def _falar_xtts(self, proc: subprocess.Popen[str], texto: str) -> bytes | None:
        assert proc.stdin is not None and proc.stdout is not None
        with tempfile.TemporaryDirectory() as tmp:
            saida = Path(tmp) / "fala.wav"
            proc.stdin.write(json.dumps({"texto": texto, "saida": str(saida)}) + "\n")
            proc.stdin.flush()
            resposta = json.loads(proc.stdout.readline() or '{"erro": "processo encerrado"}')
            if "erro" in resposta:
                logger.warning("XTTS falhou (%s); usando o Kokoro", resposta["erro"])
                return None
            return saida.read_bytes()

    def _falar(self, texto: str, trecho: int | None = None) -> bytes:
        """WAV do texto inteiro ou só do [trecho] n (`dividir_trechos`); trecho além do fim = vazio,
        o app toca um enquanto pede o próximo."""
        texto = texto_para_fala(texto, self._s.fala_max_caracteres) or "Pronto."
        if trecho is not None:
            trechos = dividir_trechos(texto)
            if trecho >= len(trechos):
                return b""
            texto = trechos[trecho]
        with self._xtts_trava:  # um pedido por vez no mesmo processo
            proc = self._xtts()
            wav = self._falar_xtts(proc, texto) if proc else None
        if wav:
            return wav
        tts = self._kokoro()
        if tts is not None:
            return self._falar_kokoro(tts, texto)
        with tempfile.TemporaryDirectory() as tmp:
            saida = Path(tmp) / "fala.wav"
            if self._s.piper_modelo and shutil.which(self._s.piper_bin):
                cmd = [
                    self._s.piper_bin,
                    "--model",
                    self._s.piper_modelo,
                    "--length-scale",
                    str(self._s.piper_lentidao),
                    "--output_file",
                    str(saida),
                ]
                subprocess.run(
                    cmd, input=texto.encode(), check=True, capture_output=True, timeout=120
                )
            elif shutil.which(self._s.espeak_bin):
                cmd = [self._s.espeak_bin, "-v", self._s.espeak_voz, "-w", str(saida), texto]
                subprocess.run(cmd, check=True, capture_output=True, timeout=120)
            else:
                raise RuntimeError(
                    "Fala indisponível: instale o Piper (com uma voz pt_BR) ou o espeak-ng."
                )
            return saida.read_bytes()
