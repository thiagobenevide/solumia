"""Brings the channel notes from the Obsidian vault into the platform vault, in the notes format.

Copies `<vault>/Notas/Empreendimento/YouTube/**.md` to the same path inside the platform vault,
keeping body, links and properties. Only the frontmatter changes: `criado`/`atualizado` become
`criada`/`atualizada` (reserved vault fields), dates become ISO text and repeated ids get a
suffix (the vault indexes by id).

    python -m youtube.importer [--vault ~/Documents/github/obsidian] [--destino ~/agent-data/notas]
"""

import argparse
import os
from datetime import date, datetime
from pathlib import Path
from typing import Any

import yaml

from youtube.schema import ROOT

ORDER = ("id", "tipo", "tags", "aliases")
RENAME = {"criado": "criada", "atualizado": "atualizada"}


def _text(v: Any) -> Any:
    if isinstance(v, datetime | date):
        return v.isoformat()
    if isinstance(v, dict):
        return {str(k): _text(x) for k, x in v.items()}
    if isinstance(v, list):
        return [_text(x) for x in v]
    return v


def _separate(text: str) -> tuple[dict[str, Any] | None, str]:
    if not text.startswith("---\n"):
        return None, text
    end = text.find("\n---", 3)
    if end == -1:
        return None, text
    try:
        meta = yaml.safe_load(text[4:end])
    except yaml.YAMLError:
        return None, text
    return (
        (_text(meta), text[end + 4 :].lstrip("\n")) if isinstance(meta, dict) else (None, text)
    )


def normalize(text: str, ids: set[str]) -> str:
    """Frontmatter in the vault format; records the id used in `ids`."""
    meta, body = _separate(text)
    if meta is None:
        return text
    for old, new in RENAME.items():
        if old in meta:
            value = meta.pop(old)
            meta.setdefault(new, str(value))
    if meta.get("id") is not None:
        base = str(meta["id"])
        id_, n = base, 2
        while id_ in ids:
            id_, n = f"{base}-{n}", n + 1
        meta["id"] = id_
        ids.add(id_)
    end = {k: meta.pop(k) for k in ("criada", "atualizada") if k in meta}
    meta = {k: meta.pop(k) for k in ORDER if k in meta} | meta | end
    head = yaml.safe_dump(meta, allow_unicode=True, sort_keys=False, default_flow_style=None)
    return f"---\n{head}---\n\n{body.rstrip()}\n"


def run_import(vault: Path, destination: Path, replace: bool = False) -> dict[str, Any]:
    origin = Path(vault).expanduser() / ROOT
    if not origin.is_dir():
        raise ValueError(f"Channels folder not found in the vault: {origin}")
    destination = Path(destination).expanduser()
    ids: set[str] = set()
    imported = skipped = 0
    for file in sorted(origin.rglob("*.md")):
        rel = file.relative_to(origin)
        if any(p.startswith(".") for p in rel.parts):
            continue
        target = destination / ROOT / rel
        if target.exists() and not replace:
            meta, _ = _separate(target.read_text("utf-8"))
            if meta and meta.get("id") is not None:
                ids.add(str(meta["id"]))
            skipped += 1
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(normalize(file.read_text("utf-8"), ids), "utf-8")
        imported += 1
    return {"importadas": imported, "puladas": skipped, "origem": str(origin)}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--vault", default="~/Documents/github/obsidian")
    ap.add_argument("--destino", default=os.environ.get("GATEWAY_NOTAS_DIR", "~/agent-data/notas"))
    ap.add_argument("--substituir", action="store_true", help="rewrites existing notes")
    a = ap.parse_args()
    print(run_import(Path(a.vault), Path(a.destino), a.substituir))


if __name__ == "__main__":
    main()
