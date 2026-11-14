"""Studies module data as JSON in the data folder: `leituras.json` (books and articles),
`idiomas.json` (A1–C2 tracks with the logged sessions),
`projetos.json` (reading projects) and `conhecimento.json` (progress on the knowledge tracks,
`knowledge.py`). Syntheses and annotations live in the notes
(`/api/notas`), linked by the reading's `nota_id`."""

import json
import os
import threading
import uuid
from datetime import UTC, date, datetime
from pathlib import Path
from typing import Any

from studies.knowledge import Knowledge
from studies.languages import LANGUAGES, LEVELS, hours_studied, level_of_hours, milestones, schedule
from studies.projects import FIELDS_CLASSIFICATION, FIELDS_PROJECT, Markings, assemble_matrix

AREAS = ["Tecnologia", "Finanças", "Linguagens", "Saúde"]
STATUS_READING = ["quero ler", "lendo", "lido"]
FIELDS_READING = {
    "titulo",
    "autor",
    "tipo",
    "area",
    "status",
    "paginas",
    "pagina_atual",
    "nota_id",
    "arquivo_id",
    "tags",
    "url",
    # work record for the projects' citation matrix
    "ano",
    "referencia",
    "tipo_publicacao",
    "veiculo",
    "doi",
    "idioma",
}
FIELDS_TRACK = {
    "idioma",
    "nivel_inicial",
    "nivel_alvo",
    "minutos_por_dia",
    "dias_semana",
    "inicio",
}


class NotFound(Exception):
    pass


class Invalid(Exception):
    pass


def _now() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat()


def _data(value: str) -> date:
    try:
        return date.fromisoformat(value)
    except ValueError as e:
        raise Invalid(f"Data inválida: {value}") from e


class Collection:
    """List of dicts with `id`, written in full on every change (atomic file swap)."""

    def __init__(self, file: Path, lock: threading.RLock) -> None:
        self.arquivo = file
        self.lock = lock

    def ler(self) -> list[dict[str, Any]]:
        if not self.arquivo.exists():
            return []
        items: list[dict[str, Any]] = json.loads(self.arquivo.read_text("utf-8"))
        return items

    def gravar(self, items: list[dict[str, Any]]) -> None:
        tmp = self.arquivo.with_suffix(".tmp")
        tmp.write_text(json.dumps(items, ensure_ascii=False, indent=1), "utf-8")
        os.replace(tmp, self.arquivo)

    def obter(self, id_: str) -> dict[str, Any]:
        for x in self.ler():
            if x["id"] == id_:
                return x
        raise NotFound(id_)

    def criar(self, dados: dict[str, Any]) -> dict[str, Any]:
        with self.lock:
            items = self.ler()
            new = {
                "id": uuid.uuid4().hex[:12],
                **dados,
                "criado": _now(),
                "atualizado": _now(),
            }
            items.append(new)
            self.gravar(items)
            return new

    def edit(self, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        with self.lock:
            items = self.ler()
            for x in items:
                if x["id"] == id_:
                    x.update(dados, atualizado=_now())
                    self.gravar(items)
                    return x
        raise NotFound(id_)

    def excluir(self, id_: str) -> None:
        with self.lock:
            items = self.ler()
            restantes = [x for x in items if x["id"] != id_]
            if len(restantes) == len(items):
                raise NotFound(id_)
            self.gravar(restantes)


class Studies:
    def __init__(self, root: str | Path, marcacoes: Markings | None = None) -> None:
        self.root = Path(root).expanduser()
        self.root.mkdir(parents=True, exist_ok=True)
        lock = threading.RLock()
        self.readings = Collection(self.root / "leituras.json", lock)
        self.tracks = Collection(self.root / "idiomas.json", lock)
        self.projects = Collection(self.root / "projetos.json", lock)
        self._markings = marcacoes or (lambda _id: [])
        self.knowledge = Knowledge(
            self.root / "conhecimento.json", lock, self.readings.ler, self.create_reading
        )

    # --- reading projects ---

    def list_projects(self) -> list[dict[str, Any]]:
        items = []
        for p in self.projects.ler():
            marc = self._markings(p["id"])
            items.append({
                **{k: v for k, v in p.items() if k not in ("classificacao", "codigos")},
                "trechos": sum(m["tipo"] == "destaque" for m in marc),
                "comentarios": sum(
                    m["tipo"] == "texto" or bool(m.get("comentario")) for m in marc
                ),
                "manuscritos": len({(m["arquivo_id"], m.get("pagina")) for m in marc
                                    if m["tipo"] == "traco"}),
                "trabalhos": len({m["arquivo_id"] for m in marc}),
            })
        return sorted(items, key=lambda p: p["atualizado"], reverse=True)

    def create_project(self, dados: dict[str, Any]) -> dict[str, Any]:
        dados = {k: v for k, v in dados.items() if k in FIELDS_PROJECT}
        default = {"descricao": "", "cor": 0xFF3F51B5, "secoes": []}
        return self.projects.criar({**default, **dados, "classificacao": {}, "codigos": {}})

    def edit_project(self, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        return self.projects.edit(id_, {k: v for k, v in dados.items() if k in FIELDS_PROJECT})

    def matrix(self, id_: str) -> dict[str, Any]:
        with self.projects.lock:
            project = self.projects.obter(id_)
            m = assemble_matrix(project, self._markings(id_), self.readings.ler())
            if m["codigos"] != (project.get("codigos") or {}):
                self.projects.edit(id_, {"codigos": m["codigos"]})
        del m["codigos"]
        return m

    def classify(self, id_: str, item_id: str, dados: dict[str, Any]) -> dict[str, Any]:
        with self.projects.lock:
            project = self.projects.obter(id_)
            classif = dict(project.get("classificacao") or {})
            current = {**(classif.get(item_id) or {}),
                     **{k: v for k, v in dados.items() if k in FIELDS_CLASSIFICATION}}
            classif[item_id] = current
            self.projects.edit(id_, {"classificacao": classif})
            return current

    # --- readings ---

    def list_readings(self, area: str | None = None, status: str | None = None) -> list[dict]:
        items = [
            x
            for x in self.readings.ler()
            if (area is None or x["area"] == area) and (status is None or x["status"] == status)
        ]
        order = {s: i for i, s in enumerate(["lendo", "quero ler", "lido"])}
        return sorted(items, key=lambda x: (order.get(x["status"], 9), x["titulo"].lower()))

    def _validate_reading(self, dados: dict[str, Any]) -> dict[str, Any]:
        dados = {k: v for k, v in dados.items() if k in FIELDS_READING}
        if "status" in dados and dados["status"] not in STATUS_READING:
            raise Invalid(f"Status deve ser um de {STATUS_READING}")
        return dados

    def create_reading(self, dados: dict[str, Any]) -> dict[str, Any]:
        default = {
            "autor": "",
            "tipo": "livro",
            "status": "quero ler",
            "paginas": None,
            "pagina_atual": 0,
            "nota_id": None,
            "arquivo_id": None,
            "tags": [],
            "url": "",
        }
        return self.readings.criar({**default, **self._validate_reading(dados)})

    def edit_reading(self, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        return self.readings.edit(id_, self._validate_reading(dados))

    # --- languages ---

    def _validate_track(self, dados: dict[str, Any]) -> dict[str, Any]:
        dados = {k: v for k, v in dados.items() if k in FIELDS_TRACK}
        for field in ("nivel_inicial", "nivel_alvo"):
            if field in dados and dados[field] not in LEVELS:
                raise Invalid(f"{field} deve ser um de {LEVELS}")
        if "idioma" in dados and dados["idioma"] not in LANGUAGES:
            raise Invalid(f"Idioma deve ser um de {list(LANGUAGES)}")
        if "dias_semana" in dados:
            days = sorted({int(d) for d in dados["dias_semana"]})
            if not days or any(d < 1 or d > 7 for d in days):
                raise Invalid("dias_semana: de 1 (segunda) a 7 (domingo)")
            dados["dias_semana"] = days
        if "inicio" in dados:
            dados["inicio"] = _data(dados["inicio"]).isoformat()
        return dados

    def _with_progress(self, t: dict[str, Any], hoje: date | None = None) -> dict[str, Any]:
        hoje = hoje or date.today()
        hours = hours_studied(t)
        return {
            **{k: v for k, v in t.items() if k != "sessoes"},
            "nome": LANGUAGES[t["idioma"]],
            "horas": round(hours, 1),
            "nivel_atual": level_of_hours(hours),
            "marcos": milestones(t, hoje),
            "sessoes_feitas": len(t.get("sessoes", {})),
        }

    def list_tracks(self) -> list[dict[str, Any]]:
        return [self._with_progress(t) for t in self.tracks.ler()]

    def trilha(self, id_: str) -> dict[str, Any]:
        return self._with_progress(self.tracks.obter(id_))

    def create_track(self, dados: dict[str, Any]) -> dict[str, Any]:
        default = {
            "nivel_inicial": "A1",
            "nivel_alvo": "C2",
            "minutos_por_dia": 45,
            "dias_semana": [1, 2, 3, 4, 5, 6],
            "inicio": date.today().isoformat(),
        }
        t = self.tracks.criar({**default, **self._validate_track(dados), "sessoes": {}})
        return self._with_progress(t)

    def edit_track(self, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        return self._with_progress(self.tracks.edit(id_, self._validate_track(dados)))

    def schedule(self, id_: str, de: str, ate: str) -> list[dict[str, Any]]:
        return schedule(self.tracks.obter(id_), _data(de), _data(ate))

    def register_session(self, id_: str, day: str, minutos: int) -> dict[str, Any]:
        """Stores the minutes studied on the day (0 deletes the record)."""
        key = _data(day).isoformat()
        with self.tracks.lock:
            t = self.tracks.obter(id_)
            sessions = dict(t.get("sessoes", {}))
            if minutos > 0:
                sessions[key] = minutos
            else:
                sessions.pop(key, None)
            return self._with_progress(self.tracks.edit(id_, {"sessoes": sessions}))

    def add_up_minutes(self, language: str, day: str, minutos: int) -> None:
        """Adds minutes to the day of the language track (Language activities); without a track,
        nothing."""
        with self.tracks.lock:
            track = next((t for t in self.tracks.ler() if t["idioma"] == language), None)
            if track is not None:
                current = int(track.get("sessoes", {}).get(_data(day).isoformat(), 0))
                self.register_session(track["id"], day, min(current + minutos, 1440))
