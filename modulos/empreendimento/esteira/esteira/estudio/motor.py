"""Dependências do motor de render (HyperFrames): Node, pacotes npm, Chromium e ffmpeg.

Tudo fica fora do repositório e sem sudo: Node em `~/development/node` (ou `ESTUDIO_NODE`), pacotes em
`$AGENT_DATA/empreendimento/estudio/motor/node_modules` (cada produção aponta para ele) e o Chromium do Playwright em
`~/.cache/ms-playwright`. `estado()` diz o que falta; `instalar()` resolve (botão na aba Estúdio).
"""
import hashlib
import json
import os
import shutil
import subprocess
import tarfile
from pathlib import Path

import requests

from esteira.projeto import DADOS

NODE = Path(os.environ.get("ESTUDIO_NODE", "~/development/node")).expanduser()
MOTOR = DADOS / "estudio" / "motor"
PACOTES = {"hyperframes": "0.7.109", "playwright": "1.59.1"}


def _chromium():
    achados = sorted(Path("~/.cache/ms-playwright").expanduser().glob("chromium-*/chrome-linux*/chrome"))
    return str(achados[-1]) if achados else None


def ambiente():
    """Variáveis para rodar node/npx: Node na frente do PATH, Chromium e telemetria desligada."""
    env = dict(os.environ, PATH=f"{NODE / 'bin'}:{os.environ.get('PATH', '')}", HYPERFRAMES_NO_TELEMETRY="1",
               DO_NOT_TRACK="1")
    if c := _chromium():
        env["CHROME"] = c
    return env


def _versao_node():
    try:
        return subprocess.run([str(NODE / "bin" / "node"), "-v"], capture_output=True, text=True, timeout=10).stdout.strip()
    except OSError:
        return None


def estado():
    from esteira.ia import llama, local
    ids = {m["id"] for m in llama.modelos() or []}
    return {
        "node": _versao_node(),
        "pacotes": (MOTOR / "node_modules" / "hyperframes").is_dir(),
        "chromium": _chromium(),
        "ffmpeg": bool(shutil.which("ffmpeg")),
        "opencv": _opencv(),  # rosto no modo apresentador
        "llama": llama.modelos() is not None,
        "modelo_texto": local.TEXTO if local.TEXTO in ids else None,
        "modelo_visao": local.VISAO if local.VISAO in ids else None,
    }


def _opencv():
    import importlib.util
    return importlib.util.find_spec("cv2") is not None


def pronto():
    e = estado()
    return bool(e["node"] and e["pacotes"] and e["chromium"] and e["ffmpeg"])


def _instalar_node(progresso):
    versoes = requests.get("https://nodejs.org/dist/index.json", timeout=30).json()
    v = next(x["version"] for x in versoes if x["version"].startswith("v22.") and x.get("lts"))
    nome = f"node-{v}-linux-x64.tar.xz"
    somas = requests.get(f"https://nodejs.org/dist/{v}/SHASUMS256.txt", timeout=30).text
    esperado = next(linha.split()[0] for linha in somas.splitlines() if linha.endswith(nome))
    progresso(f"baixando Node {v}")
    tmp = NODE.parent / nome
    NODE.parent.mkdir(parents=True, exist_ok=True)
    h = hashlib.sha256()
    with requests.get(f"https://nodejs.org/dist/{v}/{nome}", stream=True, timeout=60) as r, open(tmp, "wb") as f:
        r.raise_for_status()
        for bloco in r.iter_content(1 << 20):
            f.write(bloco)
            h.update(bloco)
    if h.hexdigest() != esperado:
        tmp.unlink()
        raise RuntimeError("Node baixado com checksum errado")
    with tarfile.open(tmp) as t:
        t.extractall(NODE.parent, filter="data")
    tmp.unlink()
    (NODE.parent / nome.removesuffix(".tar.xz")).rename(NODE)


def instalar(progresso=print):
    """Instala o que faltar, na ordem: Node → pacotes npm → Chromium. Devolve o estado final."""
    if not _versao_node():
        _instalar_node(progresso)
    env = ambiente()
    if not (MOTOR / "node_modules" / "hyperframes").is_dir():
        progresso("instalando hyperframes e playwright (npm)")
        MOTOR.mkdir(parents=True, exist_ok=True)
        (MOTOR / "package.json").write_text(json.dumps({"name": "estudio-motor", "private": True, "type": "module",
                                                        "devDependencies": PACOTES}, indent=1))
        subprocess.run(["npm", "install", "--no-audit", "--no-fund", "--silent"], cwd=MOTOR, env=env, check=True)
    if not _chromium():
        progresso("baixando o Chromium do Playwright")
        subprocess.run(["npx", "playwright", "install", "chromium"], cwd=MOTOR, env=env, check=True)
    if not _opencv():
        import sys
        progresso("instalando o OpenCV (rosto do apresentador)")
        uv = shutil.which("uv") or str(Path.home() / ".local/bin/uv")
        subprocess.run([uv, "pip", "install", "--python", sys.executable, "opencv-python-headless<5"], check=True)
    return estado()


def npx(args, cwd, log=None):
    """Roda `npx <args>` na pasta da produção (que tem node_modules → MOTOR/node_modules)."""
    alvo = Path(cwd) / "node_modules"
    if not alvo.exists():
        alvo.symlink_to(MOTOR / "node_modules")
    return subprocess.run(["npx", *args], cwd=cwd, env=ambiente(), stdout=log, stderr=subprocess.STDOUT if log else None,
                          text=True, check=True)
