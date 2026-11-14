"""Internet for the local AI: the LLM picks the tools (FIPE, currencies, stocks, central bank
indicators, web search), the server runs them and the LLM answers with the data and the sources.

The modules receive an [Internet] in `app.state.internet` (Nagger: "busque na internet …";
Finance: FIPE price and CDI in the scenarios).
"""

import asyncio
import json
import re
from collections.abc import Awaitable, Callable
from datetime import datetime
from typing import Any

import httpx

from backend.internet import tools as f

ChatLLM = Callable[[list[dict[str, str]]], Awaitable[str]]
# Search done on the PC through the worker (`shared.web_search`); None = no worker or it failed.
FetchNodePC = Callable[[str], Awaitable[dict[str, Any] | None]]

SYSTEM_PLAN = """Today is {hoje}. You decide which real-time data tools to use to answer the request
(written in Brazilian Portuguese). Tools:
- fipe: {{"marca": "Ford", "modelo": "EcoSport", "ano": "2015", "tipo": "carros|motos|caminhoes"}}
- moedas: {{"pares": ["USD-BRL", "EUR-BRL", "BTC-BRL"]}}
- acoes: {{"tickers": ["PETR4", "MXRF11", "AAPL", "^BVSP"]}} (stocks, REITs (FIIs), indexes)
- indicadores: {{}} (current Selic, CDI, IPCA)
- mercado: {{"tipo": "stock|fund"}} (the day's 10 biggest gains and losses on B3; fund = FIIs)
- proventos: {{"ticker": "MXRF11"}} (12-month dividends/income and dividend yield)
- noticias: {{"tema": "economia|acoes|fiis|impostos|juros"}} (headlines of the last 24 h)
- buscar_web: {{"consulta": "..."}} (anything else current: news, prices, rules)
Respond ONLY with JSON: {{"ferramentas": [{{"nome": "fipe", "args": {{...}}}}]}}.
Use up to 4 tools. If the request does not need current data, return {{"ferramentas": []}}.
For a car/motorcycle give the brand even if the person does not say it (EcoSport → Ford).
For a listed company use the ticker even if the person only says the name (Klabin → KLBN11,
Petrobras → PETR4, Vale → VALE3, Itaú → ITUB4) and add buscar_web when they ask for news or the
reason why."""

SYSTEM_ANSWER = """Today is {hoje}. Answer in Brazilian Portuguese, directly, using the REAL-TIME
DATA below (it is worth more than what you remember from training). Give the numbers with their
date/reference and cite the source of each one in parentheses. Times always in Brasília time (the
data already comes in it). If a tool failed, say you could not get that data. Do not invent
values."""


# Tool → how the progress notice names it.
_ONGOING = {
    "fipe": "a tabela FIPE",
    "moedas": "a cotação das moedas",
    "acoes": "as cotações da bolsa",
    "indicadores": "os indicadores do Banco Central",
    "mercado": "as maiores altas e baixas da B3",
    "proventos": "os proventos",
    "noticias": "as últimas notícias",
    "buscar_web": "a web",
}


def _join(items: list[str]) -> str:
    return items[0] if len(items) == 1 else ", ".join(items[:-1]) + " e " + items[-1]


def _json_of_answer(text: str) -> Any:
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL)
    i = text.find("{")
    if i < 0:
        return {}
    try:
        return json.JSONDecoder().raw_decode(text[i:])[0]
    except json.JSONDecodeError:
        return {}


class Internet:
    """Tools + agent. The transport replaces the network in tests."""

    def __init__(
        self,
        transport: httpx.AsyncBaseTransport | None = None,
        buscar_no_pc: FetchNodePC | None = None,
    ) -> None:
        self._transporte = transport
        # Search engines block the VPS IP: with the worker connected, the search goes out from the
        # home PC.
        self.fetch_node_pc = buscar_no_pc

    def _cliente(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(transport=self._transporte, follow_redirects=True)

    async def use(self, nome: str, args: dict[str, Any]) -> dict[str, Any]:
        """Runs a tool; a failure becomes `{"erro": ...}` (the AI says it could not)."""
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
                        return await f.currencies(c, list(args.get("pares") or []) or None)
                    case "acoes":
                        return await f.actions(c, [str(t) for t in args.get("tickers") or []])
                    case "indicadores":
                        return await f.indicators(c)
                    case "mercado":
                        return await f.market(c, tipo=str(args.get("tipo") or "stock"))
                    case "noticias":
                        return await f.news(c, str(args.get("tema") or "economia"))
                    case "proventos":
                        return await f.dividends(c, str(args.get("ticker", "")))
                    case "buscar_web":
                        query = str(args.get("consulta", ""))
                        found = await self.fetch_node_pc(query) if self.fetch_node_pc else None
                        return await f.fetch_web(c, query, achados=found)
                    case _:
                        return {"erro": f"ferramenta desconhecida: {nome}"}
            except f.ToolFailed as e:
                return {"erro": str(e)}

    async def pesquisar(
        self,
        llm: ChatLLM,
        request: str,
        contexto: str = "",
        aviso: Callable[[str], Awaitable[None]] | None = None,
    ) -> dict[str, Any]:
        """Plans with the LLM, runs the tools in parallel and answers with the sources.
        The notice callback receives the progress ("Consultando a cotação das moedas…") for the app
        to speak."""
        today = datetime.now(f.BRASILIA).strftime("%d/%m/%Y, %H:%M (horário de Brasília)")
        plan = _json_of_answer(
            await llm(
                [
                    {"role": "system", "content": SYSTEM_PLAN.format(hoje=today)},
                    {"role": "user", "content": request},
                ]
            )
        )
        calls = [
            (str(x.get("nome")), x.get("args") or {})
            for x in (plan.get("ferramentas") or [] if isinstance(plan, dict) else [])
            if isinstance(x, dict)
        ][:4]
        if not calls:  # the model did not plan: general search with the request itself
            calls = [("buscar_web", {"consulta": request})]
        if aviso is not None:
            names = list(dict.fromkeys(_ONGOING.get(n, "a web") for n, _ in calls))
            await aviso("Consultando " + _join(names) + ".")
        results = await asyncio.gather(*(self.use(n, a) for n, a in calls))
        data = [
            {"ferramenta": n, "args": a, "resultado": r}
            for (n, a), r in zip(calls, results, strict=True)
        ]
        answer = await llm(
            [
                {
                    "role": "system",
                    "content": SYSTEM_ANSWER.format(hoje=today)
                    + (f"\n\n{contexto}" if contexto else ""),
                },
                {
                    "role": "user",
                    "content": f"Request: {request}\n\nREAL-TIME DATA:\n"
                    + json.dumps(data, ensure_ascii=False)[:14000],
                },
            ]
        )
        sources = sorted({r.get("fonte", "") for r in results if r.get("fonte")})
        links = [
            {"titulo": x["titulo"], "url": x["url"]}
            for r in results
            for x in r.get("resultados", [])[:3]
        ]
        return {
            "resposta": re.sub(r"<think>.*?</think>", "", answer, flags=re.DOTALL).strip(),
            "fontes": sources,
            "links": links,
            "dados": data,
        }
