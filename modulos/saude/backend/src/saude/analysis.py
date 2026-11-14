"""Análise de saúde pela LLM local (nunca por serviço externo: são dados pessoais).

Junta, por dia, os dados do relógio com o diário de humor/ansiedade, foco, hábitos e treinos, mais o
contexto que a plataforma fornece dos outros módulos (finanças, rotinas, estudos), e pede ao modelo
uma leitura com recomendações práticas.
"""

from collections.abc import Awaitable, Callable
from datetime import UTC, date, datetime, timedelta
from typing import Any

from saude.mental import Mental
from saude.watch import Relogio
from saude.sessions import Sessoes
from saude.workouts import Treinos

ChatLLM = Callable[[list[dict[str, str]]], Awaitable[str]]
# (de, ate) -> texto com o que os outros módulos registraram no período
ContextoExtra = Callable[[date, date], str]

SISTEMA = """Você é um acompanhante de saúde pessoal: sono, atividade física, coração, corpo e
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

ROTULOS = {
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


def _horas(minutos: float) -> str:
    return f"{int(minutos // 60)}h{int(minutos % 60):02d}"


def _linha_relogio(d: dict[str, Any]) -> str:
    partes = []
    for k, rotulo in ROTULOS.items():
        if k not in d:
            continue
        v = d[k]
        texto = _horas(v) if k.startswith("sono") and k.endswith("_min") else v
        partes.append(f"{rotulo} {texto}")
    for e in d.get("exercicios", []):
        partes.append(f"exercício {e.get('tipo')} {e.get('minutos')} min")
    return ", ".join(partes)


def montar_contexto(
    relogio: Relogio,
    mental: Mental,
    treinos: Treinos,
    de: date,
    ate: date,
    extra: ContextoExtra | None = None,
) -> str:
    d1, d2 = de.isoformat(), ate.isoformat()
    por_dia: dict[str, list[str]] = {}

    def add(dia: str, texto: str) -> None:
        if texto:
            por_dia.setdefault(dia, []).append(texto)

    for d in relogio.dias(d1, d2):
        add(d["data"], "relógio: " + _linha_relogio(d))
    for d in mental.diario(d1, d2):
        campos = [
            f"{k} {d[k]}" for k in ("humor", "ansiedade", "gatilhos") if d.get(k) not in (None, "")
        ]
        add(d["data"], "diário: " + ", ".join(campos) if campos else "")
    for dia, minutos in mental.foco(d1, d2)["minutos_por_dia"].items():
        add(dia, f"foco {minutos} min")
    habitos = mental.habitos(d1, d2)
    for h in habitos:
        for dia in h["feitos"]:
            add(dia, f"hábito {'feito' if h['tipo'] == 'construir' else 'recaída'}: {h['nome']}")
    treinos_dia: dict[str, list[int]] = {}
    for i in treinos.agenda(d1, d2):
        treinos_dia.setdefault(i["data"], [0, 0])
        treinos_dia[i["data"]][0] += 1
        treinos_dia[i["data"]][1] += 1 if i.get("feito") else 0
    for dia, (total, feitos) in treinos_dia.items():
        add(dia, f"treino {feitos}/{total} exercícios feitos")
    for s in Sessoes(treinos).listar(d1, d2):
        if (r := s.get("resumo")) is None:
            continue
        fc = s.get("frequencia") or {}
        add(s["data"], f"sessão de treino {r['ativo_min']} min, {r['series_feitas']}/"
            f"{r['series_planejadas']} séries, volume {r['volume_kg']} kg"
            + (f", esforço {s['esforco']}/10" if s.get("esforco") else "")
            + (f", FC média {fc['media']:.0f} máx {fc['maxima']:.0f}"
               if fc.get("media") and fc.get("maxima") else ""))

    resumo = relogio.resumo(d1, d2)
    linhas = [f"Período: {d1} a {d2} ({(ate - de).days + 1} dias)", "", "# Médias do relógio"]
    linhas += [f"- {ROTULOS.get(k, k)}: {v}" for k, v in sorted(resumo["medias"].items())]
    linhas += ["", "# Metas"]
    linhas += [
        f"- {k}: {m['batidos']} de {m['dias']} dias (meta {m['meta']})"
        for k, m in resumo["metas"].items()
    ]
    if habitos:
        linhas += ["", "# Hábitos"]
        linhas += [f"- {h['nome']} ({h['tipo']}), sequência {h['sequencia']}" for h in habitos]
    linhas += ["", "# Dia a dia"]
    linhas += [f"- {dia}: " + "; ".join(por_dia[dia]) for dia in sorted(por_dia)]
    if extra:
        texto = extra(de, ate).strip()
        if texto:
            linhas += ["", "# Outros módulos", texto[:6000]]
    return "\n".join(linhas)


async def analisar(
    llm: ChatLLM,
    relogio: Relogio,
    mental: Mental,
    treinos: Treinos,
    dias: int = 30,
    pergunta: str = "",
    extra: ContextoExtra | None = None,
    hoje: date | None = None,
) -> dict[str, Any]:
    ate = hoje or date.today()
    de = ate - timedelta(days=dias - 1)
    contexto = montar_contexto(relogio, mental, treinos, de, ate, extra)
    usuario = contexto + (f"\n\nPergunta do usuário: {pergunta}" if pergunta.strip() else "")
    texto = await llm(
        [{"role": "system", "content": SISTEMA}, {"role": "user", "content": usuario}]
    )
    return relogio.guardar_analise(
        {
            "criada_em": datetime.now(UTC).isoformat(timespec="seconds"),
            "de": de.isoformat(),
            "ate": ate.isoformat(),
            "pergunta": pergunta.strip(),
            "texto": texto.strip(),
        }
    )
