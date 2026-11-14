"""Análise de saúde pela LLM local (nunca por serviço externo: são dados pessoais).

Junta, por dia, os dados do relógio com o diário de humor/ansiedade, foco, hábitos e treinos, mais o
contexto que a plataforma fornece dos outros módulos (finanças, rotinas, estudos), e pede ao modelo
uma leitura com recomendações práticas.
"""

from collections.abc import Awaitable, Callable
from datetime import UTC, date, datetime, timedelta
from typing import Any

from saude.mental import Mental
from saude.watch import Clock
from saude.sessions import Sessions
from saude.workouts import Workouts

ChatLLM = Callable[[list[dict[str, str]]], Awaitable[str]]
# (de, ate) -> texto com o que os outros módulos registraram no período
ContextExtra = Callable[[date, date], str]

SYSTEM = """Você é um acompanhante de saúde pessoal: sono, atividade física, coração, corpo e
saúde mental. Recebe os dados diários do relógio (Galaxy Watch) e os registros do próprio usuário.
Responda em português do Brasil, em Markdown, direto e acolhedor, sem diagnóstico médico.
Estrutura:
## Resumo do período
## O que está bom
## Pontos de atenção
(cite números: médias, dias abaixo da meta, tendência da primeira para a segunda metade)
## Relações encontradas
(cruze sono, passos, estresse e FC com humor, ansiedade, foco, treinos, gastos e rotina;
diga só o que os dados sustentam e o tamanho da amostra)
## Plano para os próximos 7 dias
(3 a 5 ações concretas, com horário ou quantidade: hora de dormir, caminhada, descanso, treino)
Metas de referência: sono 7–9 h, 8000 passos, 30 min ativos, 2 L de água.
Se faltarem dados, diga quais e como registrá-los."""

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
        add(d["data"], "relógio: " + _line_clock(d))
    for d in mental.diario(d1, d2):
        fields = [
            f"{k} {d[k]}" for k in ("humor", "ansiedade", "gatilhos") if d.get(k) not in (None, "")
        ]
        add(d["data"], "diário: " + ", ".join(fields) if fields else "")
    for day, minutes in mental.foco(d1, d2)["minutos_por_dia"].items():
        add(day, f"foco {minutes} min")
    habits = mental.habitos(d1, d2)
    for h in habits:
        for day in h["feitos"]:
            add(day, f"hábito {'feito' if h['tipo'] == 'construir' else 'recaída'}: {h['nome']}")
    workouts_day: dict[str, list[int]] = {}
    for i in workouts.agenda(d1, d2):
        workouts_day.setdefault(i["data"], [0, 0])
        workouts_day[i["data"]][0] += 1
        workouts_day[i["data"]][1] += 1 if i.get("feito") else 0
    for day, (total, done) in workouts_day.items():
        add(day, f"treino {done}/{total} exercícios feitos")
    for s in Sessions(workouts).listar(d1, d2):
        if (r := s.get("resumo")) is None:
            continue
        fc = s.get("frequencia") or {}
        add(s["data"], f"sessão de treino {r['ativo_min']} min, {r['series_feitas']}/"
            f"{r['series_planejadas']} séries, volume {r['volume_kg']} kg"
            + (f", esforço {s['esforco']}/10" if s.get("esforco") else "")
            + (f", FC média {fc['media']:.0f} máx {fc['maxima']:.0f}"
               if fc.get("media") and fc.get("maxima") else ""))

    summary = clock.resumo(d1, d2)
    lines = [f"Período: {d1} a {d2} ({(ate - de).days + 1} dias)", "", "# Médias do relógio"]
    lines += [f"- {LABELS.get(k, k)}: {v}" for k, v in sorted(summary["medias"].items())]
    lines += ["", "# Metas"]
    lines += [
        f"- {k}: {m['batidos']} de {m['dias']} dias (meta {m['meta']})"
        for k, m in summary["metas"].items()
    ]
    if habits:
        lines += ["", "# Hábitos"]
        lines += [f"- {h['nome']} ({h['tipo']}), sequência {h['sequencia']}" for h in habits]
    lines += ["", "# Dia a dia"]
    lines += [f"- {day}: " + "; ".join(by_day[day]) for day in sorted(by_day)]
    if extra:
        text = extra(de, ate).strip()
        if text:
            lines += ["", "# Outros módulos", text[:6000]]
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
    user = context + (f"\n\nPergunta do usuário: {pergunta}" if pergunta.strip() else "")
    text = await llm(
        [{"role": "system", "content": SYSTEM}, {"role": "user", "content": user}]
    )
    return clock.guardar_analise(
        {
            "criada_em": datetime.now(UTC).isoformat(timespec="seconds"),
            "de": de.isoformat(),
            "ate": until.isoformat(),
            "pergunta": pergunta.strip(),
            "texto": text.strip(),
        }
    )
