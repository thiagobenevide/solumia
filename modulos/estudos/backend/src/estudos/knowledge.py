"""Trilhas de conhecimento (Tecnologia → Arquiteto de Software): o catálogo vem de
`catalogo_tecnologia.py`; o que é da pessoa fica em `conhecimento.json`:
`livros` ({id: {tenho, leitura_id}}), `lidas` ({"etapa#i": data}), `praticas` ({etapa: data}) e
`notas` ({etapa: nota_id}). Cada livro pode ser ligado a uma leitura da aba Leituras (com o PDF dos
Arquivos), onde se lê e grifa; a trilha só diz o que ler e em que ordem."""

import json
import os
import threading
import unicodedata
from collections.abc import Callable
from datetime import date
from pathlib import Path
from typing import Any

from estudos.technology_catalog import FRONTS, BOOKS, TRACKS

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
        arquivo: Path,
        lock: threading.RLock,
        readings: Callable[[], list[dict[str, Any]]],
        create_reading: Callable[[dict[str, Any]], dict[str, Any]],
    ) -> None:
        self.arquivo = arquivo
        self.trava = lock
        self._leituras = readings
        self._criar_leitura = create_reading

    def _ler(self) -> dict[str, Any]:
        base: dict[str, Any] = {"livros": {}, "lidas": {}, "praticas": {}, "notas": {}}
        if self.arquivo.exists():
            base.update(json.loads(self.arquivo.read_text("utf-8")))
        return base

    def _gravar(self, estado: dict[str, Any]) -> None:
        tmp = self.arquivo.with_suffix(".tmp")
        tmp.write_text(json.dumps(estado, ensure_ascii=False, indent=1), "utf-8")
        os.replace(tmp, self.arquivo)

    # --- estante ---

    def _leitura_do_livro(
        self, book: dict[str, Any], my: dict[str, Any], readings: list[dict[str, Any]]
    ) -> dict[str, Any] | None:
        """A leitura ligada (por id) ou, se não houver, a de mesmo título na aba Leituras."""
        names = {_normal(book["titulo"]), _normal(book["original"])}
        achada = next((x for x in readings if x["id"] == my.get("leitura_id")), None)
        achada = achada or next((x for x in readings if _normal(x["titulo"]) in names), None)
        if achada is None:
            return None
        fields = ("id", "status", "arquivo_id", "nota_id", "pagina_atual", "paginas")
        return {k: achada.get(k) for k in fields}

    def _livro(
        self, id_: str, estado: dict[str, Any], readings: list[dict[str, Any]]
    ) -> dict[str, Any]:
        book = _BOOKS[id_]
        my = estado["livros"].get(id_, {})
        return {
            **book,
            "tenho": my.get("tenho", book["tenho"]),
            "leitura": self._leitura_do_livro(book, my, readings),
        }

    def livros(self) -> list[dict[str, Any]]:
        state, readings = self._ler(), self._leituras()
        uses: dict[str, int] = {}
        for t in TRACKS:
            for e in t["etapas"]:
                for ind in e["leituras"]:
                    uses[ind["livro"]] = uses.get(ind["livro"], 0) + 1
        return [{**self._livro(x["id"], state, readings), "indicacoes": uses.get(x["id"], 0)}
                for x in BOOKS]

    def editar_livro(self, id_: str, have: bool) -> dict[str, Any]:
        if id_ not in _BOOKS:
            raise ItemNonexistent(id_)
        with self.trava:
            state = self._ler()
            state["livros"].setdefault(id_, {})["tenho"] = have
            self._gravar(state)
            return self._livro(id_, state, self._leituras())

    def vincular_leitura(self, id_: str) -> dict[str, Any]:
        """Liga o livro a uma leitura da aba Leituras (cria se não houver) para ler e grifar lá."""
        if id_ not in _BOOKS:
            raise ItemNonexistent(id_)
        with self.trava:
            state = self._ler()
            book = _BOOKS[id_]
            reading = self._leitura_do_livro(book, state["livros"].get(id_, {}), self._leituras())
            if reading is None:
                reading = self._criar_leitura({
                    "titulo": book["titulo"],
                    "autor": book["autor"],
                    "area": "Tecnologia",
                    "url": book.get("url", ""),
                    "tags": ["trilha", "arquitetura"],
                })
            my = state["livros"].setdefault(id_, {})
            my["leitura_id"] = reading["id"]
            my["tenho"] = True
            self._gravar(state)
            return self._livro(id_, state, self._leituras())

    # --- trilhas ---

    def _etapa(
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
                "livro": self._livro(ind["livro"], estado, readings),
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
        """Leitura dinâmica: a primeira etapa aberta; nela, o primeiro capítulo não lido de um livro
        que a pessoa tem (senão o primeiro não lido, a conseguir); lido tudo, a prática."""
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

    def _resumo(self, stages: list[dict[str, Any]]) -> dict[str, Any]:
        return {
            "total_etapas": len(stages),
            "etapas_concluidas": sum(e["concluida"] for e in stages),
            "progresso": round(sum(e["progresso"] for e in stages) / len(stages), 3)
            if stages
            else 0,
        }

    def listar_trilhas(self) -> list[dict[str, Any]]:
        state, readings = self._ler(), self._leituras()
        items = []
        for t in TRACKS:
            stages = [self._etapa(e, state, readings) for e in t["etapas"]]
            items.append({
                **{k: v for k, v in t.items() if k != "etapas"},
                **self._resumo(stages),
                "proxima": self._proxima(stages),
            })
        return items

    def trilha(self, id_: str, frente: str | None = None) -> dict[str, Any]:
        t = _TRACKS.get(id_)
        if t is None:
            raise ItemNonexistent(id_)
        state, readings = self._ler(), self._leituras()
        stages = [self._etapa(e, state, readings) for e in t["etapas"]
                  if frente is None or frente in e["frentes"]]
        presentes = {f for e in t["etapas"] for f in e["frentes"]}
        return {
            **{k: v for k, v in t.items() if k != "etapas"},
            "frentes": [f for f in FRONTS if f in presentes],
            "frente": frente,
            "etapas": stages,
            **self._resumo(stages),
            "proxima": self._proxima(stages),
        }

    def marcar(self, track_id: str, stage_id: str, dados: dict[str, Any]) -> dict[str, Any]:
        """`leitura` (índice) + `feita`, `pratica` (bool) e/ou `nota_id`; devolve a etapa."""
        t = _TRACKS.get(track_id)
        stage = next((e for e in t["etapas"] if e["id"] == stage_id), None) if t else None
        if stage is None:
            raise ItemNonexistent(stage_id)
        today = date.today().isoformat()
        with self.trava:
            state = self._ler()
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
            self._gravar(state)
            return self._etapa(stage, state, self._leituras())
