"""Mapeamento reverso de citações: o autor anexa o documento (pré-TCC inteiro ou só uma parte,
como introdução ou resumo, em .docx ou PDF) a um projeto de leitura; o arquivo fica nos Arquivos e
o Claude (Claude Code, `claude_json` no worker, nunca a LLM local nem a API) lista as referências
(documento inteiro), depois as citações (o texto em partes, para não estourar a resposta), liga
cada referência a um PDF da biblioteca, baixa sozinho o PDF das obras de acesso aberto (OpenAlex e,
sem ele, o Claude buscando na web) e acha em cada PDF o trecho citado. O trecho vira um destaque no
PDF, no projeto (`projetos: [id]`), já classificado (seção, tipo de citação, "Usado"); as
referências fechadas viram pendências de download (tarefas no Quadro de Rotinas). "Refazer" roda
tudo de novo e só acrescenta o que ainda não foi marcado (id do destaque estável por citação).
Nada gravado para o autor (comentário, observação) menciona a IA: ele revisa e decide."""

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
    FileInvalid,
    FileNotFound,
    Collection,
)
from backend.files.rewrite import Rewrite

logger = logging.getLogger("gateway.mapeamento")

COLOR_HIGHLIGHT = 0x66FFD54F  # amarelo translúcido, como o marca-texto
LIMIT_CATALOG = 400  # caracteres da 1ª página de cada PDF para o Claude reconhecer a obra
LIMIT_PDF = 160_000  # caracteres de um PDF por pedido (livro grande: só as páginas prováveis)
LIMIT_PART = 30_000  # caracteres do documento por pedido de citações
MODEL = "opus"  # mapeamento delicado: o modelo mais capaz do Claude Code
SEARCHES_CONCURRENT = 3
TAG_TASK = "download-referencia"

W = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
XHTML = "{http://www.w3.org/1999/xhtml}"


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


# --- texto do documento e dos PDFs ---


def text_docx(content: bytes) -> str:
    """Parágrafos do corpo (com os títulos marcados por `#`) e as notas de rodapé."""
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
    """Partes de até [limite] caracteres, cortadas de preferência num título (`#`); cada parte
    que começa no meio de uma seção leva o título dela, para a citação sair com a seção certa."""
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
    """Texto de cada página (pdftotext; páginas separadas por form feed)."""
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
    """Palavras da página (0-based) com a caixa em pontos PDF, origem no canto de cima (como o
    leitor do app) e o número da linha."""
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
    text = re.sub(r"(\w)-\s*\n\s*(\w)", r"\1\2", text)  # hifenização de quebra de linha
    return [t for t in (_norm(p) for p in text.split()) if t]


def locate(
    words: list[tuple[str, list[float], int]], span: str
) -> tuple[list[list[float]], str, float]:
    """Acha [trecho] nas palavras da página (aproximado: o PDF quebra linhas, hifeniza e às vezes
    o trecho vem com pequenas diferenças). Devolve um retângulo por linha, o texto como está no PDF
    e a cobertura (0–1)."""
    target = _tokens(span)
    if not target or not words:
        return [], "", 0.0
    # junta palavra hifenizada no fim da linha com a primeira da linha seguinte
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

SYSTEM_REFERENCES = """Você analisa trabalhos acadêmicos brasileiros (pré-projeto de TCC, \
monografia, artigo) em ABNT para o mapeamento reverso das citações: lista as obras que o \
documento cita, para o autor marcar os trechos nas obras originais.

Regras fixas:
- Uma entrada por obra da lista de REFERÊNCIAS do documento e também por obra citada no texto \
que não está na lista (`fora_da_lista` = true). O documento pode ser só uma parte do trabalho \
(introdução, resumo/abstract, um capítulo) sem lista de referências: então monte uma entrada \
para cada obra citada no texto, todas com `fora_da_lista` = true.
- `referencia`: a entrada completa como está no documento; sem ela, o que o texto traz \
("SILVA, 2020"). `autor_citacao`: como aparece no texto ("Silva", "Silva e Souza", "Silva et \
al."). `titulo`: só o título da obra, como está no documento; "" se o documento não traz.
- `arquivo_id`: o id do catálogo de PDFs da biblioteca que é essa mesma obra (confira título, \
autores e ano pelo início do texto); "" se nenhum for ela. Nunca ligue a uma obra parecida.
- Não invente obras nem complete dados que o documento não traz."""

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

SYSTEM_QUOTES = """Você faz o mapeamento reverso das citações de um trabalho acadêmico \
brasileiro (ABNT): recebe a lista numerada das obras citadas e uma parte do texto, e lista cada \
citação feita nessa parte.

Regras fixas:
- Cada ocorrência de citação no corpo do texto, na ordem, com `ref` = o número da obra na lista. \
Ignore a própria lista de referências, sumário e cabeçalhos.
- `trecho_documento`: a frase (ou frases) do documento que traz a citação, copiada como está.
- `citacao`: nas diretas, só o texto entre aspas ou o recuado; "" nas indiretas.
- `tipo`: "direta", "indireta" ou "apud" (citação de citação: `ref` é a obra consultada, a que \
tem o "apud").
- `pagina`: a página citada como está ("p. 23"), ou "".
- `secao`: o título da seção onde a citação está (linhas começando com # são títulos; \
"continuação da seção" diz a seção do começo da parte). Sem títulos marcados, use o título \
que o texto mostra (ex.: "Introdução", "Resumo").
- Uma mesma frase citando duas obras gera duas citações. Não invente citações; citação de obra \
que não está na lista fica de fora."""

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

SYSTEM_FETCH = """Você acha na internet o PDF gratuito e público de uma obra acadêmica citada \
num trabalho, para baixar. Use a busca na web e abra as páginas para conferir.

Regras fixas:
- Identifique a obra pela referência; se ela está incompleta (só autor e ano), use as frases \
que a citam para achar qual é. Sem certeza de que é a mesma obra, `encontrado` = false.
- `urls_pdf`: links que baixam direto o PDF da própria obra (mesmo título, autores e ano; \
preprint/versão aceita do mesmo trabalho vale), de acesso aberto: repositórios institucionais, \
SciELO, PubMed Central, arXiv, site do periódico ou do autor. Do melhor para o pior. Nunca \
sites piratas nem páginas que pedem login ou pagamento.
- `titulo`, `doi` e `referencia_completa` (ABNT) da obra identificada; "" no que não achar.
- Obra fechada, sem PDF público: `encontrado` = true e `urls_pdf` vazio."""

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

SYSTEM_LOCATE = """Você confere citações de um trabalho acadêmico nas obras originais, como o \
autor faria com o marca-texto: para cada citação, acha na obra o trecho que ela usa.

Regras fixas:
- A obra vem página por página ("=== Página N ===", N é a página do PDF, que pode diferir da \
numeração impressa citada no trabalho).
- `trecho`: copie da obra, palavra por palavra como está no texto da página (mesmo com erros de \
extração), o trecho que a citação usa: nas diretas, exatamente o texto citado; nas indiretas \
(paráfrase), a frase ou as poucas frases que sustentam a ideia (no máximo um parágrafo).
- `pagina`: o N da página onde o trecho começa. Se a citação não está nesta obra ou nas páginas \
enviadas, devolva `encontrado` = false, com o motivo em `observacao`.
- `confianca`: "alta" quando o trecho é claramente o citado, "media" ou "baixa" quando é o mais \
provável. Não invente texto que não está na obra."""

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
        f'- id "{c["id"]}" · arquivo: {c["titulo"]}'
        + (f" · ficha: {c['ficha']}" if c.get("ficha") else "")
        + f"\n  início: {c['inicio']}"
        for c in catalog
    ]
    return (
        "<catalogo_de_pdfs>\n" + ("\n".join(lines) or "(biblioteca vazia)")
        + "\n</catalogo_de_pdfs>\n\n<documento>\n" + document + "\n</documento>\n\n"
        "Liste todas as obras citadas no documento, ligando ao catálogo."
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
        f"<obras>\n{_list_works(refs)}\n</obras>\n\n"
        f"<texto parte=\"{k} de {total}\">\n{part}\n</texto>\n\n"
        "Liste todas as citações desta parte do texto."
    )


def prompt_fetch(ref: dict[str, Any], cits: list[dict[str, Any]]) -> str:
    sentences = "\n".join(f"- {c['trecho_documento'][:400]}" for c in cits[:4])
    return (
        f"Referência como está no trabalho: {ref['referencia']}\n"
        f"Autor no texto: {ref['autor_citacao']} · ano: {ref['ano']}"
        + (f" · título: {ref['titulo']}" if ref.get("titulo") else "")
        + (f"\n\nFrases do trabalho que citam a obra:\n{sentences}" if sentences else "")
        + "\n\nAche o PDF público desta obra."
    )


def _pages_likely(pages: list[str], citacoes: list[dict[str, Any]]) -> list[int]:
    """Livro grande: as páginas com mais palavras em comum com as citações, até o limite."""
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
        f"[{n}] tipo: {c['tipo']}" + (f" · página citada: {c['pagina']}" if c["pagina"] else "")
        + f"\nno trabalho: {c['trecho_documento']}"
        + (f"\ntexto citado: {c['citacao']}" if c["citacao"] else "")
        for n, c in enumerate(citacoes)
    )
    work = "\n\n".join(f"=== Página {i + 1} ===\n{pages[i].strip()}" for i in indexes)
    return (
        f"Obra: {ref['referencia']}\n\n<citacoes>\n{cits}\n</citacoes>\n\n"
        f"<obra>\n{work}\n</obra>\n\nAche na obra o trecho de cada citação (`c` = número entre "
        "colchetes)."
    )


# --- processo ---


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
    """Roda um mapeamento por projeto por vez, em segundo plano; o estado fica no projeto
    (`mapeamento`), para o app acompanhar."""

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
        except Exception as e:  # noqa: BLE001 — qualquer falha vira estado legível no app
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
            except Exception as e:  # noqa: BLE001 — uma obra com problema não para as outras
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
        """Para cada referência: DOI e link do artigo (para a planilha citar com o link) e, se
        ainda não tem PDF, baixa sozinho o de acesso aberto (OpenAlex; sem ele, o Claude busca
        na web) para Arquivos (pasta "Referências"). As fechadas ficam como pendência."""
        lock = asyncio.Semaphore(SEARCHES_CONCURRENT)
        done = 0

        async def uma(ref: dict[str, Any]) -> None:
            nonlocal done
            async with lock:
                try:
                    await self._fetch_work(ref, [c for c in citacoes
                                                  if int(c["ref"]) == ref["n"]])
                except Exception:  # noqa: BLE001 — falha numa obra não para o mapeamento
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
        ref["marcadas"] = len(cits) - len(a_fazer)  # já marcadas num mapeamento anterior
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
        """Cria a ficha da leitura (autor, ano, referência, DOI e link) dos PDFs ligados que ainda
        não têm, e completa DOI/link/referência que faltam nas existentes, para a matriz e a
        planilha citarem certo e com o link do artigo."""
        from estudos.studies import AREAS

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
        """Pendência de download no Quadro de Rotinas para cada referência sem PDF; a que já
        tem PDF é concluída."""
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
    from estudos.studies import NotFound

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
    """Guarda o documento nos Arquivos (pasta com o nome do projeto; um documento já anexado é
    substituído pela versão nova) e começa o mapeamento."""
    project = _project(m, id_)
    name = arquivo.filename or "documento.docx"
    if Path(name).suffix.lower() not in (".docx", ".pdf"):
        raise HTTPException(422, "Envie o documento em .docx ou PDF.")
    content = await arquivo.read()
    previous = (project.get("mapeamento") or {}).get("documento_id")
    try:
        current = m.collection.obter(previous) if previous else None
    except FileNotFound:
        current = None  # o documento anterior foi excluído dos Arquivos
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
