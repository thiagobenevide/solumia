"""Installs the Solumia watch app (Wear OS) over Wi-Fi with ADB.

The watch only accepts installs through wireless debugging: Settings › Developer options ›
Wireless debugging. The first time, "Pair new device" shows a pairing port and a 6-digit code
(`adb pair`); after that only the connection port is needed (`adb connect`). The verified APK
from the release is installed and the watch app receives the server address and its own key
(`relogio:` scope: only the watch routes) through the launch intent, like `modulos/saude/wear/instalar`.
"""

from __future__ import annotations

import ipaddress
import os
import shutil
import subprocess
from collections.abc import Callable
from pathlib import Path

import httpx

PACKAGE = "com.thiagobenevide.agent.relogio"
ACTIVITY = "com.thiagobenevide.agent.watch.MainActivity"
_ADB_CANDIDATES = (
    Path.home() / "Android/Sdk/platform-tools/adb",
    Path.home() / "development/android-sdk/platform-tools/adb",
    Path("/usr/bin/adb"),
)


class WatchError(Exception):
    pass


def adb_path() -> str:
    found = shutil.which("adb")
    if found:
        return found
    sdk = os.environ.get("ANDROID_HOME")
    candidates = list(_ADB_CANDIDATES)
    if sdk:
        candidates.insert(0, Path(sdk) / "platform-tools/adb")
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    raise WatchError("adb não encontrado: instale com 'sudo apt install adb' e tente de novo")


def check_address(host: str, port: int) -> str:
    """Only a private IPv4/IPv6 address on the local network and a valid port (no hostnames)."""
    try:
        ip = ipaddress.ip_address(host.strip())
    except ValueError as e:
        raise WatchError(f"IP do relógio inválido: {host!r}") from e
    if not ip.is_private or ip.is_loopback:
        raise WatchError("o IP do relógio precisa ser da rede local (ex.: 192.168.0.23)")
    if not 1 <= port <= 65535:
        raise WatchError(f"porta inválida: {port}")
    return f"[{ip}]:{port}" if ip.version == 6 else f"{ip}:{port}"


def _adb(args: list[str], log: Callable[[str], None], timeout: int = 60) -> str:
    result = subprocess.run([adb_path(), *args], capture_output=True, text=True, timeout=timeout, check=False)
    output = (result.stdout + result.stderr).strip()
    if output:
        log(output)
    if result.returncode != 0:
        raise WatchError(f"adb {args[0]} falhou: {output or result.returncode}")
    return output


def pair(host: str, port: int, code: str, log: Callable[[str], None] = print) -> None:
    code = code.strip()
    if not (code.isdigit() and len(code) == 6):
        raise WatchError("o código de pareamento tem 6 dígitos")
    output = _adb(["pair", check_address(host, port), code], log)
    if "Successfully paired" not in output:
        raise WatchError("o relógio recusou o pareamento: confira a porta e o código (eles mudam a cada vez)")


def connect(host: str, port: int, log: Callable[[str], None] = print) -> str:
    target = check_address(host, port)
    output = _adb(["connect", target], log)
    if "connected to" not in output:
        raise WatchError("não conectou: o relógio está com a depuração por Wi-Fi ligada e na mesma rede?")
    return target


def check_key(url: str, key: str, log: Callable[[str], None] = print) -> None:
    """The VPS must already accept the watch key, otherwise the watch would only get 401."""
    r = httpx.get(f"{url}/api/atualizacoes", headers={"Authorization": f"Bearer {key}"}, timeout=15)
    if r.status_code in (401, 403):
        raise WatchError("a VPS ainda não conhece a chave do relógio: em VPS, aplique a instalação de novo "
                         "e depois repita a instalação no relógio")
    r.raise_for_status()
    log(f"Chave do relógio aceita por {url}")


def install(target: str, apk: Path, url: str, key: str, log: Callable[[str], None] = print) -> None:
    _adb(["-s", target, "install", "-r", str(apk)], log, timeout=600)
    _adb(["-s", target, "shell", "am", "start", "-n", f"{PACKAGE}/{ACTIVITY}",
          "--es", "url", url, "--es", "chave", key], log)
    log("App aberto no relógio já com o servidor e a chave")
