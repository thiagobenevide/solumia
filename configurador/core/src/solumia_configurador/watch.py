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
import socket
import subprocess
import time
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import httpx

PACKAGE = "com.thiagobenevide.agent.relogio"
ACTIVITY = "com.thiagobenevide.agent.watch.MainActivity"
_ADB_CANDIDATES = (
    Path.home() / "Android/Sdk/platform-tools/adb",
    Path.home() / "development/android-sdk/platform-tools/adb",
    Path("/usr/bin/adb"),
)
# Android picks the wireless-debugging port among the high ephemeral ports.
_SCAN_FIRST, _SCAN_LAST = 30000, 49999


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


def _device_states() -> dict[str, str]:
    """`adb devices`: serial → state (device, offline, unauthorized)."""
    result = subprocess.run([adb_path(), "devices"], capture_output=True, text=True, timeout=15, check=False)
    states: dict[str, str] = {}
    for line in result.stdout.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2:
            states[parts[0]] = parts[1]
    return states


def _drop_stale(host: str, log: Callable[[str], None]) -> None:
    """Old entries of this watch (another port, or stuck `offline`) make adb pick the wrong one."""
    prefix = check_address(host, 1).rsplit(":", 1)[0] + ":"
    for serial in _device_states():
        if serial.startswith(prefix):
            subprocess.run([adb_path(), "disconnect", serial], capture_output=True, timeout=15, check=False)
            log(f"Conexão antiga desfeita: {serial}")


def discover_port(host: str, log: Callable[[str], None]) -> int | None:
    """Current wireless-debugging port announced by the watch over mDNS (it changes every time
    wireless debugging is turned on); None when the network does not carry mDNS."""
    try:
        result = subprocess.run([adb_path(), "mdns", "services"], capture_output=True, text=True,
                                timeout=10, check=False)
    except subprocess.TimeoutExpired:
        return None
    for line in result.stdout.splitlines():
        if "_adb-tls-connect" not in line:
            continue
        address = line.split()[-1]
        found_host, _, port = address.rpartition(":")
        if found_host.strip("[]") == host.strip() and port.isdigit():
            log(f"Porta atual anunciada pelo relógio: {port}")
            return int(port)
    return None


def _wait_ready(target: str, log: Callable[[str], None], seconds: int = 20) -> None:
    state = ""
    for _ in range(seconds):
        state = _device_states().get(target, "")
        if state == "device":
            log(f"Relógio pronto: {target}")
            return
        time.sleep(1)
    if state == "unauthorized":
        raise WatchError("o relógio não autorizou este PC: refaça o pareamento (Parear novo dispositivo)")
    raise WatchError(f"o relógio conectou mas ficou '{state or 'sem resposta'}': deixe a tela dele ligada, "
                     "confira se a depuração por Wi-Fi continua ativa e tente de novo")


def _port_open(host: str, port: int) -> bool:
    try:
        with socket.create_connection((host, port), timeout=1.5):
            return True
    except OSError:
        return False


def scan_ports(host: str, log: Callable[[str], None]) -> list[int]:
    """Open TCP ports of the watch in the range Android uses for wireless debugging. Used when mDNS
    does not cross the network (e.g. PC on cable, watch on Wi-Fi): only the watch's own local IP."""
    check_address(host, 1)
    log(f"Procurando a porta da depuração por Wi-Fi em {host} ({_SCAN_FIRST}–{_SCAN_LAST})…")
    found: list[int] = []
    with ThreadPoolExecutor(max_workers=400) as pool:
        ports = range(_SCAN_FIRST, _SCAN_LAST + 1)
        for port, is_open in zip(ports, pool.map(lambda p: _port_open(host, p), ports), strict=True):
            if is_open:
                found.append(port)
    log(f"Portas abertas: {', '.join(map(str, found)) or 'nenhuma'}")
    return found


def _try_connect(target: str, log: Callable[[str], None]) -> str:
    """Output of `adb connect` (never raises: the caller decides with the next candidate)."""
    result = subprocess.run([adb_path(), "connect", target], capture_output=True, text=True,
                            timeout=20, check=False)
    output = (result.stdout + result.stderr).strip()
    log(output)
    return output


def connect(host: str, port: int | None = None, log: Callable[[str], None] = print) -> str:
    """Connects to the watch without asking for the connection port: mDNS, the given port, or a scan."""
    _drop_stale(host, log)
    candidates: list[int] = []
    announced = discover_port(host, log)
    if announced:
        candidates.append(announced)
    if port and port not in candidates:
        candidates.append(port)
    if not candidates:
        candidates = scan_ports(host, log)
    if not candidates:
        raise WatchError(
            "não achei a depuração por Wi-Fi no relógio: abra Opções do desenvolvedor › Depuração por "
            "Wi-Fi no relógio, deixe essa tela aberta com o relógio no carregador e tente de novo")
    for candidate in candidates:
        target = check_address(host, candidate)
        if "connected to" in _try_connect(target, log):
            _wait_ready(target, log)
            return target
        # a failed try (e.g. the pairing port) leaves an `offline` entry behind
        subprocess.run([adb_path(), "disconnect", target], capture_output=True, timeout=15, check=False)
    raise WatchError(
        "o relógio não aceitou a conexão: deixe a tela Depuração por Wi-Fi aberta no relógio (de "
        "preferência no carregador, para o Wi-Fi não dormir) e tente de novo; se continuar, pareie de novo")


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
