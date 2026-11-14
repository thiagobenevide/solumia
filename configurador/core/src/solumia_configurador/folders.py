"""Validation of the media folders (images, videos, audio, in production, produced).

Rules, the same on Linux and Windows:
- absolute path (`~` accepted), no `..`;
- outside system folders;
- the five folders are distinct and none is inside another (keeps the pipeline from deleting or
  reprocessing its own library);
- the folder exists or can be created, and the configurator can write to it.
"""

from __future__ import annotations

import os
import tempfile
from dataclasses import dataclass, field
from pathlib import Path, PurePath, PurePosixPath, PureWindowsPath

from .manifest import Folders

LABELS = {
    "imagens": "Imagens",
    "videos": "Vídeos (acervo)",
    "audio": "Áudio",
    "producao": "Vídeos para produção",
    "produzidos": "Vídeos produzidos",
}

_LINUX_SYSTEM_DIRS = ("/", "/bin", "/boot", "/dev", "/etc", "/lib", "/lib64", "/proc", "/root", "/run",
                  "/sbin", "/sys", "/usr", "/var")
_WINDOWS_SYSTEM_DIRS = ("c:\\", "c:\\windows", "c:\\program files", "c:\\program files (x86)",
                    "c:\\programdata")


@dataclass
class Result:
    ok: bool = True
    erros: dict[str, list[str]] = field(default_factory=dict)
    avisos: dict[str, list[str]] = field(default_factory=dict)
    resolvidas: dict[str, str] = field(default_factory=dict)

    def error(self, key: str, msg: str) -> None:
        self.ok = False
        self.erros.setdefault(key, []).append(msg)


def _puro(path: str, windows: bool) -> PurePath:
    return PureWindowsPath(path) if windows else PurePosixPath(path)


def _expandir(path: str, windows: bool, matches: str | None) -> str:
    if path.startswith("~"):
        matches = matches or str(Path.home())
        return matches + path[1:]
    return path


def _is_system_path(p: PurePath, windows: bool) -> bool:
    if windows:
        parts = [x.lower().rstrip("\\") for x in p.parts]
        if len(parts) == 1:  # root of any drive (C:\, D:\)
            return True
        target = "\\".join(parts[:2]) if parts[0].endswith(":") else ""
        return any(target == x.rstrip("\\") for x in _WINDOWS_SYSTEM_DIRS[1:]) and parts[0] == "c:"
    parts = list(p.parts)
    if len(parts) == 1:  # "/"
        return True
    top = "/" + parts[1]
    if top == "/var":
        return not (len(parts) > 2 and parts[2] == "lib")
    return top in _LINUX_SYSTEM_DIRS


def validate(folders: Folders, *, windows: bool, local: bool = True, matches: str | None = None) -> Result:
    """`local=False` only validates the form (remote node): existence and write access are checked when applying."""
    r = Result()
    plain: dict[str, PurePath] = {}
    for key in LABELS:
        raw = getattr(folders, key).strip()
        if not raw:
            r.error(key, "pasta não definida")
            continue
        if "\x00" in raw:
            r.error(key, "caractere inválido")
            continue
        expanded = _expandir(raw, windows, matches)
        p = _puro(expanded, windows)
        if not p.is_absolute():
            example = "D:\\Midia\\videos" if windows else "/home/voce/videos"
            r.error(key, f"use um caminho absoluto (ex.: {example})")
            continue
        if ".." in p.parts:
            r.error(key, "'..' não é permitido")
            continue
        if _is_system_path(p, windows):
            r.error(key, "pasta do sistema operacional não é permitida")
            continue
        plain[key] = p
        r.resolvidas[key] = str(p)

    keys = list(plain)
    for i, a in enumerate(keys):
        for b in keys[i + 1 :]:
            pa, pb = plain[a], plain[b]
            ia, ib = (str(pa).lower(), str(pb).lower()) if windows else (str(pa), str(pb))
            if ia == ib:
                r.error(b, f"igual à pasta de {LABELS[a]}")
            elif _is_inside(pb, pa, windows):
                r.error(b, f"está dentro da pasta de {LABELS[a]}")
            elif _is_inside(pa, pb, windows):
                r.error(a, f"está dentro da pasta de {LABELS[b]}")

    if local and r.ok:
        for key, p in plain.items():
            _check_writable(Path(str(p)), key, r)
    return r


def _is_inside(child: PurePath, parent: PurePath, windows: bool) -> bool:
    f = [x.lower() for x in child.parts] if windows else list(child.parts)
    p = [x.lower() for x in parent.parts] if windows else list(parent.parts)
    return len(f) > len(p) and f[: len(p)] == p


def _check_writable(p: Path, key: str, r: Result) -> None:
    target = p
    while not target.exists():
        if target.parent == target:
            r.error(key, "nenhuma parte do caminho existe")
            return
        target = target.parent
    if not target.is_dir():
        r.error(key, f"{target} existe e não é pasta")
        return
    if target != p:
        r.avisos.setdefault(key, []).append("será criada ao aplicar")
    if not os.access(target, os.W_OK):
        r.error(key, f"sem permissão de escrita em {target}")
        return
    try:
        with tempfile.NamedTemporaryFile(dir=target, prefix=".solumia-teste-"):
            pass
    except OSError as e:
        r.error(key, f"não consegui gravar em {target}: {e.strerror}")


def create(folders: Folders, matches: str | None = None) -> list[str]:
    """Creates the missing local folders; returns the ones created."""
    created = []
    for key in LABELS:
        p = Path(_expandir(getattr(folders, key), os.name == "nt", matches))
        if not p.exists():
            p.mkdir(parents=True, exist_ok=True)
            created.append(str(p))
    return created
