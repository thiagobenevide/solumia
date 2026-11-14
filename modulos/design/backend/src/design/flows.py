"""Fluxogramas de regra de negócio gerados pela IA: a partir de uma descrição, de um arquivo de
código ou ajustando o fluxo que já está no quadro.

O LLM só decide a estrutura (blocos e ligações, em JSON); as posições saem daqui, em camadas de
cima para baixo, para o desenho ser sempre legível independente do modelo. O app transforma o
resultado em elementos do quadro (`no` e `ligacao`).
"""

import json
import re
from collections.abc import Awaitable, Callable
from typing import Any

ChatLLM = Callable[[list[dict[str, str]]], Awaitable[str]]

KINDS = ("inicio", "fim", "processo", "decisao", "dado", "subprocesso", "quadrado", "circulo")
MAX_CODE = 30_000
MAX_NODES = 80

SYSTEM = """Você desenha fluxogramas de REGRAS DE NEGÓCIO em português do Brasil.
Responda SOMENTE com um JSON, sem texto antes ou depois, no formato:
{"titulo": "...", "nos": [{"id": "n1", "tipo": "inicio", "texto": "..."}],
 "ligacoes": [{"de": "n1", "para": "n2", "rotulo": ""}]}
Tipos de nó: inicio, fim, processo (ação/operação), decisao (pergunta de sim/não ou condição),
dado (entrada/saída: formulário, arquivo, API, banco), subprocesso (etapa detalhada em outro fluxo),
circulo (conector: junta caminhos ou continua em outra página).
Regras:
- Exatamente um "inicio"; um ou mais "fim".
- Toda "decisao" tem duas ou mais saídas com rótulo (ex.: "Sim"/"Não", "> R$ 1.000", "Aprovado").
- Textos curtos (até ~8 palavras), na linguagem do negócio, não do código: "Cliente tem crédito?"
  em vez de "if cliente.credito > 0".
- Inclua as validações, exceções e caminhos de erro que importam para a decisão de negócio.
- No máximo 40 nós; agrupe detalhes técnicos em "subprocesso"."""


class FlowInvalid(ValueError):
    pass


def assemble_messages(
    request: str, codigo: str = "", arquivo: str = "", atual: dict[str, Any] | None = None
) -> list[dict[str, str]]:
    parts = []
    if atual and atual.get("nos"):
        parts.append(
            "Fluxo atual (ajuste-o conforme o pedido, mantendo os ids do que não mudar):\n"
            + json.dumps(_structure(atual), ensure_ascii=False)
        )
    if codigo:
        cut = codigo[:MAX_CODE]
        warning = "" if len(codigo) <= MAX_CODE else "\n[código cortado: só o começo foi enviado]"
        parts.append(
            f"Extraia as regras de negócio deste código ({arquivo or 'arquivo'}) e desenhe o "
            f"fluxo que ele implementa:\n```\n{cut}\n```{warning}"
        )
    parts.append(f"Pedido: {request.strip() or 'Desenhe o fluxo.'}")
    return [
        {"role": "system", "content": SYSTEM},
        {"role": "user", "content": "\n\n".join(parts)},
    ]


def _structure(fluxo: dict[str, Any]) -> dict[str, Any]:
    """Só o que o LLM precisa do fluxo atual (sem posições)."""
    return {
        "titulo": fluxo.get("titulo", ""),
        "nos": [{k: n.get(k, "") for k in ("id", "tipo", "texto")} for n in fluxo.get("nos", [])],
        "ligacoes": [
            {k: lg.get(k, "") for k in ("de", "para", "rotulo")} for lg in fluxo.get("ligacoes", [])
        ],
    }


def extract_json(answer: str) -> dict[str, Any]:
    """Primeiro objeto JSON da resposta (ignora <think>, cercas ``` e texto em volta)."""
    text = re.sub(r"<think>.*?</think>", "", answer, flags=re.DOTALL)
    start = text.find("{")
    if start < 0:
        raise FlowInvalid("A IA não devolveu um fluxo (sem JSON na resposta).")
    try:
        data, _ = json.JSONDecoder().raw_decode(text[start:])
    except json.JSONDecodeError as e:
        raise FlowInvalid(f"A IA devolveu um JSON inválido: {e.msg}.") from e
    if not isinstance(data, dict):
        raise FlowInvalid("A IA não devolveu um objeto de fluxo.")
    return data


def validate(dados: dict[str, Any]) -> dict[str, Any]:
    """Normaliza tipos, ids e textos; descarta ligações para nós que não existem."""
    nodes: list[dict[str, Any]] = []
    seen: set[str] = set()
    for i, n in enumerate(dados.get("nos") or []):
        if not isinstance(n, dict):
            continue
        nid = str(n.get("id") or f"n{i + 1}").strip()[:40]
        if nid in seen:
            continue
        seen.add(nid)
        kind = str(n.get("tipo", "processo")).lower().strip()
        kind = {"início": "inicio", "decisão": "decisao", "entrada": "dado", "saida": "dado"}.get(
            kind, kind
        )
        nodes.append(
            {
                "id": nid,
                "tipo": kind if kind in KINDS else "processo",
                "texto": str(n.get("texto", "")).strip()[:160],
            }
        )
    if not nodes:
        raise FlowInvalid("O fluxo veio sem blocos.")
    if len(nodes) > MAX_NODES:
        raise FlowInvalid(f"O fluxo veio com {len(nodes)} blocos (máximo {MAX_NODES}).")
    ligacoes = []
    for lg in dados.get("ligacoes") or []:
        if not isinstance(lg, dict):
            continue
        de, para = str(lg.get("de", "")), str(lg.get("para", ""))
        if de in seen and para in seen and de != para:
            ligacoes.append({"de": de, "para": para, "rotulo": str(lg.get("rotulo") or "")[:40]})
    return {"titulo": str(dados.get("titulo", "")).strip()[:120], "nos": nodes, "ligacoes": ligacoes}


def _size(no: dict[str, Any]) -> tuple[float, float]:
    """Largura e altura do bloco pelo texto (quebra em ~22 caracteres por linha)."""
    text = no["texto"] or " "
    largura = min(260.0, max(150.0, len(text) * 7.5 + 40))
    by_line = max(10, int((largura - 30) / 8))
    lines = max(1, -(-len(text) // by_line))
    altura = 44.0 + 20 * lines
    if no["tipo"] in ("decisao", "circulo"):
        largura, altura = largura * 1.25, altura * 1.5
    return largura, altura


def position(fluxo: dict[str, Any]) -> dict[str, Any]:
    """Camadas de cima para baixo: a camada é o caminho mais longo desde o início, ignorando as
    ligações de volta (laços); dentro da camada, a ordem segue a média das posições dos pais."""
    nodes = {n["id"]: n for n in fluxo["nos"]}
    saidas: dict[str, list[str]] = {i: [] for i in nodes}
    for lg in fluxo["ligacoes"]:
        saidas[lg["de"]].append(lg["para"])
    inputs = {i: 0 for i in nodes}
    for lg in fluxo["ligacoes"]:
        inputs[lg["para"]] += 1
    roots = (
        [i for i, n in nodes.items() if n["tipo"] == "inicio"]
        or [i for i in nodes if inputs[i] == 0]
        or [next(iter(nodes))]
    )

    # Ligações de volta pela busca em profundidade (aresta para um nó ainda na pilha).
    lap: set[tuple[str, str]] = set()
    state: dict[str, int] = {}

    def dfs(u: str) -> None:
        state[u] = 1
        for v in saidas[u]:
            if state.get(v) == 1:
                lap.add((u, v))
            elif v not in state:
                dfs(v)
        state[u] = 2

    for r in roots + list(nodes):
        if r not in state:
            dfs(r)

    camada = {i: 0 for i in nodes}
    order_top: list[str] = []
    grau = {i: 0 for i in nodes}
    for u in nodes:
        for v in saidas[u]:
            if (u, v) not in lap:
                grau[v] += 1
    queue = [i for i in nodes if grau[i] == 0]
    while queue:
        u = queue.pop(0)
        order_top.append(u)
        for v in saidas[u]:
            if (u, v) in lap:
                continue
            camada[v] = max(camada[v], camada[u] + 1)
            grau[v] -= 1
            if grau[v] == 0:
                queue.append(v)

    by_camada: dict[int, list[str]] = {}
    for u in order_top:
        by_camada.setdefault(camada[u], []).append(u)
    pais: dict[str, list[str]] = {i: [] for i in nodes}
    for u in nodes:
        for v in saidas[u]:
            if (u, v) not in lap:
                pais[v].append(u)

    tamanhos = {i: _size(n) for i, n in nodes.items()}
    centro_x: dict[str, float] = {}
    y = 0.0
    for c in sorted(by_camada):
        line = by_camada[c]
        if c > 0:
            line.sort(
                key=lambda i: sum(centro_x[p] for p in pais[i]) / len(pais[i]) if pais[i] else 0
            )
        larguras = [tamanhos[i][0] for i in line]
        total = sum(larguras) + 80 * (len(line) - 1)
        x = -total / 2
        altura = max(tamanhos[i][1] for i in line)
        for i, w in zip(line, larguras, strict=True):
            h = tamanhos[i][1]
            nodes[i].update(
                x=round(x, 1), y=round(y + (altura - h) / 2, 1), w=round(w, 1), h=round(h, 1)
            )
            centro_x[i] = x + w / 2
            x += w + 80
        y += altura + 90
    return fluxo


async def generate(
    llm: ChatLLM,
    request: str,
    codigo: str = "",
    arquivo: str = "",
    atual: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Pede o fluxo à IA (uma nova tentativa se o JSON vier quebrado) e devolve já posicionado."""
    messages = assemble_messages(request, codigo, arquivo, atual)
    answer = await llm(messages)
    try:
        data = extract_json(answer)
    except FlowInvalid as e:
        messages += [
            {"role": "assistant", "content": answer[:4000]},
            {"role": "user", "content": f"{e} Responda de novo SOMENTE com o JSON do fluxo."},
        ]
        data = extract_json(await llm(messages))
    return position(validate(data))


# Cores padrão dos blocos por tipo (as mesmas de `coresDoFluxo` no app).
COLORS = {
    "inicio": 0xFF2E7D32,
    "fim": 0xFFC62828,
    "processo": 0xFF1565C0,
    "decisao": 0xFFEF6C00,
    "dado": 0xFF6A1B9A,
    "subprocesso": 0xFF00838F,
    "quadrado": 0xFF455A64,
    "circulo": 0xFF5D4037,
}


def elements(fluxo: dict[str, Any], id_flow: str) -> list[dict[str, Any]]:
    """Fluxo posicionado → elementos do quadro (`no` e `ligacao`), como `elementosDoFluxo` no app.
    As ligações vão com a=b: o app as reencaixa nos blocos ao abrir o quadro."""
    output: list[dict[str, Any]] = []
    for n in fluxo["nos"]:
        x, y = float(n.get("x", 0)), float(n.get("y", 0))
        output.append({
            "id": f"{id_flow}.{n['id']}",
            "tipo": "no",
            "no": n["tipo"],
            "texto": str(n.get("texto", "")),
            "a": [x, y],
            "b": [x + float(n.get("w", 160)), y + float(n.get("h", 60))],
            "cor": COLORS.get(n["tipo"], COLORS["processo"]),
            "fluxo": id_flow,
        })
    for i, lg in enumerate(fluxo["ligacoes"]):
        output.append({
            "id": f"{id_flow}.l{i}",
            "tipo": "ligacao",
            "de": f"{id_flow}.{lg['de']}",
            "para": f"{id_flow}.{lg['para']}",
            "rotulo": str(lg.get("rotulo", "")),
            "a": [0, 0],
            "b": [0, 0],
            "cor": 0xFF37474F,
            "fluxo": id_flow,
            "ortogonal": True,
        })
    return output
