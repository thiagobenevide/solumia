"""Runs ngspice in batch mode.

Used by the worker (task `simular_spice`) and, when no worker is connected, by the backend itself.
"""

import asyncio
import base64
import os
import shutil
import tempfile
from pathlib import Path
from typing import Any

MAX_RAW_FILE_SIZE = 50 * 1024 * 1024


class NgspiceMissing(RuntimeError):
    pass


def _write_text_file(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")


def _read_raw_file(path: Path) -> bytes:
    if not path.exists():
        return b""
    if path.stat().st_size > MAX_RAW_FILE_SIZE:
        raise RuntimeError("Result is too large: increase the step or shorten the analysis.")
    return path.read_bytes()


async def run_ngspice(
    netlist: str, timeout_s: float = 120.0, binary: str = "ngspice"
) -> dict[str, Any]:
    """`{raw_b64, log, codigo}`: ASCII raw file (base64), end of the output and exit code."""
    executable = shutil.which(binary)
    if executable is None:
        raise NgspiceMissing(
            "ngspice is not installed on this machine (install it with `sudo apt install ngspice`)."
        )

    with tempfile.TemporaryDirectory(prefix="ngspice-") as folder:
        circuit_path = Path(folder, "circuito.cir")
        raw_path = Path(folder, "saida.raw")
        _write_text_file(circuit_path, netlist)

        environment = dict(os.environ)
        environment["SPICE_ASCIIRAWFILE"] = "1"

        process = await asyncio.create_subprocess_exec(
            executable,
            "-b",
            "-r",
            str(raw_path),
            str(circuit_path),
            cwd=folder,
            env=environment,
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        try:
            output, _ = await asyncio.wait_for(process.communicate(), timeout_s)
        except TimeoutError as error:
            process.kill()
            await process.wait()
            raise RuntimeError(
                f"ngspice took more than {timeout_s:g} s and was stopped."
            ) from error
        raw_data = _read_raw_file(raw_path)

    # The keys are part of the contract with the backend and the app.
    return {
        "raw_b64": base64.b64encode(raw_data).decode(),
        "log": output.decode(errors="replace")[-4000:],
        "codigo": process.returncode,
    }
