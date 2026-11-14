"""Reescrita de trechos de documentos (TCC) pelo Claude Code — `shared.claude_code`, rodando no
worker do PC (assinatura logada lá); sem worker, no próprio backend se ele tiver o `claude`."""

import subprocess
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from backend.api.deps import require_client_api_key
from backend.arquivos.biblioteca import ArquivoNaoEncontrado, Biblioteca
from shared.claude_code import (
    REWRITE_GOALS,
    REWRITE_SCHEMA,
    REWRITE_SYSTEM_PROMPT,
    InvalidRewriteRequest,
    build_rewrite_prompt,
)


@dataclass
class Reescrita:
    executar: Callable[[dict[str, Any]], Awaitable[dict[str, Any]]]
    disponivel: Callable[[], str | None]
    """Motivo de não dar para reescrever agora (sem worker e sem `claude` aqui), ou None."""
    executar_json: Callable[[dict[str, Any]], Awaitable[dict[str, Any]]] | None = None
    """`claude_json` genérico (prompt, sistema, esquema): usado pelo mapeamento de citações."""
    traducao_json: Callable[[dict[str, Any]], Awaitable[dict[str, Any]]] | None = None
    """O mesmo pedido pela LLM local: a tradução das páginas (sem ela, cai no `executar_json`)."""


class PedidoReescrita(BaseModel):
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


def get_reescrita(request: Request) -> Reescrita:
    reescrita: Reescrita = request.app.state.reescrita
    return reescrita


ReescritaDep = Annotated[Reescrita, Depends(get_reescrita)]


def texto_do_documento(biblioteca: Biblioteca, id_: str) -> str:
    """Texto do PDF exibido (DOCX já convertido) pelo pdftotext; vazio se não houver."""
    pdf = biblioteca.caminho_pdf(id_)
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
def estado(reescrita: ReescritaDep) -> Any:
    return {"objetivos": sorted(REWRITE_GOALS), "indisponivel": reescrita.disponivel()}


@router.post("/reescrever")
async def reescrever(pedido: PedidoReescrita, request: Request, reescrita: ReescritaDep) -> Any:
    # traduzir vai pela LLM local quando houver; os demais objetivos, pelo Claude
    local = reescrita.traducao_json if pedido.objetivo == "traduzir" else None
    motivo = None if local else reescrita.disponivel()
    if motivo:
        raise HTTPException(503, motivo)
    dados = pedido.model_dump()
    if not pedido.contexto and pedido.arquivo_id:
        biblioteca: Biblioteca = request.app.state.biblioteca
        try:
            biblioteca.obter(pedido.arquivo_id)
        except ArquivoNaoEncontrado as e:
            raise HTTPException(404, "Arquivo não encontrado") from e
        dados["contexto"] = texto_do_documento(biblioteca, pedido.arquivo_id)
    try:
        build_rewrite_prompt(dados)  # valida antes de ocupar o worker
    except InvalidRewriteRequest as e:
        raise HTTPException(422, str(e)) from e
    try:
        if local:
            prompt = build_rewrite_prompt(dados)
            return await local(
                {"prompt": prompt, "sistema": REWRITE_SYSTEM_PROMPT, "esquema": REWRITE_SCHEMA}
            )
        return await reescrita.executar(dados)
    except RuntimeError as e:
        raise HTTPException(502, str(e)) from e


# --- tradução do documento, frase a frase (o leitor liga cada frase em português ao original) ---

SISTEMA_TRADUCAO = """Você traduz artigos acadêmicos para o português do Brasil, para um leitor \
que está aprendendo inglês e precisa ler o documento inteiro.

Regras fixas:
- Recebe frases numeradas ([n] texto), extraídas do PDF na ordem de leitura; devolva uma tradução \
para cada número, sem juntar, dividir, pular nem reordenar frases.
- Tradução fiel e completa (sem resumir nem comentar), em registro acadêmico; termos técnicos \
consagrados em português, ou o termo original quando é assim que se usa na área.
- Mantenha números, fórmulas, siglas, nomes próprios, citações (AUTOR, ano) e referências \
bibliográficas como estão (traduza só as palavras comuns delas).
- Hifenização de quebra de linha ("trans- lation") é uma palavra só. Cabeçalhos, legendas e \
fragmentos soltos também são traduzidos, do jeito que vierem."""

ESQUEMA_TRADUCAO = {
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

LIMITE_TRADUCAO = 40_000
"""Caracteres por pedido (o app manda algumas páginas por vez)."""


class PaginaParaTraduzir(BaseModel):
    pagina: int = Field(ge=0)
    segmentos: list[str] = Field(max_length=600)


class PedidoTraducao(BaseModel):
    paginas: list[PaginaParaTraduzir] = Field(min_length=1, max_length=60)
    refazer: bool = False


def prompt_traducao(titulo: str, segmentos: list[str]) -> str:
    linhas = "\n".join(f"[{n}] {s}" for n, s in enumerate(segmentos, 1))
    return f"Documento: {titulo}\n\nTraduza cada frase:\n\n{linhas}"


@router.get("/{id_}/traducao")
def traducao(id_: str, request: Request) -> Any:
    biblioteca: Biblioteca = request.app.state.biblioteca
    try:
        return biblioteca.traducao(id_)
    except ArquivoNaoEncontrado as e:
        raise HTTPException(404, "Arquivo não encontrado") from e


@router.post("/{id_}/traducao")
async def traduzir(
    id_: str, pedido: PedidoTraducao, request: Request, reescrita: ReescritaDep
) -> Any:
    """Traduz as páginas pedidas (as que já estão no cache com as mesmas frases voltam direto)."""
    biblioteca: Biblioteca = request.app.state.biblioteca
    try:
        meta = biblioteca.obter(id_)
        cache = biblioteca.traducao(id_)
    except ArquivoNaoEncontrado as e:
        raise HTTPException(404, "Arquivo não encontrado") from e
    faltam = [
        p
        for p in pedido.paginas
        if pedido.refazer or cache.get(str(p.pagina), {}).get("segmentos") != p.segmentos
    ]
    if faltam:
        frases = [s for p in faltam for s in p.segmentos]
        if sum(len(s) for s in frases) > LIMITE_TRADUCAO:
            raise HTTPException(422, "Páginas demais num pedido só.")
        por_n: dict[int, str] = {}
        if frases:
            executar = reescrita.traducao_json or reescrita.executar_json
            motivo = None if reescrita.traducao_json else reescrita.disponivel()
            if motivo or executar is None:
                raise HTTPException(503, motivo or "Tradução indisponível neste servidor.")
            try:
                r = await executar(
                    {
                        "prompt": prompt_traducao(str(meta.get("titulo") or ""), frases),
                        "sistema": SISTEMA_TRADUCAO,
                        "esquema": ESQUEMA_TRADUCAO,
                        "effort": "medium",
                        "limite_s": 280,
                    }
                )
            except RuntimeError as e:
                raise HTTPException(502, str(e)) from e
            por_n = {
                int(t["n"]): str(t.get("pt") or "").strip()
                for t in r.get("traducoes") or []
                if isinstance(t, dict) and isinstance(t.get("n"), int)
            }
        novas, n = {}, 1
        for p in faltam:
            traducoes = []
            for _ in p.segmentos:
                traducoes.append(por_n.get(n, ""))
                n += 1
            novas[str(p.pagina)] = {"segmentos": p.segmentos, "traducoes": traducoes}
        cache = biblioteca.salvar_traducao(id_, novas)
    return {str(p.pagina): cache[str(p.pagina)] for p in pedido.paginas}
