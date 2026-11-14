"""Etapa 1: transcreve a narração com faster-whisper, guardando o tempo de cada palavra."""

import ctypes
import glob
import os
import site
import subprocess


def _load_libs_cuda():
    # As bibliotecas CUDA vêm dos pacotes pip nvidia-*; o ctranslate2 só as encontra pré-carregadas.
    for base in site.getsitepackages():
        for default in ("nvidia/cublas/lib/libcublas*.so.*", "nvidia/cudnn/lib/libcudnn*.so.*"):
            for lib in sorted(glob.glob(os.path.join(base, default))):
                try:
                    ctypes.CDLL(lib, mode=ctypes.RTLD_GLOBAL)
                except OSError:
                    pass


def _decode(audio):
    # 16 kHz mono float32, o formato que o Whisper espera; o ffmpeg lê qualquer áudio ou vídeo.
    import numpy as np
    raw = subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-i", str(audio), "-ac", "1",
                            "-ar", "16000", "-f", "f32le", "-"], capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.float32)


from esteira.core import events

STRETCHED = 1.2   # s: palavra mais longa que isto costuma esconder fala que o Whisper não escreveu (retake)
SLOW = 1.0      # palavras/s numa janela de 6 palavras: abaixo disto, idem


def _suspects(words):
    """Regiões [(ini, fim)] onde o Whisper "esticou" palavras por cima de fala repetida: ele escreve o texto
    uma vez só e espalha as palavras pelo tempo dos retakes (ex.: "análise" com 11 s)."""
    marks = set()
    for k, w in enumerate(words):
        if w["fim"] - w["ini"] > STRETCHED:
            marks.add(k)
        j = k + 5
        if j < len(words) and words[j]["fim"] - w["ini"] > 6 / SLOW:
            # janela lenta: só conta se não for pausa simples entre duas palavras
            durs = [words[i]["fim"] - words[i]["ini"] for i in range(k, j + 1)]
            if sum(durs) > 4:
                marks.update(range(k, j + 1))
    regions = []
    for k in sorted(marks):
        a = words[max(k - 1, 0)]["ini"]
        b = words[min(k + 1, len(words) - 1)]["fim"]
        if regions and a <= regions[-1][1] + 1.0:
            regions[-1][1] = max(regions[-1][1], b)
        else:
            regions.append([a, b])
    return regions


def _refine(model, signal, words, language, sr=16000):
    """Retranscreve as regiões suspeitas em pedaços curtos, separados pelos silêncios (VAD), cada um sem
    contexto: assim cada tentativa da mesma frase vira texto próprio e a etapa de cortes enxerga o retake."""
    from faster_whisper.vad import VadOptions, get_speech_timestamps

    regions = _suspects(words)
    if not regions:
        return words
    recuperadas = 0
    for a, b in regions:
        a, b = max(a - 0.3, 0), min(b + 0.3, len(signal) / sr)
        span = signal[int(a * sr):int(b * sr)]
        speeches = get_speech_timestamps(span, VadOptions(min_silence_duration_ms=250, speech_pad_ms=120))
        new = []
        for f in speeches:
            chunk = span[f["start"]:f["end"]]
            if len(chunk) < sr * 0.3:
                continue
            segs, _ = model.transcribe(chunk, language=language, word_timestamps=True, beam_size=5,
                                        vad_filter=False, condition_on_previous_text=False)
            base = a + f["start"] / sr
            for s in segs:
                new += [{"p": w.word.strip(), "ini": round(base + w.start, 3), "fim": round(base + w.end, 3)}
                          for w in s.words if w.word.strip()]
        velhas = [w for w in words if a <= w["ini"] < b]
        # só troca se recuperou fala (mais palavras); senão o Whisper só falou devagar ali
        if len(new) > len(velhas):
            recuperadas += len(new) - len(velhas)
            words = [w for w in words if w["ini"] < a] + new + [w for w in words if w["ini"] >= b]
    if recuperadas:
        print(f"  {len(regions)} regiões com palavras esticadas retranscritas: +{recuperadas} palavras (retakes)")
        events.debug("retranscrição de regiões esticadas", regioes=len(regions), palavras=recuperadas)
    return words


def transcribe(project, cfg, audio=None, output_json="transcricao.json"):
    from esteira.ai.local import free_gpu
    free_gpu()  # o Whisper large-v3 precisa da VRAM que o LLM local ocupa
    _load_libs_cuda()
    from faster_whisper import WhisperModel

    from esteira.clapper import HOTWORDS

    c = cfg["transcricao"]
    disp = c["dispositivo"]
    if disp == "auto":
        import ctranslate2
        disp = "cuda" if ctranslate2.get_cuda_device_count() > 0 else "cpu"
    model = WhisperModel(c["modelo"], device=disp, compute_type="float16" if disp == "cuda" else "int8")

    audio = audio or project.audio()
    print(f"  transcrevendo {audio.name} com {c['modelo']} ({disp})…")
    signal = _decode(audio)
    segments, info = model.transcribe(signal, language=c["idioma"], word_timestamps=True,
                                        vad_filter=True, beam_size=5,
                                        # sem isto o Whisper "pula" retakes (texto repetido) da gravação bruta
                                        condition_on_previous_text=False,
                                        # "Corte parte N" / "Cancela parte N" na gravação bruta (esteira.clapper)
                                        hotwords=HOTWORDS if output_json == "transcricao_bruta.json" else None)
    words, texts = [], []
    for seg in segments:
        events.progress(min(int(seg.end), int(info.duration)), int(info.duration), seg.text.strip())
        texts.append(seg.text.strip())
        for w in seg.words:
            words.append({"p": w.word.strip(), "ini": round(w.start, 3), "fim": round(w.end, 3)})
    words = _refine(model, signal, words, c["idioma"])

    output = {"audio": audio.name, "duracao": round(info.duration, 3), "texto": " ".join(texts),
             "palavras": words, "refinada": True}
    project.save_json(output_json, output)
    print(f"  {len(words)} palavras, {info.duration:.1f}s → {output_json}")
    return output
