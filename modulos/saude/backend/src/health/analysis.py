"""Health analysis by the local LLM (never by an external service: this is personal data).

Joins, per day, the watch data with the mood/anxiety journal, focus, habits and workouts, plus the
context the platform provides from the other modules (finance, routines, studies), and asks the
model for a reading with practical recommendations.
"""

from collections.abc import Awaitable, Callable
from datetime import UTC, date, datetime, timedelta
from typing import Any

from health.mental import Mental
from health.sessions import Sessions
from health.watch import Clock
from health.workouts import Workouts

ChatLLM = Callable[[list[dict[str, str]]], Awaitable[str]]
# (start, end) -> text with what the other modules recorded in the period
ContextExtra = Callable[[date, date], str]

SYSTEM = """You are a personal health companion: sleep, physical activity, heart, body and mental
health. You receive the daily data from the watch (Galaxy Watch) and the user's own records.
Answer in Brazilian Portuguese, in Markdown, direct and warm, with no medical diagnosis.
Use exactly these section headings (in Portuguese):
## Resumo do período
## O que está bom
## Pontos de atenção
(cite numbers: averages, days below the goal, trend from the first to the second half)
## Relações encontradas
(cross sleep, steps, stress and HR with mood, anxiety, focus, workouts, spending and routine; say
only what the data supports and the sample size)
## Plano para os próximos 7 dias
(3 to 5 concrete actions, with a time or an amount: bedtime, walk, rest, workout)
Reference goals: sleep 7–9 h, 8000 steps, 30 active min, 2 L of water.
If data is missing, say which and how to record it."""

LABELS = {
    "sono_min": "sono",
    "sono_profundo_min": "profundo",
    "sono_rem_min": "REM",
    "sono_acordado_min": "acordado",
    "sono_inicio": "deitou",
    "sono_fim": "acordou",
    "sono_pontuacao": "nota sono",
    "passos": "passos",
    "distancia_km": "km",
    "minutos_ativos": "min ativos",
    "calorias_ativas": "kcal ativas",
    "fc_repouso": "FC repouso",
    "fc_media": "FC média",
    "hrv_ms": "HRV",
    "spo2": "SpO2",
    "estresse": "estresse",
    "peso_kg": "peso",
    "gordura_pct": "gordura %",
    "agua_ml": "água ml",
}


def _hours(minutos: float) -> str:
    return f"{int(minutos // 60)}h{int(minutos % 60):02d}"


def _line_clock(d: dict[str, Any]) -> str:
    parts = []
    for k, label in LABELS.items():
        if k not in d:
            continue
        v = d[k]
        text = _hours(v) if k.startswith("sono") and k.endswith("_min") else v
        parts.append(f"{label} {text}")
    for e in d.get("exercicios", []):
        parts.append(f"exercício {e.get('tipo')} {e.get('minutos')} min")
    return ", ".join(parts)


def assemble_context(
    clock: Clock,
    mental: Mental,
    workouts: Workouts,
    de: date,
    ate: date,
    extra: ContextExtra | None = None,
) -> str:
    d1, d2 = de.isoformat(), ate.isoformat()
    by_day: dict[str, list[str]] = {}

    def add(day: str, text: str) -> None:
        if text:
            by_day.setdefault(day, []).append(text)

    for d in clock.dias(d1, d2):
        add(d["data"], "watch: " + _line_clock(d))
    for d in mental.daily(d1, d2):
        fields = [
            f"{k} {d[k]}" for k in ("humor", "ansiedade", "gatilhos") if d.get(k) not in (None, "")
        ]
        add(d["data"], "journal: " + ", ".join(fields) if fields else "")
    for day, minutes in mental.focus(d1, d2)["minutos_por_dia"].items():
        add(day, f"focus {minutes} min")
    habits = mental.habits(d1, d2)
    for h in habits:
        for day in h["feitos"]:
            add(day, f"habit {'done' if h['tipo'] == 'construir' else 'relapse'}: {h['nome']}")
    workouts_day: dict[str, list[int]] = {}
    for i in workouts.agenda(d1, d2):
        workouts_day.setdefault(i["data"], [0, 0])
        workouts_day[i["data"]][0] += 1
        workouts_day[i["data"]][1] += 1 if i.get("feito") else 0
    for day, (total, done) in workouts_day.items():
        add(day, f"workout {done}/{total} exercises done")
    for s in Sessions(workouts).list_all(d1, d2):
        if (r := s.get("resumo")) is None:
            continue
        fc = s.get("frequencia") or {}
        add(s["data"], f"workout session {r['ativo_min']} min, {r['series_feitas']}/"
            f"{r['series_planejadas']} sets, volume {r['volume_kg']} kg"
            + (f", effort {s['esforco']}/10" if s.get("esforco") else "")
            + (f", average HR {fc['media']:.0f} max {fc['maxima']:.0f}"
               if fc.get("media") and fc.get("maxima") else ""))

    summary = clock.resumo(d1, d2)
    lines = [f"Period: {d1} to {d2} ({(ate - de).days + 1} days)", "", "# Watch averages"]
    lines += [f"- {LABELS.get(k, k)}: {v}" for k, v in sorted(summary["medias"].items())]
    lines += ["", "# Goals"]
    lines += [
        f"- {k}: {m['batidos']} of {m['dias']} days (goal {m['meta']})"
        for k, m in summary["metas"].items()
    ]
    if habits:
        lines += ["", "# Habits"]
        lines += [f"- {h['nome']} ({h['tipo']}), streak {h['sequencia']}" for h in habits]
    lines += ["", "# Day by day"]
    lines += [f"- {day}: " + "; ".join(by_day[day]) for day in sorted(by_day)]
    if extra:
        text = extra(de, ate).strip()
        if text:
            lines += ["", "# Other modules", text[:6000]]
    return "\n".join(lines)


async def analyze(
    llm: ChatLLM,
    clock: Clock,
    mental: Mental,
    workouts: Workouts,
    dias: int = 30,
    pergunta: str = "",
    extra: ContextExtra | None = None,
    hoje: date | None = None,
) -> dict[str, Any]:
    until = hoje or date.today()
    de = until - timedelta(days=dias - 1)
    context = assemble_context(clock, mental, workouts, de, until, extra)
    user = context + (f"\n\nThe user's question: {pergunta}" if pergunta.strip() else "")
    text = await llm(
        [{"role": "system", "content": SYSTEM}, {"role": "user", "content": user}]
    )
    return clock.store_analysis(
        {
            "criada_em": datetime.now(UTC).isoformat(timespec="seconds"),
            "de": de.isoformat(),
            "ate": until.isoformat(),
            "pergunta": pergunta.strip(),
            "texto": text.strip(),
        }
    )
