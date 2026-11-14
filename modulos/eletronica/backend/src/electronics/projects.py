"""Electronics projects stored one per file in `projetos/<id>.json` in the data folder. The
schematic lives in `folhas` ([{id, nome}]) and in the lists `componentes` (library symbol,
`ref`, `valor`, `encapsulamento`, position `x`/`y` in µm, `rot` 0/90/180/270 and `espelho`), `fios`
(`pontos` [[x, y], …]), `rotulos` (net name at `x`/`y`) and `textos`. Every item names its `folha`.
`versao` goes up on every save: whoever saves with an old version gets [Conflict] (several
devices)."""

import json
import os
import re
import threading
import uuid
from collections.abc import Callable
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from electronics.library import POR_ID

# Finds the symbol by id (base or imported); None = unknown.
SearchSymbol = Callable[[str], dict[str, Any] | None]

LISTS = ("componentes", "fios", "rotulos", "textos", "sondas")
FIELDS_EDITABLE = {"titulo", "pasta"}
ROTATIONS = (0, 90, 180, 270)
_ID = re.compile(r"^[0-9a-f]{32}$")


class NotFound(Exception):
    pass


class Invalid(Exception):
    pass


class Conflict(Exception):
    def __init__(self, current: dict[str, Any]) -> None:
        super().__init__("O projeto mudou em outro aparelho")
        self.atual = current


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


def _is_piece(symbol: SearchSymbol, id_: str) -> bool:
    s = symbol(id_)
    return s is None or s["tipo"] == "componente"


def _whole(v: Any) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def validate_schematic(e: dict[str, Any], symbol: SearchSymbol = POR_ID.get) -> None:
    folhas = e.get("folhas")
    if not isinstance(folhas, list) or not folhas:
        raise Invalid("O projeto precisa de ao menos uma folha")
    if not all(
        isinstance(f, dict) and f.get("id") and isinstance(f.get("nome"), str) for f in folhas
    ):
        raise Invalid("Folhas precisam de id e nome")
    ids_folhas = {f["id"] for f in folhas}
    for items in LISTS:
        itens = e.get(items, [])
        if not isinstance(itens, list):
            raise Invalid(f"{items} deve ser uma lista")
        for i in itens:
            if not isinstance(i, dict) or not i.get("id") or i.get("folha") not in ids_folhas:
                raise Invalid(f"Item de {items} sem id ou com folha desconhecida")
    for c in e.get("componentes", []):
        if not isinstance(c.get("simbolo"), str) or symbol(c["simbolo"]) is None:
            raise Invalid(f"Símbolo desconhecido: {c.get('simbolo')}")
        if not (_whole(c.get("x")) and _whole(c.get("y"))) or c.get("rot", 0) not in ROTATIONS:
            raise Invalid("Componente com posição ou rotação inválida")
    for f in e.get("fios", []):
        points = f.get("pontos")
        if not isinstance(points, list) or len(points) < 2:
            raise Invalid("Fio precisa de ao menos dois pontos")
        if not all(isinstance(p, list) and len(p) == 2 and all(map(_whole, p)) for p in points):
            raise Invalid("Pontos de fio devem ser [x, y] inteiros (µm)")
    for s in e.get("sondas", []):
        if s.get("tipo") not in ("v", "i") or not (_whole(s.get("x")) and _whole(s.get("y"))):
            raise Invalid("Sonda precisa de tipo v ou i e posição inteira (µm)")
        if s["tipo"] == "i" and not isinstance(s.get("ref"), str):
            raise Invalid("Sonda de corrente precisa da referência do componente")
    for r in e.get("rotulos", []):
        if not isinstance(r.get("nome"), str) or not r["nome"].strip():
            raise Invalid("Rótulo sem nome")


class Projects:
    def __init__(self, root: str | Path, symbol: SearchSymbol = POR_ID.get) -> None:
        self.symbol = symbol
        self.root = Path(root).expanduser() / "projetos"
        self.root.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()

    def _summary(self, p: dict[str, Any]) -> dict[str, Any]:
        return {
            **{k: v for k, v in p.items() if k not in LISTS},
            "total": sum(1 for c in p["componentes"] if _is_piece(self.symbol, c["simbolo"])),
        }

    def _path(self, id_: str) -> Path:
        if not _ID.match(id_):
            raise NotFound(id_)
        return self.root / f"{id_}.json"

    def _read(self, id_: str) -> dict[str, Any]:
        path = self._path(id_)
        if not path.exists():
            raise NotFound(id_)
        data: dict[str, Any] = json.loads(path.read_text("utf-8"))
        return data

    def _write(self, p: dict[str, Any]) -> None:
        path = self._path(p["id"])
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(p, ensure_ascii=False, separators=(",", ":")), "utf-8")
        os.replace(tmp, path)

    def list_all(self, pasta: str | None = None) -> list[dict[str, Any]]:
        with self._lock:
            projects = [self._summary(self._read(p.stem)) for p in self.root.glob("*.json")]
        if pasta is not None:
            projects = [p for p in projects if p["pasta"] == pasta]
        return sorted(projects, key=lambda p: p["atualizado"], reverse=True)

    def obter(self, id_: str) -> dict[str, Any]:
        with self._lock:
            return self._read(id_)

    def criar(self, fields: dict[str, Any]) -> dict[str, Any]:
        schematic = {
            "folhas": fields.get("folhas") or [{"id": "f1", "nome": "Folha 1"}],
            **{items: fields.get(items, []) for items in LISTS},
        }
        validate_schematic(schematic, self.symbol)
        now = _now()
        p = {
            "id": uuid.uuid4().hex,
            "titulo": fields.get("titulo") or "Projeto sem título",
            "pasta": fields.get("pasta", ""),
            "criado": now,
            "atualizado": now,
            "versao": 1,
            **schematic,
        }
        with self._lock:
            self._write(p)
        return p

    def edit(self, id_: str, fields: dict[str, Any]) -> dict[str, Any]:
        fields = {k: v for k, v in fields.items() if k in FIELDS_EDITABLE and v is not None}
        with self._lock:
            p = self._read(id_)
            p.update(fields, atualizado=_now())
            self._write(p)
        return self._summary(p)

    def salvar(self, id_: str, schematic: dict[str, Any], versao: int) -> dict[str, Any]:
        """Replaces sheets and items if the version is the current one; returns the summary with
        the new version."""
        validate_schematic(schematic, self.symbol)
        with self._lock:
            p = self._read(id_)
            if versao != p["versao"]:
                raise Conflict(p)
            p.update(
                {k: schematic.get(k, []) for k in ("folhas", *LISTS)},
                versao=p["versao"] + 1,
                atualizado=_now(),
            )
            self._write(p)
        return self._summary(p)

    def duplicate(self, id_: str) -> dict[str, Any]:
        p = self.obter(id_)
        return self.criar({**p, "titulo": f"{p['titulo']} (cópia)"})

    def excluir(self, id_: str) -> None:
        with self._lock:
            path = self._path(id_)
            if not path.exists():
                raise NotFound(id_)
            path.unlink()
