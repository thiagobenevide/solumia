"""Inferência sem fine-tuning (linha de base da F6): esquema N1 forçado + 3–5 exemplos aprovados parecidos.

Os exemplos vêm do registro (uso `sft`, fora do ouro), ordenados pela semelhança do contexto (embeddings na :8082);
sem o servidor de embeddings, os mais recentes. O mesmo prompt é o que a exportação ensina, então a diferença entre
a bancada sem treino e com o adaptador mede só o fine-tuning.
"""
import json

from esteira.dataset import export as X
from esteira.dataset import registry as R


def _summary(cx: dict) -> str:
    return json.dumps(cx, ensure_ascii=False)[:2000]


def examples(task: str, context: dict, k: int = 3, outside: set[str] = frozenset()) -> list[tuple[dict, object]]:
    pairs = [(r, cx, resp) for r, cx, resp in X._pairs(task) if r["id"] not in outside]
    if not pairs:
        return []
    try:
        from esteira.ai import embeddings
        if not embeddings.available():
            raise RuntimeError
        target, *vs = embeddings.vectors([_summary(context)] + [_summary(cx) for _, cx, _ in pairs])
        order = sorted(range(len(pairs)), key=lambda i: -embeddings.cosine(target, vs[i]))
    except Exception:  # noqa: BLE001 — sem embeddings: os mais recentes
        order = list(range(len(pairs)))[::-1]
    chosen = []
    for i in order[:k]:
        _, cx, resp = pairs[i]
        chosen.append((cx, resp))
    return chosen


def prompt(task: str, context: dict, k: int = 3, outside: set[str] = frozenset()) -> str:
    return X.prompt(task, context, examples(task, context, k, outside))


def generate(task: str, context: dict, model: str | None = None, k: int = 3):
    """Uma resposta do modelo local, validada pelo esquema N1 da tarefa (ou None)."""
    from esteira.dataset import app_training
    from esteira.ai import local
    esq = X.schema(task)
    app = R.TASKS[task]
    model = model or app_training.promoted(app)  # o adaptador promovido da app, se houver
    kw = {"modelo": model} if model else {}
    return local.ask(prompt(task, context, k, outside=X.gold(task)), esq, temperature=0.2, max_tokens=6000,
                           operation=f"n1_{task}", **kw)
