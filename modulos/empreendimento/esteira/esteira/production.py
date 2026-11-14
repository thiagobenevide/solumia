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


def mode(project):
    return project.cfg.get("producao", {}).get("modo", "dark")


def camera(project):
    """Arquivo da câmera do episódio (camera.mp4/.mov/...), ou None."""
    return next((p for p in sorted(project.pasta.glob("camera.*")) if p.suffix.lower() in VIDEO_EXT), None)


def info_camera(project):
    file = project.caminho("camera.json")
    return json.loads(file.read_text()) if file.exists() else {"offset": 0.0}


# ---------------------------------------------------------------- sincronização WAV × câmera

def _envelope(file, segundos=240, taxa=8000, window=80):
    """Energia do áudio (janelas de 10 ms) dos primeiros `segundos`."""
    pcm = subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-t", str(segundos), "-i", str(file),
                          "-vn", "-ac", "1", "-ar", str(taxa), "-f", "f32le", "-"], capture_output=True, check=True).stdout
    x = np.frombuffer(pcm, dtype=np.float32)
    x = x[: len(x) // window * window].reshape(-1, window)
    env = np.sqrt((x ** 2).mean(axis=1))
    return (env - env.mean()) / (env.std() + 1e-9)


def sync(wav, video):
    """Deslocamento (s) tal que tempo_na_camera = tempo_no_wav + offset; e a confiança (0–1)."""
    a, b = _envelope(wav), _envelope(video)
    n = 1 << int(np.ceil(np.log2(len(a) + len(b))))
    corr = np.fft.irfft(np.fft.rfft(b, n) * np.conj(np.fft.rfft(a, n)), n)
    corr = np.concatenate([corr[-(len(a) - 1):], corr[:len(b)]])  # lags de -(len(a)-1) a len(b)-1
    k = int(np.argmax(corr))
    lag = k - (len(a) - 1)
    peak = corr[k] / min(len(a), len(b))
    return round(lag * 0.01, 3), round(float(np.clip(peak, 0, 1)), 3)


def prepare_camera(pasta, video, wav=None):
    """Liga o vídeo da câmera ao projeto (link, sem copiar gigabytes) e grava camera.json. Devolve o áudio
    a usar como narração: o WAV sincronizado ou o som extraído da câmera."""
    video = Path(video)
    destination = pasta / f"camera{video.suffix.lower()}"
    if not destination.exists():
        destination.symlink_to(video.resolve())
    from esteira.library import _probe
    w, h, duration = _probe(destination)
    info = {"arquivo": str(video.resolve()), "largura": w, "altura": h, "duracao": duration, "offset": 0.0}
    if wav:
        info["offset"], info["confianca_sync"] = sync(wav, destination)
        if info["confianca_sync"] < 0.3:
            print(f"  ! sincronia WAV × câmera fraca ({info['confianca_sync']}); confira no FilmCraft")
    else:
        wav = pasta / "narracao_camera.wav"
        subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-i", str(destination), "-vn", "-ac", "1",
                        "-ar", "48000", "-c:a", "pcm_s16le", str(wav)], check=True)
    (pasta / "camera.json").write_text(json.dumps(info, indent=1))
    return wav


# ---------------------------------------------------------------- quais cenas mostram o apresentador

def _instants_of_part(project):
    """Instante (s) em que começa cada Parte do roteiro, pela 1ª frase com tempo da fala de abertura."""
    file = project.caminho("roteiro.json")
    if not file.exists() or not project.caminho("frases.json").exists():
        return []
    from esteira.graphics.plan import _speech_to_sentence
    rot, sentences = json.loads(file.read_text()), project.carregar_json("frases.json")
    mapping = _speech_to_sentence(project.roteiro().read_text())
    output = []
    for cap in rot.get("capitulos", []):
        k = mapping[min(cap["fala"], len(mapping) - 1)] if mapping else 0
        t = next((sentences[i]["ini"] for i in range(k, len(sentences)) if sentences[i]["ini"] is not None), None)
        if t is not None:
            output.append(t)
    return output


def mark_presenter(project, plan, save=True):
    """Modo apresentador: marca `camera: true` nas cenas em que você aparece (sem mídia de banco).
    Regras, em ordem: nota de cena pedindo câmera → câmera; nota de cena descrevendo outra imagem → B-roll;
    1ª cena do vídeo e de cada Parte → câmera; no resto, B-roll até cobrir `[producao] broll` do tempo."""
    if mode(project) != "apresentador" or any("camera" in c for c in plan["cenas"]):
        return
    from esteira.curation import _notes_by_time
    target = project.cfg.get("producao", {}).get("broll", 0.45)
    notes, parts = _notes_by_time(project), _instants_of_part(project)

    def dentro(c, t):
        return c["inicio"] - 0.5 <= t < c["fim"]

    time = broll = 0.0
    for i, c in enumerate(plan["cenas"]):
        note = next((txt for t, txt in notes if dentro(c, t)), "")
        if note:
            c["camera"] = bool(RE_CAMERA.search(note))
        elif i == 0 or any(dentro(c, t) for t in parts):
            c["camera"] = True
        else:
            c["camera"] = time > 0 and broll / time >= target
        duration = c["fim"] - c["inicio"]
        time += duration
        broll += 0 if c["camera"] else duration
    if save:
        project.salvar_json("plano.json", plan)
    n = sum(c["camera"] for c in plan["cenas"])
    print(f"  modo apresentador: {n} cenas na câmera, {len(plan['cenas']) - n} com B-roll "
          f"({broll / max(time, 1e-9):.0%} do tempo)")


def spans_camera(project):
    """[(início na timeline, início na câmera, duração)] a partir dos intervalos mantidos pelos cortes."""
    cuts = project.carregar_json("cortes.json") if project.caminho("cortes.json").exists() else {}
    intervals = cuts.get("intervalos")
    if not intervals and cuts.get("trechos") and project.caminho("transcricao_bruta.json").exists():
        from esteira.cuts import _intervals  # cortes.json de antes dos intervalos: recalcula das decisões
        words = project.carregar_json("transcricao_bruta.json")["palavras"]
        intervals = _intervals(cuts["trechos"], words, cuts.get("excluir", []))
    off = info_camera(project).get("offset", 0.0)
    if not intervals:  # sem cortes: a gravação inteira
        return [(0.0, off, info_camera(project).get("duracao", 0) - off)]
    output, t = [], 0.0
    for a, b in intervals:
        output.append((round(t, 4), round(a + off, 4), round(b - a, 4)))
        t += b - a
    return output
