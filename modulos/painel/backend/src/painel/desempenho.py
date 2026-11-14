"""Desempenho nas tarefas e na agenda numa janela de dias: o que foi concluído, no prazo ou não,
quanto tempo levou, aderência aos blocos e o dia da semana que rende mais. Serve ao
`/desempenho` e ao agente (o LLM comenta os números, não os inventa)."""

from datetime import date, datetime, timedelta
from typing import Any

from painel.cobrador import Cobrador, _min

DIAS_SEMANA = ("segunda", "terça", "quarta", "quinta", "sexta", "sábado", "domingo")


def _dia(iso: str | None) -> str:
    return (iso or "")[:10]


def _pct(parte: int, total: int) -> int | None:
    return round(100 * parte / total) if total else None


def analisar(
    tarefas: list[dict[str, Any]], cobrador: Cobrador, dias: int = 30, hoje: date | None = None
) -> dict[str, Any]:
    hoje = hoje or cobrador.agora().date()
    dias = max(1, min(dias, 365))
    inicio = (hoje - timedelta(days=dias - 1)).isoformat()
    fim = hoje.isoformat()

    concluidas = [t for t in tarefas if inicio <= _dia(t.get("concluida_em")) <= fim]
    criadas = [t for t in tarefas if inicio <= _dia(t.get("criada_em")) <= fim]
    com_prazo = [t for t in concluidas if t.get("prazo")]
    no_prazo = [t for t in com_prazo if _dia(t["concluida_em"]) <= _dia(t["prazo"])]
    abertas = [t for t in tarefas if t.get("coluna") != "concluida"]
    atrasadas = [t for t in abertas if t.get("prazo") and _dia(t["prazo"]) < fim]

    duracoes = []
    for t in concluidas:
        if t.get("criada_em"):
            delta = datetime.fromisoformat(t["concluida_em"]) - datetime.fromisoformat(
                t["criada_em"]
            )
            duracoes.append(delta.total_seconds() / 86400)

    por_prioridade = {}
    for p in ("alta", "media", "baixa"):
        feitas = sum(t.get("prioridade") == p for t in concluidas)
        pendentes = sum(t.get("prioridade") == p for t in abertas)
        por_prioridade[p] = {"concluidas": feitas, "abertas": pendentes}

    # agenda: blocos planejados x feitos por dia (hoje entra só com o que já venceu, para não
    # contar como falha o que ainda vai acontecer)
    planejados = feitos = 0
    semana = {d: [0, 0] for d in DIAS_SEMANA}
    agora = cobrador.agora()
    minuto = agora.hour * 60 + agora.minute
    for i in range(dias):
        d = hoje - timedelta(days=i)
        blocos = cobrador.agenda(d.isoformat())["blocos"]
        if d == agora.date():
            blocos = [b for b in blocos if _min(b["fim"]) <= minuto]
        f = sum(bool(b.get("feito")) for b in blocos)
        planejados += len(blocos)
        feitos += f
        semana[DIAS_SEMANA[d.weekday()]][0] += len(blocos)
        semana[DIAS_SEMANA[d.weekday()]][1] += f
    aderencia_semana = {d: _pct(f, p) for d, (p, f) in semana.items() if p}

    return {
        "inicio": inicio,
        "fim": fim,
        "dias": dias,
        "tarefas": {
            "criadas": len(criadas),
            "concluidas": len(concluidas),
            "por_dia": round(len(concluidas) / dias, 2),
            "no_prazo": len(no_prazo),
            "fora_do_prazo": len(com_prazo) - len(no_prazo),
            "pct_no_prazo": _pct(len(no_prazo), len(com_prazo)),
            "abertas": len(abertas),
            "atrasadas": [{"titulo": t["titulo"], "prazo": _dia(t["prazo"])} for t in atrasadas],
            "dias_ate_concluir": round(sum(duracoes) / len(duracoes), 1) if duracoes else None,
            "horas_registradas": round(
                sum(t.get("tempo_total", 0) for t in concluidas) / 3600, 1
            ),
            "por_prioridade": por_prioridade,
        },
        "agenda": {
            "planejados": planejados,
            "feitos": feitos,
            "aderencia": _pct(feitos, planejados),
            "por_dia_semana": aderencia_semana,
            "melhor_dia": max(aderencia_semana, key=aderencia_semana.__getitem__, default=None),
            "pior_dia": min(aderencia_semana, key=aderencia_semana.__getitem__, default=None),
        },
        "metas": [
            {"titulo": m["titulo"], "feito": m["feito"], "esperado": m["esperado"]}
            for m in cobrador.metas(hoje)
        ],
    }


def texto(d: dict[str, Any]) -> str:
    """Os números da análise em texto para o prompt."""
    t, a = d["tarefas"], d["agenda"]
    linhas = [
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
        linhas.append(
            "- Aderência por dia da semana: "
            + ", ".join(f"{k} {v}%" for k, v in a["por_dia_semana"].items())
        )
    for m in d["metas"]:
        linhas.append(f"- Meta {m['titulo']}: {m['feito']:g} de {m['esperado']:g} esperados")
    return "\n".join(linhas)
