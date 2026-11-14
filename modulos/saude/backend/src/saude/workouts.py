"""Treinos guardados em JSON na pasta de dados: `exercicios.json` (catálogo base + os criados pelo
usuário), `agenda.json` (exercícios marcados em cada dia, com séries, carga e se foi feito) e
`imagens/` (fotos enviadas e o cache das imagens do free-exercise-db)."""

import json
import os
import re
import threading
import unicodedata
import urllib.request
import uuid
from datetime import date
from pathlib import Path
from typing import Any

from saude.catalog import URL_IMAGES, exercises_base

FIELDS_EXERCISE = {"nome", "area", "grupo", "equipamento", "series", "repeticoes", "carga_kg",
                    "instrucoes"}
FIELDS_ITEM = {"data", "ordem", "series", "repeticoes", "carga_kg", "observacao", "feito"}
KINDS_IMAGE = {"image/jpeg": "jpg", "image/png": "png", "image/webp": "webp"}


class NotFound(Exception):
    pass


class Invalid(Exception):
    pass


def _read(caminho: Path, default: Any) -> Any:
    if not caminho.exists():
        return default
    return json.loads(caminho.read_text("utf-8"))


def _write(caminho: Path, dados: Any) -> None:
    tmp = caminho.with_suffix(".tmp")
    tmp.write_text(json.dumps(dados, ensure_ascii=False, indent=1), "utf-8")
    os.replace(tmp, caminho)


def _slug(text: str) -> str:
    without_accent = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", without_accent.lower()).strip("-") or "exercicio"


def _data(valor: str) -> str:
    try:
        return date.fromisoformat(valor).isoformat()
    except ValueError as e:
        raise Invalid(f"Data inválida: {valor}") from e


class Workouts:
    def __init__(self, root: str | Path, baixar_imagens: bool = True) -> None:
        self.root = Path(root).expanduser()
        self.imagens = self.root / "imagens"
        self.imagens.mkdir(parents=True, exist_ok=True)
        self.download_images = baixar_imagens
        self._lock = threading.RLock()
        self._file_exercises = self.root / "exercicios.json"
        self._file_agenda = self.root / "agenda.json"

    # --- exercícios ---

    def _exercises(self) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = _read(self._file_exercises, None)
        if items is None:
            items = exercises_base()
            _write(self._file_exercises, items)
        return items

    def list_exercises(self) -> list[dict[str, Any]]:
        with self._lock:
            return self._exercises()

    def exercicio(self, id_: str) -> dict[str, Any]:
        with self._lock:
            for e in self._exercises():
                if e["id"] == id_:
                    return e
        raise NotFound(id_)

    def create_exercise(self, dados: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            items = self._exercises()
            used = {e["id"] for e in items}
            base = id_ = _slug(dados["nome"])
            n = 2
            while id_ in used:
                id_, n = f"{base}-{n}", n + 1
            new = {
                "id": id_, "ref": None, "series": 3, "repeticoes": "10", "carga_kg": None,
                "grupo": "", "equipamento": "", "instrucoes": "",
                **{k: v for k, v in dados.items() if k in FIELDS_EXERCISE},
                "personalizado": True, "imagem_propria": False,
            }
            items.append(new)
            _write(self._file_exercises, items)
            return new

    def edit_exercise(self, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            items = self._exercises()
            for e in items:
                if e["id"] == id_:
                    e.update({k: v for k, v in dados.items() if k in FIELDS_EXERCISE})
                    _write(self._file_exercises, items)
                    return e
        raise NotFound(id_)

    def delete_exercise(self, id_: str) -> None:
        """Exclui o exercício, a foto dele e as marcações na agenda."""
        with self._lock:
            items = self._exercises()
            restantes = [e for e in items if e["id"] != id_]
            if len(restantes) == len(items):
                raise NotFound(id_)
            _write(self._file_exercises, restantes)
            agenda = _read(self._file_agenda, [])
            _write(self._file_agenda, [i for i in agenda if i["exercicio_id"] != id_])
            for f in self.imagens.glob(f"{id_}.*"):
                f.unlink()

    # --- imagens ---

    def save_image(self, id_: str, tipo: str, content: bytes) -> dict[str, Any]:
        ext = KINDS_IMAGE.get(tipo)
        if ext is None:
            raise Invalid("Imagem deve ser JPEG, PNG ou WEBP")
        with self._lock:
            self.exercicio(id_)
            for f in self.imagens.glob(f"{id_}.*"):
                f.unlink()
            (self.imagens / f"{id_}.{ext}").write_bytes(content)
            return self._mark_image(id_, True)

    def remove_image(self, id_: str) -> dict[str, Any]:
        with self._lock:
            for f in self.imagens.glob(f"{id_}.*"):
                f.unlink()
            return self._mark_image(id_, False)

    def _mark_image(self, id_: str, propria: bool) -> dict[str, Any]:
        items = self._exercises()
        for e in items:
            if e["id"] == id_:
                e["imagem_propria"] = propria
                _write(self._file_exercises, items)
                return e
        raise NotFound(id_)

    def imagem(self, id_: str, n: int = 0) -> Path:
        """Foto enviada pelo usuário ou, sem ela, a imagem `n` (0 = início, 1 = fim do movimento)
        do free-exercise-db, baixada uma vez e guardada em cache."""
        e = self.exercicio(id_)
        if e.get("imagem_propria"):
            for f in self.imagens.glob(f"{id_}.*"):
                return f
        ref = e.get("ref")
        if not ref or n not in (0, 1):
            raise NotFound(id_)
        cache = self.imagens / "ref" / f"{ref}_{n}.jpg"
        if not cache.exists():
            if not self.download_images:
                raise NotFound(id_)
            try:
                with urllib.request.urlopen(URL_IMAGES.format(ref=ref, n=n), timeout=15) as r:
                    content = r.read()
            except OSError as error:
                raise NotFound(id_) from error
            cache.parent.mkdir(exist_ok=True)
            cache.write_bytes(content)
        return cache

    # --- agenda ---

    def agenda(self, de: str, ate: str) -> list[dict[str, Any]]:
        de, ate = _data(de), _data(ate)
        with self._lock:
            items = [i for i in _read(self._file_agenda, []) if de <= i["data"] <= ate]
        return sorted(items, key=lambda i: (i["data"], i["ordem"]))

    def marcar(self, dados: dict[str, Any]) -> dict[str, Any]:
        """Põe um exercício num dia; séries, repetições e carga vêm do exercício se não vierem."""
        with self._lock:
            e = self.exercicio(dados["exercicio_id"])
            agenda = _read(self._file_agenda, [])
            day = _data(dados["data"])
            item = {
                "id": uuid.uuid4().hex[:12],
                "data": day,
                "exercicio_id": e["id"],
                "ordem": max((i["ordem"] for i in agenda if i["data"] == day), default=-1) + 1,
                "series": e["series"],
                "repeticoes": e["repeticoes"],
                "carga_kg": e["carga_kg"],
                "observacao": "",
                "feito": False,
            }
            item.update({k: v for k, v in dados.items() if k in FIELDS_ITEM and v is not None})
            item["data"] = day
            agenda.append(item)
            _write(self._file_agenda, agenda)
            return item

    def edit_item(self, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            agenda = _read(self._file_agenda, [])
            for i in agenda:
                if i["id"] == id_:
                    i.update({k: v for k, v in dados.items() if k in FIELDS_ITEM})
                    i["data"] = _data(i["data"])
                    _write(self._file_agenda, agenda)
                    return dict(i)
        raise NotFound(id_)

    def unmark(self, id_: str) -> None:
        with self._lock:
            agenda = _read(self._file_agenda, [])
            restantes = [i for i in agenda if i["id"] != id_]
            if len(restantes) == len(agenda):
                raise NotFound(id_)
            _write(self._file_agenda, restantes)

    def copy(self, de: str, ate: str, destination: str) -> list[dict[str, Any]]:
        """Copia os itens de [de, ate] para o período que começa em `destino` (mesmo deslocamento
        de dias), sem marcar como feitos. Serve para repetir um dia ou uma semana de treino."""
        desloc = date.fromisoformat(_data(destination)) - date.fromisoformat(_data(de))
        new = []
        for i in self.agenda(de, ate):
            day = (date.fromisoformat(i["data"]) + desloc).isoformat()
            new.append(self.marcar({**i, "data": day, "feito": False, "ordem": None}))
        return new
