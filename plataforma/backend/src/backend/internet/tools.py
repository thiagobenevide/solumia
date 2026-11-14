"""Real-time data for the local AI (which only knows what it saw in training): FIPE table,
currencies, B3/foreign quotes, Selic/CDI/IPCA and general web search. All without an API key.

Sources: Parallelum (FIPE), AwesomeAPI (currencies), Yahoo Finance (quotes), the Central Bank SGS
(indicators) and Bing/DuckDuckGo (search, `shared.web_search`). Each function receives the
`httpx.AsyncClient` (tests use a fake transport) and returns data ready to become JSON, with the
source.
"""

import asyncio
import html
import re
import unicodedata
from datetime import datetime
from email.utils import parsedate_to_datetime
from typing import Any
from urllib.parse import urlparse
from xml.etree import ElementTree
from zoneinfo import ZoneInfo

import httpx

from shared import web_search

AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/130 Safari/537.36"
)
FIPE = "https://parallelum.com.br/fipe/api/v1"
# Times always in Brasília time, whatever the server time zone (the VPS runs on UTC).
BRASILIA = ZoneInfo("America/Sao_Paulo")


class ToolFailed(RuntimeError):
    pass


def _norm(t: str) -> str:
    t = unicodedata.normalize("NFKD", t).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", t).strip()


async def _json(cliente: httpx.AsyncClient, url: str, agente: str = AGENT, **kw: Any) -> Any:
    try:
        r = await cliente.get(url, headers={"User-Agent": agente}, timeout=15, **kw)
        r.raise_for_status()
        return r.json()
    except (httpx.HTTPError, ValueError) as e:
        raise ToolFailed(f"{urlparse(url).netloc}: {e.__class__.__name__}") from e


# ---------- currencies ----------


async def currencies(cliente: httpx.AsyncClient, pairs: list[str] | None = None) -> dict[str, Any]:
    """Current quote (e.g. ["USD-BRL", "EUR-BRL", "BTC-BRL"])."""
    pairs = [p.upper().replace("/", "-") for p in (pairs or ["USD-BRL", "EUR-BRL"])][:6]
    try:
        data = await _json(
            cliente, f"https://economia.awesomeapi.com.br/json/last/{','.join(pairs)}"
        )
    except ToolFailed as e:
        # AwesomeAPI refuses datacenter IPs (the VPS); Yahoo has the same pairs
        return await _currencies_yahoo(cliente, pairs, e)
    output = {}
    for v in data.values():
        output[f"{v['code']}-{v['codein']}"] = {
            "nome": v.get("name"),
            "compra": float(v["bid"]),
            "venda": float(v["ask"]),
            "variacao_pct": float(v.get("pctChange") or 0),
            "atualizado": v.get("create_date"),
        }
    return {"fonte": "AwesomeAPI (economia.awesomeapi.com.br)", "cotacoes": output}


async def _currencies_yahoo(
    cliente: httpx.AsyncClient, pairs: list[str], motivo: Exception
) -> dict[str, Any]:
    """Second exchange-rate source: USD-BRL → USDBRL=X; BTC-BRL → BTC-BRL (crypto on Yahoo)."""
    cripto = {"BTC", "ETH", "SOL", "XRP", "USDT", "DOGE"}
    symbols = {
        p: (p if p.split("-")[0] in cripto else p.replace("-", "") + "=X") for p in pairs
    }
    r = await actions(cliente, list(symbols.values()))
    output = {}
    for pair, symbol in symbols.items():
        v = r["cotacoes"].get(symbol) or {}
        if v.get("preco") is None:
            continue
        output[pair] = {
            "nome": pair.replace("-", "/"),
            "compra": v["preco"],
            "venda": v["preco"],
            "variacao_pct": v.get("variacao_pct") or 0,
            "atualizado": v.get("horario"),
        }
    if not output:
        raise ToolFailed(f"câmbio indisponível ({motivo})")
    return {"fonte": "Yahoo Finance", "cotacoes": output}


# ---------- stocks ----------


def _ticker_yahoo(t: str) -> str:
    t = t.upper().strip()
    # PETR4, ITUB4, MXRF11, BOVA11 → B3 (.SA); AAPL, ^BVSP stay as they are
    return f"{t}.SA" if re.fullmatch(r"[A-Z]{4}\d{1,2}", t) else t


async def actions(cliente: httpx.AsyncClient, tickers: list[str]) -> dict[str, Any]:
    """Last price, previous close and change (e.g. ["PETR4", "MXRF11", "AAPL", "^BVSP"])."""

    async def uma(t: str) -> tuple[str, Any]:
        url = f"https://query1.finance.yahoo.com/v8/finance/chart/{_ticker_yahoo(t)}"
        try:
            # Yahoo refuses the full browser user agent without cookies; the short one passes.
            d = await _json(
                cliente, url, agente="Mozilla/5.0", params={"range": "1d", "interval": "1d"}
            )
            meta = d["chart"]["result"][0]["meta"]
        except (ToolFailed, KeyError, IndexError, TypeError) as e:
            if _ticker_yahoo(t).endswith(".SA"):
                return t, await _brapi(cliente, t, e)
            return t, {"erro": f"sem cotação ({e})"}
        preco, previous = meta.get("regularMarketPrice"), meta.get("chartPreviousClose")
        return t, {
            "preco": preco,
            "fechamento_anterior": previous,
            "variacao_pct": round((preco / previous - 1) * 100, 2) if preco and previous else None,
            "moeda": meta.get("currency"),
            "nome": meta.get("longName") or meta.get("shortName"),
            "horario": datetime.fromtimestamp(meta["regularMarketTime"], BRASILIA).isoformat(
                timespec="minutes"
            )
            if meta.get("regularMarketTime")
            else None,
        }

    results = await asyncio.gather(*(uma(t) for t in tickers[:8]))
    return {"fonte": "Yahoo Finance", "cotacoes": dict(results)}


async def _brapi(cliente: httpx.AsyncClient, t: str, motivo: Exception) -> dict[str, Any]:
    """Second source for B3 (brapi.dev; without a token only a few tickers)."""
    try:
        r = (await _json(cliente, f"https://brapi.dev/api/quote/{t.upper()}"))["results"][0]
        return {
            "preco": r.get("regularMarketPrice"),
            "fechamento_anterior": r.get("regularMarketPreviousClose"),
            "variacao_pct": r.get("regularMarketChangePercent"),
            "moeda": r.get("currency"),
            "nome": r.get("longName") or r.get("shortName"),
            "horario": r.get("regularMarketTime"),
            "fonte": "brapi.dev",
        }
    except (ToolFailed, KeyError, IndexError, TypeError):
        return {"erro": f"sem cotação ({motivo})"}


async def dividends(cliente: httpx.AsyncClient, ticker: str) -> dict[str, Any]:
    """Dividends/income paid in the last 12 months and the dividend yield over the current price."""
    url = f"https://query1.finance.yahoo.com/v8/finance/chart/{_ticker_yahoo(ticker)}"
    d = await _json(
        cliente,
        url,
        agente="Mozilla/5.0",
        params={"range": "1y", "interval": "1mo", "events": "div"},
    )
    try:
        r = d["chart"]["result"][0]
    except (KeyError, IndexError, TypeError) as e:
        raise ToolFailed(f"sem proventos de {ticker}") from e
    pagos = sorted(
        (
            {
                "data": datetime.fromtimestamp(v["date"], BRASILIA).date().isoformat(),
                "valor": round(v["amount"], 4),
            }
            for v in (r.get("events", {}).get("dividends") or {}).values()
        ),
        key=lambda x: x["data"],
    )
    preco = r["meta"].get("regularMarketPrice")
    total = round(sum(x["valor"] for x in pagos), 4)
    return {
        "fonte": "Yahoo Finance",
        "ticker": ticker.upper(),
        "preco": preco,
        "pagos_12m": pagos,
        "total_12m": total,
        "dy_12m_pct": round(total / preco * 100, 2) if preco else None,
    }


async def market(cliente: httpx.AsyncClient, n: int = 10, tipo: str = "stock") -> dict[str, Any]:
    """Top gainers and losers of the day on B3 among the 150 most traded tickers (type `stock` for
    stocks, `fund` for REITs): sorting the whole list would only bring odd lots and untraded
    tickers."""
    d = await _json(
        cliente,
        "https://brapi.dev/api/quote/list",
        params={"sortBy": "volume", "sortOrder": "desc", "limit": 150, "type": tipo},
    )
    roles = [
        {
            "ticker": x["stock"],
            "nome": x.get("name"),
            "preco": x.get("close"),
            "variacao_pct": round(x["change"], 2),
            "volume": x.get("volume"),
            "setor": x.get("sector"),
            "logo": x.get("logo"),
        }
        for x in d.get("stocks", [])
        if x.get("change") is not None and not x["stock"].endswith("F")
    ]
    roles.sort(key=lambda x: x["variacao_pct"], reverse=True)
    return {
        "fonte": "brapi.dev (B3, mais negociados do dia)",
        "atualizado": datetime.now(BRASILIA).isoformat(timespec="minutes"),
        "altas": roles[:n],
        "baixas": roles[::-1][:n],
    }


# ---------- today's news ----------

THEMES_NEWS = {
    "economia": "economia brasileira OR Ibovespa OR dólar OR mercado financeiro",
    "acoes": "Ibovespa OR ações OR B3 OR bolsa de valores",
    "fiis": '"fundos imobiliários" OR FII OR IFIX',
    "impostos": '"imposto de renda" OR "Receita Federal" OR "reforma tributária" OR tributação',
    "juros": "Selic OR Copom OR IPCA OR inflação OR Tesouro Direto",
}


async def news(
    cliente: httpx.AsyncClient, tema: str = "economia", n: int = 30
) -> dict[str, Any]:
    """Headlines of the last 24 h on Google News (Portuguese RSS, no key), newest first."""
    query = THEMES_NEWS.get(tema, THEMES_NEWS["economia"])
    try:
        r = await cliente.get(
            "https://news.google.com/rss/search",
            params={"q": f"{query} when:1d", "hl": "pt-BR", "gl": "BR", "ceid": "BR:pt-419"},
            headers={"User-Agent": AGENT},
            timeout=15,
        )
        r.raise_for_status()
        root = ElementTree.fromstring(r.content)
    except (httpx.HTTPError, ElementTree.ParseError) as e:
        raise ToolFailed(f"notícias: {e.__class__.__name__}") from e
    items, seen = [], set()
    for it in root.iter("item"):
        source = it.findtext("source") or ""
        title = (it.findtext("title") or "").strip()
        # Google puts " - Source" at the end of the title
        if source and title.endswith(f" - {source}"):
            title = title[: -len(source) - 3]
        if not title or _norm(title) in seen:
            continue
        seen.add(_norm(title))
        try:
            data = parsedate_to_datetime(it.findtext("pubDate") or "").astimezone()
        except (TypeError, ValueError):
            data = None
        items.append(
            {
                "titulo": html.unescape(title),
                "fonte": source,
                "url": it.findtext("link") or "",
                "data": data.isoformat(timespec="minutes") if data else None,
            }
        )
    items.sort(key=lambda x: x["data"] or "", reverse=True)
    return {
        "fonte": "Google Notícias",
        "tema": tema,
        "atualizado": datetime.now(BRASILIA).isoformat(timespec="minutes"),
        "noticias": items[:n],
    }


# ---------- Central Bank indicators ----------

SERIES_BCB = {
    "selic_meta_aa": 432,
    "cdi_aa": 4389,
    "ipca_mes": 433,
    "ipca_12_meses": 13522,
}


async def indicators(cliente: httpx.AsyncClient) -> dict[str, Any]:
    """Selic target (% p.a.), CDI (% p.a.), IPCA of the last month and the last 12 months (%)."""

    async def serie(nome: str, code: int) -> tuple[str, Any]:
        url = f"https://api.bcb.gov.br/dados/serie/bcdata.sgs.{code}/dados/ultimos/1"
        error: Exception | None = None
        for attempt in range(2):  # SGS sometimes refuses parallel requests
            try:
                [d] = await _json(cliente, url, params={"formato": "json"})
                return nome, {"valor": float(d["valor"]), "data": d["data"]}
            except (ToolFailed, ValueError, KeyError, TypeError) as e:
                error = e
                await asyncio.sleep(0.8 * (attempt + 1))
        return nome, {"erro": str(error)}

    r = await asyncio.gather(*(serie(n, c) for n, c in SERIES_BCB.items()))
    return {"fonte": "Banco Central do Brasil (SGS)", "indicadores": dict(r)}


# ---------- FIPE ----------


async def fipe(
    cliente: httpx.AsyncClient, mark: str, modelo: str, year: str = "", tipo: str = "carros"
) -> dict[str, Any]:
    """FIPE table price: versions of the brand's model in the year (e.g. Ford, EcoSport, 2015)."""
    tipo = tipo if tipo in ("carros", "motos", "caminhoes") else "carros"
    marks = await _json(cliente, f"{FIPE}/{tipo}/marcas")
    target = _norm(mark)
    m = next((x for x in marks if _norm(x["nome"]) == target), None) or next(
        (x for x in marks if target and target in _norm(x["nome"])), None
    )
    if m is None:
        raise ToolFailed(f"Marca '{mark}' não encontrada na FIPE.")
    models = (await _json(cliente, f"{FIPE}/{tipo}/marcas/{m['codigo']}/modelos"))["modelos"]
    words = _norm(modelo).split()
    candidates = [x for x in models if all(p in _norm(x["nome"]) for p in words)][:12]
    if not candidates:
        raise ToolFailed(f"Modelo '{modelo}' não encontrado na FIPE para {m['nome']}.")

    async def versoes(mod: dict[str, Any]) -> list[dict[str, Any]]:
        base = f"{FIPE}/{tipo}/marcas/{m['codigo']}/modelos/{mod['codigo']}/anos"
        try:
            years = await _json(cliente, base)
        except ToolFailed:
            return []
        chosen = [a for a in years if not year or str(a["codigo"]).startswith(str(year))][:2]
        output = []
        for a in chosen:
            try:
                v = await _json(cliente, f"{base}/{a['codigo']}")
            except ToolFailed:
                continue
            value = float(re.sub(r"[^\d,]", "", v["Valor"]).replace(",", "."))
            output.append(
                {
                    "modelo": v["Modelo"],
                    "ano": v["AnoModelo"],
                    "combustivel": v.get("Combustivel"),
                    "valor": value,
                    "referencia": v.get("MesReferencia", "").strip(),
                    "codigo_fipe": v.get("CodigoFipe"),
                }
            )
        return output

    groups = await asyncio.gather(*(versoes(c) for c in candidates))
    everything = [v for items in groups for v in items]
    if not everything:
        raise ToolFailed(f"Sem preço FIPE de {m['nome']} {modelo} {year}.")
    values = sorted(v["valor"] for v in everything)
    return {
        "fonte": "Tabela FIPE (parallelum.com.br)",
        "marca": m["nome"],
        "versoes": everything,
        "menor": values[0],
        "maior": values[-1],
        "media": round(sum(values) / len(values), 2),
    }


# ---------- web search ----------


def _text_html(page: str) -> str:
    page = re.sub(r"(?is)<(script|style|noscript|svg|nav|footer|header)[^>]*>.*?</\1>", " ", page)
    text = html.unescape(re.sub(r"(?s)<[^>]+>", " ", page))
    return re.sub(r"\s+", " ", text).strip()


async def fetch_web(
    cliente: httpx.AsyncClient,
    query: str,
    read: int = 2,
    achados: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Search results (title, address, snippet) and the text of the first pages read.
    Found: the search already done on the PC (`shared.web_search` through the worker); without it,
    searches from here."""
    if not achados:
        try:
            achados = await web_search.search(cliente, query)
        except web_search.SearchFailed as e:
            raise ToolFailed(f"busca: {e}") from e
    results = [dict(x) for x in achados["resultados"]]

    async def ler_pagina(res: dict[str, Any]) -> None:
        try:
            p = await cliente.get(
                res["url"], headers={"User-Agent": AGENT}, timeout=10, follow_redirects=True
            )
            if "html" in p.headers.get("content-type", ""):
                res["texto"] = _text_html(p.text)[:3500]
        except httpx.HTTPError:
            pass

    await asyncio.gather(*(ler_pagina(x) for x in results[:read]))
    return {"fonte": achados["fonte"], "consulta": query, "resultados": results}
