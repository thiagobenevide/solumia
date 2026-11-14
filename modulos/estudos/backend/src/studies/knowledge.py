"""Knowledge tracks (Technology → Software Architect): the catalog comes from
`technology_catalog.py`; what belongs to the person lives in `conhecimento.json`:
`livros` ({id: {tenho, leitura_id}}), `lidas` ({"etapa#i": date}), `praticas` ({etapa: date}) and
`notas` ({etapa: nota_id}). Each book can be linked to a reading in the Readings tab (with the PDF
from Files), where it is read and highlighted; the track only says what to read and in which
order."""

import json
import os
import threading
import unicodedata
from collections.abc import Callable
from datetime import date
from pathlib import Path
from typing import Any

from studies.technology_catalog import BOOKS, FRONTS, TRACKS

_BOOKS = {x["id"]: x for x in BOOKS}
_TRACKS = {t["id"]: t for t in TRACKS}


class ItemNonexistent(KeyError):
    pass


def _normal(text: str) -> str:
    t = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode().lower()
    return " ".join(t.replace(":", " ").split())


class Knowledge:
    def __init__(
        self,
        file: Path,
        lock: threading.RLock,
        readings: Callable[[], list[dict[str, Any]]],
        create_reading: Callable[[dict[str, Any]], dict[str, Any]],
    ) -> None:
        self.arquivo = file
        self.lock = lock
        self._readings = readings
        self._create_reading = create_reading

    def _read(self) -> dict[str, Any]:
        base: dict[str, Any] = {"livros": {}, "lidas": {}, "praticas": {}, "notas": {}}
        if self.arquivo.exists():
            base.update(json.loads(self.arquivo.read_text("utf-8")))
        return base

    def _write(self, estado: dict[str, Any]) -> None:
        tmp = self.arquivo.with_suffix(".tmp")
        tmp.write_text(json.dumps(estado, ensure_ascii=False, indent=1), "utf-8")
        os.replace(tmp, self.arquivo)

    # --- estante ---

    def _reading_of_book(
        self, book: dict[str, Any], my: dict[str, Any], readings: list[dict[str, Any]]
    ) -> dict[str, Any] | None:
        """The linked reading (by id) or, if there is none, the one with the same title in the
        Readings tab."""
        names = {_normal(book["titulo"]), _normal(book["original"])}
        achada = next((x for x in readings if x["id"] == my.get("leitura_id")), None)
        achada = achada or next((x for x in readings if _normal(x["titulo"]) in names), None)
        if achada is None:
            return None
        fields = ("id", "status", "arquivo_id", "nota_id", "pagina_atual", "paginas")
        return {k: achada.get(k) for k in fields}

    def _book(
        self, id_: str, estado: dict[str, Any], readings: list[dict[str, Any]]
    ) -> dict[str, Any]:
        book = _BOOKS[id_]
        my = estado["livros"].get(id_, {})
        return {
            **book,
            "tenho": my.get("tenho", book["tenho"]),
            "leitura": self._reading_of_book(book, my, readings),
        }

    def livros(self) -> list[dict[str, Any]]:
        state, readings = self._read(), self._readings()
        uses: dict[str, int] = {}
        for t in TRACKS:
            for e in t["etapas"]:
                for ind in e["leituras"]:
                    uses[ind["livro"]] = uses.get(ind["livro"], 0) + 1
        return [{**self._book(x["id"], state, readings), "indicacoes": uses.get(x["id"], 0)}
                for x in BOOKS]

    def edit_book(self, id_: str, have: bool) -> dict[str, Any]:
        if id_ not in _BOOKS:
            raise ItemNonexistent(id_)
        with self.lock:
            state = self._read()
            state["livros"].setdefault(id_, {})["tenho"] = have
            self._write(state)
            return self._book(id_, state, self._readings())

    def link_reading(self, id_: str) -> dict[str, Any]:
        """Links the book to a reading in the Readings tab (creates one if missing) to read and
        highlight there."""
        if id_ not in _BOOKS:
            raise ItemNonexistent(id_)
        with self.lock:
            state = self._read()
            book = _BOOKS[id_]
            reading = self._reading_of_book(book, state["livros"].get(id_, {}), self._readings())
            if reading is None:
                reading = self._create_reading({
                    "titulo": book["titulo"],
                    "autor": book["autor"],
                    "area": "Tecnologia",
                    "url": book.get("url", ""),
                    "tags": ["trilha", "arquitetura"],
                })
            my = state["livros"].setdefault(id_, {})
            my["leitura_id"] = reading["id"]
            my["tenho"] = True
            self._write(state)
            return self._book(id_, state, self._readings())

    # --- tracks ---

    def _stage(
        self, e: dict[str, Any], estado: dict[str, Any], readings: list[dict[str, Any]]
    ) -> dict[str, Any]:
        indicacoes = []
        for i, ind in enumerate(e["leituras"]):
            key = f"{e['id']}#{i}"
            indicacoes.append({
                **ind,
                "chave": key,
                "indice": i,
                "feita": estado["lidas"].get(key),
                "livro": self._book(ind["livro"], estado, readings),
            })
        practice = estado["praticas"].get(e["id"])
        done = sum(bool(x["feita"]) for x in indicacoes) + bool(practice)
        total = len(indicacoes) + 1
        return {
            **e,
            "leituras": indicacoes,
            "pratica_feita": practice,
            "nota_id": estado["notas"].get(e["id"]),
            "progresso": round(done / total, 3),
            "concluida": done == total,
        }

    @staticmethod
    def _proxima(stages: list[dict[str, Any]]) -> dict[str, Any] | None:
        """Dynamic reading: the first open step; in it, the first unread chapter of a book the
        person
        owns (otherwise the first unread one, to get); with everything read, the practice."""
        for e in stages:
            if e["concluida"]:
                continue
            opened = [x for x in e["leituras"] if not x["feita"]]
            in_estante = [x for x in opened if x["livro"]["tenho"]]
            base = {"etapa_id": e["id"], "etapa": e["titulo"], "fase": e["fase"]}
            if in_estante:
                return {**base, "tipo": "leitura", "indicacao": in_estante[0]}
            if opened:
                return {**base, "tipo": "conseguir", "indicacao": opened[0]}
            return {**base, "tipo": "pratica", "pratica": e["pratica"]}
        return None

    def _summary(self, stages: list[dict[str, Any]]) -> dict[str, Any]:
        return {
            "total_etapas": len(stages),
            "etapas_concluidas": sum(e["concluida"] for e in stages),
            "progresso": round(sum(e["progresso"] for e in stages) / len(stages), 3)
            if stages
            else 0,
        }

    def list_tracks(self) -> list[dict[str, Any]]:
        state, readings = self._read(), self._readings()
        items = []
        for t in TRACKS:
            stages = [self._stage(e, state, readings) for e in t["etapas"]]
            items.append({
                **{k: v for k, v in t.items() if k != "etapas"},
                **self._summary(stages),
                "proxima": self._proxima(stages),
            })
        return items

    def trilha(self, id_: str, frente: str | None = None) -> dict[str, Any]:
        t = _TRACKS.get(id_)
        if t is None:
            raise ItemNonexistent(id_)
        state, readings = self._read(), self._readings()
        stages = [self._stage(e, state, readings) for e in t["etapas"]
                  if frente is None or frente in e["frentes"]]
        presentes = {f for e in t["etapas"] for f in e["frentes"]}
        return {
            **{k: v for k, v in t.items() if k != "etapas"},
            "frentes": [f for f in FRONTS if f in presentes],
            "frente": frente,
            "etapas": stages,
            **self._summary(stages),
            "proxima": self._proxima(stages),
        }

    def marcar(self, track_id: str, stage_id: str, dados: dict[str, Any]) -> dict[str, Any]:
        """`leitura` (index) + `feita`, `pratica` (bool) and/or `nota_id`; returns the step."""
        t = _TRACKS.get(track_id)
        stage = next((e for e in t["etapas"] if e["id"] == stage_id), None) if t else None
        if stage is None:
            raise ItemNonexistent(stage_id)
        today = date.today().isoformat()
        with self.lock:
            state = self._read()
            if dados.get("leitura") is not None:
                i = int(dados["leitura"])
                if not 0 <= i < len(stage["leituras"]):
                    raise ItemNonexistent(f"{stage_id}#{i}")
                key = f"{stage_id}#{i}"
                if dados.get("feita", True):
                    state["lidas"][key] = today
                else:
                    state["lidas"].pop(key, None)
            if dados.get("pratica") is not None:
                if dados["pratica"]:
                    state["praticas"][stage_id] = today
                else:
                    state["praticas"].pop(stage_id, None)
            if dados.get("nota_id"):
                state["notas"][stage_id] = dados["nota_id"]
            self._write(state)
            return self._stage(stage, state, self._readings())
