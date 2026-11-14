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
AGENTE = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124 Safari/537.36"
)
LIMITE_BYTES = 80 * 1024 * 1024
SEMELHANCA_TITULO = 0.85


def _norma(texto: str) -> str:
    t = unicodedata.normalize("NFKD", texto).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", t).strip()


def doi_da_referencia(texto: str) -> str | None:
    m = re.search(r"\b(10\.\d{4,9}/[^\s\"<>]+)", texto, re.IGNORECASE)
    return re.sub(r"[.,;)\]]+$", "", m.group(1)) if m else None


def links_da_referencia(texto: str) -> list[str]:
    """Links diretos para PDF citados na referência (terminados em .pdf ou do arXiv)."""
    links = []
    for url in re.findall(r"https?://[^\s<>)\]]+", texto):
        url = re.sub(r"[.,;]+$", "", url)
        arxiv = re.search(r"arxiv\.org/abs/([\w.\-/]+)", url)
        if arxiv:
            links.append(f"https://arxiv.org/pdf/{arxiv.group(1)}")
        elif url.lower().split("?")[0].endswith(".pdf"):
            links.append(url)
    return links


def links_openalex(obra: dict[str, Any]) -> list[str]:
    """Links de PDF aberto de uma obra do OpenAlex, do melhor para o pior."""
    links = []
    for loc in [obra.get("best_oa_location") or {}, *(obra.get("locations") or [])]:
        if loc.get("pdf_url") and loc.get("is_oa"):
            links.append(loc["pdf_url"])
    oa = (obra.get("open_access") or {}).get("oa_url")
    if oa:
        links.append(oa)
    return list(dict.fromkeys(links))


async def _obra(cliente: httpx.AsyncClient, ref: dict[str, Any]) -> dict[str, Any] | None:
    doi = doi_da_referencia(ref.get("referencia") or "")
    if doi:
        r = await cliente.get(f"{OPENALEX}/doi:{doi}")
        if r.status_code == 200:
            return dict(r.json())
    titulo = (ref.get("titulo") or "").strip()
    if len(titulo) < 12:
        return None
    r = await cliente.get(OPENALEX, params={"search": titulo, "per-page": 5})
    if r.status_code != 200:
        return None
    alvo = _norma(titulo)
    for obra in r.json().get("results") or []:
        nome = _norma(obra.get("title") or "")
        if nome and SequenceMatcher(None, alvo, nome).ratio() >= SEMELHANCA_TITULO:
            return dict(obra)
    return None


async def _baixar(cliente: httpx.AsyncClient, url: str) -> bytes | None:
    try:
        async with cliente.stream("GET", url, headers={"Accept": "application/pdf,*/*"}) as r:
            if r.status_code != 200:
                return None
            partes, total = [], 0
            async for bloco in r.aiter_bytes():
                if not partes and not bloco.lstrip()[:5].startswith(b"%PDF"):
                    return None  # página HTML (paywall, captcha): não é o PDF
                total += len(bloco)
                if total > LIMITE_BYTES:
                    return None
                partes.append(bloco)
            return b"".join(partes) or None
    except httpx.HTTPError:
        return None


def _doi_url(doi: str) -> str:
    doi = re.sub(r"^https?://(dx\.)?doi\.org/", "", doi.strip(), flags=re.IGNORECASE)
    return f"https://doi.org/{doi}" if doi else ""


async def buscar_pdf_aberto(
    ref: dict[str, Any], extras: list[str] | None = None, baixar: bool = True
) -> dict[str, Any]:
    """Acha a obra (OpenAlex) e, com [baixar], o PDF de acesso aberto. Devolve `pdf` (bytes ou
    `None`), `url_pdf` (de onde veio), `doi` e `link` (página do artigo: DOI, página do periódico
    ou o próprio PDF), para a planilha citar com o link. [extras]: links de PDF já conhecidos
    (achados na web), tentados primeiro."""
    achado: dict[str, Any] = {"pdf": None, "url_pdf": "", "doi": "", "link": ""}
    doi = doi_da_referencia(ref.get("referencia") or "")
    if doi:
        achado["doi"] = doi
        achado["link"] = _doi_url(doi)
    async with httpx.AsyncClient(
        timeout=httpx.Timeout(30, connect=10),
        follow_redirects=True,
        headers={"User-Agent": AGENTE},
    ) as cliente:
        candidatos = [*(extras or []), *links_da_referencia(ref.get("referencia") or "")]
        try:
            obra = await _obra(cliente, ref)
        except (httpx.HTTPError, ValueError):
            obra = None
        if obra:
            candidatos += links_openalex(obra)
            if obra.get("doi") and not achado["doi"]:
                achado["doi"] = re.sub(r"^https?://doi\.org/", "", obra["doi"])
            pagina = (obra.get("primary_location") or {}).get("landing_page_url") or ""
            achado["link"] = achado["link"] or _doi_url(achado["doi"]) or pagina
        if baixar:
            for url in dict.fromkeys(candidatos):
                pdf = await _baixar(cliente, url)
                if pdf:
                    logger.info("PDF aberto baixado para %r: %s", ref.get("titulo"), url)
                    achado.update(pdf=pdf, url_pdf=url)
                    achado["link"] = achado["link"] or url
                    break
    return achado
