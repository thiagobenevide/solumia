"""Desempenho nas tarefas e na agenda numa janela de dias: o que foi concluído, no prazo ou não,
quanto tempo levou, aderência aos blocos e o dia da semana que rende mais. Serve ao
`/desempenho` e ao agente (o LLM comenta os números, não os inventa)."""

from datetime import date, datetime, timedelta
from typing import Any

from painel.nagger import Nagger, _min

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
    criadas = [t for t in tarefas if start <= _day(t.get("criada_em")) <= end]
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

    # agenda: blocos planejados x feitos por dia (hoje entra só com o que já venceu, para não
    # contar como falha o que ainda vai acontecer)
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
            "criadas": len(criadas),
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
    """Os números da análise em texto para o prompt."""
    t, a = d["tarefas"], d["agenda"]
    lines = [
        f"## Desempenho de {d['inicio']} a {d['fim']} ({d['dias']} dias)",
        f"- Tarefas criadas: {t['criadas']}; concluídas: {t['concluidas']} ({t['por_dia']}/dia)",
        f"- Com prazo: {t['no_prazo']} no prazo, {t['fora_do_prazo']} fora "
        f"({t['pct_no_prazo'] if t['pct_no_prazo'] is not None else '—'}% no prazo)",
        f"- Tempo médio até concluir: {t['dias_ate_concluir'] or '—'} dias; "
        f"horas registradas no temporizador: {t['horas_registradas']}",
        f"- Abertas: {t['abertas']}; atrasadas: "
        + (", ".join(f"{x['titulo']} (prazo {x['prazo']})" for x in t["atrasadas"]) or "nenhuma"),
        "- Por prioridade: "
        + "; ".join(
            f"{p}: {v['concluidas']} concluídas, {v['abertas']} abertas"
            for p, v in t["por_prioridade"].items()
        ),
        f"- Agenda: {a['feitos']}/{a['planejados']} blocos cumpridos "
        f"({a['aderencia'] if a['aderencia'] is not None else '—'}%)",
    ]
    if a["por_dia_semana"]:
        lines.append(
            "- Aderência por dia da semana: "
            + ", ".join(f"{k} {v}%" for k, v in a["por_dia_semana"].items())
        )
    for m in d["metas"]:
        lines.append(f"- Meta {m['titulo']}: {m['feito']:g} de {m['esperado']:g} esperados")
    return "\n".join(lines)
