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


def _resembles(titulo, file):
    """O PDF é desse artigo? Compara o título com o nome do arquivo, os metadados e a 1ª página."""
    target = _slug(titulo)
    if SequenceMatcher(None, target, _slug(file.stem)).ratio() >= 0.7:
        return True
    try:
        doc = pymupdf.open(file)
        meta = _slug(doc.metadata.get("title") or "")
        pag1 = _slug(doc[0].get_text()[:1500]) if len(doc) else ""
    except Exception:
        return False
    return SequenceMatcher(None, target, meta).ratio() >= 0.7 or target[:40] in pag1


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


def find_pdf(fonte, folder_vault=None):
    """Caminho do PDF da fonte, ou None."""
    destination = CACHE / f"{_slug(fonte['titulo'])}.pdf"
    if destination.exists():
        return destination
    if folder_vault:
        for file in Path(folder_vault).expanduser().glob("*.pdf"):
            if _resembles(fonte["titulo"], file):
                return file
    urls = [fonte["url"]] if fonte.get("url", "") and fonte["url"].lower().endswith(".pdf") else []
    if fonte.get("doi"):
        urls += _urls_openalex(fonte["doi"])
    for u in urls:
        if _download(u, destination) and _resembles(fonte["titulo"], destination):
            events.debug("artigo baixado", titulo=fonte["titulo"][:60], url=u)
            return destination
        destination.unlink(missing_ok=True)
    return None


NUM = re.compile(r"\d+(?:[.,]\d+)?")


def _numbers(texto):
    return {n.replace(",", ".").rstrip("0").rstrip(".") for n in NUM.findall(texto)}


def candidates_span(pdf, fala, terms_en=(), max_pages=30, n=8):
    """Frases do PDF que mais se parecem com a fala: números iguais pesam mais que palavras-chave."""
    doc = pymupdf.open(pdf)
    nums, terms = _numbers(fala) - {"1", "2", "3"}, {t.lower() for t in terms_en}
    output = []
    for k in range(min(len(doc), max_pages)):
        text = re.sub(r"-\n(?=\w)", "", doc[k].get_text())  # junta palavras hifenizadas
        text = re.sub(r"\s+", " ", text)
        for sentence in re.split(r"(?<=[.!?])\s+(?=[A-Z])", text):
            if not 40 <= len(sentence) <= 400:
                continue
            note = 3 * len(nums & _numbers(sentence)) + sum(t in sentence.lower() for t in terms)
            if note:
                output.append((note, k, sentence.strip()))
    output.sort(key=lambda x: (-x[0], x[1]))
    return output[:n]
