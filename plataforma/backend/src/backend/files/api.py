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
from backend.files.library import (
    AnnotationsConflict,
    FileInvalid,
    FileNotFound,
    Collection,
)
from backend.files.wopi import session as sessao_collabora

router = APIRouter(
    prefix="/api/arquivos", tags=["arquivos"], dependencies=[Depends(require_client_api_key)]
)


def get_collection(request: Request) -> Collection:
    collection: Collection = request.app.state.biblioteca
    return collection


CollectionDep = Annotated[Collection, Depends(get_collection)]


class FileEdit(BaseModel):
    titulo: str | None = Field(None, min_length=1, max_length=200)
    pasta: str | None = Field(None, max_length=200)
    tags: list[str] | None = None


class AnnotationsInput(BaseModel):
    versao_base: int
    tracos: list[dict[str, Any]] = []
    destaques: list[dict[str, Any]] = []
    textos: list[dict[str, Any]] = []


def _404(e: FileNotFound) -> HTTPException:
    return HTTPException(404, "Arquivo não encontrado")


@router.get("")
def list_all(
    biblioteca: CollectionDep, q: str = "", tipo: str | None = None, pasta: str | None = None
) -> Any:
    return biblioteca.listar(q, tipo, pasta)


@router.post("", status_code=201)
async def send(
    biblioteca: CollectionDep,
    tarefas: BackgroundTasks,
    arquivo: Annotated[UploadFile, File()],
    pasta: Annotated[str, Form()] = "",
) -> Any:
    try:
        meta = biblioteca.adicionar(arquivo.filename or "", await arquivo.read(), pasta)
    except FileInvalid as e:
        raise HTTPException(415, str(e)) from e
    if meta["status"] == "convertendo" and not meta.get("duplicado"):
        tarefas.add_task(biblioteca.converter, meta["id"])
    return meta


class NewFile(BaseModel):
    tipo: str = Field(pattern="^(documento|planilha|apresentacao)$")
    titulo: str = Field("Sem título", max_length=200)
    pasta: str = Field("", max_length=200)


@router.post("/novo", status_code=201)
def new(entrada: NewFile, biblioteca: CollectionDep, tarefas: BackgroundTasks) -> Any:
    """Documento/planilha/apresentação em branco para editar no app."""
    try:
        meta = biblioteca.criar_vazio(entrada.tipo, entrada.titulo, entrada.pasta)
    except FileInvalid as e:
        raise HTTPException(422, str(e)) from e
    if meta["status"] == "convertendo" and not meta.get("duplicado"):
        tarefas.add_task(biblioteca.converter, meta["id"])
    return meta


@router.get("/pastas")
def folders(biblioteca: CollectionDep) -> Any:
    return biblioteca.pastas()


@router.get("/destaques")
def highlights(biblioteca: CollectionDep, q: str = "", arquivo_id: str | None = None) -> Any:
    try:
        return biblioteca.destaques(q, arquivo_id)
    except FileNotFound as e:
        raise _404(e) from e


@router.get("/mudancas")
def changes(biblioteca: CollectionDep, desde: int = 0) -> Any:
    return biblioteca.mudancas(desde)


@router.get("/{id_}")
def get(id_: str, biblioteca: CollectionDep) -> Any:
    try:
        return biblioteca.obter(id_)
    except FileNotFound as e:
        raise _404(e) from e


@router.patch("/{id_}")
def edit(id_: str, edicao: FileEdit, biblioteca: CollectionDep) -> Any:
    try:
        return biblioteca.editar(id_, edicao.model_dump())
    except FileNotFound as e:
        raise _404(e) from e


@router.delete("/{id_}", status_code=204)
def delete(id_: str, biblioteca: CollectionDep) -> Response:
    try:
        biblioteca.excluir(id_)
    except FileNotFound as e:
        raise _404(e) from e
    return Response(status_code=204)


@router.post("/{id_}/duplicar", status_code=201)
def duplicate(id_: str, biblioteca: CollectionDep, tarefas: BackgroundTasks) -> Any:
    try:
        meta = biblioteca.duplicar(id_)
    except FileNotFound as e:
        raise _404(e) from e
    if meta["status"] == "convertendo":
        tarefas.add_task(biblioteca.converter, meta["id"])
    return meta


@router.post("/{id_}/converter", status_code=202)
def reconvert(id_: str, biblioteca: CollectionDep, tarefas: BackgroundTasks) -> Any:
    try:
        meta = biblioteca.marcar_convertendo(id_)
    except FileNotFound as e:
        raise _404(e) from e
    tarefas.add_task(biblioteca.converter, id_)
    return meta


@router.get("/{id_}/original")
def original(id_: str, biblioteca: CollectionDep) -> FileResponse:
    try:
        path, name = biblioteca.caminho_original(id_)
    except FileNotFound as e:
        raise _404(e) from e
    return FileResponse(path, filename=name)


@router.put("/{id_}/original")
async def replace(
    id_: str,
    biblioteca: CollectionDep,
    tarefas: BackgroundTasks,
    arquivo: Annotated[UploadFile, File()],
) -> Any:
    try:
        meta = biblioteca.substituir(id_, await arquivo.read())
    except FileNotFound as e:
        raise _404(e) from e
    except FileInvalid as e:
        raise HTTPException(415, str(e)) from e
    if meta["status"] == "convertendo":
        tarefas.add_task(biblioteca.converter, id_)
    return meta


@router.get("/{id_}/exportar")
def export(id_: str, formato: str, biblioteca: CollectionDep) -> Response:
    """Original convertido pelo LibreOffice (DOCX→ODT/PDF/RTF/TXT/HTML, XLSX→ODS/CSV/PDF…)."""
    try:
        content, name = biblioteca.exportar(id_, formato.lower())
    except FileNotFound as e:
        raise _404(e) from e
    except FileInvalid as e:
        raise HTTPException(422, str(e)) from e
    return Response(
        content,
        media_type="application/octet-stream",
        headers={"Content-Disposition": f"attachment; filename*=UTF-8''{quote(name)}"},
    )


@router.post("/{id_}/collabora")
async def collabora(id_: str, request: Request) -> Any:
    """Sessão de edição no Collabora: `{url, access_token, access_token_ttl}`; o app faz POST
    do formulário com o token na `url` (padrão WOPI)."""
    return await sessao_collabora(request, id_)


@router.get("/{id_}/pdf")
def pdf(id_: str, biblioteca: CollectionDep) -> FileResponse:
    try:
        path = biblioteca.caminho_pdf(id_)
    except FileNotFound as e:
        raise _404(e) from e
    if path is None:
        raise HTTPException(409, "O PDF ainda não está pronto")
    return FileResponse(path, media_type="application/pdf")


@router.get("/{id_}/miniatura")
def thumbnail(id_: str, biblioteca: CollectionDep) -> FileResponse:
    try:
        path = biblioteca.caminho_miniatura(id_)
    except FileNotFound as e:
        raise _404(e) from e
    if path is None:
        raise HTTPException(404, "Sem miniatura")
    # O app pede com ?v=<atualizado>: a mesma URL nunca muda de conteúdo.
    return FileResponse(
        path,
        media_type="image/png",
        headers={"Cache-Control": "private, max-age=31536000, immutable"},
    )


@router.get("/{id_}/anotacoes")
def annotations(id_: str, biblioteca: CollectionDep) -> Any:
    try:
        return biblioteca.anotacoes(id_)
    except FileNotFound as e:
        raise _404(e) from e


@router.put("/{id_}/anotacoes")
def save_annotations(id_: str, entrada: AnnotationsInput, biblioteca: CollectionDep) -> Any:
    try:
        return biblioteca.salvar_anotacoes(
            id_, entrada.versao_base, entrada.model_dump(exclude={"versao_base"})
        )
    except FileNotFound as e:
        raise _404(e) from e
    except AnnotationsConflict as e:
        # Devolve as anotações atuais para o app mesclar sem outra ida ao servidor.
        return JSONResponse(status_code=409, content={"detail": str(e), "atuais": e.atuais})
