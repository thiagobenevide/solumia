"""Differences between Linux and Windows: configurator folders, default media folders, architecture."""

from __future__ import annotations

import os
import platform
import subprocess
from dataclasses import dataclass
from pathlib import Path

from . import names


@dataclass(frozen=True)
class System:
    so: str  # "linux" | "windows"
    arquitetura: str  # "x86_64" | "aarch64"

    @property
    def windows(self) -> bool:
        return self.so == "windows"


def detect() -> System:
    so = platform.system().lower()
    if so not in ("linux", "windows"):
        raise RuntimeError(f"Sistema não suportado: {platform.system()} (só Linux e Windows).")
    machine = platform.machine().lower()
    architecture = {"amd64": "x86_64", "x86_64": "x86_64", "arm64": "aarch64", "aarch64": "aarch64"}.get(machine)
    if architecture is None:
        raise RuntimeError(f"Arquitetura não suportada: {platform.machine()}")
    return System(so, architecture)


def dir_config(system: System | None = None) -> Path:
    """Onde ficam o manifesto e o cofre."""
    system = system or detect()
    if system.windows:
        return Path(os.environ.get("APPDATA", Path.home() / "AppData" / "Roaming")) / names.DISPLAY_NAME
    return Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / names.PREFIX


def state_dir(system: System | None = None) -> Path:
    """Run log, VPS known_hosts, partial downloads."""
    system = system or detect()
    if system.windows:
        base = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local"))
        return base / names.DISPLAY_NAME / "estado"
    return Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state")) / names.PREFIX


def dir_apps(system: System | None = None) -> Path:
    """Where downloaded Craft Apps are installed (no admin rights needed)."""
    system = system or detect()
    if system.windows:
        base = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local"))
        return base / names.DISPLAY_NAME / "craft-apps"
    return Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / names.PREFIX / "craft-apps"


def _xdg_folder(key: str, default: str) -> Path:
    try:
        output = subprocess.run(
            ["xdg-user-dir", key], capture_output=True, text=True, timeout=3, check=False
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        output = ""
    path = Path(output) if output else Path.home() / default
    # xdg-user-dir returns the home folder when the folder is not configured.
    return path if path != Path.home() else Path.home() / default


def dir_downloads(system: System | None = None) -> Path:
    """Where the Solumia app installers (APK, AppImage, setup) are stored."""
    system = system or detect()
    if system.windows:
        return Path(os.environ.get("USERPROFILE", Path.home())) / "Downloads" / names.DISPLAY_NAME
    return _xdg_folder("DOWNLOAD", "Downloads") / names.DISPLAY_NAME


def default_media_folders(system: System | None = None) -> dict[str, str]:
    """Initial suggestions; the person changes them on the Folders screen."""
    system = system or detect()
    if system.windows:
        matches = Path(os.environ.get("USERPROFILE", Path.home()))
        images, videos, music = matches / "Pictures", matches / "Videos", matches / "Music"
    else:
        images = _xdg_folder("PICTURES", "Imagens")
        videos = _xdg_folder("VIDEOS", "Vídeos")
        music = _xdg_folder("MUSIC", "Músicas")
    root = videos / names.DISPLAY_NAME
    return {
        "imagens": str(images / names.DISPLAY_NAME),
        "videos": str(root / "acervo"),
        "audio": str(music / names.DISPLAY_NAME),
        "producao": str(root / "em-producao"),
        "produzidos": str(root / "produzidos"),
    }
