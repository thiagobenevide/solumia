import asyncio

import httpx
import pytest

from shared import web_search

RSS = """<?xml version="1.0"?><rss><channel>
<item><title>Klabin (KLBN11)</title><link>https://ex.com/klbn11</link>
<description>Cotação &amp; notícias</description></item></channel></rss>"""
DDG = """<a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fex.com%2Fd">Título</a>
<a class="result__snippet" href="#">trecho <b>bom</b></a>"""


def _search(bing: httpx.Response, ddg: httpx.Response) -> dict:
    def rota(pedido: httpx.Request) -> httpx.Response:
        return bing if pedido.url.host == "www.bing.com" else ddg

    async def rodar() -> dict:
        async with httpx.AsyncClient(transport=httpx.MockTransport(rota)) as c:
            return await web_search.search(c, "klabin")

    return asyncio.run(rodar())


def test_bing_first():
    r = _search(httpx.Response(200, text=RSS), httpx.Response(500))
    assert r["fonte"] == "Bing"
    assert r["resultados"] == [
        {
            "titulo": "Klabin (KLBN11)",
            "url": "https://ex.com/klbn11",
            "trecho": "Cotação & notícias",
        }
    ]


def test_empty_bing_falls_back_to_duckduckgo():
    empty = httpx.Response(200, text="<rss><channel></channel></rss>")
    r = _search(empty, httpx.Response(200, text=DDG))
    assert r["fonte"] == "DuckDuckGo"
    assert r["resultados"][0] == {
        "titulo": "Título",
        "url": "https://ex.com/d",
        "trecho": "trecho bom",
    }


def test_block_becomes_error_not_empty_list():
    # 202 without results is DuckDuckGo's anti-bot block
    with pytest.raises(web_search.SearchFailed, match="no results"):
        _search(httpx.Response(200, text="<rss><channel/></rss>"), httpx.Response(202, text="x"))
