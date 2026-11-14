"""llama.cpp em modo roteador: um `llama-server` serve todos os modelos de `~/agent-data/modelos`.

O mesmo servidor atende a esteira e o worker da plataforma (quem chegar primeiro sobe; os argumentos são os
mesmos de `WORKER_LLAMA_ARGS`). Modelo = `.gguf` solto (id = nome sem extensão) ou subpasta com o modelo e o
`mmproj-*.gguf` (visão; id = nome da pasta). Carrega sob demanda, um por vez, e descarrega após 10 min parado.
"""
import contextlib
import os
import re
import shlex
import subprocess
import time
from pathlib import Path

import requests

HOST = os.environ.get("LLAMA_HOST", "http://127.0.0.1:8081")
BIN = Path(os.environ.get("LLAMA_SERVER_BIN", "~/development/llama.cpp/build/bin/llama-server")).expanduser()
MODELOS = Path(os.environ.get("LLAMA_MODELOS_DIR", "~/agent-data/modelos")).expanduser()
ARGS = os.environ.get("LLAMA_ARGS", "--models-max 1 --fit on -c 16384 --jinja --sleep-idle-seconds 600")
# adaptadores LoRA das Craft Apps: cada seção do INI é um "modelo" do roteador = base + `lora` (dataset/treino_app)
PRESETS = MODELOS / "adaptadores" / "presets.ini"


def modelos():
    """Modelos do roteador: [{id, status, path, architecture…}] (vazio se fora do ar)."""
    try:
        r = requests.get(f"{HOST}/models", timeout=5)
        r.raise_for_status()
        return r.json().get("data") or []
    except (requests.RequestException, ValueError):
        return None


def servidor():
    """Garante o roteador no ar (sobe em segundo plano se preciso)."""
    if modelos() is not None:
        return True
    if not BIN.exists():
        return False
    MODELOS.mkdir(parents=True, exist_ok=True)
    porta = HOST.rsplit(":", 1)[-1]
    with open(MODELOS / "llama-server.log", "ab") as log:
        presets = ["--models-preset", str(PRESETS)] if PRESETS.exists() else []
        subprocess.Popen([str(BIN), "--models-dir", str(MODELOS), *presets, "--host", "127.0.0.1", "--port", porta,
                          *shlex.split(ARGS)], stdout=log, stderr=log, stdin=subprocess.DEVNULL,
                         start_new_session=True)
    for _ in range(60):
        time.sleep(0.5)
        if modelos() is not None:
            return True
    return False


def reiniciar():
    """Derruba o roteador (para ler presets novos) e sobe de novo. → True se voltou."""
    import psutil
    porta = int(HOST.rsplit(":", 1)[-1])
    for p in psutil.process_iter(["name", "cmdline"]):
        cmd = p.info.get("cmdline") or []
        if cmd and Path(cmd[0]).name == "llama-server" and "--models-dir" in cmd and str(porta) in cmd:
            p.terminate()
            try:
                p.wait(timeout=20)
            except psutil.TimeoutExpired:
                p.kill()
    return servidor()


def carregados():
    return [m["id"] for m in modelos() or [] if m["status"]["value"] == "loaded"]


def visao(m):
    return "image" in ((m.get("architecture") or {}).get("input_modalities") or [])


def descarregar():
    """Tira todos os modelos da VRAM (o Whisper e a difusão precisam dela)."""
    for id_ in carregados():
        with contextlib.suppress(requests.RequestException):
            requests.post(f"{HOST}/models/unload", json={"model": id_}, timeout=30)
    # a descarga é assíncrona: espera a VRAM ficar livre de fato
    for _ in range(60):
        if not [m for m in modelos() or [] if m["status"]["value"] not in ("unloaded", "sleeping")]:
            break
        time.sleep(0.5)
    return carregados()


def gb(id_):
    """Tamanho em disco do modelo (arquivo solto ou subpasta com o projetor)."""
    pasta = MODELOS / id_
    arqs = list(pasta.glob("*.gguf")) if pasta.is_dir() else [MODELOS / f"{id_}.gguf"]
    return round(sum(a.stat().st_size for a in arqs if a.exists()) / 1e9, 1)


# ── baixar do Hugging Face: "usuario/repo:QUANT" (QUANT padrão Q4_K_M) ──

def _arquivos_hf(repo, quant):
    r = requests.get(f"https://huggingface.co/api/models/{repo}", timeout=20)
    r.raise_for_status()
    nomes = [s["rfilename"] for s in r.json().get("siblings", []) if s["rfilename"].endswith(".gguf")]
    modelo = [n for n in nomes if quant.lower() in n.lower() and "mmproj" not in n.lower()]
    if not modelo:
        raise RuntimeError(f"nenhum .gguf {quant} em {repo}")
    projs = [n for n in nomes if "mmproj" in n.lower()]
    # projetor de visão: Q8_0 é o equilíbrio; senão f16; senão o que houver
    proj = next((n for q in ("q8_0", "f16", "") for n in projs if q in n.lower()), None)
    return modelo[0], proj


def baixar(nome, progresso):
    """Baixa para a pasta de modelos; `progresso(feito, total, msg)`. Com projetor → subpasta (visão)."""
    repo, _, quant = nome.partition(":")
    quant = quant or "Q4_K_M"
    arq, proj = _arquivos_hf(repo, quant)
    id_ = re.sub(r"[^\w.\-]+", "-", f"{repo.split('/')[-1].removesuffix('-GGUF')}-{quant}").lower()
    destino = MODELOS / id_ if proj else MODELOS
    destino.mkdir(parents=True, exist_ok=True)
    alvos = [(arq, destino / (f"{id_}.gguf" if not proj else Path(arq).name))]
    if proj:
        alvos.append((proj, destino / Path(proj).name))
    for fonte, final in alvos:
        parcial = final.with_suffix(".part")  # .part não é .gguf: o roteador ignora até terminar
        with requests.get(f"https://huggingface.co/{repo}/resolve/main/{fonte}", stream=True, timeout=60) as r:
            r.raise_for_status()
            total, feito = int(r.headers.get("content-length") or 0), 0
            with open(parcial, "wb") as f:
                for bloco in r.iter_content(1 << 20):
                    f.write(bloco)
                    feito += len(bloco)
                    progresso(feito, total, f"baixando {Path(fonte).name}")
        parcial.replace(final)
    requests.get(f"{HOST}/models", params={"reload": 1}, timeout=10)  # o roteador relê a pasta
    return id_
