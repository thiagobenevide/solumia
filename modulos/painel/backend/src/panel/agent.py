"""The Nagger as an agent: besides answering, the LLM can request actions in an ```acoes``` block
(JSON list) at the end of the answer. The server runs them, strips the block from the text and
returns what was done.

Works the same for the local LLM and for Claude, without depending on provider tool calling."""

import json
import re
import unicodedata
from collections.abc import Awaitable, Callable
from typing import TYPE_CHECKING, Any

from panel.nagger import Invalid, Nagger, NotFound

if TYPE_CHECKING:
    from panel.api import Sources

INSTRUCTIONS = """
## Actions
You can act, not only talk. When the user asks for (or agrees to) a change, end the answer with a
block like this, with only the actions needed:
```acoes
[{"tipo": "criar_tarefa", "titulo": "...", "prioridade": "alta|media|baixa", "prazo": "YYYY-MM-DD"},
 {"tipo": "adicionar_bloco", "titulo": "...", "inicio": "HH:MM", "fim": "HH:MM",
  "prioridade": "alta"},
 {"tipo": "mover_bloco", "titulo": "...", "inicio": "HH:MM", "fim": "HH:MM"},
 {"tipo": "remover_bloco", "titulo": "..."},
 {"tipo": "concluir_bloco", "titulo": "..."},
 {"tipo": "registrar_meta", "meta": "...", "quantidade": 1},
 {"tipo": "criar_meta", "titulo": "...", "frequencia": "diaria|semanal", "alvo": 1,
  "unidade": "vez"},
 {"tipo": "concluir_tarefa", "titulo": "..."},
 {"tipo": "mover_tarefa", "titulo": "...", "coluna": "pendente|execucao|concluida"},
 {"tipo": "criar_nota", "titulo": "...", "corpo": "markdown", "tags": ["..."]}]
```
Use the exact titles from the agenda, the tasks and the goals. Before removing or pushing back a
high-priority block, push back and only act if the user insists with a reason. With no change
request, do not use the block. Requested notes (summary, plan, minutes, study) go with the complete
content in `corpo`. A clear request to create something ("crie uma tarefa…", "cria um caderno…") is
to be done right away, without asking for confirmation; say in one sentence what you did. Titles
and note contents are in Brazilian Portuguese.

## Queries
If you need information that is not in the snapshot, ask for it before answering, in an ```acoes```
block with queries only; you receive the results and then answer (and act, if needed):
```acoes
[{"tipo": "pesquisar_web", "consulta": "..."},
 {"tipo": "pesquisar_notas", "consulta": "..."},
 {"tipo": "analisar_desempenho", "dias": 30}]
```
Use `pesquisar_web` for current or external facts, `pesquisar_notas` for what the user already
wrote down and `analisar_desempenho` when they ask how they are doing with the tasks and the agenda.
"""

COMPUTER = """
## The user's computer
You also control their PC (Linux, Brave browser). When they ask to open, search or shut down
something on the computer, answer in one sentence and use the ```acoes``` block:
```acoes
[{"tipo": "abrir_site", "url": "https://..."},
 {"tipo": "pesquisar_no_pc", "consulta": "...", "onde": "google|youtube"},
 {"tipo": "abrir_programa", "nome": "brave|firefox|arquivos|terminal|calculadora|spotify|steam"},
 {"tipo": "desligar_pc", "minutos": 0},
 {"tipo": "cancelar_desligar_pc"}]
```
A known channel or profile goes straight to its address (e.g.: YouTube channel @Fulano →
`abrir_site` with https://www.youtube.com/@Fulano). `desligar_pc` only with an explicit request.
"""

# Actions run on the PC by the worker (type → `acao` of the worker `pc` task).
PC = {
    "abrir_site": "abrir_site",
    "pesquisar_no_pc": "pesquisar",
    "abrir_programa": "abrir_programa",
    "desligar_pc": "desligar",
    "cancelar_desligar_pc": "cancelar_desligar",
}

# Actions that bring information to the LLM instead of changing something; the server runs them and
# asks again.
QUERIES = ("pesquisar_web", "pesquisar_notas", "analisar_desempenho")

ANALYSIS = """
## How to analyze performance
Comment on the numbers above without inventing others: what got better or worse, where the
bottleneck is (missed deadlines, high priority stalled, unfulfilled blocks, weak weekday) and end
with up to 3 concrete adjustments for the next days. If the user asks, turn the adjustments into
tasks or a note with `criar_tarefa`/`criar_nota`.
"""

_BLOCK = re.compile(r"```acoes\s*(.*?)```", re.S)


def _key(text: str) -> str:
    sem = unicodedata.normalize("NFD", text.lower())
    return " ".join("".join(c for c in sem if unicodedata.category(c) != "Mn").split())


def extract(text: str) -> tuple[str, list[dict[str, Any]]]:
    """Splits the text for the user from the requested actions (invalid block = no action)."""
    actions: list[dict[str, Any]] = []
    for m in _BLOCK.finditer(text):
        try:
            read = json.loads(m.group(1))
        except json.JSONDecodeError:
            continue
        actions += [a for a in (read if isinstance(read, list) else [read]) if isinstance(a, dict)]
    return _BLOCK.sub("", text).strip(), actions


def separate(actions: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """(queries, actions that change something)."""
    queries = [a for a in actions if a.get("tipo") in QUERIES]
    return queries, [a for a in actions if a.get("tipo") not in QUERIES]


def separate_pc(actions: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """(PC actions, the rest)."""
    on_pc = [a for a in actions if a.get("tipo") in PC]
    rest = [a for a in actions if a.get("tipo") not in PC]
    return on_pc, rest


async def execute_pc(
    actions: list[dict[str, Any]], pc: Callable[[dict[str, Any]], Awaitable[dict[str, Any]]] | None
) -> list[dict[str, Any]]:
    """Sends each action to the worker (`pc` task); without a worker or on error, comes back with
    ok=False."""
    done = []
    for a in actions:
        kind = str(a["tipo"])
        if pc is None:
            done.append({"tipo": kind, "ok": False, "detalhe": "Comandos no PC indisponíveis"})
            continue
        request = {k: v for k, v in a.items() if k != "tipo"} | {"acao": PC[kind]}
        try:
            r = await pc(request)
            done.append({"tipo": kind, "ok": True, "detalhe": str(r.get("detalhe", "Feito"))})
        # a PC that is off or a refused request does not break the conversation
        except Exception as e:
            done.append({"tipo": kind, "ok": False, "detalhe": f"No PC: {e}"})
    return done


def instructions_modules(modules: "dict[str, tuple[str, Any]]") -> str:
    """Prompt section with the actions the other modules registered (see `Sources`)."""
    if not modules:
        return ""
    examples = ",\n ".join(example for example, _ in modules.values())
    return (
        "\n## Other modules of the tool\nYou also create things in the other modules, with the "
        "same ```acoes``` block:\n```acoes\n[" + examples + "]\n```\n"
        "caderno = pen notes (Design tab); quadro = free board/diagram; fluxograma = process flow "
        "drawn from the `descricao`; projeto de estudo = organizes readings on a theme; leitura = "
        "book/article on the reading list.\n"
    )


def separate_modules(
    actions: list[dict[str, Any]], modules: "dict[str, tuple[str, Any]]"
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """(actions of other modules, the rest)."""
    return (
        [a for a in actions if a.get("tipo") in modules],
        [a for a in actions if a.get("tipo") not in modules],
    )


async def execute_modules(
    actions: list[dict[str, Any]], modules: "dict[str, tuple[str, Any]]", llm: Any
) -> list[dict[str, Any]]:
    """Runs the actions of the other modules; a failure becomes ok=False and does not stop the
    others."""
    done = []
    for a in actions:
        kind = str(a["tipo"])
        try:
            detail = await modules[kind][1](a, llm)
            done.append({"tipo": kind, "ok": True, "detalhe": detail})
        # the module refused or the AI is down: report it without breaking the conversation
        except Exception as e:
            done.append({"tipo": kind, "ok": False, "detalhe": f"Não consegui: {e}"})
    return done


def _find(items: list[dict[str, Any]], titulo: str) -> dict[str, Any]:
    target = _key(titulo)
    for item in items:
        if _key(item["titulo"]) == target:
            return item
    parecidos = [i for i in items if target and target in _key(i["titulo"])]
    if len(parecidos) == 1:
        return parecidos[0]
    raise NotFound(titulo)


def execute(
    actions: list[dict[str, Any]], nagger: Nagger, sources: "Sources", motivo: str
) -> list[dict[str, Any]]:
    """Runs in order; each action returns `{tipo, ok, detalhe}` and a failure does not stop the
    others."""
    done = []
    day = nagger.agora().date().isoformat()
    for a in actions:
        kind = str(a.get("tipo", ""))
        try:
            detail = _one(kind, a, nagger, sources, day, motivo)
            done.append({"tipo": kind, "ok": True, "detalhe": detail})
        except NotFound as e:
            done.append({"tipo": kind, "ok": False, "detalhe": f"Não achei “{e}”."})
        except (Invalid, KeyError, ValueError, TypeError) as e:
            done.append({"tipo": kind, "ok": False, "detalhe": f"Ação inválida: {e}"})
    return done


def _one(
    tipo: str, a: dict[str, Any], nagger: Nagger, sources: "Sources", day: str, motivo: str
) -> str:
    if tipo == "criar_tarefa":
        data = {"titulo": a["titulo"], "prioridade": a.get("prioridade", "media")}
        if a.get("prazo"):
            data["prazo"] = a["prazo"]
        t = sources.criar_tarefa(data)
        return f"Tarefa criada: {t['titulo']}"
    if tipo == "criar_nota":
        tags = [str(t) for t in a.get("tags") or [] if str(t).strip()]
        n = sources.criar_nota(
            {"titulo": a["titulo"], "corpo": a.get("corpo", ""), "tags": ["cobrador", *tags]}
        )
        return f"Nota criada: {n['titulo']}"
    if tipo in ("concluir_tarefa", "mover_tarefa"):
        coluna = "concluida" if tipo == "concluir_tarefa" else a["coluna"]
        t = _find(sources.tarefas(), a["titulo"])
        sources.mover_tarefa(t["id"], coluna)
        return f"Tarefa {t['titulo']} → {coluna}"
    if tipo == "criar_meta":
        data = {k: a[k] for k in ("frequencia", "alvo", "unidade") if a.get(k)}
        meta = nagger.create_meta({"titulo": str(a["titulo"]), **data})
        return f"Meta criada: {meta['titulo']}"
    if tipo == "registrar_meta":
        meta = _find(nagger.metas(), a["meta"])
        nagger.register_action(meta["id"], float(a.get("quantidade", 1)))
        return f"Registrado em {meta['titulo']}"

    blocks = nagger.agenda(day)["blocos"]
    if tipo == "concluir_bloco":
        b = _find(blocks, a["titulo"])
        nagger.marcar(day, b["id"])
        return f"Concluído: {b['titulo']}"
    if tipo == "adicionar_bloco":
        new = {k: a[k] for k in ("titulo", "inicio", "fim")} | {
            "prioridade": a.get("prioridade", "media")
        }
        blocks = [*blocks, new]
        summary = f"Bloco {new['inicio']}–{new['fim']}: {new['titulo']}"
    elif tipo == "mover_bloco":
        b = _find(blocks, a["titulo"])
        b |= {"inicio": a["inicio"], "fim": a["fim"]}
        summary = f"{b['titulo']} agora {b['inicio']}–{b['fim']}"
    elif tipo == "remover_bloco":
        b = _find(blocks, a["titulo"])
        blocks = [x for x in blocks if x is not b]
        summary = f"Removido: {b['titulo']}"
    else:
        raise Invalid(f"tipo {tipo!r}")
    saved = nagger.salvar(day, blocks, motivo)
    if saved["contestacoes"]:
        summary += " (contestado: " + " ".join(saved["contestacoes"]) + ")"
    return summary
