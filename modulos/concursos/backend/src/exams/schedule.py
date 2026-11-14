"""Task calendar from the notice structure (subjects → topics in order).

Phases, from the start date to the exam:
1. Content (until 7 days before the exam): theory + question blocks, interleaving the subjects
   so all of them advance at the same pace; each subject's topics follow the flow order. Takes at
   most 80% of the free time: if the notice asks for more hours than that, each topic's hours are
   compressed by the same ratio (`fator` < 1).
2. Review and questions: what is left until 7 days before, with the subjects that weigh more on the
   exam showing up more often.
3. Final week: only light review of the summaries and the day before.
Weekly fixed slots: Saturday (from the 2nd week on) essay practice; Sunday review of the week's
topics, replaced by a mock exam every two weeks from the 3rd on."""

import uuid
from datetime import date, timedelta
from typing import Any

BLOCK_MAX = 90
BLOCK_MIN = 30
DAYS_WEEK_FINAL = 7


def _id() -> str:
    return uuid.uuid4().hex[:10]


def _task(
    day: date, tipo: str, titulo: str, minutos: int, subject: str = "", **extra: Any
) -> dict[str, Any]:
    return {
        "id": _id(),
        "data": day.isoformat(),
        "tipo": tipo,
        "disciplina": subject,
        "titulo": titulo,
        "minutos": int(minutos),
        "feito": False,
        **extra,
    }


def _blocks(
    structure: dict[str, Any], factor: float, done: set[str]
) -> dict[str, list[dict[str, Any]]]:
    """Content blocks per subject, in topic order, without the done ones (keys)."""
    queues: dict[str, list[dict[str, Any]]] = {}
    for d in structure.get("disciplinas", []):
        queue = []
        for t in d.get("topicos", []):
            total = max(BLOCK_MIN, round(float(t.get("horas") or 1) * 60 * factor / 15) * 15)
            parts = -(-total // BLOCK_MAX)
            for i in range(parts):
                key = f"{d['nome']}|{t['titulo']}|{i}"
                if key in done:
                    continue
                suffix = f" ({i + 1}/{parts})" if parts > 1 else ""
                queue.append(
                    {
                        "chave": key,
                        "topico": t["titulo"],
                        "titulo": t["titulo"] + suffix,
                        "detalhe": t.get("conteudo", ""),
                        "minutos": min(BLOCK_MAX, total - i * BLOCK_MAX),
                        "ultimo": i == parts - 1,
                    }
                )
        if queue:
            queues[d["nome"]] = queue
    return queues


def generate(
    structure: dict[str, Any],
    inicio: date,
    data_prova: date,
    minutes_util: int,
    minutes_fds: int,
    done: set[str] | None = None,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Returns (tasks, summary). Done: keys of the blocks already finished (replanning)."""
    done = done or set()
    end_content = data_prova - timedelta(days=DAYS_WEEK_FINAL)
    days = [inicio + timedelta(n) for n in range(max(0, (end_content - inicio).days + 1))]
    has_discursiva = bool(structure.get("discursiva", {}).get("descricao"))
    disciplinas = structure.get("disciplinas", [])
    weight = {d["nome"]: max(1, int(d.get("questoes") or 1)) for d in disciplinas}

    def capacidade(d: date) -> int:
        return minutes_fds if d.weekday() >= 5 else minutes_util

    # weekly fixed slots (week 0 = the one containing the start date)
    fixed: dict[date, list[dict[str, Any]]] = {}
    for d in days:
        week = (d - (inicio - timedelta(inicio.weekday()))).days // 7
        cap = capacidade(d)
        if d.weekday() == 5 and week >= 1 and has_discursiva:
            fixed[d] = [
                _task(
                    d,
                    "discursiva",
                    "Treino de discursiva: escrever 1 resposta de 30 linhas e corrigir",
                    min(60, cap),
                )
            ]
        if d.weekday() == 6:
            if week >= 2 and week % 2 == 0:
                fixed[d] = [
                    _task(
                        d,
                        "simulado",
                        "Simulado no estilo da banca (cronometrado) e análise dos erros",
                        min(cap, 180),
                    )
                ]
            else:
                fixed[d] = [_task(d, "revisao", "Revisão da semana", min(60, cap))]

    free = {d: capacidade(d) - sum(t["minutos"] for t in fixed.get(d, [])) for d in days}
    total_free = sum(free.values())
    requests = sum(
        max(BLOCK_MIN, round(float(t.get("horas") or 1) * 60 / 15) * 15)
        for d in disciplinas
        for t in d.get("topicos", [])
    )
    factor = min(1.0, 0.8 * total_free / requests) if requests else 1.0
    queues = _blocks(structure, factor, done)
    total_disc = {n: sum(b["minutos"] for b in f) for n, f in queues.items()}
    done_disc = dict.fromkeys(queues, 0)

    tasks: list[dict[str, Any]] = []
    end_fase_content: date | None = None
    seen_week: list[str] = []
    rodizio = 0
    # weighted, interleaved rotation: a subject with 10 questions shows up 2× more than one with 5
    slots = sorted((k / weight[n], n) for n in weight for k in range(weight[n]))
    order_review = [n for _, n in slots]
    for d in days:
        resta = free[d]
        today: list[dict[str, Any]] = []
        used: set[str] = set()
        while resta >= BLOCK_MIN and any(queues.values()):
            # the subject most behind proportionally, preferring one not seen today yet
            candidates = [n for n, f in queues.items() if f]
            n = min(candidates, key=lambda x: (x in used, done_disc[x] / total_disc[x]))
            block = queues[n][0]
            minutes = min(block["minutos"], resta)
            if minutes < block["minutos"]:
                # the block does not fit: part today, the rest goes to the next day
                block["minutos"] -= minutes
                partial = True
            else:
                queues[n].pop(0)
                partial = False
            today.append(
                _task(
                    d,
                    "conteudo",
                    f"Teoria + questões: {block['titulo']}",
                    minutes,
                    n,
                    detalhe=block["detalhe"],
                    chave=None if partial else block["chave"],
                )
            )
            if not partial and block["ultimo"]:
                seen_week.append(block["topico"])
            done_disc[n] += minutes
            used.add(n)
            resta -= minutes
            if not any(queues.values()):
                end_fase_content = d
        # review phase: once the content is over, free time becomes review + questions
        while resta >= BLOCK_MIN and not any(queues.values()) and order_review:
            n = order_review[rodizio % len(order_review)]
            rodizio += 1
            minutes = min(60, resta)
            today.append(_task(d, "revisao", f"Revisão + bateria de questões: {n}", minutes, n))
            resta -= minutes
        for t in fixed.get(d, []):
            if t["titulo"] == "Revisão da semana" and seen_week:
                t["detalhe"] = "Tópicos concluídos: " + "; ".join(seen_week)
            today.append(t)
        if d.weekday() == 6:
            seen_week = []
        tasks += today

    # final week: light review, no new content
    names = [d["nome"] for d in sorted(disciplinas, key=lambda x: -int(x.get("questoes") or 0))]
    for i in range(1, DAYS_WEEK_FINAL):
        d = end_content + timedelta(i)
        if d < inicio:
            continue
        if d == data_prova - timedelta(1):
            tasks.append(
                _task(
                    d,
                    "final",
                    "Véspera: separar documento com foto e caneta transparente, conferir o local, "
                    "dormir cedo",
                    30,
                )
            )
        elif names:
            n = names[(i - 1) % len(names)]
            tasks.append(
                _task(d, "final", f"Revisão leve dos resumos: {n}", min(60, capacidade(d)), n)
            )

    summary = {
        "fator": round(factor, 2),
        "horas_pedidas": round(requests / 60, 1),
        "horas_livres": round(total_free / 60, 1),
        "fim_conteudo": end_fase_content.isoformat() if end_fase_content else None,
        "fim_estudo": end_content.isoformat(),
        "conteudo_pendente": sum(len(f) for f in queues.values()),
    }
    return tasks, summary
