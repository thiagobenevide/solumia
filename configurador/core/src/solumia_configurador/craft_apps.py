"""Craft Apps (FilmCraft, SoundCraft, EffectCraft, PhotoCraft): catalog, verified download and installation.

Source: GitHub Releases of each repository (organization `storytold`). Each release publishes
`SHA256SUMS.txt`, the signature `SHA256SUMS.txt.asc` and `release-signing-key.asc`.

Security:
- catalog repositories only; file names checked by regular expression;
- downloads only from github.com / *.githubusercontent.com, over HTTPS, with a size limit;
- signature checked against the fingerprint PINNED below (not against the release key);
- extraction guarded against paths that escape the folder (zip/tar slip);
- installed in the user's folder, without admin rights (the .deb and the .msi ask the system for elevation).
"""

from __future__ import annotations

import json
import os
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import zipfile
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

import httpx

from . import names, verification
from .platform_setup import System, dir_apps, state_dir

# Chave "ArtCraft Linux Release Signing Key" (a mesma nas quatro releases, conferida em 2026-11-12).
ARTCRAFT_FINGERPRINT = "2B76741B414AAD6CD33E631213A005C0B9D7C3ED"


@dataclass(frozen=True)
class CatalogApp:
    id: str
    nome: str
    descricao: str
    repositorio: str  # "dono/repo"
    impressoes: tuple[str, ...] = (ARTCRAFT_FINGERPRINT,)
    exigir_assinatura: bool = True

    @property
    def url_github(self) -> str:
        return f"https://github.com/{self.repositorio}"

    @property
    def url_releases(self) -> str:
        return f"{self.url_github}/releases"


CATALOG: dict[str, CatalogApp] = {
    a.id: a
    for a in (
        CatalogApp("filmcraft", "FilmCraft", "Editor de vídeo não linear", "storytold/filmcraft"),
        CatalogApp("soundcraft", "SoundCraft", "Estação de áudio digital (DAW)", "storytold/soundcraft"),
        CatalogApp("effectcraft", "EffectCraft", "Motion graphics e composição", "storytold/effectcraft"),
        CatalogApp("photocraft", "PhotoCraft", "Editor de fotos", "storytold/photocraft"),
    )
}

_API = "https://api.github.com"
_HOSTS_PERMITIDOS = ("github.com", "api.github.com", "objects.githubusercontent.com",
                     "release-assets.githubusercontent.com", "github-releases.githubusercontent.com")
_MAX_SIZE = 2 * 1024**3  # 2 GiB por arquivo
_MAX_TEXT_SIZE = 1024**2

# format -> (file name suffix for linux, for windows)
_FORMATS = {
    "appimage": ("{arq}.AppImage", None),
    "deb": ("{arq}.deb", None),
    "tar.gz": ("{arq}.tar.gz", None),
    "msi": (None, "{arq}.msi"),
    "portatil": (None, "{arq}-portable.zip"),
}


class CraftError(Exception):
    pass


@dataclass
class Release:
    versao: str
    publicada_em: str
    arquivos: dict[str, str]  # name -> download URL


def _cliente() -> httpx.Client:
    return httpx.Client(
        headers={"User-Agent": names.USER_AGENT, "Accept": "application/vnd.github+json"},
        timeout=httpx.Timeout(30.0, read=120.0),
        follow_redirects=True,
        event_hooks={"request": [_check_host]},
    )


def _check_host(req: httpx.Request) -> None:
    host = req.url.host
    if req.url.scheme != "https" or not any(host == h or host.endswith("." + h) for h in _HOSTS_PERMITIDOS):
        raise CraftError(f"download recusado: host não permitido ({host})")


def _app(app_id: str) -> CatalogApp:
    try:
        return CATALOG[app_id]
    except KeyError as e:
        raise CraftError(f"app fora do catálogo: {app_id!r}") from e


def fetch_release(app_id: str, version: str = "ultima", cliente: httpx.Client | None = None) -> Release:
    app = _app(app_id)
    return fetch_repo_release(app.repositorio, app.nome, version, cliente)


def fetch_repo_release(repository: str, name: str, version: str = "ultima",
                        cliente: httpx.Client | None = None) -> Release:
    path = "releases/latest" if version == "ultima" else f"releases/tags/v{version}"
    if version != "ultima" and not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise CraftError("versão inválida")
    with cliente or _cliente() as c:
        r = c.get(f"{_API}/repos/{repository}/{path}")
        if r.status_code == 404:
            raise CraftError(f"release {version} de {name} não encontrada")
        if r.status_code == 403:
            raise CraftError("limite de consultas do GitHub atingido; tente em alguns minutos")
        r.raise_for_status()
        data = r.json()
    tag = str(data.get("tag_name", ""))
    m = re.fullmatch(r"v?(\d+\.\d+\.\d+)", tag)
    if not m:
        raise CraftError(f"tag de release inesperada: {tag!r}")
    files = {}
    for a in data.get("assets", []):
        name, url = str(a.get("name", "")), str(a.get("browser_download_url", ""))
        if re.fullmatch(r"[A-Za-z0-9._+-]{1,200}", name) and urlparse(url).scheme == "https":
            files[name] = url
    return Release(m.group(1), str(data.get("published_at", "")), files)


def file_name(app_id: str, version: str, system: System, fmt: str = "auto") -> str:
    if fmt == "auto":
        fmt = "portatil" if system.windows else "appimage"
    if fmt not in _FORMATS:
        raise CraftError(f"formato desconhecido: {fmt}")
    model = _FORMATS[fmt][1 if system.windows else 0]
    if model is None:
        raise CraftError(f"formato {fmt} não existe para {system.so}")
    file = {("linux", "x86_64"): "linux-x86_64", ("linux", "aarch64"): "linux-aarch64",
           ("windows", "x86_64"): "windows-x64", ("windows", "aarch64"): "windows-arm64"}[
        (system.so, system.arquitetura)
    ]
    return f"{app_id}-{version}-" + model.format(arq=file)


def _download(c: httpx.Client, url: str, destination: Path, limit: int,
            progresso: Callable[[int, int | None], None] | None = None) -> None:
    with c.stream("GET", url) as r:
        r.raise_for_status()
        total = int(r.headers["content-length"]) if "content-length" in r.headers else None
        if total is not None and total > limit:
            raise CraftError(f"arquivo maior que o limite ({total} bytes)")
        read = 0
        with destination.open("wb") as f:
            for block in r.iter_bytes(1 << 20):
                read += len(block)
                if read > limit:
                    raise CraftError("arquivo excedeu o limite de tamanho")
                f.write(block)
                if progresso:
                    progresso(read, total)


def download_verified(release: Release, name: str, folder: Path, fingerprints: tuple[str, ...],
                      log: Callable[[str], None] = print,
                      progresso: Callable[[int, int | None], None] | None = None) -> tuple[Path, str]:
    """Downloads `name` from the release into `folder` only after checking the signed SHA256SUMS and the SHA-256.

    Empty `fingerprints` turns the signature check off (only the SHA-256 is checked)."""
    required = [name, "SHA256SUMS.txt"] + (["SHA256SUMS.txt.asc", "release-signing-key.asc"] if fingerprints else [])
    for needed in required:
        if needed not in release.arquivos:
            raise CraftError(f"a release {release.versao} não tem {needed}")
    with _cliente() as c, tempfile.TemporaryDirectory(prefix="solumia-sums-") as tmp:
        t = Path(tmp)
        sums = t / "SHA256SUMS.txt"
        _download(c, release.arquivos["SHA256SUMS.txt"], sums, _MAX_TEXT_SIZE)
        if fingerprints:
            sums_asc, key = t / "SHA256SUMS.txt.asc", t / "chave.asc"
            _download(c, release.arquivos["SHA256SUMS.txt.asc"], sums_asc, _MAX_TEXT_SIZE)
            _download(c, release.arquivos["release-signing-key.asc"], key, _MAX_TEXT_SIZE)
            fingerprint = verification.check_signature(key.read_bytes(), sums_asc, sums, list(fingerprints))
            log(f"Assinatura do SHA256SUMS válida (chave …{fingerprint[-16:]})")
        else:
            log("ATENÇÃO: assinatura desligada; só o SHA-256 será conferido")
        somas = verification.read_sums(sums.read_text())

        partial = folder / (name + ".parcial")
        log(f"Baixando {name}")
        try:
            _download(c, release.arquivos[name], partial, _MAX_SIZE, progresso)
            total = verification.check_file(partial, name, somas)
        except BaseException:
            partial.unlink(missing_ok=True)
            raise
    log(f"SHA-256 confere: {total[:16]}…")
    final = folder / name
    os.replace(partial, final)
    return final, total


def _extract_zip(file: Path, destination: Path) -> None:
    root = destination.resolve()
    with zipfile.ZipFile(file) as z:
        for info in z.infolist():
            target = (destination / info.filename).resolve()
            if not target.is_relative_to(root):
                raise CraftError(f"arquivo zip tenta escrever fora da pasta: {info.filename}")
            if stat.S_ISLNK(info.external_attr >> 16):
                raise CraftError("arquivo zip com link simbólico recusado")
        z.extractall(destination)  # noqa: S202 — cada entrada conferida acima


def _extract_tar(file: Path, destination: Path) -> None:
    with tarfile.open(file) as t:
        t.extractall(destination, filter="data")  # noqa: S202 — the "data" filter blocks absolute paths, '..' and links pointing outside


def _state_file() -> Path:
    return state_dir() / "craft_apps.json"


def instalados() -> dict[str, dict[str, str]]:
    try:
        return json.loads(_state_file().read_text())
    except (OSError, ValueError):
        return {}


def _register(app_id: str, info: dict[str, str]) -> None:
    data = instalados()
    data[app_id] = info
    path = _state_file()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2))
    os.replace(tmp, path)


def install(app_id: str, system: System, version: str = "ultima", fmt: str = "auto",
             log: Callable[[str], None] = print,
             progresso: Callable[[int, int | None], None] | None = None) -> dict[str, str]:
    app = _app(app_id)
    log(f"Consultando releases de {app.nome} em {app.url_releases}")
    release = fetch_release(app_id, version)
    name = file_name(app_id, release.versao, system, fmt)
    with tempfile.TemporaryDirectory(prefix=f"solumia-{app_id}-") as tmp:
        downloaded, total = download_verified(release, name, Path(tmp), app.impressoes if app.exigir_assinatura else (),
                                          log, progresso)
        destination = dir_apps(system) / app_id
        path = _install_file(app, downloaded, destination, system, log)

    info = {"versao": release.versao, "arquivo": name, "sha256": total, "caminho": str(path)}
    _register(app_id, info)
    log(f"{app.nome} {release.versao} instalado em {path}")
    return info


def _install_file(app: CatalogApp, downloaded: Path, destination: Path, system: System,
                      log: Callable[[str], None]) -> Path:
    name = downloaded.name
    new = destination.with_name(destination.name + ".novo")
    shutil.rmtree(new, ignore_errors=True)
    new.mkdir(parents=True)
    if name.endswith(".AppImage"):
        target = new / f"{app.id}.AppImage"
        shutil.copy2(downloaded, target)
        target.chmod(0o755)
        executable = destination / target.name
    elif name.endswith(".tar.gz"):
        _extract_tar(downloaded, new)
        executable = destination
    elif name.endswith("-portable.zip"):
        _extract_zip(downloaded, new)
        executable = destination
    elif name.endswith(".deb"):
        shutil.rmtree(new)
        if shutil.which("pkexec") is None:
            raise CraftError("instalar .deb exige pkexec; use o formato AppImage")
        log("Pedindo permissão de administrador ao sistema para instalar o .deb")
        subprocess.run(["pkexec", "apt-get", "install", "-y", str(downloaded)], check=True, timeout=900)
        return Path("/usr/bin") / app.id
    elif name.endswith(".msi"):
        shutil.rmtree(new)
        log("Abrindo o instalador do Windows (pode pedir permissão de administrador)")
        subprocess.run(["msiexec", "/i", str(downloaded), "/qb"], check=True, timeout=900)
        return Path(os.environ.get("ProgramFiles", "C:\\Program Files")) / app.nome
    else:
        raise CraftError(f"formato não suportado: {name}")

    # Atomic swap: the previous version is only removed once the new one is complete.
    old = destination.with_name(destination.name + ".antigo")
    shutil.rmtree(old, ignore_errors=True)
    if destination.exists():
        destination.rename(old)
    new.rename(destination)
    shutil.rmtree(old, ignore_errors=True)
    if not system.windows and executable.suffix == ".AppImage":
        _linux_shortcut(app, executable)
    return executable


def _linux_shortcut(app: CatalogApp, executable: Path) -> None:
    folder = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / "applications"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / f"{names.PREFIX}-{app.id}.desktop").write_text(
        "[Desktop Entry]\nType=Application\n"
        f"Name={app.nome}\nComment={app.descricao}\nExec=\"{executable}\" %F\n"
        f"Categories=AudioVideo;Graphics;\nX-Solumia-App={app.id}\n"
    )


def remove(app_id: str, system: System) -> None:
    _app(app_id)
    shutil.rmtree(dir_apps(system) / app_id, ignore_errors=True)
    shortcut = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / "applications" / (
        f"{names.PREFIX}-{app_id}.desktop"
    )
    shortcut.unlink(missing_ok=True)
    data = instalados()
    if data.pop(app_id, None) is not None:
        _state_file().write_text(json.dumps(data, indent=2))
