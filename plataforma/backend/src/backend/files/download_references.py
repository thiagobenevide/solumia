"""Download automático do PDF de uma referência de acesso aberto. Procura a obra no OpenAlex
(pelo DOI do texto da referência ou, sem DOI, pelo título, aceitando só título bem parecido) e
tenta os links de PDF aberto que ele conhece, mais os links `.pdf`/arXiv da própria referência.
Só aceita resposta que começa com `%PDF`; obra fechada (paywall) simplesmente fica sem PDF."""

from __future__ import annotations

import logging
import re
import unicodedata
from difflib import SequenceMatcher
from typing import Any

import httpx

logger = logging.getLogger("gateway.mapeamento")

OPENALEX = "https://api.openalex.org/works"
AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124 Safari/537.36"
)
LIMIT_BYTES = 80 * 1024 * 1024
SIMILARITY_TITLE = 0.85


def _norm(text: str) -> str:
    t = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", t).strip()


def doi_of_reference(text: str) -> str | None:
    m = re.search(r"\b(10\.\d{4,9}/[^\s\"<>]+)", text, re.IGNORECASE)
    return re.sub(r"[.,;)\]]+$", "", m.group(1)) if m else None


def links_of_reference(text: str) -> list[str]:
    """Links diretos para PDF citados na referência (terminados em .pdf ou do arXiv)."""
    links = []
    for url in re.findall(r"https?://[^\s<>)\]]+", text):
        url = re.sub(r"[.,;]+$", "", url)
        arxiv = re.search(r"arxiv\.org/abs/([\w.\-/]+)", url)
        if arxiv:
            links.append(f"https://arxiv.org/pdf/{arxiv.group(1)}")
        elif url.lower().split("?")[0].endswith(".pdf"):
            links.append(url)
    return links


def links_openalex(work: dict[str, Any]) -> list[str]:
    """Links de PDF aberto de uma obra do OpenAlex, do melhor para o pior."""
    links = []
    for loc in [work.get("best_oa_location") or {}, *(work.get("locations") or [])]:
        if loc.get("pdf_url") and loc.get("is_oa"):
            links.append(loc["pdf_url"])
    oa = (work.get("open_access") or {}).get("oa_url")
    if oa:
        links.append(oa)
    return list(dict.fromkeys(links))


async def _work(cliente: httpx.AsyncClient, ref: dict[str, Any]) -> dict[str, Any] | None:
    doi = doi_of_reference(ref.get("referencia") or "")
    if doi:
        r = await cliente.get(f"{OPENALEX}/doi:{doi}")
        if r.status_code == 200:
            return dict(r.json())
    title = (ref.get("titulo") or "").strip()
    if len(title) < 12:
        return None
    r = await cliente.get(OPENALEX, params={"search": title, "per-page": 5})
    if r.status_code != 200:
        return None
    target = _norm(title)
    for work in r.json().get("results") or []:
        name = _norm(work.get("title") or "")
        if name and SequenceMatcher(None, target, name).ratio() >= SIMILARITY_TITLE:
            return dict(work)
    return None


async def _download(cliente: httpx.AsyncClient, url: str) -> bytes | None:
    try:
        async with cliente.stream("GET", url, headers={"Accept": "application/pdf,*/*"}) as r:
            if r.status_code != 200:
                return None
            parts, total = [], 0
            async for block in r.aiter_bytes():
                if not parts and not block.lstrip()[:5].startswith(b"%PDF"):
                    return None  # página HTML (paywall, captcha): não é o PDF
                total += len(block)
                if total > LIMIT_BYTES:
                    return None
                parts.append(block)
            return b"".join(parts) or None
    except httpx.HTTPError:
        return None


def _doi_url(doi: str) -> str:
    doi = re.sub(r"^https?://(dx\.)?doi\.org/", "", doi.strip(), flags=re.IGNORECASE)
    return f"https://doi.org/{doi}" if doi else ""


async def fetch_pdf_open(
    ref: dict[str, Any], extras: list[str] | None = None, baixar: bool = True
) -> dict[str, Any]:
    """Acha a obra (OpenAlex) e, com [baixar], o PDF de acesso aberto. Devolve `pdf` (bytes ou
    `None`), `url_pdf` (de onde veio), `doi` e `link` (página do artigo: DOI, página do periódico
    ou o próprio PDF), para a planilha citar com o link. [extras]: links de PDF já conhecidos
    (achados na web), tentados primeiro."""
    found: dict[str, Any] = {"pdf": None, "url_pdf": "", "doi": "", "link": ""}
    doi = doi_of_reference(ref.get("referencia") or "")
    if doi:
        found["doi"] = doi
        found["link"] = _doi_url(doi)
    async with httpx.AsyncClient(
        timeout=httpx.Timeout(30, connect=10),
        follow_redirects=True,
        headers={"User-Agent": AGENT},
    ) as cliente:
        candidates = [*(extras or []), *links_of_reference(ref.get("referencia") or "")]
        try:
            work = await _work(cliente, ref)
        except (httpx.HTTPError, ValueError):
            work = None
        if work:
            candidates += links_openalex(work)
            if work.get("doi") and not found["doi"]:
                found["doi"] = re.sub(r"^https?://doi\.org/", "", work["doi"])
            page = (work.get("primary_location") or {}).get("landing_page_url") or ""
            found["link"] = found["link"] or _doi_url(found["doi"]) or page
        if baixar:
            for url in dict.fromkeys(candidates):
                pdf = await _download(cliente, url)
                if pdf:
                    logger.info("PDF aberto baixado para %r: %s", ref.get("titulo"), url)
                    found.update(pdf=pdf, url_pdf=url)
                    found["link"] = found["link"] or url
                    break
    return found
