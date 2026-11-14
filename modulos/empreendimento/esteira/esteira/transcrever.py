"""Etapa 1: transcreve a narração com faster-whisper, guardando o tempo de cada palavra."""

import ctypes
import glob
import os
import site
import subprocess


def _carregar_libs_cuda():
    # As bibliotecas CUDA vêm dos pacotes pip nvidia-*; o ctranslate2 só as encontra pré-carregadas.
    for base in site.getsitepackages():
        for padrao in ("nvidia/cublas/lib/libcublas*.so.*", "nvidia/cudnn/lib/libcudnn*.so.*"):
            for lib in sorted(glob.glob(os.path.join(base, padrao))):
                try:
                    ctypes.CDLL(lib, mode=ctypes.RTLD_GLOBAL)
                except OSError:
                    pass


def _decodificar(audio):
    # 16 kHz mono float32, o formato que o Whisper espera; o ffmpeg lê qualquer áudio ou vídeo.
    import numpy as np
    bruto = subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-i", str(audio), "-ac", "1",
                            "-ar", "16000", "-f", "f32le", "-"], capture_output=True, check=True).stdout
    return np.frombuffer(bruto, np.float32)


from esteira.nucleo import eventos

ESTICADA = 1.2   # s: palavra mais longa que isto costuma esconder fala que o Whisper não escreveu (retake)
LENTO = 1.0      # palavras/s numa janela de 6 palavras: abaixo disto, idem


def _suspeitas(palavras):
    """Regiões [(ini, fim)] onde o Whisper "esticou" palavras por cima de fala repetida: ele escreve o texto
    uma vez só e espalha as palavras pelo tempo dos retakes (ex.: "análise" com 11 s)."""
    marcas = set()
    for k, w in enumerate(palavras):
        if w["fim"] - w["ini"] > ESTICADA:
            marcas.add(k)
        j = k + 5
        if j < len(palavras) and palavras[j]["fim"] - w["ini"] > 6 / LENTO:
            # janela lenta: só conta se não for pausa simples entre duas palavras
            durs = [palavras[i]["fim"] - palavras[i]["ini"] for i in range(k, j + 1)]
            if sum(durs) > 4:
                marcas.update(range(k, j + 1))
    regioes = []
    for k in sorted(marcas):
        a = palavras[max(k - 1, 0)]["ini"]
        b = palavras[min(k + 1, len(palavras) - 1)]["fim"]
        if regioes and a <= regioes[-1][1] + 1.0:
            regioes[-1][1] = max(regioes[-1][1], b)
        else:
            regioes.append([a, b])
    return regioes


def _refinar(modelo, sinal, palavras, idioma, sr=16000):
    """Retranscreve as regiões suspeitas em pedaços curtos, separados pelos silêncios (VAD), cada um sem
    contexto: assim cada tentativa da mesma frase vira texto próprio e a etapa de cortes enxerga o retake."""
    from faster_whisper.vad import VadOptions, get_speech_timestamps

    regioes = _suspeitas(palavras)
    if not regioes:
        return palavras
    recuperadas = 0
    for a, b in regioes:
        a, b = max(a - 0.3, 0), min(b + 0.3, len(sinal) / sr)
        trecho = sinal[int(a * sr):int(b * sr)]
        falas = get_speech_timestamps(trecho, VadOptions(min_silence_duration_ms=250, speech_pad_ms=120))
        novas = []
        for f in falas:
            pedaco = trecho[f["start"]:f["end"]]
            if len(pedaco) < sr * 0.3:
                continue
            segs, _ = modelo.transcribe(pedaco, language=idioma, word_timestamps=True, beam_size=5,
                                        vad_filter=False, condition_on_previous_text=False)
            base = a + f["start"] / sr
            for s in segs:
                novas += [{"p": w.word.strip(), "ini": round(base + w.start, 3), "fim": round(base + w.end, 3)}
                          for w in s.words if w.word.strip()]
        velhas = [w for w in palavras if a <= w["ini"] < b]
        # só troca se recuperou fala (mais palavras); senão o Whisper só falou devagar ali
        if len(novas) > len(velhas):
            recuperadas += len(novas) - len(velhas)
            palavras = [w for w in palavras if w["ini"] < a] + novas + [w for w in palavras if w["ini"] >= b]
    if recuperadas:
        print(f"  {len(regioes)} regiões com palavras esticadas retranscritas: +{recuperadas} palavras (retakes)")
        eventos.debug("retranscrição de regiões esticadas", regioes=len(regioes), palavras=recuperadas)
    return palavras


def transcrever(projeto, cfg, audio=None, saida_json="transcricao.json"):
    from esteira.ia.local import liberar_gpu
    liberar_gpu()  # o Whisper large-v3 precisa da VRAM que o LLM local ocupa
    _carregar_libs_cuda()
    from faster_whisper import WhisperModel

    from esteira.claquete import HOTWORDS

    c = cfg["transcricao"]
    disp = c["dispositivo"]
    if disp == "auto":
        import ctranslate2
        disp = "cuda" if ctranslate2.get_cuda_device_count() > 0 else "cpu"
    modelo = WhisperModel(c["modelo"], device=disp, compute_type="float16" if disp == "cuda" else "int8")

    audio = audio or projeto.audio()
    print(f"  transcrevendo {audio.name} com {c['modelo']} ({disp})…")
    sinal = _decodificar(audio)
    segmentos, info = modelo.transcribe(sinal, language=c["idioma"], word_timestamps=True,
                                        vad_filter=True, beam_size=5,
                                        # sem isto o Whisper "pula" retakes (texto repetido) da gravação bruta
                                        condition_on_previous_text=False,
                                        # "Corte parte N" / "Cancela parte N" na gravação bruta (esteira.claquete)
                                        hotwords=HOTWORDS if saida_json == "transcricao_bruta.json" else None)
    palavras, textos = [], []
    for seg in segmentos:
        eventos.progresso(min(int(seg.end), int(info.duration)), int(info.duration), seg.text.strip())
        textos.append(seg.text.strip())
        for w in seg.words:
            palavras.append({"p": w.word.strip(), "ini": round(w.start, 3), "fim": round(w.end, 3)})
    palavras = _refinar(modelo, sinal, palavras, c["idioma"])

    saida = {"audio": audio.name, "duracao": round(info.duration, 3), "texto": " ".join(textos),
             "palavras": palavras, "refinada": True}
    projeto.salvar_json(saida_json, saida)
    print(f"  {len(palavras)} palavras, {info.duration:.1f}s → {saida_json}")
    return saida
