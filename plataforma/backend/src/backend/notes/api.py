from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field

from backend.api.deps import require_client_api_key
from backend.notes.note_types import KINDS
from backend.notes.vault import NoteConflict, NoteNotFound, Vault

router = APIRouter(
    prefix="/api/notas", tags=["notas"], dependencies=[Depends(require_client_api_key)]
)


def get_vault(request: Request) -> Vault:
    vault: Vault = request.app.state.cofre
    return vault


VaultDep = Annotated[Vault, Depends(get_vault)]


class NoteInput(BaseModel):
    titulo: str = Field(min_length=1, max_length=200)
    tipo: str = "nota"
    tags: list[str] = []
    aliases: list[str] = []
    propriedades: dict[str, Any] = {}
    corpo: str = ""
    pasta: str = ""


class NoteEdit(BaseModel):
    titulo: str | None = Field(None, min_length=1, max_length=200)
    tipo: str | None = None
    tags: list[str] | None = None
    aliases: list[str] | None = None
    propriedades: dict[str, Any] | None = None
    corpo: str | None = None


def _error(e: Exception) -> HTTPException:
    if isinstance(e, NoteNotFound):
        return HTTPException(404, "Nota não encontrada")
    return HTTPException(409, str(e))


@router.get("")
def list_all(cofre: VaultDep, q: str = "", tipo: str | None = None, tag: str | None = None) -> Any:
    return cofre.list_all(q, tipo, tag)


@router.get("/tipos")
def kinds() -> Any:
    return KINDS


@router.get("/sugestoes")
def suggestions(cofre: VaultDep, q: str = "", limite: int = 10) -> Any:
    return cofre.suggest(q, limite)


@router.get("/analise")
def analysis(cofre: VaultDep) -> Any:
    return cofre.analysis()


@router.get("/grafo")
def graph(cofre: VaultDep) -> Any:
    return cofre.graph()


@router.get("/espelho")
def mirror(cofre: VaultDep) -> Any:
    """All notes in full in one call: the app stores them to read and edit offline."""
    return [cofre.obter(r["id"]) for r in cofre.list_all()]


@router.get("/{id_}")
def get(id_: str, cofre: VaultDep) -> Any:
    try:
        return cofre.obter(id_)
    except NoteNotFound as e:
        raise _error(e) from e


@router.post("", status_code=201)
def create(entrada: NoteInput, cofre: VaultDep) -> Any:
    try:
        return cofre.criar(entrada.model_dump())
    except NoteConflict as e:
        raise _error(e) from e


@router.put("/{id_}")
def update(id_: str, edicao: NoteEdit, cofre: VaultDep) -> Any:
    try:
        return cofre.atualizar(id_, edicao.model_dump())
    except (NoteNotFound, NoteConflict) as e:
        raise _error(e) from e


@router.delete("/{id_}", status_code=204)
def delete(id_: str, cofre: VaultDep) -> Response:
    try:
        cofre.excluir(id_)
    except NoteNotFound as e:
        raise _error(e) from e
    return Response(status_code=204)
