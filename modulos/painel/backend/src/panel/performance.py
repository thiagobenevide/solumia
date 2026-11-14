"""Performance on tasks and agenda over a window of days: what was finished, on time or not,
how long it took, adherence to the blocks and the most productive weekday. Serves
`/desempenho` and the agent (the LLM comments on the numbers, it does not make them up)."""

from datetime import date, datetime, timedelta
from typing import Any

from panel.nagger import Nagger, _min

DAYS_WEEK = ("segunda", "terça", "quarta", "quinta", "sexta", "sábado", "domingo")


def _day(iso: str | None) -> str:
    return (iso or "")[:10]


def _pct(part: int, total: int) -> int | None:
    return round(100 * part / total) if total else None


def analyze(
    tarefas: list[dict[str, Any]], nagger: Nagger, dias: int = 30, hoje: date | None = None
) -> dict[str, Any]:
    hoje = hoje or nagger.agora().date()
    dias = max(1, min(dias, 365))
    start = (hoje - timedelta(days=dias - 1)).isoformat()
    end = hoje.isoformat()

    finished = [t for t in tarefas if start <= _day(t.get("concluida_em")) <= end]
    created = [t for t in tarefas if start <= _day(t.get("criada_em")) <= end]
    with_deadline = [t for t in finished if t.get("prazo")]
    node_deadline = [t for t in with_deadline if _day(t["concluida_em"]) <= _day(t["prazo"])]
    opened = [t for t in tarefas if t.get("coluna") != "concluida"]
    atrasadas = [t for t in opened if t.get("prazo") and _day(t["prazo"]) < end]

    duracoes = []
    for t in finished:
        if t.get("criada_em"):
            delta = datetime.fromisoformat(t["concluida_em"]) - datetime.fromisoformat(
                t["criada_em"]
            )
            duracoes.append(delta.total_seconds() / 86400)

    by_prioridade = {}
    for p in ("alta", "media", "baixa"):
        done = sum(t.get("prioridade") == p for t in finished)
        pending = sum(t.get("prioridade") == p for t in opened)
        by_prioridade[p] = {"concluidas": done, "abertas": pending}

    # agenda: planned vs done blocks per day (today only counts what is already past, so what is
    # still to happen does not count as a miss)
    planejados = feitos = 0
    week = {d: [0, 0] for d in DAYS_WEEK}
    now = nagger.agora()
    minuto = now.hour * 60 + now.minute
    for i in range(dias):
        d = hoje - timedelta(days=i)
        blocks = nagger.agenda(d.isoformat())["blocos"]
        if d == now.date():
            blocks = [b for b in blocks if _min(b["fim"]) <= minuto]
        f = sum(bool(b.get("feito")) for b in blocks)
        planejados += len(blocks)
        feitos += f
        week[DAYS_WEEK[d.weekday()]][0] += len(blocks)
        week[DAYS_WEEK[d.weekday()]][1] += f
    aderencia_week = {d: _pct(f, p) for d, (p, f) in week.items() if p}

    return {
        "inicio": start,
        "fim": end,
        "dias": dias,
        "tarefas": {
            "criadas": len(created),
            "concluidas": len(finished),
            "por_dia": round(len(finished) / dias, 2),
            "no_prazo": len(node_deadline),
            "fora_do_prazo": len(with_deadline) - len(node_deadline),
            "pct_no_prazo": _pct(len(node_deadline), len(with_deadline)),
            "abertas": len(opened),
            "atrasadas": [{"titulo": t["titulo"], "prazo": _day(t["prazo"])} for t in atrasadas],
            "dias_ate_concluir": round(sum(duracoes) / len(duracoes), 1) if duracoes else None,
            "horas_registradas": round(
                sum(t.get("tempo_total", 0) for t in finished) / 3600, 1
            ),
            "por_prioridade": by_prioridade,
        },
        "agenda": {
            "planejados": planejados,
            "feitos": feitos,
            "aderencia": _pct(feitos, planejados),
            "por_dia_semana": aderencia_week,
            "melhor_dia": max(aderencia_week, key=aderencia_week.__getitem__, default=None),
            "pior_dia": min(aderencia_week, key=aderencia_week.__getitem__, default=None),
        },
        "metas": [
            {"titulo": m["titulo"], "feito": m["feito"], "esperado": m["esperado"]}
            for m in nagger.metas(hoje)
        ],
    }


def text(d: dict[str, Any]) -> str:
    """The analysis numbers as text for the prompt."""
    t, a = d["tarefas"], d["agenda"]
    lines = [
        f"## Performance from {d['inicio']} to {d['fim']} ({d['dias']} days)",
        f"- Tasks created: {t['criadas']}; done: {t['concluidas']} ({t['por_dia']}/day)",
        f"- With a deadline: {t['no_prazo']} on time, {t['fora_do_prazo']} late "
        f"({t['pct_no_prazo'] if t['pct_no_prazo'] is not None else '—'}% on time)",
        f"- Average time to finish: {t['dias_ate_concluir'] or '—'} days; "
        f"hours logged on the timer: {t['horas_registradas']}",
        f"- Open: {t['abertas']}; overdue: "
        + (", ".join(f"{x['titulo']} (deadline {x['prazo']})" for x in t["atrasadas"]) or "none"),
        "- By priority: "
        + "; ".join(
            f"{p}: {v['concluidas']} done, {v['abertas']} open"
            for p, v in t["por_prioridade"].items()
        ),
        f"- Agenda: {a['feitos']}/{a['planejados']} blocks fulfilled "
        f"({a['aderencia'] if a['aderencia'] is not None else '—'}%)",
    ]
    if a["por_dia_semana"]:
        lines.append(
            "- Adherence by weekday: "
            + ", ".join(f"{k} {v}%" for k, v in a["por_dia_semana"].items())
        )
    for m in d["metas"]:
        lines.append(f"- Goal {m['titulo']}: {m['feito']:g} of {m['esperado']:g} expected")
    return "\n".join(lines)
