"""Craft Apps (FilmCraft, SoundCraft, EffectCraft, PhotoCraft): catálogo, download verificado e instalação.

Fonte: GitHub Releases de cada repositório (organização `storytold`). Cada release publica
`SHA256SUMS.txt`, a assinatura `SHA256SUMS.txt.asc` e `release-signing-key.asc`.

Segurança:
- só repositórios do catálogo; nomes de arquivo conferidos por expressão regular;
- download só de github.com / *.githubusercontent.com, por HTTPS, com limite de tamanho;
- assinatura conferida contra a impressão digital FIXADA abaixo (não contra a chave da release);
- extração protegida contra caminhos que escapam da pasta (zip/tar slip);
- instalação na pasta do usuário, sem administrador (o .deb e o .msi pedem elevação ao sistema).
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

from . import nomes, verificacao
from .plataforma import Sistema, dir_apps, dir_estado

# Chave "ArtCraft Linux Release Signing Key" (a mesma nas quatro releases, conferida em 2026-11-12).
IMPRESSAO_ARTCRAFT = "2B76741B414AAD6CD33E631213A005C0B9D7C3ED"


@dataclass(frozen=True)
class AppCatalogo:
    id: str
    nome: str
    descricao: str
    repositorio: str  # "dono/repo"
    impressoes: tuple[str, ...] = (IMPRESSAO_ARTCRAFT,)
    exigir_assinatura: bool = True

    @property
    def url_github(self) -> str:
        return f"https://github.com/{self.repositorio}"

    @property
    def url_releases(self) -> str:
        return f"{self.url_github}/releases"


CATALOGO: dict[str, AppCatalogo] = {
    a.id: a
    for a in (
        AppCatalogo("filmcraft", "FilmCraft", "Editor de vídeo não linear", "storytold/filmcraft"),
        AppCatalogo("soundcraft", "SoundCraft", "Estação de áudio digital (DAW)", "storytold/soundcraft"),
        AppCatalogo("effectcraft", "EffectCraft", "Motion graphics e composição", "storytold/effectcraft"),
        AppCatalogo("photocraft", "PhotoCraft", "Editor de fotos", "storytold/photocraft"),
    )
}

_API = "https://api.github.com"
_HOSTS_PERMITIDOS = ("github.com", "api.github.com", "objects.githubusercontent.com",
                     "release-assets.githubusercontent.com", "github-releases.githubusercontent.com")
_TAMANHO_MAX = 2 * 1024**3  # 2 GiB por arquivo
_TAMANHO_MAX_TEXTO = 1024**2

# formato -> (sufixo no nome do arquivo para linux, para windows)
_FORMATOS = {
    "appimage": ("{arq}.AppImage", None),
    "deb": ("{arq}.deb", None),
    "tar.gz": ("{arq}.tar.gz", None),
    "msi": (None, "{arq}.msi"),
    "portatil": (None, "{arq}-portable.zip"),
}


class CraftErro(Exception):
    pass


@dataclass
class Release:
    versao: str
    publicada_em: str
    arquivos: dict[str, str]  # nome -> URL de download


def _cliente() -> httpx.Client:
    return httpx.Client(
        headers={"User-Agent": nomes.USER_AGENT, "Accept": "application/vnd.github+json"},
        timeout=httpx.Timeout(30.0, read=120.0),
        follow_redirects=True,
        event_hooks={"request": [_conferir_host]},
    )


def _conferir_host(req: httpx.Request) -> None:
    host = req.url.host
    if req.url.scheme != "https" or not any(host == h or host.endswith("." + h) for h in _HOSTS_PERMITIDOS):
        raise CraftErro(f"download recusado: host não permitido ({host})")


def _app(app_id: str) -> AppCatalogo:
    try:
        return CATALOGO[app_id]
    except KeyError as e:
        raise CraftErro(f"app fora do catálogo: {app_id!r}") from e


def buscar_release(app_id: str, versao: str = "ultima", cliente: httpx.Client | None = None) -> Release:
    app = _app(app_id)
    return buscar_release_repo(app.repositorio, app.nome, versao, cliente)


def buscar_release_repo(repositorio: str, nome: str, versao: str = "ultima",
                        cliente: httpx.Client | None = None) -> Release:
    caminho = "releases/latest" if versao == "ultima" else f"releases/tags/v{versao}"
    if versao != "ultima" and not re.fullmatch(r"\d+\.\d+\.\d+", versao):
        raise CraftErro("versão inválida")
    with cliente or _cliente() as c:
        r = c.get(f"{_API}/repos/{repositorio}/{caminho}")
        if r.status_code == 404:
            raise CraftErro(f"release {versao} de {nome} não encontrada")
        if r.status_code == 403:
            raise CraftErro("limite de consultas do GitHub atingido; tente em alguns minutos")
        r.raise_for_status()
        dados = r.json()
    tag = str(dados.get("tag_name", ""))
    m = re.fullmatch(r"v?(\d+\.\d+\.\d+)", tag)
    if not m:
        raise CraftErro(f"tag de release inesperada: {tag!r}")
    arquivos = {}
    for a in dados.get("assets", []):
        nome, url = str(a.get("name", "")), str(a.get("browser_download_url", ""))
        if re.fullmatch(r"[A-Za-z0-9._+-]{1,200}", nome) and urlparse(url).scheme == "https":
            arquivos[nome] = url
    return Release(m.group(1), str(dados.get("published_at", "")), arquivos)


def nome_arquivo(app_id: str, versao: str, sistema: Sistema, formato: str = "auto") -> str:
    if formato == "auto":
        formato = "portatil" if sistema.windows else "appimage"
    if formato not in _FORMATOS:
        raise CraftErro(f"formato desconhecido: {formato}")
    modelo = _FORMATOS[formato][1 if sistema.windows else 0]
    if modelo is None:
        raise CraftErro(f"formato {formato} não existe para {sistema.so}")
    arq = {("linux", "x86_64"): "linux-x86_64", ("linux", "aarch64"): "linux-aarch64",
           ("windows", "x86_64"): "windows-x64", ("windows", "aarch64"): "windows-arm64"}[
        (sistema.so, sistema.arquitetura)
    ]
    return f"{app_id}-{versao}-" + modelo.format(arq=arq)


def _baixar(c: httpx.Client, url: str, destino: Path, limite: int,
            progresso: Callable[[int, int | None], None] | None = None) -> None:
    with c.stream("GET", url) as r:
        r.raise_for_status()
        total = int(r.headers["content-length"]) if "content-length" in r.headers else None
        if total is not None and total > limite:
            raise CraftErro(f"arquivo maior que o limite ({total} bytes)")
        lido = 0
        with destino.open("wb") as f:
            for bloco in r.iter_bytes(1 << 20):
                lido += len(bloco)
                if lido > limite:
                    raise CraftErro("arquivo excedeu o limite de tamanho")
                f.write(bloco)
                if progresso:
                    progresso(lido, total)


def baixar_verificado(release: Release, nome: str, pasta: Path, impressoes: tuple[str, ...],
                      log: Callable[[str], None] = print,
                      progresso: Callable[[int, int | None], None] | None = None) -> tuple[Path, str]:
    """Baixa `nome` da release para `pasta` só depois de conferir SHA256SUMS assinado e o SHA-256.

    `impressoes` vazio desliga a assinatura (só o SHA-256 é conferido)."""
    exigidos = [nome, "SHA256SUMS.txt"] + (["SHA256SUMS.txt.asc", "release-signing-key.asc"] if impressoes else [])
    for necessario in exigidos:
        if necessario not in release.arquivos:
            raise CraftErro(f"a release {release.versao} não tem {necessario}")
    with _cliente() as c, tempfile.TemporaryDirectory(prefix="solumia-sums-") as tmp:
        t = Path(tmp)
        sums = t / "SHA256SUMS.txt"
        _baixar(c, release.arquivos["SHA256SUMS.txt"], sums, _TAMANHO_MAX_TEXTO)
        if impressoes:
            sums_asc, chave = t / "SHA256SUMS.txt.asc", t / "chave.asc"
            _baixar(c, release.arquivos["SHA256SUMS.txt.asc"], sums_asc, _TAMANHO_MAX_TEXTO)
            _baixar(c, release.arquivos["release-signing-key.asc"], chave, _TAMANHO_MAX_TEXTO)
            impressao = verificacao.conferir_assinatura(chave.read_bytes(), sums_asc, sums, list(impressoes))
            log(f"Assinatura do SHA256SUMS válida (chave …{impressao[-16:]})")
        else:
            log("ATENÇÃO: assinatura desligada; só o SHA-256 será conferido")
        somas = verificacao.ler_sums(sums.read_text())

        parcial = pasta / (nome + ".parcial")
        log(f"Baixando {nome}")
        try:
            _baixar(c, release.arquivos[nome], parcial, _TAMANHO_MAX, progresso)
            soma = verificacao.conferir_arquivo(parcial, nome, somas)
        except BaseException:
            parcial.unlink(missing_ok=True)
            raise
    log(f"SHA-256 confere: {soma[:16]}…")
    final = pasta / nome
    os.replace(parcial, final)
    return final, soma


def _extrair_zip(arquivo: Path, destino: Path) -> None:
    raiz = destino.resolve()
    with zipfile.ZipFile(arquivo) as z:
        for info in z.infolist():
            alvo = (destino / info.filename).resolve()
            if not alvo.is_relative_to(raiz):
                raise CraftErro(f"arquivo zip tenta escrever fora da pasta: {info.filename}")
            if stat.S_ISLNK(info.external_attr >> 16):
                raise CraftErro("arquivo zip com link simbólico recusado")
        z.extractall(destino)  # noqa: S202 — cada entrada conferida acima


def _extrair_tar(arquivo: Path, destino: Path) -> None:
    with tarfile.open(arquivo) as t:
        t.extractall(destino, filter="data")  # noqa: S202 — filtro "data" bloqueia caminhos absolutos, '..' e links para fora


def _estado_arquivo() -> Path:
    return dir_estado() / "craft_apps.json"


def instalados() -> dict[str, dict[str, str]]:
    try:
        return json.loads(_estado_arquivo().read_text())
    except (OSError, ValueError):
        return {}


def _registrar(app_id: str, info: dict[str, str]) -> None:
    dados = instalados()
    dados[app_id] = info
    caminho = _estado_arquivo()
    caminho.parent.mkdir(parents=True, exist_ok=True)
    tmp = caminho.with_suffix(".tmp")
    tmp.write_text(json.dumps(dados, indent=2))
    os.replace(tmp, caminho)


def instalar(app_id: str, sistema: Sistema, versao: str = "ultima", formato: str = "auto",
             log: Callable[[str], None] = print,
             progresso: Callable[[int, int | None], None] | None = None) -> dict[str, str]:
    app = _app(app_id)
    log(f"Consultando releases de {app.nome} em {app.url_releases}")
    release = buscar_release(app_id, versao)
    nome = nome_arquivo(app_id, release.versao, sistema, formato)
    with tempfile.TemporaryDirectory(prefix=f"solumia-{app_id}-") as tmp:
        baixado, soma = baixar_verificado(release, nome, Path(tmp), app.impressoes if app.exigir_assinatura else (),
                                          log, progresso)
        destino = dir_apps(sistema) / app_id
        caminho = _instalar_arquivo(app, baixado, destino, sistema, log)

    info = {"versao": release.versao, "arquivo": nome, "sha256": soma, "caminho": str(caminho)}
    _registrar(app_id, info)
    log(f"{app.nome} {release.versao} instalado em {caminho}")
    return info


def _instalar_arquivo(app: AppCatalogo, baixado: Path, destino: Path, sistema: Sistema,
                      log: Callable[[str], None]) -> Path:
    nome = baixado.name
    novo = destino.with_name(destino.name + ".novo")
    shutil.rmtree(novo, ignore_errors=True)
    novo.mkdir(parents=True)
    if nome.endswith(".AppImage"):
        alvo = novo / f"{app.id}.AppImage"
        shutil.copy2(baixado, alvo)
        alvo.chmod(0o755)
        executavel = destino / alvo.name
    elif nome.endswith(".tar.gz"):
        _extrair_tar(baixado, novo)
        executavel = destino
    elif nome.endswith("-portable.zip"):
        _extrair_zip(baixado, novo)
        executavel = destino
    elif nome.endswith(".deb"):
        shutil.rmtree(novo)
        if shutil.which("pkexec") is None:
            raise CraftErro("instalar .deb exige pkexec; use o formato AppImage")
        log("Pedindo permissão de administrador ao sistema para instalar o .deb")
        subprocess.run(["pkexec", "apt-get", "install", "-y", str(baixado)], check=True, timeout=900)
        return Path("/usr/bin") / app.id
    elif nome.endswith(".msi"):
        shutil.rmtree(novo)
        log("Abrindo o instalador do Windows (pode pedir permissão de administrador)")
        subprocess.run(["msiexec", "/i", str(baixado), "/qb"], check=True, timeout=900)
        return Path(os.environ.get("ProgramFiles", "C:\\Program Files")) / app.nome
    else:
        raise CraftErro(f"formato não suportado: {nome}")

    # Troca atômica: a versão anterior só sai depois que a nova está completa.
    antigo = destino.with_name(destino.name + ".antigo")
    shutil.rmtree(antigo, ignore_errors=True)
    if destino.exists():
        destino.rename(antigo)
    novo.rename(destino)
    shutil.rmtree(antigo, ignore_errors=True)
    if not sistema.windows and executavel.suffix == ".AppImage":
        _atalho_linux(app, executavel)
    return executavel


def _atalho_linux(app: AppCatalogo, executavel: Path) -> None:
    pasta = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / "applications"
    pasta.mkdir(parents=True, exist_ok=True)
    (pasta / f"{nomes.PREFIXO}-{app.id}.desktop").write_text(
        "[Desktop Entry]\nType=Application\n"
        f"Name={app.nome}\nComment={app.descricao}\nExec=\"{executavel}\" %F\n"
        f"Categories=AudioVideo;Graphics;\nX-Solumia-App={app.id}\n"
    )


def remover(app_id: str, sistema: Sistema) -> None:
    _app(app_id)
    shutil.rmtree(dir_apps(sistema) / app_id, ignore_errors=True)
    atalho = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / "applications" / (
        f"{nomes.PREFIXO}-{app_id}.desktop"
    )
    atalho.unlink(missing_ok=True)
    dados = instalados()
    if dados.pop(app_id, None) is not None:
        _estado_arquivo().write_text(json.dumps(dados, indent=2))
