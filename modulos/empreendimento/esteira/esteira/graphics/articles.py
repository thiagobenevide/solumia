"""PDF de cada fonte do roteiro e o trecho dele que sustenta uma fala (para a citação em tela).

Ordem de busca do PDF: `cache/artigos/` (já baixado) → pasta de artigos do vault (título no nome do
arquivo ou nos metadados) → versão de acesso aberto pelo DOI (OpenAlex) ou link direto para .pdf da fonte.
"""
import re
import unicodedata
from difflib import SequenceMatcher
from pathlib import Path

import pymupdf
import requests

from esteira.core import events
from esteira.project import CACHE

CACHE = CACHE / "artigos"
UA = {"User-Agent": "esteira-dark/1.0 (pesquisa de citações para vídeos)"}


def _slug(t):
    s = unicodedata.normalize("NFKD", t.lower())
    return re.sub(r"[^a-z0-9]+", "-", "".join(c for c in s if not unicodedata.combining(c))).strip("-")[:60]


def _resembles(titulo, arq):
    """O PDF é desse artigo? Compara o título com o nome do arquivo, os metadados e a 1ª página."""
    alvo = _slug(titulo)
    if SequenceMatcher(None, alvo, _slug(arq.stem)).ratio() >= 0.7:
        return True
    try:
        doc = pymupdf.open(arq)
        meta = _slug(doc.metadata.get("title") or "")
        pag1 = _slug(doc[0].get_text()[:1500]) if len(doc) else ""
    except Exception:
        return False
    return SequenceMatcher(None, alvo, meta).ratio() >= 0.7 or alvo[:40] in pag1


def _download(url, destino):
    try:
        r = requests.get(url, headers=UA, timeout=40, allow_redirects=True)
    except requests.RequestException:
        return False
    if r.status_code != 200 or not r.content.startswith(b"%PDF"):
        return False
    destino.parent.mkdir(parents=True, exist_ok=True)
    destino.write_bytes(r.content)
    return True


def _urls_openalex(doi):
    try:
        w = requests.get(f"https://api.openalex.org/works/doi:{doi}", headers=UA, timeout=20).json()
    except (requests.RequestException, ValueError):
        return []
    locs = [w.get("best_oa_location") or {}] + (w.get("locations") or [])
    return [u for l in locs for u in (l.get("pdf_url"),) if u]


def find_pdf(fonte, pasta_vault=None):
    """Caminho do PDF da fonte, ou None."""
    destino = CACHE / f"{_slug(fonte['titulo'])}.pdf"
    if destino.exists():
        return destino
    if pasta_vault:
        for arq in Path(pasta_vault).expanduser().glob("*.pdf"):
            if _resembles(fonte["titulo"], arq):
                return arq
    urls = [fonte["url"]] if fonte.get("url", "") and fonte["url"].lower().endswith(".pdf") else []
    if fonte.get("doi"):
        urls += _urls_openalex(fonte["doi"])
    for u in urls:
        if _download(u, destino) and _resembles(fonte["titulo"], destino):
            events.debug("artigo baixado", titulo=fonte["titulo"][:60], url=u)
            return destino
        destino.unlink(missing_ok=True)
    return None


NUM = re.compile(r"\d+(?:[.,]\d+)?")


def _numbers(texto):
    return {n.replace(",", ".").rstrip("0").rstrip(".") for n in NUM.findall(texto)}


def candidates_span(pdf, fala, termos_en=(), max_paginas=30, n=8):
    """Frases do PDF que mais se parecem com a fala: números iguais pesam mais que palavras-chave."""
    doc = pymupdf.open(pdf)
    nums, termos = _numbers(fala) - {"1", "2", "3"}, {t.lower() for t in termos_en}
    saida = []
    for k in range(min(len(doc), max_paginas)):
        texto = re.sub(r"-\n(?=\w)", "", doc[k].get_text())  # junta palavras hifenizadas
        texto = re.sub(r"\s+", " ", texto)
        for frase in re.split(r"(?<=[.!?])\s+(?=[A-Z])", texto):
            if not 40 <= len(frase) <= 400:
                continue
            nota = 3 * len(nums & _numbers(frase)) + sum(t in frase.lower() for t in termos)
            if nota:
                saida.append((nota, k, frase.strip()))
    saida.sort(key=lambda x: (-x[0], x[1]))
    return saida[:n]
