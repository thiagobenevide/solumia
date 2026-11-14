"""Snapshot of the Worker machine usage, sent with the heartbeat: CPU load, RAM and NVIDIA GPUs
(through `nvidia-smi`, if present). Only reads `/proc`; on another OS the fields stay null."""

import os
import shutil
import subprocess
from pathlib import Path
from typing import Any


def _ram_pct() -> float | None:
    try:
        info = dict(
            line.split(":", 1) for line in Path("/proc/meminfo").read_text().splitlines()
        )
        total = int(info["MemTotal"].split()[0])
        free = int(info["MemAvailable"].split()[0])
    except (OSError, KeyError, ValueError):
        return None
    return round(100 * (total - free) / total, 1)


def _gpus() -> list[dict[str, Any]]:
    if not shutil.which("nvidia-smi"):
        return []
    fields = "name,utilization.gpu,memory.used,memory.total,temperature.gpu"
    try:
        output = subprocess.run(
            ["nvidia-smi", f"--query-gpu={fields}", "--format=csv,noheader,nounits"],
            capture_output=True,
            text=True,
            timeout=3,
            check=True,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    gpus = []
    for line in output.strip().splitlines():
        name, usage, usada, total, temp = (c.strip() for c in line.split(","))
        gpus.append(
            {
                "nome": name,
                "uso_pct": float(usage),
                "mem_usada_mb": float(usada),
                "mem_total_mb": float(total),
                "temp_c": float(temp),
            }
        )
    return gpus


def collect() -> dict[str, Any]:
    try:
        cpu = round(100 * os.getloadavg()[0] / (os.cpu_count() or 1), 1)
    except OSError:
        cpu = None
    return {"cpu_pct": cpu, "ram_pct": _ram_pct(), "gpus": _gpus()}
