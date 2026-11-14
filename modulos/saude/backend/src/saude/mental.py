"""Saúde mental em JSON na pasta de dados: `habitos.json` (hábitos a construir ou evitar, com dias
cumpridos), `foco.json` (sessões de foco/pomodoro contra a procrastinação) e `diario.json` (humor,
ansiedade, gatilhos e gratidão por dia)."""

import threading
import uuid
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any

from saude.workouts import Invalid, NotFound, _write, _read

FIELDS_HABIT = {"nome", "tipo", "dias_semana", "descricao", "arquivado"}
FIELDS_DAILY = {"humor", "ansiedade", "gatilhos", "o_que_fiz", "gratidao", "texto"}


def _data(valor: str) -> date:
    try:
        return date.fromisoformat(valor)
    except ValueError as e:
        raise Invalid(f"Data inválida: {valor}") from e


def sequence(done: set[str], days_week: list[int], hoje: date) -> int:
    """Dias previstos seguidos cumpridos até hoje (hoje ainda em aberto não quebra a sequência)."""
    n = 0
    d = hoje
    for _ in range(3660):
        if d.isoweekday() in days_week:
            if d.isoformat() in done:
                n += 1
            elif d != hoje:
                break
        d -= timedelta(days=1)
    return n


class Mental:
    def __init__(self, root: str | Path) -> None:
        self.root = Path(root).expanduser()
        self.root.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._habits = self.root / "habitos.json"
        self._focus = self.root / "foco.json"
        self._daily = self.root / "diario.json"

    # --- hábitos ---

    def _with_summary(self, h: dict[str, Any], de: date, ate: date, hoje: date) -> dict[str, Any]:
        done = set(h.get("feitos", []))
        return {
            **{k: v for k, v in h.items() if k != "feitos"},
            "feitos": sorted(d for d in done if de.isoformat() <= d <= ate.isoformat()),
            "sequencia": sequence(done, h["dias_semana"], hoje),
            "total": len(done),
        }

    def habits(self, de: str, ate: str, hoje: date | None = None) -> list[dict[str, Any]]:
        d1, d2 = _data(de), _data(ate)
        with self._lock:
            items = _read(self._habits, [])
        return [self._with_summary(h, d1, d2, hoje or date.today()) for h in items]

    def _validate(self, dados: dict[str, Any]) -> dict[str, Any]:
        dados = {k: v for k, v in dados.items() if k in FIELDS_HABIT}
        if "tipo" in dados and dados["tipo"] not in ("construir", "evitar"):
            raise Invalid("tipo: construir ou evitar")
        if "dias_semana" in dados:
            days = sorted({int(d) for d in dados["dias_semana"]})
            if not days or days[0] < 1 or days[-1] > 7:
                raise Invalid("dias_semana: de 1 (segunda) a 7 (domingo)")
            dados["dias_semana"] = days
        return dados

    def create_habit(self, dados: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            items = _read(self._habits, [])
            new = {
                "id": uuid.uuid4().hex[:12],
                "tipo": "construir",
                "dias_semana": [1, 2, 3, 4, 5, 6, 7],
                "descricao": "",
                "arquivado": False,
                **self._validate(dados),
                "feitos": [],
            }
            items.append(new)
            _write(self._habits, items)
            today = date.today()
            return self._with_summary(new, today, today, today)

    def _alterar(self, id_: str, change: Any) -> dict[str, Any]:
        with self._lock:
            items = _read(self._habits, [])
            for h in items:
                if h["id"] == id_:
                    change(h)
                    _write(self._habits, items)
                    today = date.today()
                    return self._with_summary(h, today - timedelta(days=6), today, today)
        raise NotFound(id_)

    def edit_habit(self, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        valid = self._validate(dados)
        return self._alterar(id_, lambda h: h.update(valid))

    def mark_habit(self, id_: str, day: str, done: bool) -> dict[str, Any]:
        key = _data(day).isoformat()

        def mudar(h: dict[str, Any]) -> None:
            feitos = set(h.get("feitos", []))
            if done:
                feitos.add(key)
            else:
                feitos.discard(key)
            h["feitos"] = sorted(feitos)

        return self._alterar(id_, mudar)

    def delete_habit(self, id_: str) -> None:
        with self._lock:
            items = _read(self._habits, [])
            restantes = [h for h in items if h["id"] != id_]
            if len(restantes) == len(items):
                raise NotFound(id_)
            _write(self._habits, restantes)

    # --- foco ---

    def register_focus(self, dados: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            items = _read(self._focus, [])
            start = dados.get("inicio") or datetime.now().replace(microsecond=0).isoformat()
            try:
                datetime.fromisoformat(start)
            except ValueError as e:
                raise Invalid(f"Início inválido: {start}") from e
            session = {
                "id": uuid.uuid4().hex[:12],
                "inicio": start,
                "minutos": dados["minutos"],
                "tarefa": dados.get("tarefa", ""),
                "concluida": dados.get("concluida", True),
                "distracoes": dados.get("distracoes", 0),
            }
            items.append(session)
            _write(self._focus, items)
            return session

    def focus(self, de: str, ate: str) -> dict[str, Any]:
        d1, d2 = _data(de).isoformat(), _data(ate).isoformat()
        with self._lock:
            sessions = [s for s in _read(self._focus, []) if d1 <= s["inicio"][:10] <= d2]
        by_day: dict[str, int] = {}
        for s in sessions:
            if s["concluida"]:
                by_day[s["inicio"][:10]] = by_day.get(s["inicio"][:10], 0) + s["minutos"]
        return {"sessoes": sorted(sessions, key=lambda s: s["inicio"]), "minutos_por_dia": by_day}

    # --- diário (humor e ansiedade) ---

    def save_day(self, day: str, dados: dict[str, Any]) -> dict[str, Any]:
        key = _data(day).isoformat()
        with self._lock:
            daily: dict[str, Any] = _read(self._daily, {})
            current = daily.get(key, {"data": key})
            current.update({k: v for k, v in dados.items() if k in FIELDS_DAILY})
            daily[key] = current
            _write(self._daily, daily)
            return dict(current)

    def daily(self, de: str, ate: str) -> list[dict[str, Any]]:
        d1, d2 = _data(de).isoformat(), _data(ate).isoformat()
        with self._lock:
            daily: dict[str, Any] = _read(self._daily, {})
        return [daily[k] for k in sorted(daily) if d1 <= k <= d2]
