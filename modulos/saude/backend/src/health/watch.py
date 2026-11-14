"""Galaxy Watch data (through Samsung Health) per day in `relogio/dias.json`.

The phone app reads Health Connect, sums each day and sends it (update, overwrites). The old
history and what Health Connect does not receive (stress, sleep score) come from the Samsung Health
export zip (Samsung import, only fills what is missing, except those two fields).
Sleep counts on the day the person wakes up.
"""

import csv
import io
import threading
import zipfile
from collections import defaultdict
from datetime import UTC, date, datetime, timedelta, timezone
from pathlib import Path
from statistics import mean
from typing import IO, Any

from health.workouts import Invalid, _read, _write

FIELDS_NUMERIC = {
    # activity
    "passos",
    "distancia_km",
    "andares",
    "calorias_ativas",
    "calorias_total",
    "minutos_ativos",
    "agua_ml",
    # sleep (minutes)
    "sono_min",
    "sono_profundo_min",
    "sono_leve_min",
    "sono_rem_min",
    "sono_acordado_min",
    "sono_pontuacao",
    # heart and breathing
    "fc_media",
    "fc_min",
    "fc_max",
    "fc_repouso",
    "hrv_ms",
    "spo2",
    "respiracao",
    "pressao_sistolica",
    "pressao_diastolica",
    "estresse",
    # body
    "peso_kg",
    "gordura_pct",
    "massa_magra_kg",
}
FIELDS_TEXT = {"sono_inicio", "sono_fim"}  # "HH:MM" local
FIELDS = FIELDS_NUMERIC | FIELDS_TEXT | {"exercicios"}
SO_DA_EXPORT = {"estresse", "sono_pontuacao"}  # Health Connect does not receive these

GOALS = {"passos": 8000, "sono_min": 420, "minutos_ativos": 30, "agua_ml": 2000}


def _day(value: str) -> str:
    try:
        return date.fromisoformat(value).isoformat()
    except (TypeError, ValueError) as e:
        raise Invalid(f"Data inválida: {value}") from e


def score_sleep(d: dict[str, Any]) -> int | None:
    """0–100 score of the night from the stages, modeled on Samsung Health's (which does not reach
    Health Connect): duration (8 h target), efficiency (time awake in bed), deep sleep (~20%) and
    REM (~22%). Without stages, only the existing parts count, rescaled to 100."""
    dormido = d.get("sono_min")
    if not isinstance(dormido, int | float) or dormido < 60:
        return None

    def faixa(v: float, bad: float, bom: float) -> float:
        return max(0.0, min(1.0, (v - bad) / (bom - bad)))

    parts = [(40, faixa(dormido, 240, 480))]  # 4 h = 0, 8 h = cheio
    acordado = d.get("sono_acordado_min")
    if isinstance(acordado, int | float):
        parts.append((20, faixa(dormido / (dormido + acordado), 0.75, 0.95)))
    profundo, rem = d.get("sono_profundo_min"), d.get("sono_rem_min")
    if isinstance(profundo, int | float) and isinstance(rem, int | float) and profundo + rem > 0:
        parts.append((20, faixa(profundo / dormido, 0.05, 0.18)))
        parts.append((20, faixa(rem / dormido, 0.08, 0.20)))
    weight = sum(p for p, _ in parts)
    return round(sum(p * v for p, v in parts) * 100 / weight)


def _clean(dados: dict[str, Any]) -> dict[str, Any]:
    output: dict[str, Any] = {}
    for k, v in dados.items():
        if k not in FIELDS or v is None:
            continue
        if k in FIELDS_NUMERIC:
            try:
                output[k] = round(float(v), 2)
            except (TypeError, ValueError) as e:
                raise Invalid(f"{k}: número inválido") from e
        elif k in FIELDS_TEXT:
            output[k] = str(v)[:5]
        elif isinstance(v, list):
            output[k] = [
                {
                    c: e[c]
                    for c in ("tipo", "inicio", "minutos", "calorias", "distancia_km")
                    if c in e
                }
                for e in v
                if isinstance(e, dict)
            ][:30]
    return output


class Clock:
    def __init__(self, root: str | Path) -> None:
        self.root = Path(root).expanduser()
        self.root.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._days = self.root / "dias.json"
        self._analyses = self.root / "analises.json"
        self._state = self.root / "estado.json"

    def dias(self, de: str, ate: str) -> list[dict[str, Any]]:
        d1, d2 = _day(de), _day(ate)
        with self._lock:
            everything: dict[str, Any] = _read(self._days, {})
        output = [{"data": k, **everything[k]} for k in sorted(everything) if d1 <= k <= d2]
        for d in output:  # without the Samsung score (it only comes in the export), compute ours
            if "sono_pontuacao" not in d and (note := score_sleep(d)) is not None:
                d["sono_pontuacao"] = note
                d["sono_pontuacao_estimada"] = True
        return output

    def atualizar(
        self, dias: list[dict[str, Any]], sobrescrever: bool = True, origem: str = ""
    ) -> int:
        """Stores the days; with overwrite=False it only fills empty fields (except the ones
        exclusive
        to the export, which always go in)."""
        with self._lock:
            everything: dict[str, Any] = _read(self._days, {})
            n = 0
            for d in dias:
                key = _day(d.get("data", ""))
                new = _clean(d)
                if not new:
                    continue
                current = everything.setdefault(key, {})
                for k, v in new.items():
                    if sobrescrever or k in SO_DA_EXPORT or k not in current:
                        current[k] = v
                n += 1
            _write(self._days, everything)
            if origem:
                state = _read(self._state, {})
                state[origem] = datetime.now(UTC).isoformat(timespec="seconds")
                _write(self._state, state)
            return n

    def estado(self) -> dict[str, Any]:
        """Last sync of each source (`health_connect`, `exportacao`)."""
        with self._lock:
            return dict(_read(self._state, {}))

    def resumo(self, de: str, ate: str) -> dict[str, Any]:
        """Average of each metric over the days that have it and how many days hit each target."""
        days = self.dias(de, ate)
        medias: dict[str, float] = {}
        for k in FIELDS_NUMERIC:
            values = [d[k] for d in days if isinstance(d.get(k), int | float)]
            if values:
                medias[k] = round(mean(values), 1)
        goals = {
            k: {
                "meta": m,
                "batidos": sum(1 for d in days if d.get(k, 0) >= m),
                "dias": sum(1 for d in days if k in d),
            }
            for k, m in GOALS.items()
        }
        return {
            "de": _day(de),
            "ate": _day(ate),
            "dias": len(days),
            "medias": medias,
            "metas": goals,
        }

    # --- local LLM analyses ---

    def analyses(self) -> list[dict[str, Any]]:
        with self._lock:
            return list(_read(self._analyses, []))

    def store_analysis(self, analysis: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            items = [analysis, *_read(self._analyses, [])][:20]
            _write(self._analyses, items)
        return analysis

    # --- Samsung Health export ---

    def import_samsung(self, file: IO[bytes]) -> dict[str, Any]:
        try:
            with zipfile.ZipFile(file) as z:
                days, read = read_export(z)
        except zipfile.BadZipFile as e:
            raise Invalid("Envie o .zip da exportação do Samsung Health") from e
        if not read:
            raise Invalid("Nenhum CSV do Samsung Health reconhecido no zip")
        n = self.atualizar(days, sobrescrever=False, origem="exportacao")
        return {"dias": n, "arquivos": read}


# ---------------------------------------------------------------- export CSVs
#
# Each CSV has a metadata line, the header and the rows. Columns sometimes come with the type
# prefix (`com.samsung.health.heart_rate.heart_rate`); only the end of the name is used. Times are
# in UTC, with the offset in the `time_offset` column ("UTC-0300").

STAGES = {
    "40001": "sono_acordado_min",
    "40002": "sono_leve_min",
    "40003": "sono_profundo_min",
    "40004": "sono_rem_min",
}
EXERCISES = {
    "1001": "caminhada",
    "1002": "corrida",
    "11007": "bicicleta",
    "13001": "trilha",
    "14001": "natação",
    "15003": "bicicleta ergométrica",
    "15004": "musculação",
    "15005": "elíptico",
    "10007": "boxe",
}


def _lines(z: zipfile.ZipFile, nome: str) -> list[dict[str, str]]:
    text = z.read(nome).decode("utf-8-sig", "replace")
    parts = text.split("\n", 1)
    if len(parts) < 2:
        return []
    leitor = csv.reader(io.StringIO(parts[1]))
    cabecalho = [c.rsplit(".", 1)[-1].strip() for c in next(leitor, [])]
    return [dict(zip(cabecalho, line, strict=False)) for line in leitor if line]


def _timezone(text: str) -> timezone:
    t = (text or "").replace("UTC", "").strip()
    if len(t) == 5 and t[0] in "+-" and t[1:].isdigit():
        minutes = int(t[1:3]) * 60 + int(t[3:])
        return timezone(timedelta(minutes=minutes if t[0] == "+" else -minutes))
    return timezone(timedelta(hours=-3))


def _hour(line: dict[str, str], coluna: str) -> datetime | None:
    value = (line.get(coluna) or "").strip()
    if not value:
        return None
    try:
        if value.isdigit():
            utc = datetime.fromtimestamp(int(value) / 1000, UTC)
        else:
            utc = datetime.fromisoformat(value.replace(" ", "T")[:19]).replace(tzinfo=UTC)
    except ValueError:
        return None
    return utc.astimezone(_timezone(line.get("time_offset", "")))


def _num(line: dict[str, str], coluna: str) -> float | None:
    try:
        v = float(line.get(coluna) or "")
    except ValueError:
        return None
    return v if v == v else None  # NaN


def read_export(z: zipfile.ZipFile) -> tuple[list[dict[str, Any]], list[str]]:
    """Days built from the recognized CSVs and the types read."""
    days: dict[str, dict[str, Any]] = defaultdict(dict)
    lists: dict[str, dict[str, list[float]]] = defaultdict(lambda: defaultdict(list))
    read: list[str] = []

    def tipo(nome: str) -> str:
        base = nome.rsplit("/", 1)[-1].removesuffix(".csv")
        parts = base.split(".")
        return ".".join(parts[:-1]) if parts[-1].isdigit() else base

    leitores = {
        "tracker.pedometer_day_summary": _steps,
        "sleep": _sleep,
        "sleep_stage": _stages,
        "tracker.heart_rate": _fc,
        "stress": _stress,
        "weight": _weight,
        "tracker.oxygen_saturation": _spo2,
        "exercise": _exercise,
        "water_intake": _water,
        "floors_climbed": _floors,
    }
    for nome in z.namelist():
        if not nome.endswith(".csv"):
            continue
        t = tipo(nome)
        for key, leitor in leitores.items():
            if t.endswith("." + key):
                leitor(_lines(z, nome), days, lists)
                read.append(key)
                break

    for d, metricas in lists.items():
        for k, values in metricas.items():
            if not values:
                continue
            if k == "fc_min":
                days[d][k] = min(values)
            elif k == "fc_max":
                days[d][k] = max(values)
            else:
                days[d][k] = round(mean(values), 1)
    for v in days.values():
        v.pop("_maior_sono", None)
    return [{"data": d, **v} for d, v in sorted(days.items())], sorted(set(read))


Days = dict[str, dict[str, Any]]
Lists = dict[str, dict[str, list[float]]]


def _steps(lines: list[dict[str, str]], dias: Days, _: Lists) -> None:
    for x in lines:
        day = _num(x, "day_time")
        steps = _num(x, "step_count")
        if day is None or steps is None:
            continue
        d = datetime.fromtimestamp(day / 1000, UTC).date().isoformat()
        if steps <= dias[d].get("passos", -1):
            continue  # one record per device; the largest one (the combined) stays
        dias[d]["passos"] = int(steps)
        if (m := _num(x, "distance")) is not None:
            dias[d]["distancia_km"] = round(m / 1000, 2)
        if (c := _num(x, "calorie")) is not None:
            dias[d]["calorias_ativas"] = round(c)
        if (a := _num(x, "active_time")) is not None:
            dias[d]["minutos_ativos"] = round(a / 60000)


def _sleep(lines: list[dict[str, str]], dias: Days, _: Lists) -> None:
    for x in lines:
        start, end = _hour(x, "start_time"), _hour(x, "end_time")
        if not start or not end or end <= start:
            continue
        d = dias[end.date().isoformat()]
        minutes = round((end - start).total_seconds() / 60)
        d["sono_min"] = d.get("sono_min", 0) + minutes
        if minutes > d.get("_maior_sono", 0):  # times of the main night, not of the nap
            d.update(
                _maior_sono=minutes,
                sono_inicio=start.strftime("%H:%M"),
                sono_fim=end.strftime("%H:%M"),
            )
            if (p := _num(x, "sleep_score")) is not None and p > 0:
                d["sono_pontuacao"] = p


def _stages(lines: list[dict[str, str]], dias: Days, _: Lists) -> None:
    for x in lines:
        start, end = _hour(x, "start_time"), _hour(x, "end_time")
        field = STAGES.get((x.get("stage") or "").strip())
        if not start or not end or not field:
            continue
        d = dias[end.date().isoformat()]
        d[field] = d.get(field, 0) + round((end - start).total_seconds() / 60)


def _media_of_day(coluna: str, field: str):  # noqa: ANN202
    def ler(lines: list[dict[str, str]], _: Days, lists: Lists) -> None:
        for x in lines:
            start, v = _hour(x, "start_time"), _num(x, coluna)
            if start and v is not None and v > 0:
                lists[start.date().isoformat()][field].append(v)

    return ler


_stress = _media_of_day("score", "estresse")
_spo2 = _media_of_day("spo2", "spo2")


def _fc(lines: list[dict[str, str]], dias: Days, lists: Lists) -> None:
    for x in lines:
        start, v = _hour(x, "start_time"), _num(x, "heart_rate")
        if not start or v is None or v <= 0:
            continue
        items = lists[start.date().isoformat()]
        items["fc_media"].append(v)
        items["fc_min"].append(_num(x, "min") or v)
        items["fc_max"].append(_num(x, "max") or v)


def _weight(lines: list[dict[str, str]], dias: Days, _: Lists) -> None:
    for x in sorted(lines, key=lambda x: x.get("start_time", "")):
        start = _hour(x, "start_time")
        if not start:
            continue
        d = dias[start.date().isoformat()]
        for coluna, field in (
            ("weight", "peso_kg"),
            ("body_fat", "gordura_pct"),
            ("fat_free_mass", "massa_magra_kg"),
        ):
            if (v := _num(x, coluna)) is not None and v > 0:
                d[field] = round(v, 1)


def _exercise(lines: list[dict[str, str]], dias: Days, _: Lists) -> None:
    for x in lines:
        start = _hour(x, "start_time")
        duration = _num(x, "duration")
        if not start or not duration:
            continue
        code = (x.get("exercise_type") or "").strip()
        e: dict[str, Any] = {
            "tipo": EXERCISES.get(code, f"exercício {code}" if code else "exercício"),
            "inicio": start.strftime("%H:%M"),
            "minutos": round(duration / 60000),
        }
        if (c := _num(x, "calorie")) is not None:
            e["calorias"] = round(c)
        if (m := _num(x, "distance")) is not None and m > 0:
            e["distancia_km"] = round(m / 1000, 2)
        dias[start.date().isoformat()].setdefault("exercicios", []).append(e)


def _sum_of_day(coluna: str, field: str):  # noqa: ANN202
    def ler(lines: list[dict[str, str]], dias: Days, _: Lists) -> None:
        for x in lines:
            start, v = _hour(x, "start_time"), _num(x, coluna)
            if start and v is not None and v > 0:
                d = dias[start.date().isoformat()]
                d[field] = round(d.get(field, 0) + v, 1)

    return ler


_water = _sum_of_day("amount", "agua_ml")
_floors = _sum_of_day("floor", "andares")
