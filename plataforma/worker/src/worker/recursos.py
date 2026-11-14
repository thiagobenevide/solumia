"""Retrato do uso da máquina do Worker, enviado junto do heartbeat: carga de CPU, RAM e GPUs
NVIDIA (via `nvidia-smi`, se existir). Só lê `/proc`; em outro SO os campos ficam nulos."""

import os
import shutil
import subprocess
from pathlib import Path
from typing import Any


def _ram_pct() -> float | None:
    try:
        info = dict(
            linha.split(":", 1) for linha in Path("/proc/meminfo").read_text().splitlines()
        )
        total = int(info["MemTotal"].split()[0])
        livre = int(info["MemAvailable"].split()[0])
    except (OSError, KeyError, ValueError):
        return None
    return round(100 * (total - livre) / total, 1)


def _gpus() -> list[dict[str, Any]]:
    if not shutil.which("nvidia-smi"):
        return []
    campos = "name,utilization.gpu,memory.used,memory.total,temperature.gpu"
    try:
        saida = subprocess.run(
            ["nvidia-smi", f"--query-gpu={campos}", "--format=csv,noheader,nounits"],
            capture_output=True,
            text=True,
            timeout=3,
            check=True,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    gpus = []
    for linha in saida.strip().splitlines():
        nome, uso, usada, total, temp = (c.strip() for c in linha.split(","))
        gpus.append(
            {
                "nome": nome,
                "uso_pct": float(uso),
                "mem_usada_mb": float(usada),
                "mem_total_mb": float(total),
                "temp_c": float(temp),
            }
        )
    return gpus


def coletar() -> dict[str, Any]:
    try:
        cpu = round(100 * os.getloadavg()[0] / (os.cpu_count() or 1), 1)
    except OSError:
        cpu = None
    return {"cpu_pct": cpu, "ram_pct": _ram_pct(), "gpus": _gpus()}
