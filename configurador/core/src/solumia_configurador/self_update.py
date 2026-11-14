"""Rebuilds the configurator .deb from this repository and installs it (`configurador/empacotar_deb`).

Uses the code as it is in the working folder: no `git pull`, nothing is downloaded besides the
build dependencies Flutter and uv already use. Installing needs root: `pkexec` asks for the password
in a system window. The running window keeps working; the new version opens on the next start.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

from .engine import Cancelado, Context, Plan, Step
from .generate import repository_root
from .platform_setup import System

_TIMEOUT_S = 20 * 60


def script_path() -> Path:
    return repository_root() / "configurador" / "empacotar_deb"


def _run_script(ctx: Context, script: Path) -> None:
    process = subprocess.Popen([str(script), "--instalar"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                               cwd=script.parent)
    assert process.stdout is not None
    for line in process.stdout:
        ctx.log(line.rstrip())
        if ctx.cancelado.is_set():
            process.kill()
            raise Cancelado()
    code = process.wait(timeout=_TIMEOUT_S)
    if code != 0:
        raise RuntimeError(f"empacotar_deb terminou com código {code} (senha recusada ou falha no build)")
    ctx.log("Feche e abra o configurador para usar a versão nova.")


def plan(system: System) -> Plan:
    if system.windows:
        raise ValueError("a atualização pelo configurador ainda só existe no Linux")
    script = script_path()
    if not script.exists():
        raise ValueError(f"script de instalação não encontrado: {script}")

    def atualizar(ctx: Context) -> None:
        _run_script(ctx, script)

    return Plan("Atualizar o configurador", [
        Step("atualizar", "Gerar o .deb novo e instalar",
             f"{script}: interface (Flutter release) e núcleo a partir deste repositório; "
             "o sistema pede a senha numa janela para instalar",
             atualizar),
    ])
