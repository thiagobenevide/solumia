"""Rewriting of document excerpts (thesis) through Claude Code — `shared.claude_code`, running on
the PC worker (subscription logged in there); without a worker, on the backend itself if it has
`claude`."""

import subprocess
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from backend.api.deps import require_client_api_key
from backend.files.library import Collection, FileNotFound
from shared.claude_code import (
    REWRITE_GOALS,
    REWRITE_SCHEMA,
    REWRITE_SYSTEM_PROMPT,
    InvalidRewriteRequest,
    build_rewrite_prompt,
)


@dataclass
class Rewrite:
    executar: Callable[[dict[str, Any]], Awaitable[dict[str, Any]]]
    disponivel: Callable[[], str | None]
    """Motivo de não dar para reescrever agora (sem worker e sem `claude` aqui), ou None."""
    executar_json: Callable[[dict[str, Any]], Awaitable[dict[str, Any]]] | None = None
    """`claude_json` genérico (prompt, sistema, esquema): usado pelo mapeamento de citações."""
    traducao_json: Callable[[dict[str, Any]], Awaitable[dict[str, Any]]] | None = None
    """O mesmo pedido pela LLM local: a tradução das páginas (sem ela, cai no `executar_json`)."""


class RequestRewrite(BaseModel):
    trecho: str = Field(min_length=1, max_length=60_000)
    objetivo: str = "orientador"
    instrucao: str = Field("", max_length=4_000)
    feedback: str = Field("", max_length=20_000)
    contexto: str = ""
    """Texto do documento inteiro; vazio + `arquivo_id` = extraído do PDF do arquivo."""
    arquivo_id: str | None = None


router = APIRouter(
    prefix="/api/arquivos", tags=["arquivos"], dependencies=[Depends(require_client_api_key)]
)


def get_rewrite(request: Request) -> Rewrite:
    rewrite: Rewrite = request.app.state.reescrita
    return rewrite


RewriteDep = Annotated[Rewrite, Depends(get_rewrite)]


def text_of_document(collection: Collection, id_: str) -> str:
    """Text of the displayed PDF (DOCX already converted) through pdftotext; empty if there is
    none."""
    pdf = collection.path_pdf(id_)
    if pdf is None:
        return ""
    try:
        r = subprocess.run(
            ["pdftotext", "-layout", str(pdf), "-"], capture_output=True, timeout=60, text=True
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return ""
    return r.stdout


@router.get("/reescrita")
def state(reescrita: RewriteDep) -> Any:
    return {"objetivos": sorted(REWRITE_GOALS), "indisponivel": reescrita.disponivel()}


@router.post("/reescrever")
async def rewrite(pedido: RequestRewrite, request: Request, reescrita: RewriteDep) -> Any:
    # translating goes through the local LLM when available; the other goals, through Claude
    local = reescrita.traducao_json if pedido.objetivo == "traduzir" else None
    reason = None if local else reescrita.disponivel()
    if reason:
        raise HTTPException(503, reason)
    data = pedido.model_dump()
    if not pedido.contexto and pedido.arquivo_id:
        collection: Collection = request.app.state.collection
        try:
            collection.obter(pedido.arquivo_id)
        except FileNotFound as e:
            raise HTTPException(404, "Arquivo não encontrado") from e
        data["contexto"] = text_of_document(collection, pedido.arquivo_id)
    try:
        build_rewrite_prompt(data)  # validate before occupying the worker
    except InvalidRewriteRequest as e:
        raise HTTPException(422, str(e)) from e
    try:
        if local:
            prompt = build_rewrite_prompt(data)
            return await local(
                {"prompt": prompt, "sistema": REWRITE_SYSTEM_PROMPT, "esquema": REWRITE_SCHEMA}
            )
        return await reescrita.executar(data)
    except RuntimeError as e:
        raise HTTPException(502, str(e)) from e


# --- document translation, sentence by sentence (the reader links each Portuguese sentence to the
# original) ---

SYSTEM_TRANSLATION = """You translate academic papers into Brazilian Portuguese, for a reader who \
is learning English and needs to read the whole document.

Fixed rules:
- You receive numbered sentences ([n] text), extracted from the PDF in reading order; return one \
translation for each number, without merging, splitting, skipping or reordering sentences.
- Faithful and complete translation (no summarizing or commenting), in academic register; \
established technical terms in Portuguese, or the original term when that is how the field uses it.
- Keep numbers, formulas, acronyms, proper names, citations (AUTHOR, year) and bibliographic \
references as they are (translate only their common words).
- Line-break hyphenation ("trans- lation") is a single word. Headers, captions and loose fragments \
are also translated, as they come."""

SCHEMA_TRANSLATION = {
    "type": "object",
    "properties": {
        "traducoes": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"n": {"type": "integer"}, "pt": {"type": "string"}},
                "required": ["n", "pt"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["traducoes"],
    "additionalProperties": False,
}

LIMIT_TRANSLATION = 40_000
"""Caracteres por pedido (o app manda algumas páginas por vez)."""


class PageParaTranslate(BaseModel):
    pagina: int = Field(ge=0)
    segmentos: list[str] = Field(max_length=600)


class RequestTranslation(BaseModel):
    paginas: list[PageParaTranslate] = Field(min_length=1, max_length=60)
    refazer: bool = False


def prompt_translation(titulo: str, segments: list[str]) -> str:
    lines = "\n".join(f"[{n}] {s}" for n, s in enumerate(segments, 1))
    return f"Document: {titulo}\n\nTranslate each sentence:\n\n{lines}"


@router.get("/{id_}/traducao")
def translation(id_: str, request: Request) -> Any:
    collection: Collection = request.app.state.collection
    try:
        return collection.traducao(id_)
    except FileNotFound as e:
        raise HTTPException(404, "Arquivo não encontrado") from e


@router.post("/{id_}/traducao")
async def translate(
    id_: str, pedido: RequestTranslation, request: Request, reescrita: RewriteDep
) -> Any:
    """Translates the requested pages (the ones already cached with the same sentences come back
    directly)."""
    collection: Collection = request.app.state.collection
    try:
        meta = collection.obter(id_)
        cache = collection.traducao(id_)
    except FileNotFound as e:
        raise HTTPException(404, "Arquivo não encontrado") from e
    missing = [
        p
        for p in pedido.paginas
        if pedido.refazer or cache.get(str(p.pagina), {}).get("segmentos") != p.segmentos
    ]
    if missing:
        sentences = [s for p in missing for s in p.segmentos]
        if sum(len(s) for s in sentences) > LIMIT_TRANSLATION:
            raise HTTPException(422, "Páginas demais num pedido só.")
        by_n: dict[int, str] = {}
        if sentences:
            execute = reescrita.traducao_json or reescrita.executar_json
            reason = None if reescrita.traducao_json else reescrita.disponivel()
            if reason or execute is None:
                raise HTTPException(503, reason or "Tradução indisponível neste servidor.")
            try:
                r = await execute(
                    {
                        "prompt": prompt_translation(str(meta.get("titulo") or ""), sentences),
                        "sistema": SYSTEM_TRANSLATION,
                        "esquema": SCHEMA_TRANSLATION,
                        "effort": "medium",
                        "limite_s": 280,
                    }
                )
            except RuntimeError as e:
                raise HTTPException(502, str(e)) from e
            by_n = {
                int(t["n"]): str(t.get("pt") or "").strip()
                for t in r.get("traducoes") or []
                if isinstance(t, dict) and isinstance(t.get("n"), int)
            }
        new, n = {}, 1
        for p in missing:
            traducoes = []
            for _ in p.segmentos:
                traducoes.append(by_n.get(n, ""))
                n += 1
            new[str(p.pagina)] = {"segmentos": p.segmentos, "traducoes": traducoes}
        cache = collection.save_translation(id_, new)
    return {str(p.pagina): cache[str(p.pagina)] for p in pedido.paginas}
