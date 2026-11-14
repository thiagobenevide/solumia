"""Worker on this PC as the `solumia-worker` user service (Linux, systemd --user).

Runs in parallel with the older installation (`agent-worker`) without touching it:
- own unit name, own env file (~/.config/solumia/worker.env, 0600) and own llama-server port;
- working directory outside the repository, so the worker never loads `plataforma/worker/.env`
  (which may hold keys of the older installation);
- `WORKER_CODIGO_DIR` points to this repository, not to the older one.
"""

from __future__ import annotations

import os
import subprocess
import time
from pathlib import Path

from .. import generate, names, secret_store
from ..engine import Context, Plan, Step
from ..manifest import Manifest
from ..platform_setup import System, state_dir
from ..vault import Vault

LEGACY_UNIT = "agent-worker"


def unit_dir() -> Path:
    return Path.home() / ".config" / "systemd" / "user"


def env_path() -> Path:
    return Path.home() / ".config" / names.PREFIX / "worker.env"


def python_path() -> Path:
    return generate.repository_root() / ".venv" / "bin" / "python"


def unit_state(unit: str) -> str:
    try:
        r = subprocess.run(["systemctl", "--user", "is-active", unit], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return "desconhecido"
    return r.stdout.strip() or "desconhecido"


def status() -> dict[str, str | bool]:
    return {
        "unidade": names.WORKER_UNIT,
        "estado": unit_state(names.WORKER_UNIT),
        "instalado": (unit_dir() / f"{names.WORKER_UNIT}.service").exists(),
        "antigo": LEGACY_UNIT,
        "estado_antigo": unit_state(LEGACY_UNIT),
        "porta_llama": str(names.LLAMA_LOCAL_PORT),
    }


def _systemctl(ctx: Context, *args: str) -> None:
    r = subprocess.run(["systemctl", "--user", *args], capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        raise RuntimeError(f"systemctl {' '.join(args)}: {r.stderr.strip()[-300:]}")
    ctx.log(f"systemctl --user {' '.join(args)}: ok")


def _write_private(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(path, 0o600)


def _env_text(m: Manifest, vault: Vault) -> str:
    return (
        generate.env_worker(m, vault)
        + f"WORKER_CODIGO_DIR={generate.repository_root()}\n"
    )


def plan(m: Manifest, vault: Vault, system: System) -> Plan:
    if system.windows:
        raise ValueError("o worker como serviço ainda só existe no Linux")
    if not m.topologia.dominio:
        raise ValueError("defina o domínio e instale a VPS antes: o worker conecta ao gateway dela")
    vault.require(secret_store.WORKER_KEY)
    python = python_path()
    work_dir = state_dir(system) / "worker"
    legacy_before = unit_state(LEGACY_UNIT)

    def ambiente(ctx: Context) -> None:
        if not python.exists():
            raise RuntimeError(f"ambiente Python do repositório não encontrado em {python}")
        r = subprocess.run([str(python), "-c", "import worker.main"], capture_output=True, text=True, timeout=60)
        if r.returncode != 0:
            raise RuntimeError(f"o pacote do worker não importa: {r.stderr.strip()[-300:]}")
        ctx.log(f"Python do worker: {python}")

    def configuracao(ctx: Context) -> None:
        _write_private(env_path(), _env_text(m, vault))
        work_dir.mkdir(parents=True, exist_ok=True)
        ctx.log(f"Gravado {env_path()} (0600)")

    def unidade(ctx: Context) -> None:
        path = unit_dir() / f"{names.WORKER_UNIT}.service"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(generate.worker_unit(work_dir, python), encoding="utf-8")
        ctx.log(f"Gravado {path}")
        _systemctl(ctx, "daemon-reload")

    def ativar(ctx: Context) -> None:
        _systemctl(ctx, "enable", f"{names.WORKER_UNIT}.service")
        _systemctl(ctx, "restart", f"{names.WORKER_UNIT}.service")

    def conferir(ctx: Context) -> None:
        time.sleep(4)
        state = unit_state(names.WORKER_UNIT)
        if state != "active":
            raise RuntimeError(f"{names.WORKER_UNIT} ficou '{state}'; veja journalctl --user -u {names.WORKER_UNIT}")
        ctx.log(f"{names.WORKER_UNIT}: ativo")
        legacy_now = unit_state(LEGACY_UNIT)
        ctx.log(f"{LEGACY_UNIT} (instalação antiga): {legacy_now}")
        if legacy_before == "active" and legacy_now != "active":
            raise RuntimeError(f"{LEGACY_UNIT} estava ativo e parou; nada dele foi alterado, confira o journal")

    unit_file = unit_dir() / f"{names.WORKER_UNIT}.service"
    return Plan(f"Instalar o worker ({names.WORKER_UNIT}) neste PC", [
        Step("ambiente", "Conferir o Python do worker", str(python), ambiente),
        Step("configuracao", "Gravar a configuração do worker",
             f"{env_path()} em 0600; gateway wss://[seu domínio]; llama na porta {names.LLAMA_LOCAL_PORT}",
             configuracao),
        Step("unidade", "Gravar o serviço do usuário", f"{unit_file}; pasta de trabalho {work_dir}", unidade),
        Step("ativar", f"Ligar {names.WORKER_UNIT}", f"{LEGACY_UNIT} não é tocado", ativar),
        Step("conferir", "Conferir os dois workers", f"{names.WORKER_UNIT} ativo e {LEGACY_UNIT} como estava", conferir),
    ])
