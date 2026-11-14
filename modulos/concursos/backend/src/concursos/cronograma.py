"""Calendário de tarefas a partir da estrutura do edital (disciplinas → tópicos em ordem).

Fases, de [inicio] até a prova:
1. Conteúdo (até 7 dias antes da prova): blocos de teoria + questões, intercalando as disciplinas
   para que todas avancem no mesmo ritmo; os tópicos de cada uma seguem a ordem do fluxo. Ocupa no
   máximo 80% do tempo livre: se o edital pede mais horas que isso, as horas de cada tópico são
   comprimidas na mesma proporção (`fator` < 1).
2. Revisão e questões: o que sobra até 7 dias antes, com as disciplinas que mais pesam na prova
   aparecendo mais vezes.
3. Semana final: só revisão leve dos resumos e a véspera.
Fixos da semana: sábado (a partir da 2ª semana) treino de discursiva; domingo revisão dos tópicos
da semana, trocada por simulado a cada duas semanas a partir da 3ª."""

import uuid
from datetime import date, timedelta
from typing import Any

BLOCO_MAX = 90
BLOCO_MIN = 30
DIAS_SEMANA_FINAL = 7


def _id() -> str:
    return uuid.uuid4().hex[:10]


def _tarefa(
    dia: date, tipo: str, titulo: str, minutos: int, disciplina: str = "", **extra: Any
) -> dict[str, Any]:
    return {
        "id": _id(),
        "data": dia.isoformat(),
        "tipo": tipo,
        "disciplina": disciplina,
        "titulo": titulo,
        "minutos": int(minutos),
        "feito": False,
        **extra,
    }


def _blocos(
    estrutura: dict[str, Any], fator: float, feitas: set[str]
) -> dict[str, list[dict[str, Any]]]:
    """Blocos de conteúdo por disciplina, na ordem dos tópicos, sem os de [feitas] (chaves)."""
    filas: dict[str, list[dict[str, Any]]] = {}
    for d in estrutura.get("disciplinas", []):
        fila = []
        for t in d.get("topicos", []):
            total = max(BLOCO_MIN, round(float(t.get("horas") or 1) * 60 * fator / 15) * 15)
            partes = -(-total // BLOCO_MAX)
            for i in range(partes):
                chave = f"{d['nome']}|{t['titulo']}|{i}"
                if chave in feitas:
                    continue
                sufixo = f" ({i + 1}/{partes})" if partes > 1 else ""
                fila.append(
                    {
                        "chave": chave,
                        "topico": t["titulo"],
                        "titulo": t["titulo"] + sufixo,
                        "detalhe": t.get("conteudo", ""),
                        "minutos": min(BLOCO_MAX, total - i * BLOCO_MAX),
                        "ultimo": i == partes - 1,
                    }
                )
        if fila:
            filas[d["nome"]] = fila
    return filas


def gerar(
    estrutura: dict[str, Any],
    inicio: date,
    data_prova: date,
    minutos_util: int,
    minutos_fds: int,
    feitas: set[str] | None = None,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Devolve (tarefas, resumo). [feitas]: chaves dos blocos já concluídos (replanejar)."""
    feitas = feitas or set()
    fim_conteudo = data_prova - timedelta(days=DIAS_SEMANA_FINAL)
    dias = [inicio + timedelta(n) for n in range(max(0, (fim_conteudo - inicio).days + 1))]
    tem_discursiva = bool(estrutura.get("discursiva", {}).get("descricao"))
    disciplinas = estrutura.get("disciplinas", [])
    peso = {d["nome"]: max(1, int(d.get("questoes") or 1)) for d in disciplinas}

    def capacidade(d: date) -> int:
        return minutos_fds if d.weekday() >= 5 else minutos_util

    # fixos da semana (semana 0 = a que contém [inicio])
    fixos: dict[date, list[dict[str, Any]]] = {}
    for d in dias:
        semana = (d - (inicio - timedelta(inicio.weekday()))).days // 7
        cap = capacidade(d)
        if d.weekday() == 5 and semana >= 1 and tem_discursiva:
            fixos[d] = [
                _tarefa(
                    d,
                    "discursiva",
                    "Treino de discursiva: escrever 1 resposta de 30 linhas e corrigir",
                    min(60, cap),
                )
            ]
        if d.weekday() == 6:
            if semana >= 2 and semana % 2 == 0:
                fixos[d] = [
                    _tarefa(
                        d,
                        "simulado",
                        "Simulado no estilo da banca (cronometrado) e análise dos erros",
                        min(cap, 180),
                    )
                ]
            else:
                fixos[d] = [_tarefa(d, "revisao", "Revisão da semana", min(60, cap))]

    livre = {d: capacidade(d) - sum(t["minutos"] for t in fixos.get(d, [])) for d in dias}
    total_livre = sum(livre.values())
    pedidos = sum(
        max(BLOCO_MIN, round(float(t.get("horas") or 1) * 60 / 15) * 15)
        for d in disciplinas
        for t in d.get("topicos", [])
    )
    fator = min(1.0, 0.8 * total_livre / pedidos) if pedidos else 1.0
    filas = _blocos(estrutura, fator, feitas)
    total_disc = {n: sum(b["minutos"] for b in f) for n, f in filas.items()}
    feito_disc = dict.fromkeys(filas, 0)

    tarefas: list[dict[str, Any]] = []
    fim_fase_conteudo: date | None = None
    vistos_semana: list[str] = []
    rodizio = 0
    # rodízio ponderado e intercalado: disciplina com 10 questões aparece 2× mais que uma com 5
    ordem_revisao = [n for _, n in sorted((k / peso[n], n) for n in peso for k in range(peso[n]))]
    for d in dias:
        resta = livre[d]
        hoje: list[dict[str, Any]] = []
        usadas: set[str] = set()
        while resta >= BLOCO_MIN and any(filas.values()):
            # disciplina mais atrasada em proporção, preferindo uma ainda não vista hoje
            candidatas = [n for n, f in filas.items() if f]
            n = min(candidatas, key=lambda x: (x in usadas, feito_disc[x] / total_disc[x]))
            bloco = filas[n][0]
            minutos = min(bloco["minutos"], resta)
            if minutos < bloco["minutos"]:
                # bloco não cabe: parte hoje, o resto fica para o próximo dia
                bloco["minutos"] -= minutos
                parcial = True
            else:
                filas[n].pop(0)
                parcial = False
            hoje.append(
                _tarefa(
                    d,
                    "conteudo",
                    f"Teoria + questões: {bloco['titulo']}",
                    minutos,
                    n,
                    detalhe=bloco["detalhe"],
                    chave=None if parcial else bloco["chave"],
                )
            )
            if not parcial and bloco["ultimo"]:
                vistos_semana.append(bloco["topico"])
            feito_disc[n] += minutos
            usadas.add(n)
            resta -= minutos
            if not any(filas.values()):
                fim_fase_conteudo = d
        # fase de revisão: depois que o conteúdo acabou, o tempo livre vira revisão + questões
        while resta >= BLOCO_MIN and not any(filas.values()) and ordem_revisao:
            n = ordem_revisao[rodizio % len(ordem_revisao)]
            rodizio += 1
            minutos = min(60, resta)
            hoje.append(_tarefa(d, "revisao", f"Revisão + bateria de questões: {n}", minutos, n))
            resta -= minutos
        for t in fixos.get(d, []):
            if t["titulo"] == "Revisão da semana" and vistos_semana:
                t["detalhe"] = "Tópicos concluídos: " + "; ".join(vistos_semana)
            hoje.append(t)
        if d.weekday() == 6:
            vistos_semana = []
        tarefas += hoje

    # semana final: revisão leve, sem conteúdo novo
    nomes = [d["nome"] for d in sorted(disciplinas, key=lambda x: -int(x.get("questoes") or 0))]
    for i in range(1, DIAS_SEMANA_FINAL):
        d = fim_conteudo + timedelta(i)
        if d < inicio:
            continue
        if d == data_prova - timedelta(1):
            tarefas.append(
                _tarefa(
                    d,
                    "final",
                    "Véspera: separar documento com foto e caneta transparente, conferir o local, "
                    "dormir cedo",
                    30,
                )
            )
        elif nomes:
            n = nomes[(i - 1) % len(nomes)]
            tarefas.append(
                _tarefa(d, "final", f"Revisão leve dos resumos: {n}", min(60, capacidade(d)), n)
            )

    resumo = {
        "fator": round(fator, 2),
        "horas_pedidas": round(pedidos / 60, 1),
        "horas_livres": round(total_livre / 60, 1),
        "fim_conteudo": fim_fase_conteudo.isoformat() if fim_fase_conteudo else None,
        "fim_estudo": fim_conteudo.isoformat(),
        "conteudo_pendente": sum(len(f) for f in filas.values()),
    }
    return tarefas, resumo
