"""Modos de produção de um episódio (`[producao] modo` ou `modo:` no frontmatter do roteiro):

- `dark`: só a narração (WAV) + mídia dos bancos de imagens em todas as cenas.
- `apresentador`: o vídeo da câmera (onde você aparece) é a base da timeline (V1, com os mesmos cortes da
  narração) e a mídia dos bancos entra como cobertura (B-roll, V2) só em parte das cenas. As cenas de
  câmera não buscam mídia, o que poupa chamadas às APIs.

O áudio pode vir de um WAV gravado à parte (melhor qualidade): ele é sincronizado com o som da câmera
por correlação cruzada. Sem WAV, o áudio sai da própria câmera.
"""
import json
import re
import subprocess
from pathlib import Path

import numpy as np

VIDEO_EXT = (".mp4", ".mov", ".mkv", ".m4v")
# Notas de cena que pedem o apresentador na tela
RE_CAMERA = re.compile(r"\b(c[âa]mera|apresentador|eu (na tela|falando|olhando)|rosto|talking head|on camera)\b", re.I)


def modo(projeto):
    return projeto.cfg.get("producao", {}).get("modo", "dark")


def camera(projeto):
    """Arquivo da câmera do episódio (camera.mp4/.mov/...), ou None."""
    return next((p for p in sorted(projeto.pasta.glob("camera.*")) if p.suffix.lower() in VIDEO_EXT), None)


def info_camera(projeto):
    arq = projeto.caminho("camera.json")
    return json.loads(arq.read_text()) if arq.exists() else {"offset": 0.0}


# ---------------------------------------------------------------- sincronização WAV × câmera

def _envelope(arq, segundos=240, taxa=8000, janela=80):
    """Energia do áudio (janelas de 10 ms) dos primeiros `segundos`."""
    pcm = subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-t", str(segundos), "-i", str(arq),
                          "-vn", "-ac", "1", "-ar", str(taxa), "-f", "f32le", "-"], capture_output=True, check=True).stdout
    x = np.frombuffer(pcm, dtype=np.float32)
    x = x[: len(x) // janela * janela].reshape(-1, janela)
    env = np.sqrt((x ** 2).mean(axis=1))
    return (env - env.mean()) / (env.std() + 1e-9)


def sincronizar(wav, video):
    """Deslocamento (s) tal que tempo_na_camera = tempo_no_wav + offset; e a confiança (0–1)."""
    a, b = _envelope(wav), _envelope(video)
    n = 1 << int(np.ceil(np.log2(len(a) + len(b))))
    corr = np.fft.irfft(np.fft.rfft(b, n) * np.conj(np.fft.rfft(a, n)), n)
    corr = np.concatenate([corr[-(len(a) - 1):], corr[:len(b)]])  # lags de -(len(a)-1) a len(b)-1
    k = int(np.argmax(corr))
    lag = k - (len(a) - 1)
    pico = corr[k] / min(len(a), len(b))
    return round(lag * 0.01, 3), round(float(np.clip(pico, 0, 1)), 3)


def preparar_camera(pasta, video, wav=None):
    """Liga o vídeo da câmera ao projeto (link, sem copiar gigabytes) e grava camera.json. Devolve o áudio
    a usar como narração: o WAV sincronizado ou o som extraído da câmera."""
    video = Path(video)
    destino = pasta / f"camera{video.suffix.lower()}"
    if not destino.exists():
        destino.symlink_to(video.resolve())
    from esteira.library import _sonda
    w, h, dur = _sonda(destino)
    info = {"arquivo": str(video.resolve()), "largura": w, "altura": h, "duracao": dur, "offset": 0.0}
    if wav:
        info["offset"], info["confianca_sync"] = sincronizar(wav, destino)
        if info["confianca_sync"] < 0.3:
            print(f"  ! sincronia WAV × câmera fraca ({info['confianca_sync']}); confira no FilmCraft")
    else:
        wav = pasta / "narracao_camera.wav"
        subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-i", str(destino), "-vn", "-ac", "1",
                        "-ar", "48000", "-c:a", "pcm_s16le", str(wav)], check=True)
    (pasta / "camera.json").write_text(json.dumps(info, indent=1))
    return wav


# ---------------------------------------------------------------- quais cenas mostram o apresentador

def _instantes_de_parte(projeto):
    """Instante (s) em que começa cada Parte do roteiro, pela 1ª frase com tempo da fala de abertura."""
    arq = projeto.caminho("roteiro.json")
    if not arq.exists() or not projeto.caminho("frases.json").exists():
        return []
    from esteira.graphics.plan import _fala_para_frase
    rot, frases = json.loads(arq.read_text()), projeto.carregar_json("frases.json")
    mapa = _fala_para_frase(projeto.roteiro().read_text())
    saida = []
    for cap in rot.get("capitulos", []):
        k = mapa[min(cap["fala"], len(mapa) - 1)] if mapa else 0
        t = next((frases[i]["ini"] for i in range(k, len(frases)) if frases[i]["ini"] is not None), None)
        if t is not None:
            saida.append(t)
    return saida


def marcar_apresentador(projeto, plano, salvar=True):
    """Modo apresentador: marca `camera: true` nas cenas em que você aparece (sem mídia de banco).
    Regras, em ordem: nota de cena pedindo câmera → câmera; nota de cena descrevendo outra imagem → B-roll;
    1ª cena do vídeo e de cada Parte → câmera; no resto, B-roll até cobrir `[producao] broll` do tempo."""
    if modo(projeto) != "apresentador" or any("camera" in c for c in plano["cenas"]):
        return
    from esteira.curation import _notas_por_tempo
    alvo = projeto.cfg.get("producao", {}).get("broll", 0.45)
    notas, partes = _notas_por_tempo(projeto), _instantes_de_parte(projeto)

    def dentro(c, t):
        return c["inicio"] - 0.5 <= t < c["fim"]

    tempo = broll = 0.0
    for i, c in enumerate(plano["cenas"]):
        nota = next((txt for t, txt in notas if dentro(c, t)), "")
        if nota:
            c["camera"] = bool(RE_CAMERA.search(nota))
        elif i == 0 or any(dentro(c, t) for t in partes):
            c["camera"] = True
        else:
            c["camera"] = tempo > 0 and broll / tempo >= alvo
        dur = c["fim"] - c["inicio"]
        tempo += dur
        broll += 0 if c["camera"] else dur
    if salvar:
        projeto.salvar_json("plano.json", plano)
    n = sum(c["camera"] for c in plano["cenas"])
    print(f"  modo apresentador: {n} cenas na câmera, {len(plano['cenas']) - n} com B-roll "
          f"({broll / max(tempo, 1e-9):.0%} do tempo)")


def trechos_camera(projeto):
    """[(início na timeline, início na câmera, duração)] a partir dos intervalos mantidos pelos cortes."""
    cortes = projeto.carregar_json("cortes.json") if projeto.caminho("cortes.json").exists() else {}
    intervalos = cortes.get("intervalos")
    if not intervalos and cortes.get("trechos") and projeto.caminho("transcricao_bruta.json").exists():
        from esteira.cuts import _intervalos  # cortes.json de antes dos intervalos: recalcula das decisões
        palavras = projeto.carregar_json("transcricao_bruta.json")["palavras"]
        intervalos = _intervalos(cortes["trechos"], palavras, cortes.get("excluir", []))
    off = info_camera(projeto).get("offset", 0.0)
    if not intervalos:  # sem cortes: a gravação inteira
        return [(0.0, off, info_camera(projeto).get("duracao", 0) - off)]
    saida, t = [], 0.0
    for a, b in intervalos:
        saida.append((round(t, 4), round(a + off, 4), round(b - a, 4)))
        t += b - a
    return saida
