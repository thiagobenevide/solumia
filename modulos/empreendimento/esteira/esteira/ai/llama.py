"""llama.cpp in router mode: one `llama-server` serves every model in `~/agent-data/modelos`.

The same server answers the pipeline and the platform worker (whoever arrives first starts it; the arguments are
the same as `WORKER_LLAMA_ARGS`). Model = a loose `.gguf` (id = name without extension) or a subfolder with the
model and the `mmproj-*.gguf` (vision; id = folder name). Loads on demand, one at a time, and unloads after 10 min
idle.
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
MODELS_DIR = Path(os.environ.get("LLAMA_MODELS_DIR", "~/agent-data/modelos")).expanduser()
ARGS = os.environ.get("LLAMA_ARGS", "--models-max 1 --fit on -c 16384 --jinja --sleep-idle-seconds 600")
# LoRA adapters of the Craft Apps: each INI section is a router "model" = base + `lora` (dataset/treino_app)
PRESETS = MODELS_DIR / "adaptadores" / "presets.ini"


def models():
    """Router models: [{id, status, path, architecture…}]; None when the server is down."""
    try:
        r = requests.get(f"{HOST}/models", timeout=5)
        r.raise_for_status()
        return r.json().get("data") or []
    except (requests.RequestException, ValueError):
        return None


def server():
    """Makes sure the router is up (starts it in the background if needed)."""
    if models() is not None:
        return True
    if not BIN.exists():
        return False
    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    port = HOST.rsplit(":", 1)[-1]
    presets = []
    if PRESETS.exists():
        presets = ["--models-preset", str(PRESETS)]
    with open(MODELS_DIR / "llama-server.log", "ab") as log:
        subprocess.Popen([str(BIN), "--models-dir", str(MODELS_DIR), *presets, "--host", "127.0.0.1", "--port", port,
                          *shlex.split(ARGS)], stdout=log, stderr=log, stdin=subprocess.DEVNULL,
                         start_new_session=True)
    for _ in range(60):
        time.sleep(0.5)
        if models() is not None:
            return True
    return False


def restart():
    """Stops the router (to read new presets) and starts it again. → True if it came back."""
    import psutil
    port = int(HOST.rsplit(":", 1)[-1])
    for process in psutil.process_iter(["name", "cmdline"]):
        cmd = process.info.get("cmdline") or []
        if cmd and Path(cmd[0]).name == "llama-server" and "--models-dir" in cmd and str(port) in cmd:
            process.terminate()
            try:
                process.wait(timeout=20)
            except psutil.TimeoutExpired:
                process.kill()
    return server()


def loaded():
    ids = []
    for model in models() or []:
        if model["status"]["value"] == "loaded":
            ids.append(model["id"])
    return ids


def vision(model):
    return "image" in ((model.get("architecture") or {}).get("input_modalities") or [])


def _busy():
    for model in models() or []:
        if model["status"]["value"] not in ("unloaded", "sleeping"):
            return True
    return False


def unload():
    """Takes every model out of the VRAM (Whisper and diffusion need it)."""
    for model_id in loaded():
        with contextlib.suppress(requests.RequestException):
            requests.post(f"{HOST}/models/unload", json={"model": model_id}, timeout=30)
    # unloading is asynchronous: wait until the VRAM is actually free
    for _ in range(60):
        if not _busy():
            break
        time.sleep(0.5)
    return loaded()


def gb(model_id):
    """Size on disk of the model (loose file or subfolder with the projector)."""
    folder = MODELS_DIR / model_id
    files = [MODELS_DIR / f"{model_id}.gguf"]
    if folder.is_dir():
        files = list(folder.glob("*.gguf"))
    total = 0
    for file in files:
        if file.exists():
            total += file.stat().st_size
    return round(total / 1e9, 1)


# ── download from Hugging Face: "user/repo:QUANT" (default QUANT Q4_K_M) ──

def _projector(names):
    """Vision projector: Q8_0 is the balance; otherwise f16; otherwise whatever exists."""
    projectors = []
    for name in names:
        if "mmproj" in name.lower():
            projectors.append(name)
    for quant in ("q8_0", "f16", ""):
        for name in projectors:
            if quant in name.lower():
                return name
    return None


def _hf_files(repo, quant):
    r = requests.get(f"https://huggingface.co/api/models/{repo}", timeout=20)
    r.raise_for_status()
    names = []
    for sibling in r.json().get("siblings", []):
        if sibling["rfilename"].endswith(".gguf"):
            names.append(sibling["rfilename"])
    for name in names:
        if quant.lower() in name.lower() and "mmproj" not in name.lower():
            return name, _projector(names)
    raise RuntimeError(f"no {quant} .gguf in {repo}")


def download(name, progress):
    """Downloads into the models folder; `progress(done, total, message)`. With a projector → subfolder (vision)."""
    repo, _, quant = name.partition(":")
    quant = quant or "Q4_K_M"
    file, projector = _hf_files(repo, quant)
    model_id = re.sub(r"[^\w.\-]+", "-", f"{repo.split('/')[-1].removesuffix('-GGUF')}-{quant}").lower()
    if projector:
        destination = MODELS_DIR / model_id
        targets = [(file, destination / Path(file).name), (projector, destination / Path(projector).name)]
    else:
        destination = MODELS_DIR
        targets = [(file, destination / f"{model_id}.gguf")]
    destination.mkdir(parents=True, exist_ok=True)
    for source, final in targets:
        partial = final.with_suffix(".part")  # .part is not .gguf: the router ignores it until it finishes
        with requests.get(f"https://huggingface.co/{repo}/resolve/main/{source}", stream=True, timeout=60) as r:
            r.raise_for_status()
            total, done = int(r.headers.get("content-length") or 0), 0
            with open(partial, "wb") as f:
                for block in r.iter_content(1 << 20):
                    f.write(block)
                    done += len(block)
                    progress(done, total, f"downloading {Path(source).name}")
        partial.replace(final)
    requests.get(f"{HOST}/models", params={"reload": 1}, timeout=10)  # the router rereads the folder
    return model_id
