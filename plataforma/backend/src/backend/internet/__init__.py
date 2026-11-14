"""Internet para a IA local: o LLM escolhe as ferramentas (FIPE, moedas, ações, indicadores do BC,
busca na web), o servidor executa e o LLM responde com os dados e as fontes.

Os módulos recebem uma [Internet] em `app.state.internet` (Cobrador: "busque na internet …";
Finanças: preço FIPE e CDI nos cenários).
"""

import asyncio
import json
import re
from collections.abc import Awaitable, Callable
from datetime import datetime
from typing import Any

import httpx

from backend.internet import ferramentas as f

ChatLLM = Callable[[list[dict[str, str]]], Awaitable[str]]
# Busca feita no PC pelo worker (`shared.web_search`); None = sem worker ou falhou.
BuscarNoPC = Callable[[str], Awaitable[dict[str, Any] | None]]

SISTEMA_PLANO = """Hoje é {hoje}. Você decide quais ferramentas de dados em tempo real usar para
responder ao pedido. Ferramentas:
- fipe: {{"marca": "Ford", "modelo": "EcoSport", "ano": "2015", "tipo": "carros|motos|caminhoes"}}
- moedas: {{"pares": ["USD-BRL", "EUR-BRL", "BTC-BRL"]}}
- acoes: {{"tickers": ["PETR4", "MXRF11", "AAPL", "^BVSP"]}} (ações, FIIs, índices)
- indicadores: {{}} (Selic, CDI, IPCA atuais)
- mercado: {{"tipo": "stock|fund"}} (10 maiores altas e baixas do dia na B3; fund = FIIs)
- proventos: {{"ticker": "MXRF11"}} (dividendos/rendimentos de 12 meses e dividend yield)
- noticias: {{"tema": "economia|acoes|fiis|impostos|juros"}} (manchetes das últimas 24 h)
- buscar_web: {{"consulta": "..."}} (qualquer outra coisa atual: notícias, preços, regras)
Responda SOMENTE com JSON: {{"ferramentas": [{{"nome": "fipe", "args": {{...}}}}]}}.
Use até 4 ferramentas. Se o pedido não precisa de dado atual, devolva {{"ferramentas": []}}.
Para carro/moto informe a marca mesmo que a pessoa não diga (EcoSport → Ford).
Para empresa da bolsa use o ticker mesmo que a pessoa só diga o nome (Klabin → KLBN11, Petrobras →
PETR4, Vale → VALE3, Itaú → ITUB4) e junte buscar_web quando pedirem notícias ou o porquê."""

SISTEMA_RESPOSTA = """Hoje é {hoje}. Responda em português, direto, usando os DADOS EM TEMPO REAL
abaixo (eles valem mais do que o que você lembra do treino). Dê os números com a data/referência e
cite a fonte de cada um entre parênteses. Horários sempre no de Brasília (os dados já vêm
nele). Se uma ferramenta falhou, diga que não conseguiu aquele
dado. Não invente valores."""


# Ferramenta → como o aviso de andamento a chama.
_ANDAMENTO = {
    "fipe": "a tabela FIPE",
    "moedas": "a cotação das moedas",
    "acoes": "as cotações da bolsa",
    "indicadores": "os indicadores do Banco Central",
    "mercado": "as maiores altas e baixas da B3",
    "proventos": "os proventos",
    "noticias": "as últimas notícias",
    "buscar_web": "a web",
}


def _juntar(itens: list[str]) -> str:
    return itens[0] if len(itens) == 1 else ", ".join(itens[:-1]) + " e " + itens[-1]


def _json_da_resposta(texto: str) -> Any:
    texto = re.sub(r"<think>.*?</think>", "", texto, flags=re.DOTALL)
    i = texto.find("{")
    if i < 0:
        return {}
    try:
        return json.JSONDecoder().raw_decode(texto[i:])[0]
    except json.JSONDecodeError:
        return {}


class Internet:
    """Ferramentas + agente. [transporte] troca a rede nos testes."""

    def __init__(
        self,
        transporte: httpx.AsyncBaseTransport | None = None,
        buscar_no_pc: BuscarNoPC | None = None,
    ) -> None:
        self._transporte = transporte
        # Os buscadores barram o IP da VPS: com o worker conectado, a busca sai do PC de casa.
        self.buscar_no_pc = buscar_no_pc

    def _cliente(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(transport=self._transporte, follow_redirects=True)

    async def usar(self, nome: str, args: dict[str, Any]) -> dict[str, Any]:
        """Roda uma ferramenta; falha vira `{"erro": ...}` (a IA diz que não conseguiu)."""
        async with self._cliente() as c:
            try:
                match nome:
                    case "fipe":
                        return await f.fipe(
                            c,
                            str(args.get("marca", "")),
                            str(args.get("modelo", "")),
                            str(args.get("ano", "")),
                            str(args.get("tipo", "carros")),
                        )
                    case "moedas":
                        return await f.moedas(c, list(args.get("pares") or []) or None)
                    case "acoes":
                        return await f.acoes(c, [str(t) for t in args.get("tickers") or []])
                    case "indicadores":
                        return await f.indicadores(c)
                    case "mercado":
                        return await f.mercado(c, tipo=str(args.get("tipo") or "stock"))
                    case "noticias":
                        return await f.noticias(c, str(args.get("tema") or "economia"))
                    case "proventos":
                        return await f.proventos(c, str(args.get("ticker", "")))
                    case "buscar_web":
                        consulta = str(args.get("consulta", ""))
                        achados = await self.buscar_no_pc(consulta) if self.buscar_no_pc else None
                        return await f.buscar_web(c, consulta, achados=achados)
                    case _:
                        return {"erro": f"ferramenta desconhecida: {nome}"}
            except f.FerramentaFalhou as e:
                return {"erro": str(e)}

    async def pesquisar(
        self,
        llm: ChatLLM,
        pedido: str,
        contexto: str = "",
        aviso: Callable[[str], Awaitable[None]] | None = None,
    ) -> dict[str, Any]:
        """Planeja com o LLM, executa as ferramentas em paralelo e responde com as fontes.
        [aviso] recebe o andamento ("Consultando a cotação das moedas…") para o app falar."""
        hoje = datetime.now(f.BRASILIA).strftime("%d/%m/%Y, %H:%M (horário de Brasília)")
        plano = _json_da_resposta(
            await llm(
                [
                    {"role": "system", "content": SISTEMA_PLANO.format(hoje=hoje)},
                    {"role": "user", "content": pedido},
                ]
            )
        )
        chamadas = [
            (str(x.get("nome")), x.get("args") or {})
            for x in (plano.get("ferramentas") or [] if isinstance(plano, dict) else [])
            if isinstance(x, dict)
        ][:4]
        if not chamadas:  # o modelo não planejou: busca geral com o próprio pedido
            chamadas = [("buscar_web", {"consulta": pedido})]
        if aviso is not None:
            nomes = list(dict.fromkeys(_ANDAMENTO.get(n, "a web") for n, _ in chamadas))
            await aviso("Consultando " + _juntar(nomes) + ".")
        resultados = await asyncio.gather(*(self.usar(n, a) for n, a in chamadas))
        dados = [
            {"ferramenta": n, "args": a, "resultado": r}
            for (n, a), r in zip(chamadas, resultados, strict=True)
        ]
        resposta = await llm(
            [
                {
                    "role": "system",
                    "content": SISTEMA_RESPOSTA.format(hoje=hoje)
                    + (f"\n\n{contexto}" if contexto else ""),
                },
                {
                    "role": "user",
                    "content": f"Pedido: {pedido}\n\nDADOS EM TEMPO REAL:\n"
                    + json.dumps(dados, ensure_ascii=False)[:14000],
                },
            ]
        )
        fontes = sorted({r.get("fonte", "") for r in resultados if r.get("fonte")})
        links = [
            {"titulo": x["titulo"], "url": x["url"]}
            for r in resultados
            for x in r.get("resultados", [])[:3]
        ]
        return {
            "resposta": re.sub(r"<think>.*?</think>", "", resposta, flags=re.DOTALL).strip(),
            "fontes": fontes,
            "links": links,
            "dados": dados,
        }
