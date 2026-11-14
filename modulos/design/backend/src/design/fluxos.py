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

TIPOS = ("inicio", "fim", "processo", "decisao", "dado", "subprocesso", "quadrado", "circulo")
MAX_CODIGO = 30_000
MAX_NOS = 80

SISTEMA = """Você desenha fluxogramas de REGRAS DE NEGÓCIO em português do Brasil.
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


class FluxoInvalido(ValueError):
    pass


def montar_mensagens(
    pedido: str, codigo: str = "", arquivo: str = "", atual: dict[str, Any] | None = None
) -> list[dict[str, str]]:
    partes = []
    if atual and atual.get("nos"):
        partes.append(
            "Fluxo atual (ajuste-o conforme o pedido, mantendo os ids do que não mudar):\n"
            + json.dumps(_estrutura(atual), ensure_ascii=False)
        )
    if codigo:
        corte = codigo[:MAX_CODIGO]
        aviso = "" if len(codigo) <= MAX_CODIGO else "\n[código cortado: só o começo foi enviado]"
        partes.append(
            f"Extraia as regras de negócio deste código ({arquivo or 'arquivo'}) e desenhe o "
            f"fluxo que ele implementa:\n```\n{corte}\n```{aviso}"
        )
    partes.append(f"Pedido: {pedido.strip() or 'Desenhe o fluxo.'}")
    return [
        {"role": "system", "content": SISTEMA},
        {"role": "user", "content": "\n\n".join(partes)},
    ]


def _estrutura(fluxo: dict[str, Any]) -> dict[str, Any]:
    """Só o que o LLM precisa do fluxo atual (sem posições)."""
    return {
        "titulo": fluxo.get("titulo", ""),
        "nos": [{k: n.get(k, "") for k in ("id", "tipo", "texto")} for n in fluxo.get("nos", [])],
        "ligacoes": [
            {k: lg.get(k, "") for k in ("de", "para", "rotulo")} for lg in fluxo.get("ligacoes", [])
        ],
    }


def extrair_json(resposta: str) -> dict[str, Any]:
    """Primeiro objeto JSON da resposta (ignora <think>, cercas ``` e texto em volta)."""
    texto = re.sub(r"<think>.*?</think>", "", resposta, flags=re.DOTALL)
    inicio = texto.find("{")
    if inicio < 0:
        raise FluxoInvalido("A IA não devolveu um fluxo (sem JSON na resposta).")
    try:
        dados, _ = json.JSONDecoder().raw_decode(texto[inicio:])
    except json.JSONDecodeError as e:
        raise FluxoInvalido(f"A IA devolveu um JSON inválido: {e.msg}.") from e
    if not isinstance(dados, dict):
        raise FluxoInvalido("A IA não devolveu um objeto de fluxo.")
    return dados


def validar(dados: dict[str, Any]) -> dict[str, Any]:
    """Normaliza tipos, ids e textos; descarta ligações para nós que não existem."""
    nos: list[dict[str, Any]] = []
    vistos: set[str] = set()
    for i, n in enumerate(dados.get("nos") or []):
        if not isinstance(n, dict):
            continue
        nid = str(n.get("id") or f"n{i + 1}").strip()[:40]
        if nid in vistos:
            continue
        vistos.add(nid)
        tipo = str(n.get("tipo", "processo")).lower().strip()
        tipo = {"início": "inicio", "decisão": "decisao", "entrada": "dado", "saida": "dado"}.get(
            tipo, tipo
        )
        nos.append(
            {
                "id": nid,
                "tipo": tipo if tipo in TIPOS else "processo",
                "texto": str(n.get("texto", "")).strip()[:160],
            }
        )
    if not nos:
        raise FluxoInvalido("O fluxo veio sem blocos.")
    if len(nos) > MAX_NOS:
        raise FluxoInvalido(f"O fluxo veio com {len(nos)} blocos (máximo {MAX_NOS}).")
    ligacoes = []
    for lg in dados.get("ligacoes") or []:
        if not isinstance(lg, dict):
            continue
        de, para = str(lg.get("de", "")), str(lg.get("para", ""))
        if de in vistos and para in vistos and de != para:
            ligacoes.append({"de": de, "para": para, "rotulo": str(lg.get("rotulo") or "")[:40]})
    return {"titulo": str(dados.get("titulo", "")).strip()[:120], "nos": nos, "ligacoes": ligacoes}


def _tamanho(no: dict[str, Any]) -> tuple[float, float]:
    """Largura e altura do bloco pelo texto (quebra em ~22 caracteres por linha)."""
    texto = no["texto"] or " "
    largura = min(260.0, max(150.0, len(texto) * 7.5 + 40))
    por_linha = max(10, int((largura - 30) / 8))
    linhas = max(1, -(-len(texto) // por_linha))
    altura = 44.0 + 20 * linhas
    if no["tipo"] in ("decisao", "circulo"):
        largura, altura = largura * 1.25, altura * 1.5
    return largura, altura


def posicionar(fluxo: dict[str, Any]) -> dict[str, Any]:
    """Camadas de cima para baixo: a camada é o caminho mais longo desde o início, ignorando as
    ligações de volta (laços); dentro da camada, a ordem segue a média das posições dos pais."""
    nos = {n["id"]: n for n in fluxo["nos"]}
    saidas: dict[str, list[str]] = {i: [] for i in nos}
    for lg in fluxo["ligacoes"]:
        saidas[lg["de"]].append(lg["para"])
    entradas = {i: 0 for i in nos}
    for lg in fluxo["ligacoes"]:
        entradas[lg["para"]] += 1
    raizes = (
        [i for i, n in nos.items() if n["tipo"] == "inicio"]
        or [i for i in nos if entradas[i] == 0]
        or [next(iter(nos))]
    )

    # Ligações de volta pela busca em profundidade (aresta para um nó ainda na pilha).
    volta: set[tuple[str, str]] = set()
    estado: dict[str, int] = {}

    def dfs(u: str) -> None:
        estado[u] = 1
        for v in saidas[u]:
            if estado.get(v) == 1:
                volta.add((u, v))
            elif v not in estado:
                dfs(v)
        estado[u] = 2

    for r in raizes + list(nos):
        if r not in estado:
            dfs(r)

    camada = {i: 0 for i in nos}
    ordem_topo: list[str] = []
    grau = {i: 0 for i in nos}
    for u in nos:
        for v in saidas[u]:
            if (u, v) not in volta:
                grau[v] += 1
    fila = [i for i in nos if grau[i] == 0]
    while fila:
        u = fila.pop(0)
        ordem_topo.append(u)
        for v in saidas[u]:
            if (u, v) in volta:
                continue
            camada[v] = max(camada[v], camada[u] + 1)
            grau[v] -= 1
            if grau[v] == 0:
                fila.append(v)

    por_camada: dict[int, list[str]] = {}
    for u in ordem_topo:
        por_camada.setdefault(camada[u], []).append(u)
    pais: dict[str, list[str]] = {i: [] for i in nos}
    for u in nos:
        for v in saidas[u]:
            if (u, v) not in volta:
                pais[v].append(u)

    tamanhos = {i: _tamanho(n) for i, n in nos.items()}
    centro_x: dict[str, float] = {}
    y = 0.0
    for c in sorted(por_camada):
        linha = por_camada[c]
        if c > 0:
            linha.sort(
                key=lambda i: sum(centro_x[p] for p in pais[i]) / len(pais[i]) if pais[i] else 0
            )
        larguras = [tamanhos[i][0] for i in linha]
        total = sum(larguras) + 80 * (len(linha) - 1)
        x = -total / 2
        altura = max(tamanhos[i][1] for i in linha)
        for i, w in zip(linha, larguras, strict=True):
            h = tamanhos[i][1]
            nos[i].update(
                x=round(x, 1), y=round(y + (altura - h) / 2, 1), w=round(w, 1), h=round(h, 1)
            )
            centro_x[i] = x + w / 2
            x += w + 80
        y += altura + 90
    return fluxo


async def gerar(
    llm: ChatLLM,
    pedido: str,
    codigo: str = "",
    arquivo: str = "",
    atual: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Pede o fluxo à IA (uma nova tentativa se o JSON vier quebrado) e devolve já posicionado."""
    mensagens = montar_mensagens(pedido, codigo, arquivo, atual)
    resposta = await llm(mensagens)
    try:
        dados = extrair_json(resposta)
    except FluxoInvalido as e:
        mensagens += [
            {"role": "assistant", "content": resposta[:4000]},
            {"role": "user", "content": f"{e} Responda de novo SOMENTE com o JSON do fluxo."},
        ]
        dados = extrair_json(await llm(mensagens))
    return posicionar(validar(dados))


# Cores padrão dos blocos por tipo (as mesmas de `coresDoFluxo` no app).
CORES = {
    "inicio": 0xFF2E7D32,
    "fim": 0xFFC62828,
    "processo": 0xFF1565C0,
    "decisao": 0xFFEF6C00,
    "dado": 0xFF6A1B9A,
    "subprocesso": 0xFF00838F,
    "quadrado": 0xFF455A64,
    "circulo": 0xFF5D4037,
}


def elementos(fluxo: dict[str, Any], id_fluxo: str) -> list[dict[str, Any]]:
    """Fluxo posicionado → elementos do quadro (`no` e `ligacao`), como `elementosDoFluxo` no app.
    As ligações vão com a=b: o app as reencaixa nos blocos ao abrir o quadro."""
    saida: list[dict[str, Any]] = []
    for n in fluxo["nos"]:
        x, y = float(n.get("x", 0)), float(n.get("y", 0))
        saida.append({
            "id": f"{id_fluxo}.{n['id']}",
            "tipo": "no",
            "no": n["tipo"],
            "texto": str(n.get("texto", "")),
            "a": [x, y],
            "b": [x + float(n.get("w", 160)), y + float(n.get("h", 60))],
            "cor": CORES.get(n["tipo"], CORES["processo"]),
            "fluxo": id_fluxo,
        })
    for i, lg in enumerate(fluxo["ligacoes"]):
        saida.append({
            "id": f"{id_fluxo}.l{i}",
            "tipo": "ligacao",
            "de": f"{id_fluxo}.{lg['de']}",
            "para": f"{id_fluxo}.{lg['para']}",
            "rotulo": str(lg.get("rotulo", "")),
            "a": [0, 0],
            "b": [0, 0],
            "cor": 0xFF37474F,
            "fluxo": id_fluxo,
            "ortogonal": True,
        })
    return saida
