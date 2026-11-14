from typing import Annotated, Any
from urllib.parse import quote

from fastapi import (
    APIRouter,
    BackgroundTasks,
    Depends,
    File,
    Form,
    HTTPException,
    Request,
    Response,
    UploadFile,
)
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, Field

from backend.api.deps import require_client_api_key
from backend.arquivos.biblioteca import (
    AnotacoesConflito,
    ArquivoInvalido,
    ArquivoNaoEncontrado,
    Biblioteca,
)
from backend.arquivos.wopi import sessao as sessao_collabora

router = APIRouter(
    prefix="/api/arquivos", tags=["arquivos"], dependencies=[Depends(require_client_api_key)]
)


def get_biblioteca(request: Request) -> Biblioteca:
    biblioteca: Biblioteca = request.app.state.biblioteca
    return biblioteca


BibliotecaDep = Annotated[Biblioteca, Depends(get_biblioteca)]


class ArquivoEdicao(BaseModel):
    titulo: str | None = Field(None, min_length=1, max_length=200)
    pasta: str | None = Field(None, max_length=200)
    tags: list[str] | None = None


class AnotacoesEntrada(BaseModel):
    versao_base: int
    tracos: list[dict[str, Any]] = []
    destaques: list[dict[str, Any]] = []
    textos: list[dict[str, Any]] = []


def _404(e: ArquivoNaoEncontrado) -> HTTPException:
    return HTTPException(404, "Arquivo não encontrado")


@router.get("")
def listar(
    biblioteca: BibliotecaDep, q: str = "", tipo: str | None = None, pasta: str | None = None
) -> Any:
    return biblioteca.listar(q, tipo, pasta)


@router.post("", status_code=201)
async def enviar(
    biblioteca: BibliotecaDep,
    tarefas: BackgroundTasks,
    arquivo: Annotated[UploadFile, File()],
    pasta: Annotated[str, Form()] = "",
) -> Any:
    try:
        meta = biblioteca.adicionar(arquivo.filename or "", await arquivo.read(), pasta)
    except ArquivoInvalido as e:
        raise HTTPException(415, str(e)) from e
    if meta["status"] == "convertendo" and not meta.get("duplicado"):
        tarefas.add_task(biblioteca.converter, meta["id"])
    return meta


class NovoArquivo(BaseModel):
    tipo: str = Field(pattern="^(documento|planilha|apresentacao)$")
    titulo: str = Field("Sem título", max_length=200)
    pasta: str = Field("", max_length=200)


@router.post("/novo", status_code=201)
def novo(entrada: NovoArquivo, biblioteca: BibliotecaDep, tarefas: BackgroundTasks) -> Any:
    """Documento/planilha/apresentação em branco para editar no app."""
    try:
        meta = biblioteca.criar_vazio(entrada.tipo, entrada.titulo, entrada.pasta)
    except ArquivoInvalido as e:
        raise HTTPException(422, str(e)) from e
    if meta["status"] == "convertendo" and not meta.get("duplicado"):
        tarefas.add_task(biblioteca.converter, meta["id"])
    return meta


@router.get("/pastas")
def pastas(biblioteca: BibliotecaDep) -> Any:
    return biblioteca.pastas()


@router.get("/destaques")
def destaques(biblioteca: BibliotecaDep, q: str = "", arquivo_id: str | None = None) -> Any:
    try:
        return biblioteca.destaques(q, arquivo_id)
    except ArquivoNaoEncontrado as e:
        raise _404(e) from e


@router.get("/mudancas")
def mudancas(biblioteca: BibliotecaDep, desde: int = 0) -> Any:
    return biblioteca.mudancas(desde)


@router.get("/{id_}")
def obter(id_: str, biblioteca: BibliotecaDep) -> Any:
    try:
        return biblioteca.obter(id_)
    except ArquivoNaoEncontrado as e:
        raise _404(e) from e


@router.patch("/{id_}")
def editar(id_: str, edicao: ArquivoEdicao, biblioteca: BibliotecaDep) -> Any:
    try:
        return biblioteca.editar(id_, edicao.model_dump())
    except ArquivoNaoEncontrado as e:
        raise _404(e) from e


@router.delete("/{id_}", status_code=204)
def excluir(id_: str, biblioteca: BibliotecaDep) -> Response:
    try:
        biblioteca.excluir(id_)
    except ArquivoNaoEncontrado as e:
        raise _404(e) from e
    return Response(status_code=204)


@router.post("/{id_}/duplicar", status_code=201)
def duplicar(id_: str, biblioteca: BibliotecaDep, tarefas: BackgroundTasks) -> Any:
    try:
        meta = biblioteca.duplicar(id_)
    except ArquivoNaoEncontrado as e:
        raise _404(e) from e
    if meta["status"] == "convertendo":
        tarefas.add_task(biblioteca.converter, meta["id"])
    return meta


@router.post("/{id_}/converter", status_code=202)
def reconverter(id_: str, biblioteca: BibliotecaDep, tarefas: BackgroundTasks) -> Any:
    try:
        meta = biblioteca.marcar_convertendo(id_)
    except ArquivoNaoEncontrado as e:
        raise _404(e) from e
    tarefas.add_task(biblioteca.converter, id_)
    return meta


@router.get("/{id_}/original")
def original(id_: str, biblioteca: BibliotecaDep) -> FileResponse:
    try:
        caminho, nome = biblioteca.caminho_original(id_)
    except ArquivoNaoEncontrado as e:
        raise _404(e) from e
    return FileResponse(caminho, filename=nome)


@router.put("/{id_}/original")
async def substituir(
    id_: str,
    biblioteca: BibliotecaDep,
    tarefas: BackgroundTasks,
    arquivo: Annotated[UploadFile, File()],
) -> Any:
    try:
        meta = biblioteca.substituir(id_, await arquivo.read())
    except ArquivoNaoEncontrado as e:
        raise _404(e) from e
    except ArquivoInvalido as e:
        raise HTTPException(415, str(e)) from e
    if meta["status"] == "convertendo":
        tarefas.add_task(biblioteca.converter, id_)
    return meta


@router.get("/{id_}/exportar")
def exportar(id_: str, formato: str, biblioteca: BibliotecaDep) -> Response:
    """Original convertido pelo LibreOffice (DOCX→ODT/PDF/RTF/TXT/HTML, XLSX→ODS/CSV/PDF…)."""
    try:
        conteudo, nome = biblioteca.exportar(id_, formato.lower())
    except ArquivoNaoEncontrado as e:
        raise _404(e) from e
    except ArquivoInvalido as e:
        raise HTTPException(422, str(e)) from e
    return Response(
        conteudo,
        media_type="application/octet-stream",
        headers={"Content-Disposition": f"attachment; filename*=UTF-8''{quote(nome)}"},
    )


@router.post("/{id_}/collabora")
async def collabora(id_: str, request: Request) -> Any:
    """Sessão de edição no Collabora: `{url, access_token, access_token_ttl}`; o app faz POST
    do formulário com o token na `url` (padrão WOPI)."""
    return await sessao_collabora(request, id_)


@router.get("/{id_}/pdf")
def pdf(id_: str, biblioteca: BibliotecaDep) -> FileResponse:
    try:
        caminho = biblioteca.caminho_pdf(id_)
    except ArquivoNaoEncontrado as e:
        raise _404(e) from e
    if caminho is None:
        raise HTTPException(409, "O PDF ainda não está pronto")
    return FileResponse(caminho, media_type="application/pdf")


@router.get("/{id_}/miniatura")
def miniatura(id_: str, biblioteca: BibliotecaDep) -> FileResponse:
    try:
        caminho = biblioteca.caminho_miniatura(id_)
    except ArquivoNaoEncontrado as e:
        raise _404(e) from e
    if caminho is None:
        raise HTTPException(404, "Sem miniatura")
    # O app pede com ?v=<atualizado>: a mesma URL nunca muda de conteúdo.
    return FileResponse(
        caminho,
        media_type="image/png",
        headers={"Cache-Control": "private, max-age=31536000, immutable"},
    )


@router.get("/{id_}/anotacoes")
def anotacoes(id_: str, biblioteca: BibliotecaDep) -> Any:
    try:
        return biblioteca.anotacoes(id_)
    except ArquivoNaoEncontrado as e:
        raise _404(e) from e


@router.put("/{id_}/anotacoes")
def salvar_anotacoes(id_: str, entrada: AnotacoesEntrada, biblioteca: BibliotecaDep) -> Any:
    try:
        return biblioteca.salvar_anotacoes(
            id_, entrada.versao_base, entrada.model_dump(exclude={"versao_base"})
        )
    except ArquivoNaoEncontrado as e:
        raise _404(e) from e
    except AnotacoesConflito as e:
        # Devolve as anotações atuais para o app mesclar sem outra ida ao servidor.
        return JSONResponse(status_code=409, content={"detail": str(e), "atuais": e.atuais})
