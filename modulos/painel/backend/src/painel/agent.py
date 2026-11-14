"""O Cobrador como agente: além de responder, o LLM pode pedir ações num bloco ```acoes``` (lista
JSON) no fim da resposta. O servidor executa, tira o bloco do texto e devolve o que foi feito.

Vale igual para o LLM local e para o Claude, sem depender de tool calling do provedor."""

import json
import re
import unicodedata
from collections.abc import Awaitable, Callable
from typing import TYPE_CHECKING, Any

from painel.nagger import Nagger, Invalid, NotFound

if TYPE_CHECKING:
    from painel.api import Sources

INSTRUCTIONS = """
## Ações
Você pode agir, não só falar. Quando o usuário pedir (ou concordar) uma mudança, termine a
resposta com um bloco assim, e só com as ações necessárias:
```acoes
[{"tipo": "criar_tarefa", "titulo": "...", "prioridade": "alta|media|baixa", "prazo": "AAAA-MM-DD"},
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
Use os títulos exatos da agenda, das tarefas e das metas. Antes de tirar ou empurrar um bloco de
prioridade alta, conteste e só aja se o usuário insistir com um motivo. Sem pedido de mudança, não
use o bloco. Notas pedidas (resumo, plano, ata, estudo) vão com o conteúdo completo no `corpo`.
Pedido claro de criar algo ("crie uma tarefa…", "cria um caderno…") é para fazer já, sem pedir
confirmação; responda numa frase o que fez.

## Consultas
Se precisar de informação que não está no retrato, peça antes de responder, num bloco ```acoes```
só com consultas; você recebe os resultados e então responde (e age, se for o caso):
```acoes
[{"tipo": "pesquisar_web", "consulta": "..."},
 {"tipo": "pesquisar_notas", "consulta": "..."},
 {"tipo": "analisar_desempenho", "dias": 30}]
```
Use `pesquisar_web` para fatos atuais ou externos, `pesquisar_notas` para o que o usuário já
anotou e `analisar_desempenho` quando ele perguntar como está indo nas tarefas e na agenda.
"""

COMPUTER = """
## Computador do usuário
Você também comanda o PC dele (Linux, navegador Brave). Quando ele pedir para abrir, pesquisar ou
desligar algo no computador, responda numa frase e use o bloco ```acoes```:
```acoes
[{"tipo": "abrir_site", "url": "https://..."},
 {"tipo": "pesquisar_no_pc", "consulta": "...", "onde": "google|youtube"},
 {"tipo": "abrir_programa", "nome": "brave|firefox|arquivos|terminal|calculadora|spotify|steam"},
 {"tipo": "desligar_pc", "minutos": 0},
 {"tipo": "cancelar_desligar_pc"}]
```
Canal ou perfil conhecido vai direto pelo endereço (ex.: canal @Fulano do YouTube →
`abrir_site` com https://www.youtube.com/@Fulano). `desligar_pc` só com pedido explícito.
"""

# Ações executadas no PC pelo worker (tipo → `acao` da tarefa `pc` do worker).
PC = {
    "abrir_site": "abrir_site",
    "pesquisar_no_pc": "pesquisar",
    "abrir_programa": "abrir_programa",
    "desligar_pc": "desligar",
    "cancelar_desligar_pc": "cancelar_desligar",
}

# Ações que trazem informação ao LLM em vez de mudar algo; o servidor executa e pergunta de novo.
QUERIES = ("pesquisar_web", "pesquisar_notas", "analisar_desempenho")

ANALYSIS = """
## Como analisar o desempenho
Comente os números acima sem inventar outros: o que melhorou ou piorou, onde está o gargalo
(prazos estourados, prioridade alta parada, blocos não cumpridos, dia da semana fraco) e termine
com até 3 ajustes concretos para os próximos dias. Se o usuário pedir, transforme os ajustes em
tarefas ou numa nota com `criar_tarefa`/`criar_nota`.
"""

_BLOCK = re.compile(r"```acoes\s*(.*?)```", re.S)


def _key(text: str) -> str:
    sem = unicodedata.normalize("NFD", text.lower())
    return " ".join("".join(c for c in sem if unicodedata.category(c) != "Mn").split())


def extract(text: str) -> tuple[str, list[dict[str, Any]]]:
    """Separa o texto para o usuário das ações pedidas (bloco inválido = nenhuma ação)."""
    actions: list[dict[str, Any]] = []
    for m in _BLOCK.finditer(text):
        try:
            read = json.loads(m.group(1))
        except json.JSONDecodeError:
            continue
        actions += [a for a in (read if isinstance(read, list) else [read]) if isinstance(a, dict)]
    return _BLOCK.sub("", text).strip(), actions


def separate(actions: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """(consultas, ações que mudam algo)."""
    queries = [a for a in actions if a.get("tipo") in QUERIES]
    return queries, [a for a in actions if a.get("tipo") not in QUERIES]


def separate_pc(actions: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """(ações no PC, demais)."""
    return [a for a in actions if a.get("tipo") in PC], [a for a in actions if a.get("tipo") not in PC]


async def execute_pc(
    actions: list[dict[str, Any]], pc: Callable[[dict[str, Any]], Awaitable[dict[str, Any]]] | None
) -> list[dict[str, Any]]:
    """Manda cada ação ao worker (tarefa `pc`); sem worker ou com erro, volta com ok=False."""
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
        except Exception as e:  # PC desligado ou pedido recusado não derruba a conversa
            done.append({"tipo": kind, "ok": False, "detalhe": f"No PC: {e}"})
    return done


def instructions_modules(modules: "dict[str, tuple[str, Any]]") -> str:
    """Seção do prompt com as ações que os outros módulos registraram (ver `Fontes.modulos`)."""
    if not modules:
        return ""
    examples = ",\n ".join(example for example, _ in modules.values())
    return (
        "\n## Outros módulos da ferramenta\nVocê também cria coisas nos outros módulos, com o mesmo"
        " bloco ```acoes```:\n```acoes\n[" + examples + "]\n```\n"
        "Caderno = anotações à caneta (aba Design); quadro = lousa/diagrama livre; fluxograma = "
        "fluxo de processo desenhado a partir da `descricao`; projeto de estudo = organiza leituras"
        " sobre um tema; leitura = livro/artigo na lista de leitura.\n"
    )


def separate_modules(
    actions: list[dict[str, Any]], modules: "dict[str, tuple[str, Any]]"
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """(ações de outros módulos, demais)."""
    return (
        [a for a in actions if a.get("tipo") in modules],
        [a for a in actions if a.get("tipo") not in modules],
    )


async def execute_modules(
    actions: list[dict[str, Any]], modules: "dict[str, tuple[str, Any]]", llm: Any
) -> list[dict[str, Any]]:
    """Executa as ações dos outros módulos; uma falha vira ok=False e não para as outras."""
    done = []
    for a in actions:
        kind = str(a["tipo"])
        try:
            detail = await modules[kind][1](a, llm)
            done.append({"tipo": kind, "ok": True, "detalhe": detail})
        except Exception as e:  # módulo recusou ou IA fora do ar: avisa sem derrubar a conversa
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
    """Executa na ordem; cada ação devolve `{tipo, ok, detalhe}` e uma falha não para as outras."""
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
        meta = nagger.criar_meta({"titulo": str(a["titulo"]), **data})
        return f"Meta criada: {meta['titulo']}"
    if tipo == "registrar_meta":
        meta = _find(nagger.metas(), a["meta"])
        nagger.registrar_acao(meta["id"], float(a.get("quantidade", 1)))
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
    salva = nagger.salvar(day, blocks, motivo)
    if salva["contestacoes"]:
        summary += " (contestado: " + " ".join(salva["contestacoes"]) + ")"
    return summary
