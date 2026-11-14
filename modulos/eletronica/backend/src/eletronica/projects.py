"""Projetos de eletrônica guardados um por arquivo em `projetos/<id>.json` na pasta de dados. O
esquemático fica em `folhas` ([{id, nome}]) e nas listas `componentes` (símbolo da biblioteca,
`ref`, `valor`, `encapsulamento`, posição `x`/`y` em µm, `rot` 0/90/180/270 e `espelho`), `fios`
(`pontos` [[x, y], …]), `rotulos` (nome da rede em `x`/`y`) e `textos`. Todo item diz a sua `folha`.
`versao` sobe a cada gravação: quem grava com uma versão velha recebe [Conflito] (vários
aparelhos)."""

import json
import os
import re
import threading
import uuid
from collections.abc import Callable
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from eletronica.library import POR_ID

# Acha o símbolo pelo id (base ou importado); None = desconhecido.
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
    def __init__(self, atual: dict[str, Any]) -> None:
        super().__init__("O projeto mudou em outro aparelho")
        self.atual = atual


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
        self.simbolo = symbol
        self.raiz = Path(root).expanduser() / "projetos"
        self.raiz.mkdir(parents=True, exist_ok=True)
        self._trava = threading.RLock()

    def _resumo(self, p: dict[str, Any]) -> dict[str, Any]:
        return {
            **{k: v for k, v in p.items() if k not in LISTS},
            "total": sum(1 for c in p["componentes"] if _is_piece(self.simbolo, c["simbolo"])),
        }

    def _caminho(self, id_: str) -> Path:
        if not _ID.match(id_):
            raise NotFound(id_)
        return self.raiz / f"{id_}.json"

    def _ler(self, id_: str) -> dict[str, Any]:
        path = self._caminho(id_)
        if not path.exists():
            raise NotFound(id_)
        data: dict[str, Any] = json.loads(path.read_text("utf-8"))
        return data

    def _gravar(self, p: dict[str, Any]) -> None:
        path = self._caminho(p["id"])
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(p, ensure_ascii=False, separators=(",", ":")), "utf-8")
        os.replace(tmp, path)

    def listar(self, pasta: str | None = None) -> list[dict[str, Any]]:
        with self._trava:
            projects = [self._resumo(self._ler(p.stem)) for p in self.raiz.glob("*.json")]
        if pasta is not None:
            projects = [p for p in projects if p["pasta"] == pasta]
        return sorted(projects, key=lambda p: p["atualizado"], reverse=True)

    def obter(self, id_: str) -> dict[str, Any]:
        with self._trava:
            return self._ler(id_)

    def criar(self, fields: dict[str, Any]) -> dict[str, Any]:
        schematic = {
            "folhas": fields.get("folhas") or [{"id": "f1", "nome": "Folha 1"}],
            **{items: fields.get(items, []) for items in LISTS},
        }
        validate_schematic(schematic, self.simbolo)
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
        with self._trava:
            self._gravar(p)
        return p

    def editar(self, id_: str, fields: dict[str, Any]) -> dict[str, Any]:
        fields = {k: v for k, v in fields.items() if k in FIELDS_EDITABLE and v is not None}
        with self._trava:
            p = self._ler(id_)
            p.update(fields, atualizado=_now())
            self._gravar(p)
        return self._resumo(p)

    def salvar(self, id_: str, schematic: dict[str, Any], versao: int) -> dict[str, Any]:
        """Troca folhas e itens se [versao] for a atual; devolve o resumo com a versão nova."""
        validate_schematic(schematic, self.simbolo)
        with self._trava:
            p = self._ler(id_)
            if versao != p["versao"]:
                raise Conflict(p)
            p.update(
                {k: schematic.get(k, []) for k in ("folhas", *LISTS)},
                versao=p["versao"] + 1,
                atualizado=_now(),
            )
            self._gravar(p)
        return self._resumo(p)

    def duplicar(self, id_: str) -> dict[str, Any]:
        p = self.obter(id_)
        return self.criar({**p, "titulo": f"{p['titulo']} (cópia)"})

    def excluir(self, id_: str) -> None:
        with self._trava:
            path = self._caminho(id_)
            if not path.exists():
                raise NotFound(id_)
            path.unlink()
