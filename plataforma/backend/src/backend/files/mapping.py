"""Reverse citation mapping: the author attaches the document (whole pre-thesis or just a part,
such as the introduction or abstract, as .docx or PDF) to a reading project; the file stays in Files
and Claude (Claude Code, `claude_json` on the worker, never the local LLM or the API) lists the
references (whole document), then the citations (the text in parts, so the answer does not
overflow), links each reference to a library PDF, downloads by itself the PDF of open-access works
(OpenAlex and, without it, Claude searching the web) and finds the cited excerpt in each PDF. The
excerpt becomes a highlight in the PDF, in the project (`projetos: [id]`), already classified
(section, citation type, "Usado"); closed-access references become download to-dos (tasks on the
Routines board). "Refazer" runs everything again and only adds what is not marked yet (highlight id
stable per citation). Nothing stored for the author (comment, note) mentions the AI: they review
and decide."""

from __future__ import annotations

import asyncio
import hashlib
import io
import logging
import re
import subprocess
import unicodedata
import xml.etree.ElementTree as ET
import zipfile
from datetime import UTC, datetime
from difflib import SequenceMatcher
from pathlib import Path
from typing import Annotated, Any

from fastapi import APIRouter, BackgroundTasks, Depends, File, HTTPException, Request, UploadFile
from pydantic import BaseModel

from backend.api.deps import require_client_api_key
from backend.files.download_references import fetch_pdf_open
from backend.files.library import (
    AnnotationsConflict,
    Collection,
    FileInvalid,
    FileNotFound,
)
from backend.files.rewrite import Rewrite

logger = logging.getLogger("gateway.mapeamento")

COLOR_HIGHLIGHT = 0x66FFD54F  # translucent yellow, like a highlighter
LIMIT_CATALOG = 400  # characters of each PDF's first page for Claude to recognize the work
LIMIT_PDF = 160_000  # characters of a PDF per request (large book: only the likely pages)
LIMIT_PART = 30_000  # document characters per citations request
MODEL = "opus"  # delicate mapping: Claude Code's most capable model
SEARCHES_CONCURRENT = 3
TAG_TASK = "download-referencia"

W = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
XHTML = "{http://www.w3.org/1999/xhtml}"


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


# --- document and PDF text ---


def text_docx(content: bytes) -> str:
    """Body paragraphs (with headings marked by `#`) and the footnotes."""
    try:
        zipado = zipfile.ZipFile(io.BytesIO(content))
        body = ET.fromstring(zipado.read("word/document.xml"))
    except (zipfile.BadZipFile, KeyError, ET.ParseError) as e:
        raise FileInvalid("Não consegui ler o .docx (arquivo corrompido?).") from e

    def paragrafos(root: ET.Element) -> list[str]:
        lines = []
        for p in root.iter(f"{W}p"):
            parts = []
            for el in p.iter():
                if el.tag == f"{W}t" and el.text:
                    parts.append(el.text)
                elif el.tag == f"{W}tab":
                    parts.append("\t")
                elif el.tag in (f"{W}br", f"{W}cr"):
                    parts.append("\n")
            text = "".join(parts).strip()
            if not text:
                continue
            style = p.find(f"{W}pPr/{W}pStyle")
            name = (style.get(f"{W}val") or "") if style is not None else ""
            if re.match(r"(?i)(heading|t[ií]tulo|ttulo)\s*\d", name):
                text = "# " + text
            lines.append(text)
        return lines

    lines = paragrafos(body)
    if "word/footnotes.xml" in zipado.namelist():
        notes = paragrafos(ET.fromstring(zipado.read("word/footnotes.xml")))
        if notes:
            lines += ["", "# NOTAS DE RODAPÉ", *notes]
    return "\n".join(lines)


def divide_document(text: str, limite: int = LIMIT_PART) -> list[str]:
    """Parts of up to the limit in characters, cut preferably at a heading (`#`); each part that
    starts in the middle of a section carries its heading, so the citation comes out with the right
    section."""
    parts: list[str] = []
    current: list[str] = []
    size, secao, secao_of_part = 0, "", ""
    for line in text.splitlines():
        title = line.startswith("# ")
        if current and size + len(line) > limite and (title or size > limite * 0.6):
            parts.append(("" if current[0].startswith("# ") or not secao_of_part
                           else f"(continuação da seção: {secao_of_part})\n") + "\n".join(current))
            current, size, secao_of_part = [], 0, secao
        if title:
            secao = line[2:].strip()
            if not current:
                secao_of_part = secao
        current.append(line)
        size += len(line) + 1
    if current:
        parts.append(("" if current[0].startswith("# ") or not secao_of_part
                       else f"(continuação da seção: {secao_of_part})\n") + "\n".join(current))
    return [x for x in parts if x.strip()]


def pages_pdf(pdf: Path) -> list[str]:
    """Text of each page (pdftotext; pages separated by form feed)."""
    try:
        r = subprocess.run(
            ["pdftotext", str(pdf), "-"], capture_output=True, timeout=120, text=True
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return []
    pages = r.stdout.split("\f")
    if pages and not pages[-1].strip():
        pages.pop()
    return pages


def words_pdf(pdf: Path, page: int) -> list[tuple[str, list[float], int]]:
    """Words of the page (0-based) with their box in PDF points, origin at the top corner (like the
    app reader) and the line number."""
    try:
        r = subprocess.run(
            ["pdftotext", "-bbox-layout", "-f", str(page + 1), "-l", str(page + 1),
             str(pdf), "-"],
            capture_output=True, timeout=60, text=True,
        )
        root = ET.fromstring(r.stdout)
    except (FileNotFoundError, subprocess.TimeoutExpired, ET.ParseError):
        return []
    words = []
    for n, line in enumerate(root.iter(f"{XHTML}line")):
        for w in line.iter(f"{XHTML}word"):
            box = [float(w.get(k) or 0) for k in ("xMin", "yMin", "xMax", "yMax")]
            words.append((w.text or "", box, n))
    return words


def _norm(text: str) -> str:
    without_accent = unicodedata.normalize("NFKD", text.lower()).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]", "", without_accent)


def _tokens(text: str) -> list[str]:
    text = re.sub(r"(\w)-\s*\n\s*(\w)", r"\1\2", text)  # line-break hyphenation
    return [t for t in (_norm(p) for p in text.split()) if t]


def locate(
    words: list[tuple[str, list[float], int]], span: str
) -> tuple[list[list[float]], str, float]:
    """Finds the excerpt in the page words (approximate: the PDF breaks lines, hyphenates and
    sometimes the excerpt comes with small differences). Returns one rectangle per line, the text as
    it is in the PDF and the coverage (0–1)."""
    target = _tokens(span)
    if not target or not words:
        return [], "", 0.0
    # join a hyphenated word at the end of the line with the first one of the next line
    toks: list[str] = []
    origin: list[list[int]] = []
    i = 0
    while i < len(words):
        text, _, line = words[i]
        idx = [i]
        if (
            text.endswith("-") and i + 1 < len(words) and words[i + 1][2] != line
        ):
            text = text[:-1] + words[i + 1][0]
            idx.append(i + 1)
            i += 1
        t = _norm(text)
        if t:
            toks.append(t)
            origin.append(idx)
        i += 1
    blocks = [
        b for b in SequenceMatcher(None, toks, target, autojunk=False).get_matching_blocks()
        if b.size
    ]
    if not blocks:
        return [], "", 0.0
    largest = max(blocks, key=lambda b: b.size)
    slack = max(8, len(target) // 3)
    chosen = [
        b for b in blocks
        if largest.a - len(target) - slack <= b.a <= largest.a + len(target) + slack
    ]
    coverage = sum(b.size for b in chosen) / len(target)
    start = min(b.a for b in chosen)
    end = max(b.a + b.size for b in chosen)
    indexes = [j for k in range(start, end) for j in origin[k]]
    by_line: dict[int, list[float]] = {}
    for j in indexes:
        _, c, line = words[j]
        r = by_line.get(line)
        by_line[line] = (
            list(c) if r is None
            else [min(r[0], c[0]), min(r[1], c[1]), max(r[2], c[2]), max(r[3], c[3])]
        )
    retangulos = [[round(v, 2) for v in by_line[k]] for k in sorted(by_line)]
    text_pdf = " ".join(words[j][0] for j in indexes)
    return retangulos, text_pdf, coverage


# --- Claude ---

SYSTEM_REFERENCES = """You analyze Brazilian academic works (TCC pre-project, monograph, paper) in \
ABNT format for the reverse mapping of citations: you list the works the document cites, so that \
the author can mark the passages in the original works.

Fixed rules:
- One entry per work in the document's REFERENCES list and also per work cited in the text that is \
not in the list (`fora_da_lista` = true). The document may be only a part of the work \
(introduction, abstract, one chapter) with no reference list: then build one entry for each work \
cited in the text, all with `fora_da_lista` = true.
- `referencia`: the complete entry as it is in the document; without it, what the text brings \
("SILVA, 2020"). `autor_citacao`: as it appears in the text ("Silva", "Silva e Souza", "Silva et \
al."). `titulo`: only the title of the work, as it is in the document; "" if the document does not \
give it.
- `arquivo_id`: the id in the library's PDF catalog that is this very same work (check title, \
authors and year from the start of the text); "" if none is it. Never link to a similar work.
- Do not invent works or complete data the document does not give."""

SCHEMA_REFERENCES = {
    "type": "object",
    "properties": {
        "referencias": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "n": {"type": "integer"},
                    "referencia": {"type": "string"},
                    "autor_citacao": {"type": "string"},
                    "ano": {"type": "string"},
                    "titulo": {"type": "string"},
                    "arquivo_id": {"type": "string"},
                    "fora_da_lista": {"type": "boolean"},
                },
                "required": ["n", "referencia", "autor_citacao", "ano", "titulo", "arquivo_id",
                             "fora_da_lista"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["referencias"],
    "additionalProperties": False,
}

SYSTEM_QUOTES = """You do the reverse mapping of the citations of a Brazilian academic work \
(ABNT): you receive the numbered list of cited works and one part of the text, and you list each \
citation made in that part.

Fixed rules:
- Each occurrence of a citation in the body of the text, in order, with `ref` = the number of the \
work in the list. Ignore the reference list itself, the table of contents and headers.
- `trecho_documento`: the sentence (or sentences) of the document that brings the citation, copied \
as it is.
- `citacao`: for direct quotes, only the text in quotation marks or the indented block; "" for \
indirect ones.
- `tipo`: "direta", "indireta" or "apud" (a citation of a citation: `ref` is the work consulted, \
the one that has the "apud").
- `pagina`: the cited page as it is ("p. 23"), or "".
- `secao`: the title of the section where the citation is (lines starting with # are titles; \
"continuação da seção" gives the section at the start of the part). With no marked titles, use \
the title the text shows (e.g.: "Introdução", "Resumo").
- One sentence citing two works produces two citations. Do not invent citations; a citation of a \
work that is not in the list is left out."""

SCHEMA_QUOTES = {
    "type": "object",
    "properties": {
        "citacoes": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "ref": {"type": "integer"},
                    "trecho_documento": {"type": "string"},
                    "citacao": {"type": "string"},
                    "tipo": {"type": "string", "enum": ["direta", "indireta", "apud"]},
                    "pagina": {"type": "string"},
                    "secao": {"type": "string"},
                },
                "required": ["ref", "trecho_documento", "citacao", "tipo", "pagina", "secao"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["citacoes"],
    "additionalProperties": False,
}

SYSTEM_FETCH = """You find on the internet the free, public PDF of an academic work cited in a \
paper, to download it. Use web search and open the pages to check them.

Fixed rules:
- Identify the work by its reference; if it is incomplete (only author and year), use the \
sentences that cite it to find out which one it is. Without certainty that it is the same work, \
`encontrado` = false.
- `urls_pdf`: links that directly download the PDF of the work itself (same title, authors and \
year; a preprint/accepted version of the same work counts), in open access: institutional \
repositories, SciELO, PubMed Central, arXiv, the journal's or the author's site. From best to \
worst. Never pirate sites or pages that ask for login or payment.
- `titulo`, `doi` and `referencia_completa` (ABNT) of the identified work; "" for whatever you \
cannot find.
- Closed work, with no public PDF: `encontrado` = true and empty `urls_pdf`."""

SCHEMA_FETCH = {
    "type": "object",
    "properties": {
        "encontrado": {"type": "boolean"},
        "titulo": {"type": "string"},
        "doi": {"type": "string"},
        "referencia_completa": {"type": "string"},
        "urls_pdf": {"type": "array", "items": {"type": "string"}},
        "observacao": {"type": "string"},
    },
    "required": ["encontrado", "titulo", "doi", "referencia_completa", "urls_pdf", "observacao"],
    "additionalProperties": False,
}

SYSTEM_LOCATE = """You check the citations of an academic work against the original works, as the \
author would with a highlighter: for each citation, you find in the work the passage it uses.

Fixed rules:
- The work comes page by page ("=== Page N ===", N is the PDF page, which may differ from the \
printed numbering cited in the paper).
- `trecho`: copy from the work, word for word as it is in the page text (even with extraction \
errors), the passage the citation uses: for direct quotes, exactly the quoted text; for indirect \
ones (paraphrase), the sentence or the few sentences that support the idea (at most one \
paragraph).
- `pagina`: the N of the page where the passage starts. If the citation is not in this work or in \
the pages sent, return `encontrado` = false, with the reason in `observacao` (in Brazilian \
Portuguese).
- `confianca`: "alta" when the passage is clearly the cited one, "media" or "baixa" when it is the \
most likely one. Do not invent text that is not in the work."""

SCHEMA_LOCATE = {
    "type": "object",
    "properties": {
        "trechos": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "c": {"type": "integer"},
                    "encontrado": {"type": "boolean"},
                    "pagina": {"type": "integer"},
                    "trecho": {"type": "string"},
                    "confianca": {"type": "string", "enum": ["alta", "media", "baixa"]},
                    "observacao": {"type": "string"},
                },
                "required": ["c", "encontrado", "pagina", "trecho", "confianca", "observacao"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["trechos"],
    "additionalProperties": False,
}


def prompt_references(document: str, catalog: list[dict[str, Any]]) -> str:
    lines = [
        f'- id "{c["id"]}" · file: {c["titulo"]}'
        + (f" · record: {c['ficha']}" if c.get("ficha") else "")
        + f"\n  start: {c['inicio']}"
        for c in catalog
    ]
    return (
        "<pdf_catalog>\n" + ("\n".join(lines) or "(empty library)")
        + "\n</pdf_catalog>\n\n<document>\n" + document + "\n</document>\n\n"
        "List every work cited in the document, linking it to the catalog."
    )


def _list_works(refs: dict[int, dict[str, Any]]) -> str:
    return "\n".join(
        f"{n}. {r['autor_citacao']} ({r['ano']})"
        + (f" — {r['titulo']}" if r.get("titulo") else "")
        + f" · {r['referencia'][:240]}"
        for n, r in sorted(refs.items())
    )


def prompt_quotes(part: str, refs: dict[int, dict[str, Any]], k: int, total: int) -> str:
    return (
        f"<works>\n{_list_works(refs)}\n</works>\n\n"
        f"<text part=\"{k} of {total}\">\n{part}\n</text>\n\n"
        "List every citation in this part of the text."
    )


def prompt_fetch(ref: dict[str, Any], cits: list[dict[str, Any]]) -> str:
    sentences = "\n".join(f"- {c['trecho_documento'][:400]}" for c in cits[:4])
    return (
        f"Reference as it is in the paper: {ref['referencia']}\n"
        f"Author in the text: {ref['autor_citacao']} · year: {ref['ano']}"
        + (f" · title: {ref['titulo']}" if ref.get("titulo") else "")
        + (f"\n\nSentences of the paper that cite the work:\n{sentences}" if sentences else "")
        + "\n\nFind the public PDF of this work."
    )


def _pages_likely(pages: list[str], citacoes: list[dict[str, Any]]) -> list[int]:
    """Large book: the pages with the most words in common with the citations, up to the limit."""
    total = sum(len(p) for p in pages)
    if total <= LIMIT_PDF:
        return list(range(len(pages)))
    target = set()
    for c in citacoes:
        target |= {t for t in _tokens(c["citacao"] or c["trecho_documento"]) if len(t) > 4}
    note = sorted(
        range(len(pages)),
        key=lambda i: -len(target & set(_tokens(pages[i]))),
    )
    chosen, soma = [], 0
    for i in note:
        if soma + len(pages[i]) > LIMIT_PDF:
            continue
        chosen.append(i)
        soma += len(pages[i])
    return sorted(chosen)


def prompt_locate(ref: dict[str, Any], citacoes: list[dict[str, Any]], pages: list[str],
                     indexes: list[int]) -> str:
    cits = "\n\n".join(
        f"[{n}] tipo: {c['tipo']}" + (f" · cited page: {c['pagina']}" if c["pagina"] else "")
        + f"\nin the paper: {c['trecho_documento']}"
        + (f"\nquoted text: {c['citacao']}" if c["citacao"] else "")
        for n, c in enumerate(citacoes)
    )
    work = "\n\n".join(f"=== Page {i + 1} ===\n{pages[i].strip()}" for i in indexes)
    return (
        f"Work: {ref['referencia']}\n\n<citations>\n{cits}\n</citations>\n\n"
        f"<work>\n{work}\n</work>\n\nFind in the work the passage of each citation (`c` = the "
        "number in brackets)."
    )


# --- process ---


def _kind_quote(c: dict[str, Any], text: str) -> str:
    if c["tipo"] == "apud":
        return "Citação de citação (apud)"
    if c["tipo"] == "indireta":
        return "Indireta (paráfrase)"
    return "Direta longa (mais de 3 linhas)" if len(text) > 240 else "Direta curta (até 3 linhas)"


def _id_highlight(project_id: str, c: dict[str, Any]) -> str:
    key = f"{c['trecho_documento']}|{c['citacao']}|{c['ref_texto']}"
    return f"map-{project_id}-{hashlib.sha1(key.encode()).hexdigest()[:12]}"


class Mapper:
    """Runs one mapping per project at a time, in the background; the state stays in the project
    (`mapeamento`), for the app to follow."""

    def __init__(self, request_app: Any) -> None:
        self.app = request_app
        self.running: dict[str, asyncio.Task[None]] = {}

    @property
    def collection(self) -> Collection:
        b: Collection = self.app.state.collection
        return b

    @property
    def studies(self) -> Any:
        return self.app.state.studies

    @property
    def claude(self) -> Rewrite:
        r: Rewrite = self.app.state.reescrita
        return r

    def estado(self, project_id: str) -> dict[str, Any]:
        project = self.studies.projects.obter(project_id)
        m: dict[str, Any] = dict(project.get("mapeamento") or {})
        if m.get("estado") == "rodando" and project_id not in self.running:
            m = self._save(project_id, estado="erro", erro="Interrompido (servidor reiniciou).")
        return m

    def _save(self, project_id: str, **fields: Any) -> dict[str, Any]:
        with self.studies.projects.lock:
            project = self.studies.projects.obter(project_id)
            m = {**(project.get("mapeamento") or {}), **fields}
            self.studies.projects.edit(project_id, {"mapeamento": m})
        return m

    def iniciar(self, project_id: str, documento_id: str) -> dict[str, Any]:
        if project_id in self.running:
            raise HTTPException(409, "O mapeamento deste projeto já está rodando.")
        reason = self.claude.disponivel()
        if reason or self.claude.executar_json is None:
            raise HTTPException(503, reason or "Claude indisponível neste servidor.")
        meta = self.collection.obter(documento_id)
        m = self._save(
            project_id,
            documento_id=documento_id,
            documento_titulo=meta["titulo"],
            estado="rodando",
            etapa="Lendo o documento",
            erro=None,
            iniciado=_now(),
        )
        task = asyncio.create_task(self._run(project_id, documento_id))
        self.running[project_id] = task
        task.add_done_callback(lambda _t: self.running.pop(project_id, None))
        return m

    async def _claude(self, prompt: str, system: str, schema: dict[str, Any],
                      limit_s: float, ferramentas: str = "") -> dict[str, Any]:
        assert self.claude.executar_json is not None
        return await self.claude.executar_json({
            "prompt": prompt, "sistema": system, "esquema": schema,
            "effort": "high", "limite_s": limit_s, "modelo": MODEL,
            "ferramentas": ferramentas,
        })

    def _text_document(self, documento_id: str) -> str:
        meta = self.collection.obter(documento_id)
        if meta.get("extensao") == "docx":
            original, _ext = self.collection.path_original(documento_id)
            return text_docx(original.read_bytes())
        pdf = self.collection.path_pdf(documento_id)
        return "\n\n".join(pages_pdf(pdf)) if pdf else ""

    async def _run(self, project_id: str, documento_id: str) -> None:
        try:
            await self._mapear(project_id, documento_id)
        except Exception as e:  # noqa: BLE001 — any failure becomes a readable state in the app
            logger.exception("mapeamento do projeto %s falhou", project_id)
            self._save(project_id, estado="erro", erro=str(e) or type(e).__name__,
                         concluido=_now())

    def _catalog(self, documento_id: str) -> list[dict[str, Any]]:
        cards = {
            x["arquivo_id"]: x for x in self.studies.readings.ler() if x.get("arquivo_id")
        }
        catalog = []
        for meta in self.collection.list_all():
            if meta["id"] == documento_id or meta.get("status") != "pronto":
                continue
            pdf = self.collection.path_pdf(meta["id"])
            if pdf is None or meta.get("tipo") not in ("pdf", "documento"):
                continue
            pages = pages_pdf(pdf)
            start = re.sub(r"\s+", " ", " ".join(pages[:2]))[:LIMIT_CATALOG]
            f = cards.get(meta["id"]) or {}
            card = " · ".join(str(f.get(k)) for k in ("autor", "ano", "titulo") if f.get(k))
            catalog.append({
                "id": meta["id"], "titulo": meta["titulo"], "ficha": card, "inicio": start,
            })
        return catalog

    async def _mapear(self, project_id: str, documento_id: str) -> None:
        document = await asyncio.to_thread(self._text_document, documento_id)
        if not document.strip():
            raise RuntimeError("O documento não tem texto selecionável (PDF escaneado?).")
        self._save(project_id, etapa="Montando o catálogo dos PDFs da biblioteca")
        catalog = await asyncio.to_thread(self._catalog, documento_id)
        ids = {c["id"] for c in catalog}
        self._save(project_id, etapa="Lendo as referências do documento")
        r = await self._claude(prompt_references(document, catalog), SYSTEM_REFERENCES,
                               SCHEMA_REFERENCES, 900)
        refs = {int(x["n"]): x for x in r.get("referencias") or []}
        if not refs:
            raise RuntimeError("Nenhuma citação de obra encontrada no documento.")

        parts = divide_document(document)
        quotes: list[dict[str, Any]] = []
        for k, part in enumerate(parts, 1):
            self._save(project_id, etapa=f"Lendo as citações do texto ({k}/{len(parts)})")
            rc = await self._claude(prompt_quotes(part, refs, k, len(parts)),
                                    SYSTEM_QUOTES, SCHEMA_QUOTES, 900)
            quotes += [c for c in rc.get("citacoes") or [] if int(c.get("ref", -1)) in refs]
        for c in quotes:
            c["ref_texto"] = refs[int(c["ref"])]["referencia"]
        titulos = {m["id"]: m["titulo"] for m in self.collection.list_all()}
        references = []
        for n, ref in sorted(refs.items()):
            aid = ref.get("arquivo_id") or ""
            references.append({
                "n": n,
                "referencia": ref["referencia"],
                "autor_citacao": ref["autor_citacao"],
                "ano": ref["ano"],
                "titulo": ref["titulo"],
                "fora_da_lista": bool(ref.get("fora_da_lista")),
                "arquivo_id": aid if aid in ids else None,
                "arquivo_titulo": titulos.get(aid) if aid in ids else None,
                "citacoes": sum(int(c["ref"]) == n for c in quotes),
                "marcadas": 0,
                "nao_localizadas": [],
            })
        self._save(project_id, referencias=references, citacoes=len(quotes))
        await self._download_abertos(project_id, references, quotes)

        marcadas = 0
        for k, ref in enumerate(references):
            if not ref["arquivo_id"] or not ref["citacoes"]:
                continue
            self._save(
                project_id,
                etapa=f"Procurando as citações em {ref['autor_citacao']} {ref['ano']} "
                f"({k + 1}/{len(references)})",
            )
            cits = [c for c in quotes if int(c["ref"]) == ref["n"]]
            try:
                await self._mark_work(project_id, ref, cits)
            except Exception as e:  # noqa: BLE001 — a work with a problem does not stop the others
                logger.exception("marcação em %s falhou", ref["arquivo_id"])
                ref["nao_localizadas"].append(f"Falhou nesta obra ({e}); toque em Refazer.")
            marcadas += ref["marcadas"]
            self._save(project_id, referencias=references, marcadas=marcadas)

        self._card_readings(references)
        pending = [x for x in references if not x["arquivo_id"]]
        self._tasks_download(project_id, references)
        self._save(
            project_id,
            estado="pronto",
            etapa="",
            referencias=references,
            citacoes=len(quotes),
            marcadas=marcadas,
            pendentes=len(pending),
            concluido=_now(),
        )

    async def _download_abertos(self, project_id: str, referencias: list[dict[str, Any]],
                              citacoes: list[dict[str, Any]]) -> None:
        """For each reference: DOI and article link (for the spreadsheet to cite with the link) and,
        if it has no PDF yet, downloads the open-access one by itself (OpenAlex; without it, Claude
        searches the web) into Files ("Referências" folder). Closed ones stay as to-dos."""
        lock = asyncio.Semaphore(SEARCHES_CONCURRENT)
        done = 0

        async def uma(ref: dict[str, Any]) -> None:
            nonlocal done
            async with lock:
                try:
                    await self._fetch_work(ref, [c for c in citacoes
                                                  if int(c["ref"]) == ref["n"]])
                except Exception:  # noqa: BLE001 — a failure in one work does not stop the mapping
                    logger.exception("busca da referência %r falhou", ref.get("titulo"))
                done += 1
                self._save(project_id, referencias=referencias,
                             etapa=f"Buscando os artigos e os PDFs abertos "
                             f"({done}/{len(referencias)})")

        self._save(project_id,
                     etapa=f"Buscando os artigos e os PDFs abertos (0/{len(referencias)})")
        await asyncio.gather(*(uma(r) for r in referencias))

    async def _fetch_work(self, ref: dict[str, Any], cits: list[dict[str, Any]]) -> None:
        download = not ref["arquivo_id"]
        found = await fetch_pdf_open(ref, baixar=download)
        if (download and found["pdf"] is None) or not found["link"]:
            r = await self._claude(prompt_fetch(ref, cits), SYSTEM_FETCH, SCHEMA_FETCH,
                                   420, ferramentas="WebSearch,WebFetch")
            if r.get("encontrado"):
                if r.get("titulo") and not ref.get("titulo"):
                    ref["titulo"] = r["titulo"]
                if r.get("referencia_completa") and ref.get("fora_da_lista"):
                    ref["referencia_completa"] = r["referencia_completa"]
                extra = f" {r['doi']}" if r.get("doi") else ""
                new = await fetch_pdf_open(
                    {**ref, "referencia": ref["referencia"] + extra},
                    extras=r.get("urls_pdf") or [], baixar=download,
                )
                found = {k: found[k] or new[k] for k in found}
                if not found["link"] and r.get("urls_pdf"):
                    found["link"] = r["urls_pdf"][0]
        ref["doi"] = ref.get("doi") or found["doi"]
        ref["link"] = ref.get("link") or found["link"] or found["url_pdf"]
        if found["pdf"] is None:
            return
        name = re.sub(r'[\\/:*?"<>|\s]+', " ",
                      f"{ref['autor_citacao']} {ref['ano']} - {ref['titulo']}").strip()[:150]
        try:
            meta = await asyncio.to_thread(
                self.collection.adicionar, f"{name or 'referencia'}.pdf", found["pdf"],
                "Referências",
            )
        except FileInvalid:
            return
        ref["arquivo_id"] = meta["id"]
        ref["arquivo_titulo"] = meta["titulo"]
        ref["baixado_auto"] = True
        ref["url_pdf"] = found["url_pdf"]

    async def _mark_work(self, project_id: str, ref: dict[str, Any],
                           cits: list[dict[str, Any]]) -> int:
        aid = ref["arquivo_id"]
        pdf = self.collection.path_pdf(aid)
        if pdf is None:
            return 0
        pages = await asyncio.to_thread(pages_pdf, pdf)
        existentes = {d["id"] for d in self.collection.annotations(aid)["destaques"]}
        a_fazer = [c for c in cits if _id_highlight(project_id, c) not in existentes]
        ref["marcadas"] = len(cits) - len(a_fazer)  # already marked in a previous mapping
        if not a_fazer or not pages:
            if not pages:
                ref["nao_localizadas"] = ["PDF sem texto (escaneado?): marque à mão."]
            return 0
        indexes = _pages_likely(pages, a_fazer)
        r = await self._claude(prompt_locate(ref, a_fazer, pages, indexes),
                               SYSTEM_LOCATE, SCHEMA_LOCATE, 600)
        new = []
        for t in r.get("trechos") or []:
            n = int(t.get("c", -1))
            if not 0 <= n < len(a_fazer):
                continue
            c = a_fazer[n]
            if not t.get("encontrado") or not str(t.get("trecho") or "").strip():
                ref["nao_localizadas"].append(
                    f"{c['trecho_documento'][:160]} — {t.get('observacao') or 'não achado'}"
                )
                continue
            page = max(0, min(len(pages) - 1, int(t.get("pagina") or 1) - 1))
            retangulos, text_pdf, coverage = [], "", 0.0
            for p in dict.fromkeys([page, page + 1, page - 1]):
                if not 0 <= p < len(pages):
                    continue
                pal = await asyncio.to_thread(words_pdf, pdf, p)
                rr, tt, cc = locate(pal, t["trecho"])
                if cc > coverage:
                    retangulos, text_pdf, coverage, page = rr, tt, cc, p
                if cc >= 0.9:
                    break
            found = coverage >= 0.6
            comment = (
                f"[pré-TCC · {c['secao'] or 'sem seção'}] {c['trecho_documento']}"
                + ("" if found else "\n(Marcação aproximada: confira o trecho nesta página.)")
            )
            new.append({
                "id": _id_highlight(project_id, c),
                "pagina": page,
                "texto": text_pdf if found else t["trecho"].strip(),
                "cor": COLOR_HIGHLIGHT,
                "retangulos": retangulos if found else [],
                "comentario": comment,
                "criado": _now(),
                "projetos": [project_id],
            })
            c["_tipo_citacao"] = _kind_quote(c, t["trecho"])
            c["_confianca"] = t.get("confianca") or ""
        if new:
            self._write_highlights(aid, new)
            by_id = {d["id"]: d for d in new}
            for c in a_fazer:
                d = by_id.get(_id_highlight(project_id, c))
                if d is None:
                    continue
                self.studies.classify(project_id, d["id"], {
                    "secao": c["secao"],
                    "tipo_citacao": c["_tipo_citacao"],
                    "status_uso": "Usado",
                    "parafrase": c["trecho_documento"],
                    "observacoes": (
                        f"Mapeado do documento (confiança {c['_confianca'] or '—'}). "
                        f"Página citada: {c['pagina'] or '—'}."
                    ),
                })
        ref["marcadas"] += len(new)
        return len(new)

    def _write_highlights(self, file_id: str, new: list[dict[str, Any]]) -> None:
        for _ in range(5):
            current = self.collection.annotations(file_id)
            ids = {d["id"] for d in current["destaques"]}
            data = {**current, "destaques": [
                *current["destaques"], *(d for d in new if d["id"] not in ids)
            ]}
            try:
                self.collection.save_annotations(file_id, current["versao"], data)
                return
            except AnnotationsConflict:
                continue
        raise RuntimeError("Não consegui gravar as marcações (arquivo sendo editado).")

    def _card_readings(self, referencias: list[dict[str, Any]]) -> None:
        """Creates the reading record (author, year, reference, DOI and link) for the linked PDFs
        that
        have none yet, and fills missing DOI/link/reference in the existing ones, so the matrix and
        the spreadsheet cite correctly and with the article link."""
        from studies.studies import AREAS

        cards = {
            x["arquivo_id"]: x for x in self.studies.readings.ler() if x.get("arquivo_id")
        }
        for ref in referencias:
            if not ref["arquivo_id"]:
                continue
            reference = ref.get("referencia_completa") or ref["referencia"]
            card = cards.get(ref["arquivo_id"])
            if card is not None:
                missing = {
                    k: v for k, v in (("doi", ref.get("doi") or ""), ("url", ref.get("link") or ""),
                                      ("referencia", reference), ("ano", ref["ano"]))
                    if v and not card.get(k)
                }
                if missing:
                    self.studies.edit_reading(card["id"], missing)
                continue
            cards[ref["arquivo_id"]] = self.studies.create_reading({
                "titulo": ref["titulo"] or ref["arquivo_titulo"] or reference[:200],
                "autor": ref["autor_citacao"],
                "tipo": "artigo",
                "area": AREAS[0],
                "status": "lido",
                "arquivo_id": ref["arquivo_id"],
                "ano": ref["ano"],
                "referencia": reference,
                "doi": ref.get("doi") or "",
                "url": ref.get("link") or "",
            })

    def _tasks_download(self, project_id: str, referencias: list[dict[str, Any]]) -> None:
        """Download to-do on the Routines board for each reference without a PDF; the one that
        already has a PDF is completed."""
        frame = getattr(self.app.state, "quadro", None)
        if frame is None:
            return
        project = self.studies.projects.obter(project_id)
        tasks = {t["titulo"]: t for t in frame.list_all() if TAG_TASK in (t.get("tags") or [])}
        for ref in referencias:
            title = f"Baixar PDF: {ref['autor_citacao']} ({ref['ano']}) — {ref['titulo']}"[:300]
            t = tasks.get(title)
            if ref["arquivo_id"]:
                if t and t.get("coluna") != "concluida":
                    frame.mover(t["id"], "concluida")
                continue
            if t is None:
                frame.criar({
                    "titulo": title,
                    "descricao": (
                        f"Referência do projeto de leitura “{project.get('nome', '')}” sem PDF "
                        f"nos Arquivos ({ref['citacoes']} citação(ões) no documento).\n\n"
                        f"{ref['referencia']}\n\nBaixe o PDF, envie para Arquivos e toque em "
                        "“Refazer mapeamento” no projeto."
                    ),
                    "prioridade": "alta" if ref["citacoes"] else "media",
                    "tags": [TAG_TASK, "estudos"],
                })


# --- rotas ---

router = APIRouter(
    prefix="/api/estudos/projetos",
    tags=["estudos"],
    dependencies=[Depends(require_client_api_key)],
)


def get_mapper(request: Request) -> Mapper:
    m: Mapper | None = getattr(request.app.state, "mapeador", None)
    if m is None:
        m = request.app.state.mapeador = Mapper(request.app)
    return m


MapperDep = Annotated[Mapper, Depends(get_mapper)]


def _project(m: Mapper, id_: str) -> dict[str, Any]:
    from studies.studies import NotFound

    try:
        project: dict[str, Any] = m.studies.projects.obter(id_)
    except NotFound as e:
        raise HTTPException(404, "Projeto não encontrado") from e
    return project


@router.get("/{id_}/mapeamento")
def state(id_: str, m: MapperDep) -> Any:
    _project(m, id_)
    return m.estado(id_)


@router.post("/{id_}/documento", status_code=202)
async def attach(
    id_: str, m: MapperDep, tarefas: BackgroundTasks, arquivo: Annotated[UploadFile, File()]
) -> Any:
    """Stores the document in Files (folder named after the project; an already attached document
    is replaced by the new version) and starts the mapping."""
    project = _project(m, id_)
    name = arquivo.filename or "documento.docx"
    if Path(name).suffix.lower() not in (".docx", ".pdf"):
        raise HTTPException(422, "Envie o documento em .docx ou PDF.")
    content = await arquivo.read()
    previous = (project.get("mapeamento") or {}).get("documento_id")
    try:
        current = m.collection.obter(previous) if previous else None
    except FileNotFound:
        current = None  # the previous document was deleted from Files
    try:
        if current and current.get("extensao") == "docx" and name.lower().endswith(".docx"):
            meta = m.collection.substituir(previous, content)
        else:
            meta = m.collection.adicionar(name, content, pasta=project.get("nome", ""))
    except FileInvalid as e:
        raise HTTPException(422, str(e)) from e
    if meta.get("status") == "convertendo":
        tarefas.add_task(m.collection.convert, meta["id"])
    return m.iniciar(id_, meta["id"])


class RequestMapping(BaseModel):
    documento_id: str | None = None
    """Outro .docx/PDF que já está nos Arquivos; vazio = o documento já anexado."""


@router.post("/{id_}/mapeamento", status_code=202)
async def redo(id_: str, m: MapperDep, pedido: RequestMapping | None = None) -> Any:
    project = _project(m, id_)
    doc = (pedido.documento_id if pedido else None) or \
        (project.get("mapeamento") or {}).get("documento_id")
    if not doc:
        raise HTTPException(422, "Anexe o documento (.docx ou PDF) primeiro.")
    try:
        meta = m.collection.obter(doc)
    except FileNotFound as e:
        raise HTTPException(404, "Documento não está mais nos Arquivos.") from e
    if meta.get("extensao") not in ("docx", "pdf"):
        raise HTTPException(422, "O documento precisa ser .docx ou PDF.")
    return m.iniciar(id_, doc)
