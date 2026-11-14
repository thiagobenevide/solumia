"""Dados em tempo real para a IA local (que só sabe o que viu no treino): tabela FIPE, moedas,
cotações da B3/exterior, Selic/CDI/IPCA e busca geral na web. Todas sem chave de API.

Fontes: Parallelum (FIPE), AwesomeAPI (moedas), Yahoo Finance (cotações), SGS do Banco Central
(indicadores) e Bing/DuckDuckGo (busca, `shared.web_search`). Cada função recebe o
`httpx.AsyncClient` (testes usam um transporte falso) e devolve dados prontos para virar JSON,
com a fonte.
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

AGENTE = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/130 Safari/537.36"
)
FIPE = "https://parallelum.com.br/fipe/api/v1"
# Horários sempre no de Brasília, seja qual for o fuso do servidor (a VPS roda em UTC).
BRASILIA = ZoneInfo("America/Sao_Paulo")


class FerramentaFalhou(RuntimeError):
    pass


def _norm(t: str) -> str:
    t = unicodedata.normalize("NFKD", t).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", t).strip()


async def _json(cliente: httpx.AsyncClient, url: str, agente: str = AGENTE, **kw: Any) -> Any:
    try:
        r = await cliente.get(url, headers={"User-Agent": agente}, timeout=15, **kw)
        r.raise_for_status()
        return r.json()
    except (httpx.HTTPError, ValueError) as e:
        raise FerramentaFalhou(f"{urlparse(url).netloc}: {e.__class__.__name__}") from e


# ---------- moedas ----------


async def moedas(cliente: httpx.AsyncClient, pares: list[str] | None = None) -> dict[str, Any]:
    """Cotação atual (ex.: ["USD-BRL", "EUR-BRL", "BTC-BRL"])."""
    pares = [p.upper().replace("/", "-") for p in (pares or ["USD-BRL", "EUR-BRL"])][:6]
    try:
        dados = await _json(
            cliente, f"https://economia.awesomeapi.com.br/json/last/{','.join(pares)}"
        )
    except FerramentaFalhou as e:
        # a AwesomeAPI recusa IPs de datacenter (a VPS); o Yahoo tem os mesmos pares
        return await _moedas_yahoo(cliente, pares, e)
    saida = {}
    for v in dados.values():
        saida[f"{v['code']}-{v['codein']}"] = {
            "nome": v.get("name"),
            "compra": float(v["bid"]),
            "venda": float(v["ask"]),
            "variacao_pct": float(v.get("pctChange") or 0),
            "atualizado": v.get("create_date"),
        }
    return {"fonte": "AwesomeAPI (economia.awesomeapi.com.br)", "cotacoes": saida}


async def _moedas_yahoo(
    cliente: httpx.AsyncClient, pares: list[str], motivo: Exception
) -> dict[str, Any]:
    """Segunda fonte de câmbio: USD-BRL → USDBRL=X; BTC-BRL → BTC-BRL (cripto no Yahoo)."""
    cripto = {"BTC", "ETH", "SOL", "XRP", "USDT", "DOGE"}
    simbolos = {
        p: (p if p.split("-")[0] in cripto else p.replace("-", "") + "=X") for p in pares
    }
    r = await acoes(cliente, list(simbolos.values()))
    saida = {}
    for par, simbolo in simbolos.items():
        v = r["cotacoes"].get(simbolo) or {}
        if v.get("preco") is None:
            continue
        saida[par] = {
            "nome": par.replace("-", "/"),
            "compra": v["preco"],
            "venda": v["preco"],
            "variacao_pct": v.get("variacao_pct") or 0,
            "atualizado": v.get("horario"),
        }
    if not saida:
        raise FerramentaFalhou(f"câmbio indisponível ({motivo})")
    return {"fonte": "Yahoo Finance", "cotacoes": saida}


# ---------- ações ----------


def _ticker_yahoo(t: str) -> str:
    t = t.upper().strip()
    # PETR4, ITUB4, MXRF11, BOVA11 → B3 (.SA); AAPL, ^BVSP ficam como estão
    return f"{t}.SA" if re.fullmatch(r"[A-Z]{4}\d{1,2}", t) else t


async def acoes(cliente: httpx.AsyncClient, tickers: list[str]) -> dict[str, Any]:
    """Último preço, fechamento anterior e variação (ex.: ["PETR4", "MXRF11", "AAPL", "^BVSP"])."""

    async def uma(t: str) -> tuple[str, Any]:
        url = f"https://query1.finance.yahoo.com/v8/finance/chart/{_ticker_yahoo(t)}"
        try:
            # O Yahoo recusa o agente completo de navegador sem cookies; o curto passa.
            d = await _json(
                cliente, url, agente="Mozilla/5.0", params={"range": "1d", "interval": "1d"}
            )
            meta = d["chart"]["result"][0]["meta"]
        except (FerramentaFalhou, KeyError, IndexError, TypeError) as e:
            if _ticker_yahoo(t).endswith(".SA"):
                return t, await _brapi(cliente, t, e)
            return t, {"erro": f"sem cotação ({e})"}
        preco, anterior = meta.get("regularMarketPrice"), meta.get("chartPreviousClose")
        return t, {
            "preco": preco,
            "fechamento_anterior": anterior,
            "variacao_pct": round((preco / anterior - 1) * 100, 2) if preco and anterior else None,
            "moeda": meta.get("currency"),
            "nome": meta.get("longName") or meta.get("shortName"),
            "horario": datetime.fromtimestamp(meta["regularMarketTime"], BRASILIA).isoformat(
                timespec="minutes"
            )
            if meta.get("regularMarketTime")
            else None,
        }

    resultados = await asyncio.gather(*(uma(t) for t in tickers[:8]))
    return {"fonte": "Yahoo Finance", "cotacoes": dict(resultados)}


async def _brapi(cliente: httpx.AsyncClient, t: str, motivo: Exception) -> dict[str, Any]:
    """Segunda fonte para a B3 (brapi.dev; sem token só alguns papéis)."""
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
    except (FerramentaFalhou, KeyError, IndexError, TypeError):
        return {"erro": f"sem cotação ({motivo})"}


async def proventos(cliente: httpx.AsyncClient, ticker: str) -> dict[str, Any]:
    """Dividendos/rendimentos pagos nos últimos 12 meses e o dividend yield sobre o preço atual."""
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
        raise FerramentaFalhou(f"sem proventos de {ticker}") from e
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


async def mercado(cliente: httpx.AsyncClient, n: int = 10, tipo: str = "stock") -> dict[str, Any]:
    """Maiores altas e baixas do dia na B3 entre os 150 papéis mais negociados ([tipo] `stock` para
    ações, `fund` para FIIs): ordenar a lista inteira só traria fracionário e papel sem negócio."""
    d = await _json(
        cliente,
        "https://brapi.dev/api/quote/list",
        params={"sortBy": "volume", "sortOrder": "desc", "limit": 150, "type": tipo},
    )
    papeis = [
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
    papeis.sort(key=lambda x: x["variacao_pct"], reverse=True)
    return {
        "fonte": "brapi.dev (B3, mais negociados do dia)",
        "atualizado": datetime.now(BRASILIA).isoformat(timespec="minutes"),
        "altas": papeis[:n],
        "baixas": papeis[::-1][:n],
    }


# ---------- notícias do dia ----------

TEMAS_NOTICIAS = {
    "economia": "economia brasileira OR Ibovespa OR dólar OR mercado financeiro",
    "acoes": "Ibovespa OR ações OR B3 OR bolsa de valores",
    "fiis": '"fundos imobiliários" OR FII OR IFIX',
    "impostos": '"imposto de renda" OR "Receita Federal" OR "reforma tributária" OR tributação',
    "juros": "Selic OR Copom OR IPCA OR inflação OR Tesouro Direto",
}


async def noticias(
    cliente: httpx.AsyncClient, tema: str = "economia", n: int = 30
) -> dict[str, Any]:
    """Manchetes das últimas 24 h no Google News (RSS em português, sem chave), mais novas antes."""
    consulta = TEMAS_NOTICIAS.get(tema, TEMAS_NOTICIAS["economia"])
    try:
        r = await cliente.get(
            "https://news.google.com/rss/search",
            params={"q": f"{consulta} when:1d", "hl": "pt-BR", "gl": "BR", "ceid": "BR:pt-419"},
            headers={"User-Agent": AGENTE},
            timeout=15,
        )
        r.raise_for_status()
        raiz = ElementTree.fromstring(r.content)
    except (httpx.HTTPError, ElementTree.ParseError) as e:
        raise FerramentaFalhou(f"notícias: {e.__class__.__name__}") from e
    itens, vistos = [], set()
    for it in raiz.iter("item"):
        fonte = it.findtext("source") or ""
        titulo = (it.findtext("title") or "").strip()
        # o Google põe " - Fonte" no fim do título
        if fonte and titulo.endswith(f" - {fonte}"):
            titulo = titulo[: -len(fonte) - 3]
        if not titulo or _norm(titulo) in vistos:
            continue
        vistos.add(_norm(titulo))
        try:
            data = parsedate_to_datetime(it.findtext("pubDate") or "").astimezone()
        except (TypeError, ValueError):
            data = None
        itens.append(
            {
                "titulo": html.unescape(titulo),
                "fonte": fonte,
                "url": it.findtext("link") or "",
                "data": data.isoformat(timespec="minutes") if data else None,
            }
        )
    itens.sort(key=lambda x: x["data"] or "", reverse=True)
    return {
        "fonte": "Google Notícias",
        "tema": tema,
        "atualizado": datetime.now(BRASILIA).isoformat(timespec="minutes"),
        "noticias": itens[:n],
    }


# ---------- indicadores do Banco Central ----------

SERIES_BCB = {
    "selic_meta_aa": 432,
    "cdi_aa": 4389,
    "ipca_mes": 433,
    "ipca_12_meses": 13522,
}


async def indicadores(cliente: httpx.AsyncClient) -> dict[str, Any]:
    """Selic meta (% a.a.), CDI (% a.a.), IPCA do último mês e dos últimos 12 meses (%)."""

    async def serie(nome: str, codigo: int) -> tuple[str, Any]:
        url = f"https://api.bcb.gov.br/dados/serie/bcdata.sgs.{codigo}/dados/ultimos/1"
        erro: Exception | None = None
        for tentativa in range(2):  # o SGS às vezes recusa pedidos em paralelo
            try:
                [d] = await _json(cliente, url, params={"formato": "json"})
                return nome, {"valor": float(d["valor"]), "data": d["data"]}
            except (FerramentaFalhou, ValueError, KeyError, TypeError) as e:
                erro = e
                await asyncio.sleep(0.8 * (tentativa + 1))
        return nome, {"erro": str(erro)}

    r = await asyncio.gather(*(serie(n, c) for n, c in SERIES_BCB.items()))
    return {"fonte": "Banco Central do Brasil (SGS)", "indicadores": dict(r)}


# ---------- FIPE ----------


async def fipe(
    cliente: httpx.AsyncClient, marca: str, modelo: str, ano: str = "", tipo: str = "carros"
) -> dict[str, Any]:
    """Preço da tabela FIPE: versões do [modelo] da [marca] no [ano] (ex.: Ford, EcoSport, 2015)."""
    tipo = tipo if tipo in ("carros", "motos", "caminhoes") else "carros"
    marcas = await _json(cliente, f"{FIPE}/{tipo}/marcas")
    alvo = _norm(marca)
    m = next((x for x in marcas if _norm(x["nome"]) == alvo), None) or next(
        (x for x in marcas if alvo and alvo in _norm(x["nome"])), None
    )
    if m is None:
        raise FerramentaFalhou(f"Marca '{marca}' não encontrada na FIPE.")
    modelos = (await _json(cliente, f"{FIPE}/{tipo}/marcas/{m['codigo']}/modelos"))["modelos"]
    palavras = _norm(modelo).split()
    candidatos = [x for x in modelos if all(p in _norm(x["nome"]) for p in palavras)][:12]
    if not candidatos:
        raise FerramentaFalhou(f"Modelo '{modelo}' não encontrado na FIPE para {m['nome']}.")

    async def versoes(mod: dict[str, Any]) -> list[dict[str, Any]]:
        base = f"{FIPE}/{tipo}/marcas/{m['codigo']}/modelos/{mod['codigo']}/anos"
        try:
            anos = await _json(cliente, base)
        except FerramentaFalhou:
            return []
        escolhidos = [a for a in anos if not ano or str(a["codigo"]).startswith(str(ano))][:2]
        saida = []
        for a in escolhidos:
            try:
                v = await _json(cliente, f"{base}/{a['codigo']}")
            except FerramentaFalhou:
                continue
            valor = float(re.sub(r"[^\d,]", "", v["Valor"]).replace(",", "."))
            saida.append(
                {
                    "modelo": v["Modelo"],
                    "ano": v["AnoModelo"],
                    "combustivel": v.get("Combustivel"),
                    "valor": valor,
                    "referencia": v.get("MesReferencia", "").strip(),
                    "codigo_fipe": v.get("CodigoFipe"),
                }
            )
        return saida

    todas = [v for lista in await asyncio.gather(*(versoes(c) for c in candidatos)) for v in lista]
    if not todas:
        raise FerramentaFalhou(f"Sem preço FIPE de {m['nome']} {modelo} {ano}.")
    valores = sorted(v["valor"] for v in todas)
    return {
        "fonte": "Tabela FIPE (parallelum.com.br)",
        "marca": m["nome"],
        "versoes": todas,
        "menor": valores[0],
        "maior": valores[-1],
        "media": round(sum(valores) / len(valores), 2),
    }


# ---------- busca na web ----------


def _texto_html(pagina: str) -> str:
    pagina = re.sub(
        r"(?is)<(script|style|noscript|svg|nav|footer|header)[^>]*>.*?</\1>", " ", pagina
    )
    texto = html.unescape(re.sub(r"(?s)<[^>]+>", " ", pagina))
    return re.sub(r"\s+", " ", texto).strip()


async def buscar_web(
    cliente: httpx.AsyncClient,
    consulta: str,
    ler: int = 2,
    achados: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Resultados da busca (título, endereço, trecho) e o texto das [ler] primeiras páginas.
    [achados]: a busca já feita no PC (`shared.web_search` pelo worker); sem ela, busca daqui."""
    if not achados:
        try:
            achados = await web_search.search(cliente, consulta)
        except web_search.SearchFailed as e:
            raise FerramentaFalhou(f"busca: {e}") from e
    resultados = [dict(x) for x in achados["resultados"]]

    async def ler_pagina(res: dict[str, Any]) -> None:
        try:
            p = await cliente.get(
                res["url"], headers={"User-Agent": AGENTE}, timeout=10, follow_redirects=True
            )
            if "html" in p.headers.get("content-type", ""):
                res["texto"] = _texto_html(p.text)[:3500]
        except httpx.HTTPError:
            pass

    await asyncio.gather(*(ler_pagina(x) for x in resultados[:ler]))
    return {"fonte": achados["fonte"], "consulta": consulta, "resultados": resultados}
