"""Web search without an API key: Bing's RSS feed and, if it returns nothing, DuckDuckGo's
HTML page.

Runs on the worker (home IP) and, without a worker, on the VPS. Search engines block datacenter IPs
(Bing returns an empty list) and bursts (DuckDuckGo answers 202 with no results), so "no results"
from every engine becomes [SearchFailed] instead of an empty search that the AI would read as
"there is nothing".
"""

import html
import re
from typing import Any
from urllib.parse import parse_qs, unquote, urlparse
from xml.etree import ElementTree

import httpx

USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/130 Safari/537.36"
)
_HEADERS = {"User-Agent": USER_AGENT, "Accept-Language": "pt-BR,pt;q=0.9"}

_HTML_TAG = re.compile(r"(?s)<[^>]+>")
_WHITESPACE = re.compile(r"\s+")
_DUCKDUCKGO_RESULT = re.compile(
    r'(?s)<a[^>]+class="result__a"[^>]+href="([^"]+)"[^>]*>(.*?)</a>.*?'
    r'class="result__snippet"[^>]*>(.*?)</a>'
)


class SearchFailed(RuntimeError):
    pass


def _clean_text(fragment: str) -> str:
    """Removes HTML tags and entities and collapses whitespace."""
    without_tags = _HTML_TAG.sub(" ", fragment)
    unescaped = html.unescape(without_tags)
    return _WHITESPACE.sub(" ", unescaped).strip()


def _unwrap_duckduckgo_link(href: str) -> str:
    """DuckDuckGo wraps the real link in its redirector (`...?uddg=<real url>`)."""
    if "uddg=" not in href:
        return href
    query = parse_qs(urlparse(html.unescape(href)).query)
    values = query.get("uddg")
    if not values:
        return href
    return unquote(values[0])


# The result keys ("titulo", "url", "trecho") are part of the contract with the backend and the app.
async def _search_bing(client: httpx.AsyncClient, query: str) -> list[dict[str, str]]:
    response = await client.get(
        "https://www.bing.com/search",
        params={"q": query, "format": "rss", "mkt": "pt-BR", "setlang": "pt-BR"},
        headers=_HEADERS,
        timeout=15,
    )
    response.raise_for_status()

    results = []
    items = ElementTree.fromstring(response.content).findall("./channel/item")
    for item in items:
        link = item.findtext("link")
        if not link:
            continue
        results.append({
            "titulo": _clean_text(item.findtext("title") or ""),
            "url": link,
            "trecho": _clean_text(item.findtext("description") or ""),
        })
    return results


async def _search_duckduckgo(client: httpx.AsyncClient, query: str) -> list[dict[str, str]]:
    response = await client.post(
        "https://html.duckduckgo.com/html/",
        data={"q": query, "kl": "br-pt"},
        headers=_HEADERS,
        timeout=15,
    )
    response.raise_for_status()

    results = []
    for href, title, snippet in _DUCKDUCKGO_RESULT.findall(response.text):
        results.append({
            "titulo": _clean_text(title),
            "url": _unwrap_duckduckgo_link(href),
            "trecho": _clean_text(snippet),
        })
    return results


async def search(client: httpx.AsyncClient, query: str, limit: int = 6) -> dict[str, Any]:
    """`{"fonte", "resultados": [{titulo, url, trecho}]}` from the first engine that answers."""
    engines = [("Bing", _search_bing), ("DuckDuckGo", _search_duckduckgo)]
    errors = []
    for engine_name, engine in engines:
        try:
            results = await engine(client, query)
        except (httpx.HTTPError, ElementTree.ParseError) as error:
            errors.append(f"{engine_name}: {error.__class__.__name__}")
            continue
        if results:
            return {"fonte": engine_name, "resultados": results[:limit]}
        errors.append(f"{engine_name}: no results")
    raise SearchFailed("search engines blocked or did not answer (" + "; ".join(errors) + ")")
