"""AI coach of Health › Physical: profile, home equipment, daily weight, meals (photo -> calories)
and the week's workout built by an AI and written into the agenda.

Data in `<saude>/coach/`: `perfil.json`, `peso.json`, `refeicoes.json` + `refeicoes/<id>.<ext>`,
`planos.json`. The AI is chosen per request: `claude` (Claude Code headless on the PC) or `local`
(the local LLM of the worker); the platform gives an [Ai] that runs the JSON request on either.
The user explicitly chose Claude for this part (workout and meals), unlike the watch analysis."""

import base64
import json
import threading
import urllib.request
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from typing import Any

from health.catalog import URL_INDEX
from health.sessions import Sessions
from health.workouts import KINDS_IMAGE, Invalid, NotFound, Workouts, _data, _read, _write

PROVIDERS = ("claude", "local")
WEEKDAYS = ["seg", "ter", "qua", "qui", "sex", "sáb", "dom"]
HISTORY_PLANS = 20

DEFAULT_EQUIPMENT = [
    "Anilhas: 60 kg no total",
    "Barra W",
    "Barra reta comum (supino, remada, terra, agachamento)",
    "Barrinhas de halter (par, carregadas com as anilhas)",
    "Tapete/colchonete",
    "Cadeira (apoio, tríceps, flexão inclinada/declinada, búlgaro)",
    "Saco de pancada",
    "Tênis de corrida (corrida na rua)",
]

# free-exercise-db equipment that fits a home with bar, W bar, dumbbells and plates
IMAGE_EQUIPMENT = {"barbell", "dumbbell", "body only", "e-z curl bar", "other", None}

FIELDS_PROFILE = {
    "altura_cm", "idade", "sexo", "nivel", "objetivo_principal", "objetivo_secundario",
    "dias_semana", "minutos_sessao", "restricoes", "observacoes", "materiais", "ia",
    "meta_kcal", "meta_proteina_g",
}
FIELDS_WEIGHT = {"peso_kg", "gordura_pct", "cintura_cm", "observacao"}
FIELDS_MEAL = {"data", "hora", "tipo", "descricao"}


@dataclass
class Ai:
    executar: Callable[[dict[str, Any], str], Awaitable[dict[str, Any]]]
    """Receives `{prompt, sistema, esquema, limite_s, imagens?}` and the provider; returns the
    JSON."""
    disponivel: Callable[[str], str | None]
    """Reason it cannot run now on that provider, or None."""


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


# --- prompts and schemas (JSON keys are the API contract with the app) ---

PLAN_SYSTEM = """You are a strength and conditioning coach who builds home workouts. Answer in \
Brazilian Portuguese (the text fields) and return only the JSON of the schema.
Rules:
- Use ONLY the equipment the user listed. No gym machines, no bench unless listed (a chair \
replaces it), no pull-up bar unless listed.
- Main goal first (usually hypertrophy: 6-15 reps, sets close to failure, progressive overload, \
each muscle 2x per week, 10-20 weekly sets per big group), then the secondary goal (usually \
endurance/conditioning: running, punching bag rounds, circuits) without hurting recovery.
- The user wants to train every day: alternate muscle groups (e.g. push / pull / legs / upper / \
lower) and put conditioning or active recovery (mobility, light run, core) on the lighter days; \
never two heavy days in a row for the same group.
- Prefer exercises of the catalog (use their exact `id`). When a needed exercise is missing, \
create it in `novos_exercicios` (same area names as the catalog) and reference its `id`.
- Each new exercise gets `ref`: the id of the same (or the closest equivalent) movement in the \
image reference list, so it shows the photos of the movement; use "" only when nothing \
there matches (e.g. punching bag). Copy the ref exactly as listed.
- Loads in kg must be possible with the plates the user has (sum of the bar + plates); for \
bodyweight use null. Base the loads on the history when it exists; otherwise be conservative.
- Respect the session length. In `observacao` of each item put the execution cue, tempo or rest.
- Consider weight trend, missed days and the last sessions' effort when choosing the volume.
- `resumo`: the week's logic in a few lines; `nutricao`: daily calorie and protein target and \
practical tips for body recomposition (no medical diagnosis)."""

PLAN_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "resumo": {"type": "string"},
        "nutricao": {"type": "string"},
        "novos_exercicios": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "id": {"type": "string"},
                    "nome": {"type": "string"},
                    "area": {"type": "string"},
                    "grupo": {"type": "string"},
                    "equipamento": {"type": "string"},
                    "instrucoes": {"type": "string"},
                    "ref": {"type": "string"},
                },
                "required": ["id", "nome", "area", "grupo", "equipamento", "instrucoes", "ref"],
                "additionalProperties": False,
            },
        },
        "dias": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "data": {"type": "string"},
                    "foco": {"type": "string"},
                    "itens": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "exercicio_id": {"type": "string"},
                                "series": {"type": "integer"},
                                "repeticoes": {"type": "string"},
                                "carga_kg": {"type": ["number", "null"]},
                                "observacao": {"type": "string"},
                            },
                            "required": [
                                "exercicio_id", "series", "repeticoes", "carga_kg", "observacao",
                            ],
                            "additionalProperties": False,
                        },
                    },
                },
                "required": ["data", "foco", "itens"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["resumo", "nutricao", "novos_exercicios", "dias"],
    "additionalProperties": False,
}

MEAL_SYSTEM = """You are a sports nutritionist estimating a meal from a photo and/or a \
description. Identify each food, estimate the portion in grams or household measures (use plate, \
cutlery and packaging as scale) and the calories and macros using typical Brazilian food tables \
(TACO/IBGE). Answer in Brazilian Portuguese (text fields) and return only the JSON of the schema.
- `confianca`: "alta", "media" or "baixa" (low when the portion or the food is uncertain).
- `comentario`: 1-3 short lines about the meal for someone who wants to gain muscle and lose \
fat (protein, fiber, what to add or swap), considering the day's target when given.
- If the user's description contradicts the photo, trust the description."""

_MACROS = {
    "kcal": {"type": "number"},
    "proteina_g": {"type": "number"},
    "carboidrato_g": {"type": "number"},
    "gordura_g": {"type": "number"},
}

MEAL_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "itens": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "nome": {"type": "string"}, "quantidade": {"type": "string"}, **_MACROS,
                },
                "required": [
                    "nome", "quantidade", "kcal", "proteina_g", "carboidrato_g", "gordura_g",
                ],
                "additionalProperties": False,
            },
        },
        **_MACROS,
        "confianca": {"type": "string", "enum": ["alta", "media", "baixa"]},
        "comentario": {"type": "string"},
    },
    "required": [
        "itens", "kcal", "proteina_g", "carboidrato_g", "gordura_g", "confianca", "comentario",
    ],
    "additionalProperties": False,
}


def targets(perfil: dict[str, Any], peso_kg: float | None) -> dict[str, Any]:
    """Daily calorie/protein targets: Mifflin-St Jeor x 1.55 (trains daily) minus 15% for
    recomposition; protein 2 g/kg. The profile's own targets win."""
    result: dict[str, Any] = {
        "kcal": perfil.get("meta_kcal"), "proteina_g": perfil.get("meta_proteina_g"),
    }
    altura = perfil.get("altura_cm")
    idade = perfil.get("idade")
    if peso_kg and altura and idade and not result["kcal"]:
        bmr = 10 * peso_kg + 6.25 * altura - 5 * idade
        bmr += -161 if perfil.get("sexo") == "F" else 5
        result["kcal"] = round(bmr * 1.55 * 0.85 / 10) * 10
    if peso_kg and not result["proteina_g"]:
        result["proteina_g"] = round(peso_kg * 2)
    if peso_kg and altura:
        result["imc"] = round(peso_kg / (altura / 100) ** 2, 1)
    return result


class Coach:
    def __init__(self, workouts: Workouts) -> None:
        self.workouts = workouts
        self.root = workouts.root / "coach"
        self.photos = self.root / "refeicoes"
        self.photos.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._profile = self.root / "perfil.json"
        self._weights = self.root / "peso.json"
        self._meals = self.root / "refeicoes.json"
        self._plans = self.root / "planos.json"

    # --- profile ---

    def perfil(self) -> dict[str, Any]:
        base: dict[str, Any] = {
            "altura_cm": None, "idade": None, "sexo": "M", "nivel": "iniciante",
            "objetivo_principal": "hipertrofia", "objetivo_secundario": "resistência",
            "dias_semana": 7, "minutos_sessao": 60, "restricoes": "", "observacoes": "",
            "materiais": list(DEFAULT_EQUIPMENT), "ia": "claude",
            "meta_kcal": None, "meta_proteina_g": None,
        }
        with self._lock:
            base.update(_read(self._profile, {}))
        return base

    def save_profile(self, dados: dict[str, Any]) -> dict[str, Any]:
        if dados.get("ia") not in (None, *PROVIDERS):
            raise Invalid("IA deve ser 'claude' ou 'local'")
        with self._lock:
            current = _read(self._profile, {})
            for k, v in dados.items():
                if k in FIELDS_PROFILE:
                    current[k] = v
            _write(self._profile, current)
        return self.perfil()

    # --- weight ---

    def weights(self, de: str, ate: str) -> list[dict[str, Any]]:
        de, ate = _data(de), _data(ate)
        result = []
        with self._lock:
            for w in _read(self._weights, []):
                if de <= w["data"] <= ate:
                    result.append(w)
        return sorted(result, key=lambda w: w["data"])

    def last_weight(self) -> dict[str, Any] | None:
        with self._lock:
            items = _read(self._weights, [])
        if not items:
            return None
        return max(items, key=lambda w: w["data"])

    def save_weight(self, day: str, dados: dict[str, Any]) -> dict[str, Any]:
        day = _data(day)
        with self._lock:
            items = _read(self._weights, [])
            entry: dict[str, Any] = {"data": day}
            kept = []
            for w in items:
                if w["data"] == day:
                    entry = w
                else:
                    kept.append(w)
            for k, v in dados.items():
                if k in FIELDS_WEIGHT:
                    entry[k] = v
            kept.append(entry)
            _write(self._weights, sorted(kept, key=lambda w: w["data"]))
        return entry

    def remove_weight(self, day: str) -> None:
        day = _data(day)
        with self._lock:
            items = _read(self._weights, [])
            kept = []
            for w in items:
                if w["data"] != day:
                    kept.append(w)
            if len(kept) == len(items):
                raise NotFound(day)
            _write(self._weights, kept)

    # --- meals ---

    def meals(self, de: str, ate: str) -> list[dict[str, Any]]:
        de, ate = _data(de), _data(ate)
        result = []
        with self._lock:
            for m in _read(self._meals, []):
                if de <= m["data"] <= ate:
                    result.append(m)
        return sorted(result, key=lambda m: (m["data"], m.get("hora") or ""))

    def meal(self, id_: str) -> dict[str, Any]:
        with self._lock:
            for m in _read(self._meals, []):
                if m["id"] == id_:
                    return dict(m)
        raise NotFound(id_)

    def add_meal(self, dados: dict[str, Any], foto: bytes | None, tipo_foto: str) -> dict[str, Any]:
        item: dict[str, Any] = {
            "id": uuid.uuid4().hex[:12], "data": date.today().isoformat(), "hora": "",
            "tipo": "", "descricao": "", "foto": None, "analise": None, "criada_em": _now(),
        }
        for k, v in dados.items():
            if k in FIELDS_MEAL and v is not None:
                item[k] = v
        item["data"] = _data(item["data"])
        if foto:
            ext = KINDS_IMAGE.get(tipo_foto)
            if ext is None:
                raise Invalid("Foto deve ser JPG, PNG ou WEBP")
            (self.photos / f"{item['id']}.{ext}").write_bytes(foto)
            item["foto"] = f"{item['id']}.{ext}"
        if not foto and not item["descricao"].strip():
            raise Invalid("Mande a foto ou descreva a refeição")
        with self._lock:
            items = _read(self._meals, [])
            items.append(item)
            _write(self._meals, items)
        return item

    def edit_meal(self, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            items = _read(self._meals, [])
            for m in items:
                if m["id"] == id_:
                    for k, v in dados.items():
                        if k in FIELDS_MEAL or k == "analise":
                            m[k] = v
                    m["data"] = _data(m["data"])
                    _write(self._meals, items)
                    return dict(m)
        raise NotFound(id_)

    def remove_meal(self, id_: str) -> None:
        m = self.meal(id_)
        with self._lock:
            items = _read(self._meals, [])
            kept = []
            for item in items:
                if item["id"] != id_:
                    kept.append(item)
            _write(self._meals, kept)
        if m.get("foto"):
            (self.photos / m["foto"]).unlink(missing_ok=True)

    def photo(self, id_: str) -> Path:
        m = self.meal(id_)
        if not m.get("foto"):
            raise NotFound(id_)
        return self.photos / m["foto"]

    def day_summary(self, day: str) -> dict[str, Any]:
        totals = {"kcal": 0.0, "proteina_g": 0.0, "carboidrato_g": 0.0, "gordura_g": 0.0}
        meals = self.meals(day, day)
        for m in meals:
            a = m.get("analise") or {}
            for k in totals:
                totals[k] += float(a.get(k) or 0)
        last = self.last_weight()
        peso = last["peso_kg"] if last else None
        return {
            "data": _data(day),
            "refeicoes": len(meals),
            "total": {k: round(v) for k, v in totals.items()},
            "metas": targets(self.perfil(), peso),
            "peso": last,
        }

    def meal_request(self, m: dict[str, Any], correcao: str = "") -> dict[str, Any]:
        summary = self.day_summary(m["data"])
        lines = [
            f"Meal: {m.get('tipo') or 'unspecified'} on {m['data']} {m.get('hora') or ''}".strip(),
            f"User's description: {m.get('descricao') or '(none)'}",
            f"Day targets: {summary['metas']}",
            f"Already eaten today (other meals): {summary['total']}",
        ]
        if correcao.strip():
            previous = m.get("analise") or {}
            lines.append(f"Previous estimate: {previous.get('itens')}")
            lines.append(f"User's correction (apply it): {correcao.strip()}")
        request: dict[str, Any] = {
            "prompt": "\n".join(lines),
            "sistema": MEAL_SYSTEM,
            "esquema": MEAL_SCHEMA,
            "limite_s": 240,
            "effort": "medium",
        }
        if m.get("foto"):
            content = (self.photos / m["foto"]).read_bytes()
            tipo = "image/jpeg"
            for mime, ext in KINDS_IMAGE.items():
                if m["foto"].endswith("." + ext):
                    tipo = mime
            request["imagens"] = [
                {"nome": m["foto"], "tipo": tipo, "base64": base64.b64encode(content).decode()}
            ]
        return request

    # --- image references ---

    def image_refs(self) -> dict[str, str]:
        """free-exercise-db ids usable at home -> "equipment / main muscle", downloaded once and
        cached in `imagens/ref/indice.json`. Empty when it cannot be downloaded."""
        cache = self.workouts.imagens / "ref" / "indice.json"
        if cache.exists():
            cached: dict[str, str] = json.loads(cache.read_text("utf-8"))
            return cached
        if not self.workouts.download_images:
            return {}
        try:
            with urllib.request.urlopen(URL_INDEX, timeout=30) as r:
                entries = json.loads(r.read())
        except (OSError, ValueError):
            return {}
        refs = index_refs(entries)
        cache.parent.mkdir(exist_ok=True)
        cache.write_text(json.dumps(refs, ensure_ascii=False), "utf-8")
        return refs

    # --- week plan ---

    def plans(self) -> list[dict[str, Any]]:
        with self._lock:
            items: list[dict[str, Any]] = _read(self._plans, [])
        return list(reversed(items))

    def plan_context(self, inicio: date, fim: date, pedido: str) -> str:
        perfil = self.perfil()
        last = self.last_weight()
        peso = last["peso_kg"] if last else None
        lines = ["# Profile"]
        for k in sorted(FIELDS_PROFILE - {"materiais", "ia"}):
            if perfil.get(k) not in (None, ""):
                lines.append(f"- {k}: {perfil[k]}")
        lines.append(f"- targets: {targets(perfil, peso)}")
        lines += ["", "# Equipment at home (use only this)"]
        for item in perfil["materiais"]:
            lines.append(f"- {item}")
        lines += ["", "# Weight log (last 60 days)"]
        weights = self.weights((inicio - timedelta(days=60)).isoformat(), fim.isoformat())
        for w in weights:
            lines.append(f"- {w['data']}: {w['peso_kg']} kg" + (
                f", fat {w['gordura_pct']}%" if w.get("gordura_pct") else ""))
        if not weights:
            lines.append("- (no records)")
        lines += self._food_lines(inicio, peso)
        lines += ["", "# Exercise catalog (id | name | area | group | equipment)"]
        for e in self.workouts.list_exercises():
            lines.append(
                f"{e['id']} | {e['nome']} | {e['area']} | {e['grupo']} | {e['equipamento']}"
            )
        lines += ["", "# Image reference list (free-exercise-db `ref` by equipment)"]
        lines += image_ref_lines(self.image_refs())
        lines += self._history_lines(inicio)
        lines += ["", f"# Week to plan: {inicio.isoformat()} to {fim.isoformat()}",
                  "One entry in `dias` for each date, today included."]
        for n in range((fim - inicio).days + 1):
            d = inicio + timedelta(days=n)
            lines.append(f"- {d.isoformat()} ({WEEKDAYS[d.weekday()]})")
        if pedido.strip():
            lines += ["", f"# User's request\n{pedido.strip()}"]
        return "\n".join(lines)

    def _food_lines(self, inicio: date, peso: float | None) -> list[str]:
        """Daily totals of the last 14 days against the targets (the user logs every meal)."""
        goal = targets(self.perfil(), peso)
        lines = ["", f"# Food log, last 14 days (targets {goal.get('kcal')} kcal, "
                     f"protein {goal.get('proteina_g')} g)"]
        de = inicio - timedelta(days=14)
        days: dict[str, list[float]] = {}
        for m in self.meals(de.isoformat(), (inicio - timedelta(days=1)).isoformat()):
            a = m.get("analise") or {}
            total = days.setdefault(m["data"], [0.0, 0.0, 0])
            total[0] += float(a.get("kcal") or 0)
            total[1] += float(a.get("proteina_g") or 0)
            total[2] += 1
        for day in sorted(days):
            kcal, protein, count = days[day]
            lines.append(f"- {day}: {kcal:.0f} kcal, protein {protein:.0f} g ({count:.0f} meals)")
        if not days:
            lines.append("- (no meals logged yet)")
        return lines

    def _history_lines(self, inicio: date) -> list[str]:
        de = (inicio - timedelta(days=21)).isoformat()
        ate = (inicio - timedelta(days=1)).isoformat()
        names = {}
        for e in self.workouts.list_exercises():
            names[e["id"]] = e["nome"]
        lines = ["", "# Last 3 weeks: agenda (✓ done, ✗ missed)"]
        agenda = self.workouts.agenda(de, ate)
        for i in agenda:
            mark = "✓" if i.get("feito") else "✗"
            lines.append(f"- {i['data']} {mark} {names.get(i['exercicio_id'], i['exercicio_id'])} "
                         f"{i['series']}x{i['repeticoes']} {i.get('carga_kg') or ''}")
        if not agenda:
            lines.append("- (nothing scheduled: the user is starting or restarting now)")
        lines += ["", "# Last sessions"]
        for s in Sessions(self.workouts).list_all(de, ate):
            r = s.get("resumo")
            if r:
                lines.append(f"- {s['data']}: {r['ativo_min']} min, {r['series_feitas']}/"
                             f"{r['series_planejadas']} sets, volume {r['volume_kg']} kg, "
                             f"effort {s.get('esforco') or '?'}/10")
        return lines

    def plan_request(self, inicio: date, fim: date, pedido: str) -> dict[str, Any]:
        return {
            "prompt": self.plan_context(inicio, fim, pedido),
            "sistema": PLAN_SYSTEM,
            "esquema": PLAN_SCHEMA,
            "limite_s": 420,
            "effort": "high",
        }

    def apply_plan(
        self, plan: dict[str, Any], inicio: date, fim: date, substituir: bool, ia: str
    ) -> dict[str, Any]:
        """Creates the new exercises, clears the pending items of the period (when `substituir`)
        and schedules the plan. Unknown exercise ids and dates out of the period are skipped."""
        d1, d2 = inicio.isoformat(), fim.isoformat()
        ids: dict[str, str] = {}
        for e in self.workouts.list_exercises():
            ids[e["id"]] = e["id"]
        known_refs = set(self.image_refs())
        for novo in plan.get("novos_exercicios", []):
            if novo["id"] in ids:
                continue
            if novo.get("ref") not in known_refs:
                novo = {**novo, "ref": None}
            created = self.workouts.create_exercise(novo)
            ids[novo["id"]] = created["id"]
        if substituir:
            for i in self.workouts.agenda(d1, d2):
                if not i.get("feito"):
                    self.workouts.unmark(i["id"])
        scheduled = 0
        skipped = []
        for day in plan.get("dias", []):
            if not d1 <= day["data"] <= d2:
                skipped.append(day["data"])
                continue
            for item in day["itens"]:
                real_id = ids.get(item["exercicio_id"])
                if real_id is None:
                    skipped.append(item["exercicio_id"])
                    continue
                self.workouts.marcar({
                    "data": day["data"], "exercicio_id": real_id, "series": item["series"],
                    "repeticoes": item["repeticoes"], "carga_kg": item["carga_kg"],
                    "observacao": item["observacao"],
                })
                scheduled += 1
        stored = {
            "id": uuid.uuid4().hex[:12], "criado_em": _now(), "ia": ia, "de": d1, "ate": d2,
            "resumo": plan.get("resumo", ""), "nutricao": plan.get("nutricao", ""),
            "dias": _day_focus(plan),
            "agendados": scheduled, "ignorados": skipped,
        }
        with self._lock:
            items = _read(self._plans, [])
            items.append(stored)
            _write(self._plans, items[-HISTORY_PLANS:])
        return stored


def index_refs(entries: list[dict[str, Any]]) -> dict[str, str]:
    refs = {}
    for e in entries:
        if e.get("equipment") not in IMAGE_EQUIPMENT or not e.get("images"):
            continue
        muscles = e.get("primaryMuscles") or ["?"]
        refs[e["id"]] = f"{e.get('equipment') or 'none'} / {muscles[0]}"
    return refs


def image_ref_lines(refs: dict[str, str]) -> list[str]:
    """One line per equipment/muscle with its refs: compact enough for the prompt."""
    groups: dict[str, list[str]] = {}
    for ref, group in refs.items():
        groups.setdefault(group, []).append(ref)
    lines = []
    for group in sorted(groups):
        lines.append(f"{group}: " + ", ".join(groups[group]))
    if not lines:
        lines.append("(unavailable: use ref \"\")")
    return lines


def _day_focus(plan: dict[str, Any]) -> list[dict[str, str]]:
    result = []
    for d in plan.get("dias", []):
        result.append({"data": d["data"], "foco": d["foco"]})
    return result


def week_end(inicio: date) -> date:
    """Sunday of the week of [inicio]."""
    return inicio + timedelta(days=6 - inicio.weekday())
