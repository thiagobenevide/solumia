"""Validação das pastas de mídia (imagens, vídeos, áudio, em produção, produzidos).

Regras, iguais no Linux e no Windows:
- caminho absoluto (aceita `~`), sem `..`;
- fora de pastas do sistema;
- as cinco pastas são distintas e nenhuma fica dentro de outra (evita a esteira apagar ou
  reprocessar o próprio acervo);
- a pasta existe ou pode ser criada, e o configurador consegue gravar nela.
"""

from __future__ import annotations

import os
import tempfile
from dataclasses import dataclass, field
from pathlib import Path, PurePath, PurePosixPath, PureWindowsPath

from .manifesto import Pastas

ROTULOS = {
    "imagens": "Imagens",
    "videos": "Vídeos (acervo)",
    "audio": "Áudio",
    "producao": "Vídeos para produção",
    "produzidos": "Vídeos produzidos",
}

_SISTEMA_LINUX = ("/", "/bin", "/boot", "/dev", "/etc", "/lib", "/lib64", "/proc", "/root", "/run",
                  "/sbin", "/sys", "/usr", "/var")
_SISTEMA_WINDOWS = ("c:\\", "c:\\windows", "c:\\program files", "c:\\program files (x86)",
                    "c:\\programdata")


@dataclass
class Resultado:
    ok: bool = True
    erros: dict[str, list[str]] = field(default_factory=dict)
    avisos: dict[str, list[str]] = field(default_factory=dict)
    resolvidas: dict[str, str] = field(default_factory=dict)

    def erro(self, chave: str, msg: str) -> None:
        self.ok = False
        self.erros.setdefault(chave, []).append(msg)


def _puro(caminho: str, windows: bool) -> PurePath:
    return PureWindowsPath(caminho) if windows else PurePosixPath(caminho)


def _expandir(caminho: str, windows: bool, casa: str | None) -> str:
    if caminho.startswith("~"):
        casa = casa or str(Path.home())
        return casa + caminho[1:]
    return caminho


def _de_sistema(p: PurePath, windows: bool) -> bool:
    if windows:
        partes = [x.lower().rstrip("\\") for x in p.parts]
        if len(partes) == 1:  # raiz de qualquer unidade (C:\, D:\)
            return True
        alvo = "\\".join(partes[:2]) if partes[0].endswith(":") else ""
        return any(alvo == x.rstrip("\\") for x in _SISTEMA_WINDOWS[1:]) and partes[0] == "c:"
    partes = list(p.parts)
    if len(partes) == 1:  # "/"
        return True
    topo = "/" + partes[1]
    if topo == "/var":
        return not (len(partes) > 2 and partes[2] == "lib")
    return topo in _SISTEMA_LINUX


def validar(pastas: Pastas, *, windows: bool, local: bool = True, casa: str | None = None) -> Resultado:
    """`local=False` valida só a forma (nó remoto): existência e escrita são checadas na aplicação."""
    r = Resultado()
    puros: dict[str, PurePath] = {}
    for chave in ROTULOS:
        bruto = getattr(pastas, chave).strip()
        if not bruto:
            r.erro(chave, "pasta não definida")
            continue
        if "\x00" in bruto:
            r.erro(chave, "caractere inválido")
            continue
        expandido = _expandir(bruto, windows, casa)
        p = _puro(expandido, windows)
        if not p.is_absolute():
            exemplo = "D:\\Midia\\videos" if windows else "/home/voce/videos"
            r.erro(chave, f"use um caminho absoluto (ex.: {exemplo})")
            continue
        if ".." in p.parts:
            r.erro(chave, "'..' não é permitido")
            continue
        if _de_sistema(p, windows):
            r.erro(chave, "pasta do sistema operacional não é permitida")
            continue
        puros[chave] = p
        r.resolvidas[chave] = str(p)

    chaves = list(puros)
    for i, a in enumerate(chaves):
        for b in chaves[i + 1 :]:
            pa, pb = puros[a], puros[b]
            ia, ib = (str(pa).lower(), str(pb).lower()) if windows else (str(pa), str(pb))
            if ia == ib:
                r.erro(b, f"igual à pasta de {ROTULOS[a]}")
            elif _dentro(pb, pa, windows):
                r.erro(b, f"está dentro da pasta de {ROTULOS[a]}")
            elif _dentro(pa, pb, windows):
                r.erro(a, f"está dentro da pasta de {ROTULOS[b]}")

    if local and r.ok:
        for chave, p in puros.items():
            _checar_escrita(Path(str(p)), chave, r)
    return r


def _dentro(filho: PurePath, pai: PurePath, windows: bool) -> bool:
    f = [x.lower() for x in filho.parts] if windows else list(filho.parts)
    p = [x.lower() for x in pai.parts] if windows else list(pai.parts)
    return len(f) > len(p) and f[: len(p)] == p


def _checar_escrita(p: Path, chave: str, r: Resultado) -> None:
    alvo = p
    while not alvo.exists():
        if alvo.parent == alvo:
            r.erro(chave, "nenhuma parte do caminho existe")
            return
        alvo = alvo.parent
    if not alvo.is_dir():
        r.erro(chave, f"{alvo} existe e não é pasta")
        return
    if alvo != p:
        r.avisos.setdefault(chave, []).append("será criada ao aplicar")
    if not os.access(alvo, os.W_OK):
        r.erro(chave, f"sem permissão de escrita em {alvo}")
        return
    try:
        with tempfile.NamedTemporaryFile(dir=alvo, prefix=".solumia-teste-"):
            pass
    except OSError as e:
        r.erro(chave, f"não consegui gravar em {alvo}: {e.strerror}")


def criar(pastas: Pastas, casa: str | None = None) -> list[str]:
    """Cria as pastas locais que faltam; devolve as criadas."""
    criadas = []
    for chave in ROTULOS:
        p = Path(_expandir(getattr(pastas, chave), os.name == "nt", casa))
        if not p.exists():
            p.mkdir(parents=True, exist_ok=True)
            criadas.append(str(p))
    return criadas
