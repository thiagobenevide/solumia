"""Diferenças entre Linux e Windows: pastas do configurador, pastas de mídia padrão, arquitetura."""

from __future__ import annotations

import os
import platform
import subprocess
from dataclasses import dataclass
from pathlib import Path

from . import names


@dataclass(frozen=True)
class Sistema:
    so: str  # "linux" | "windows"
    arquitetura: str  # "x86_64" | "aarch64"

    @property
    def windows(self) -> bool:
        return self.so == "windows"


def detectar() -> Sistema:
    so = platform.system().lower()
    if so not in ("linux", "windows"):
        raise RuntimeError(f"Sistema não suportado: {platform.system()} (só Linux e Windows).")
    maquina = platform.machine().lower()
    arquitetura = {"amd64": "x86_64", "x86_64": "x86_64", "arm64": "aarch64", "aarch64": "aarch64"}.get(maquina)
    if arquitetura is None:
        raise RuntimeError(f"Arquitetura não suportada: {platform.machine()}")
    return Sistema(so, arquitetura)


def dir_config(sistema: Sistema | None = None) -> Path:
    """Onde ficam o manifesto e o cofre."""
    sistema = sistema or detectar()
    if sistema.windows:
        return Path(os.environ.get("APPDATA", Path.home() / "AppData" / "Roaming")) / names.NOME_EXIBICAO
    return Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / names.PREFIXO


def dir_estado(sistema: Sistema | None = None) -> Path:
    """Registro de execuções, known_hosts das VPS, downloads parciais."""
    sistema = sistema or detectar()
    if sistema.windows:
        base = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local"))
        return base / names.NOME_EXIBICAO / "estado"
    return Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state")) / names.PREFIXO


def dir_apps(sistema: Sistema | None = None) -> Path:
    """Onde os Craft Apps baixados são instalados (sem precisar de administrador)."""
    sistema = sistema or detectar()
    if sistema.windows:
        base = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local"))
        return base / names.NOME_EXIBICAO / "craft-apps"
    return Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / names.PREFIXO / "craft-apps"


def _pasta_xdg(chave: str, padrao: str) -> Path:
    try:
        saida = subprocess.run(
            ["xdg-user-dir", chave], capture_output=True, text=True, timeout=3, check=False
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        saida = ""
    caminho = Path(saida) if saida else Path.home() / padrao
    # xdg-user-dir devolve a home quando a pasta não está configurada.
    return caminho if caminho != Path.home() else Path.home() / padrao


def dir_downloads(sistema: Sistema | None = None) -> Path:
    """Onde os instaladores dos apps do Solumia (APK, AppImage, setup) são guardados."""
    sistema = sistema or detectar()
    if sistema.windows:
        return Path(os.environ.get("USERPROFILE", Path.home())) / "Downloads" / names.NOME_EXIBICAO
    return _pasta_xdg("DOWNLOAD", "Downloads") / names.NOME_EXIBICAO


def pastas_midia_padrao(sistema: Sistema | None = None) -> dict[str, str]:
    """Sugestões iniciais; a pessoa troca na tela Pastas."""
    sistema = sistema or detectar()
    if sistema.windows:
        casa = Path(os.environ.get("USERPROFILE", Path.home()))
        imagens, videos, musica = casa / "Pictures", casa / "Videos", casa / "Music"
    else:
        imagens = _pasta_xdg("PICTURES", "Imagens")
        videos = _pasta_xdg("VIDEOS", "Vídeos")
        musica = _pasta_xdg("MUSIC", "Músicas")
    raiz = videos / names.NOME_EXIBICAO
    return {
        "imagens": str(imagens / names.NOME_EXIBICAO),
        "videos": str(raiz / "acervo"),
        "audio": str(musica / names.NOME_EXIBICAO),
        "producao": str(raiz / "em-producao"),
        "produzidos": str(raiz / "produzidos"),
    }
