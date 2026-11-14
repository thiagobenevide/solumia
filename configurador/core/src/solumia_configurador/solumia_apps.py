"""Apps do próprio Solumia para cada dispositivo: celular/tablet, relógio, PC e notebook.

Fonte: GitHub Releases de `nomes.REPOSITORIO`. Nomes dos arquivos por release (gerados pelo CI):
`solumia-X.Y.Z-android.apk`, `solumia-X.Y.Z-wear.apk`, `solumia-X.Y.Z-linux-x86_64.AppImage`,
`solumia-X.Y.Z-windows-x64-setup.exe`, mais `SHA256SUMS.txt` assinado.

Segurança: mesmo caminho dos Craft Apps (`craft_apps.baixar_verificado`). Enquanto a chave de
assinatura das releases do Solumia não for fixada em `IMPRESSOES_SOLUMIA`, o download é bloqueado:
nunca se baixa um app do Solumia conferido só pela própria release.
"""

from __future__ import annotations

import os
import stat
import subprocess
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from . import names
from .craft_apps import CraftErro, Release, baixar_verificado, buscar_release_repo
from .platform_setup import Sistema, dir_apps, dir_downloads

# Impressão digital da chave que assina as releases do Solumia. Preencher quando o CI de release existir.
IMPRESSOES_SOLUMIA: tuple[str, ...] = ()


@dataclass(frozen=True)
class AppSolumia:
    id: str
    dispositivo: str  # celular | relogio | pc
    modelo: str  # nome do arquivo com {v}
    sistema: str | None = None  # para PC: em qual sistema pode ser instalado aqui

    def arquivo(self, versao: str) -> str:
        return self.modelo.format(v=versao)


CATALOGO: dict[str, AppSolumia] = {
    a.id: a
    for a in (
        AppSolumia("android", "celular", "solumia-{v}-android.apk"),
        AppSolumia("wear", "relogio", "solumia-{v}-wear.apk"),
        AppSolumia("linux", "pc", "solumia-{v}-linux-x86_64.AppImage", "linux"),
        AppSolumia("windows", "pc", "solumia-{v}-windows-x64-setup.exe", "windows"),
    )
}


def url_releases() -> str:
    return f"https://github.com/{names.REPOSITORIO}/releases"


def buscar(versao: str = "ultima") -> Release:
    return buscar_release_repo(names.REPOSITORIO, names.NOME_EXIBICAO, versao)


def _app(app_id: str) -> AppSolumia:
    try:
        return CATALOGO[app_id]
    except KeyError as e:
        raise CraftErro(f"app fora do catálogo: {app_id!r}") from e


def instala_aqui(app: AppSolumia, sistema: Sistema) -> bool:
    return app.sistema == sistema.so and sistema.arquitetura == "x86_64"


def baixar(app_id: str, sistema: Sistema, versao: str = "ultima", instalar: bool = False,
           log: Callable[[str], None] = print,
           progresso: Callable[[int, int | None], None] | None = None) -> dict[str, str]:
    """Baixa o instalador verificado para a pasta Downloads/Solumia; com `instalar`, instala neste PC."""
    app = _app(app_id)
    if not IMPRESSOES_SOLUMIA:
        raise CraftErro("as releases do Solumia ainda não têm chave de assinatura fixada no configurador; "
                        "download bloqueado por segurança")
    if instalar and not instala_aqui(app, sistema):
        raise CraftErro(f"o app {app_id} não é para este sistema ({sistema.so} {sistema.arquitetura})")
    log(f"Consultando releases em {url_releases()}")
    release = buscar(versao)
    nome = app.arquivo(release.versao)
    pasta = dir_downloads(sistema)
    pasta.mkdir(parents=True, exist_ok=True)
    caminho, soma = baixar_verificado(release, nome, pasta, IMPRESSOES_SOLUMIA, log, progresso)
    log(f"Salvo em {caminho}")
    if instalar:
        caminho = _instalar(caminho, sistema, log)
    return {"versao": release.versao, "arquivo": nome, "sha256": soma, "caminho": str(caminho)}


def _instalar(arquivo: Path, sistema: Sistema, log: Callable[[str], None]) -> Path:
    if sistema.windows:
        log("Abrindo o instalador do Solumia")
        subprocess.run([str(arquivo)], check=True)
        return arquivo
    destino = dir_apps(sistema).parent / "app" / "Solumia.AppImage"
    destino.parent.mkdir(parents=True, exist_ok=True)
    tmp = destino.with_suffix(".novo")
    tmp.write_bytes(arquivo.read_bytes())
    tmp.chmod(tmp.stat().st_mode | stat.S_IXUSR)
    os.replace(tmp, destino)
    atalho = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / "applications"
    atalho.mkdir(parents=True, exist_ok=True)
    (atalho / f"{names.PREFIXO}-app.desktop").write_text(
        "[Desktop Entry]\nType=Application\nName=Solumia\n"
        f"Exec=\"{destino}\"\nTerminal=false\nCategories=Office;\n"
    )
    log(f"Solumia instalado em {destino}")
    return destino
