"""Inferência sem fine-tuning (linha de base da F6): esquema N1 forçado + 3–5 exemplos aprovados parecidos.

Os exemplos vêm do registro (uso `sft`, fora do ouro), ordenados pela semelhança do contexto (embeddings na :8082);
sem o servidor de embeddings, os mais recentes. O mesmo prompt é o que a exportação ensina, então a diferença entre
a bancada sem treino e com o adaptador mede só o fine-tuning.
"""
import json

from esteira.dataset import exportar as X
from esteira.dataset import registro as R


def _resumo(cx: dict) -> str:
    return json.dumps(cx, ensure_ascii=False)[:2000]


def exemplos(tarefa: str, contexto: dict, k: int = 3, fora: set[str] = frozenset()) -> list[tuple[dict, object]]:
    pares = [(r, cx, resp) for r, cx, resp in X._pares(tarefa) if r["id"] not in fora]
    if not pares:
        return []
    try:
        from esteira.ia import embeddings
        if not embeddings.disponivel():
            raise RuntimeError
        alvo, *vs = embeddings.vetores([_resumo(contexto)] + [_resumo(cx) for _, cx, _ in pares])
        ordem = sorted(range(len(pares)), key=lambda i: -embeddings.cosseno(alvo, vs[i]))
    except Exception:  # noqa: BLE001 — sem embeddings: os mais recentes
        ordem = list(range(len(pares)))[::-1]
    escolhidos = []
    for i in ordem[:k]:
        _, cx, resp = pares[i]
        escolhidos.append((cx, resp))
    return escolhidos


def prompt(tarefa: str, contexto: dict, k: int = 3, fora: set[str] = frozenset()) -> str:
    return X.prompt(tarefa, contexto, exemplos(tarefa, contexto, k, fora))


def gerar(tarefa: str, contexto: dict, modelo: str | None = None, k: int = 3):
    """Uma resposta do modelo local, validada pelo esquema N1 da tarefa (ou None)."""
    from esteira.dataset import treino_app
    from esteira.ia import local
    esq = X.esquema(tarefa)
    app = R.TAREFAS[tarefa]
    modelo = modelo or treino_app.promovido(app)  # o adaptador promovido da app, se houver
    kw = {"modelo": modelo} if modelo else {}
    return local.perguntar(prompt(tarefa, contexto, k, fora=X.ouro(tarefa)), esq, temperatura=0.2, max_tokens=6000,
                           operacao=f"n1_{tarefa}", **kw)
