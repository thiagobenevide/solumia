"""Traz as notas dos canais do vault do Obsidian para o cofre da plataforma, no padrão das notas.

Copia `<vault>/Notas/Empreendimento/YouTube/**.md` para o mesmo caminho dentro do cofre,
mantendo corpo, links e propriedades. Só o frontmatter muda: `criado`/`atualizado` viram
`criada`/`atualizada` (campos reservados do cofre), datas viram texto ISO e ids repetidos ganham
sufixo (o cofre indexa por id).

    python -m youtube.importar [--vault ~/Documents/github/obsidian] [--destino ~/agent-data/notas]
"""

import argparse
import os
from datetime import date, datetime
from pathlib import Path
from typing import Any

import yaml

from youtube.esquema import RAIZ

ORDEM = ("id", "tipo", "tags", "aliases")
RENOMEAR = {"criado": "criada", "atualizado": "atualizada"}


def _texto(v: Any) -> Any:
    if isinstance(v, datetime | date):
        return v.isoformat()
    if isinstance(v, dict):
        return {str(k): _texto(x) for k, x in v.items()}
    if isinstance(v, list):
        return [_texto(x) for x in v]
    return v


def _separar(texto: str) -> tuple[dict[str, Any] | None, str]:
    if not texto.startswith("---\n"):
        return None, texto
    fim = texto.find("\n---", 3)
    if fim == -1:
        return None, texto
    try:
        meta = yaml.safe_load(texto[4:fim])
    except yaml.YAMLError:
        return None, texto
    return (
        (_texto(meta), texto[fim + 4 :].lstrip("\n")) if isinstance(meta, dict) else (None, texto)
    )


def normalizar(texto: str, ids: set[str]) -> str:
    """Frontmatter no padrão do cofre; registra o id usado em `ids`."""
    meta, corpo = _separar(texto)
    if meta is None:
        return texto
    for antigo, novo in RENOMEAR.items():
        if antigo in meta:
            valor = meta.pop(antigo)
            meta.setdefault(novo, str(valor))
    if meta.get("id") is not None:
        base = str(meta["id"])
        id_, n = base, 2
        while id_ in ids:
            id_, n = f"{base}-{n}", n + 1
        meta["id"] = id_
        ids.add(id_)
    fim = {k: meta.pop(k) for k in ("criada", "atualizada") if k in meta}
    meta = {k: meta.pop(k) for k in ORDEM if k in meta} | meta | fim
    cabeca = yaml.safe_dump(meta, allow_unicode=True, sort_keys=False, default_flow_style=None)
    return f"---\n{cabeca}---\n\n{corpo.rstrip()}\n"


def importar(vault: Path, destino: Path, substituir: bool = False) -> dict[str, Any]:
    origem = Path(vault).expanduser() / RAIZ
    if not origem.is_dir():
        raise ValueError(f"Pasta dos canais não encontrada no vault: {origem}")
    destino = Path(destino).expanduser()
    ids: set[str] = set()
    importadas = puladas = 0
    for arq in sorted(origem.rglob("*.md")):
        rel = arq.relative_to(origem)
        if any(p.startswith(".") for p in rel.parts):
            continue
        alvo = destino / RAIZ / rel
        if alvo.exists() and not substituir:
            meta, _ = _separar(alvo.read_text("utf-8"))
            if meta and meta.get("id") is not None:
                ids.add(str(meta["id"]))
            puladas += 1
            continue
        alvo.parent.mkdir(parents=True, exist_ok=True)
        alvo.write_text(normalizar(arq.read_text("utf-8"), ids), "utf-8")
        importadas += 1
    return {"importadas": importadas, "puladas": puladas, "origem": str(origem)}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--vault", default="~/Documents/github/obsidian")
    ap.add_argument("--destino", default=os.environ.get("GATEWAY_NOTAS_DIR", "~/agent-data/notas"))
    ap.add_argument("--substituir", action="store_true", help="regrava as notas que já existem")
    a = ap.parse_args()
    print(importar(Path(a.vault), Path(a.destino), a.substituir))


if __name__ == "__main__":
    main()
