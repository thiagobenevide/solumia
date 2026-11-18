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


# Publisher feeds that carry a photo per article (Google News RSS has none). Their items are
# filtered by the topic words and merged with Google's; a headline in both keeps Google's link
# and gains the photo.
PUBLISHER_FEEDS = {
    "InfoMoney": "https://www.infomoney.com.br/feed/",
    "Suno": "https://www.suno.com.br/noticias/feed/",
    "InvestNews": "https://investnews.com.br/feed/",
    "Seu Dinheiro": "https://www.seudinheiro.com/feed/",
    "Money Times": "https://www.moneytimes.com.br/feed/",
}
THEME_WORDS = {
    "economia": ["economia", "ibovespa", "dolar", "mercado", "pib", "fiscal", "bolsa"],
    "acoes": ["ibovespa", "acoes", "acao", "b3", "bolsa", "dividendo", "lucro", "balanco"],
    "fiis": ["fundo imobiliario", "fundos imobiliarios", "fii", "fiis", "ifix"],
    "impostos": ["imposto", "receita federal", "tributaria", "tributacao", "irpf"],
    "juros": ["selic", "copom", "ipca", "inflacao", "tesouro", "juros"],
}
_MEDIA = "{http://search.yahoo.com/mrss/}"
_CONTENT = "{http://purl.org/rss/1.0/modules/content/}encoded"
_OG_IMAGE = re.compile(r'<meta[^>]+property=["\']og:image["\'][^>]+content=["\']([^"\']+)', re.I)
# article url → photo (og:image); the page does not change, so it is fetched once per process
_PHOTO_CACHE: dict[str, str] = {}
_IMG = re.compile(r"<img[^>]+src=[\"']([^\"']+)[\"']", re.I)


async def news(
    cliente: httpx.AsyncClient, tema: str = "economia", n: int = 30
) -> dict[str, Any]:
    """Headlines of the last 24 h, newest first: Google News (Portuguese RSS, no key) plus the
    publisher feeds, which bring a photo (`imagem`), a section (`categoria`) and a summary."""
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
    items: list[dict[str, Any]] = []
    by_title: dict[str, dict[str, Any]] = {}
    for it in root.iter("item"):
        item = _google_item(it)
        if item and _norm(item["titulo"]) not in by_title:
            by_title[_norm(item["titulo"])] = item
            items.append(item)
    feeds = await asyncio.gather(
        *[_publisher_feed(cliente, name, url) for name, url in PUBLISHER_FEEDS.items()]
    )
    words = THEME_WORDS.get(tema, THEME_WORDS["economia"])
    limit = (datetime.now(BRASILIA).timestamp() - 24 * 3600) if items else 0
    for feed in feeds:
        for item in feed:
            _merge_publisher(item, by_title, items, words, limit)
    await _fill_photos(cliente, items)
    return {
        "fonte": "Google Notícias",
        "tema": tema,
        "atualizado": datetime.now(BRASILIA).isoformat(timespec="minutes"),
        "noticias": _keep_photos(items, n),
    }


async def _fill_photos(cliente: httpx.AsyncClient, items: list[dict[str, Any]]) -> None:
    """Publisher articles whose feed has no photo get the page's og:image (Google links are
    redirects and are left as they are)."""
    missing = [i for i in items if not i.get("imagem") and "news.google." not in i["url"]]
    gate = asyncio.Semaphore(8)
    photos = await asyncio.gather(*[_og_image(cliente, i["url"], gate) for i in missing[:40]])
    for item, photo in zip(missing, photos, strict=False):
        if photo:
            item["imagem"] = photo


async def _og_image(cliente: httpx.AsyncClient, url: str, gate: asyncio.Semaphore) -> str:
    if url in _PHOTO_CACHE:
        return _PHOTO_CACHE[url]
    async with gate:
        try:
            r = await cliente.get(
                url, headers={"User-Agent": AGENT}, timeout=6, follow_redirects=True
            )
            found = _OG_IMAGE.search(r.text[:200_000])
        except httpx.HTTPError:
            return ""
    photo = html.unescape(found.group(1)) if found else ""
    _PHOTO_CACHE[url] = photo
    return photo


def _keep_photos(items: list[dict[str, Any]], n: int) -> list[dict[str, Any]]:
    """The newest [n], but every article with a photo stays in (they open the screen as cards)."""
    with_photo = [i for i in items if i.get("imagem")]
    rest = [i for i in items if not i.get("imagem")]
    rest.sort(key=lambda x: x["data"] or "", reverse=True)
    chosen = with_photo + rest[: max(n - len(with_photo), 0)]
    chosen.sort(key=lambda x: x["data"] or "", reverse=True)
    return chosen


def _google_item(it: ElementTree.Element) -> dict[str, Any] | None:
    source = it.findtext("source") or ""
    title = (it.findtext("title") or "").strip()
    # Google puts " - Source" at the end of the title
    if source and title.endswith(f" - {source}"):
        title = title[: -len(source) - 3]
    if not title:
        return None
    return {
        "titulo": html.unescape(title),
        "fonte": source,
        "url": it.findtext("link") or "",
        "data": _rss_date(it.findtext("pubDate")),
    }


def _rss_date(text: str | None) -> str | None:
    try:
        return parsedate_to_datetime(text or "").astimezone().isoformat(timespec="minutes")
    except (TypeError, ValueError):
        return None


async def _publisher_feed(cliente: httpx.AsyncClient, name: str, url: str) -> list[dict[str, Any]]:
    """One publisher's items; a feed that fails is just left out."""
    try:
        r = await cliente.get(url, headers={"User-Agent": AGENT}, timeout=10, follow_redirects=True)
        r.raise_for_status()
        root = ElementTree.fromstring(r.content)
    except (httpx.HTTPError, ElementTree.ParseError):
        return []
    result = []
    for it in root.iter("item"):
        title = html.unescape((it.findtext("title") or "").strip())
        if not title:
            continue
        description = it.findtext("description") or ""
        categories = [c.text.strip() for c in it.findall("category") if c.text]
        result.append(
            {
                "titulo": title,
                "fonte": name,
                "url": it.findtext("link") or "",
                "data": _rss_date(it.findtext("pubDate")),
                "imagem": _image(it, description),
                "categoria": categories[0] if categories else "",
                "resumo": _plain(description)[:280],
                "_busca": _norm(" ".join([title, *categories])),
            }
        )
    return result


def _image(it: ElementTree.Element, description: str) -> str:
    """Photo of the article: media:content/thumbnail, an image enclosure or the first <img>."""
    for tag in (f"{_MEDIA}content", f"{_MEDIA}thumbnail"):
        node = it.find(tag)
        if node is not None and node.get("url"):
            return node.get("url") or ""
    enclosure = it.find("enclosure")
    if enclosure is not None and (enclosure.get("type") or "").startswith("image"):
        return enclosure.get("url") or ""
    for text in (description, it.findtext(_CONTENT) or ""):
        for found in _IMG.finditer(text):
            src = html.unescape(found.group(1))
            if "/themes/" not in src and not src.endswith(".svg"):  # site logo, not a photo
                return src
    return ""


def _plain(text: str) -> str:
    text = re.sub(r"<[^>]+>", " ", html.unescape(text))
    return re.sub(r"\s+", " ", text).strip()


def _merge_publisher(
    item: dict[str, Any],
    by_title: dict[str, dict[str, Any]],
    items: list[dict[str, Any]],
    words: list[str],
    limit: float,
) -> None:
    search = item.pop("_busca")
    key = _norm(item["titulo"])
    same = by_title.get(key)
    if same is not None:
        for field in ("imagem", "categoria", "resumo"):
            if item[field] and not same.get(field):
                same[field] = item[field]
        return
    if not any(f" {w} " in f" {search} " for w in words):
        return
    if limit and item["data"] and datetime.fromisoformat(item["data"]).timestamp() < limit:
        return
    by_title[key] = item
    items.append(item)


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
