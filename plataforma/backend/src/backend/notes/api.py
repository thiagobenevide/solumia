from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field

from backend.api.deps import require_client_api_key
from backend.notes.vault import Cofre, NotaConflito, NotaNaoEncontrada
from backend.notes.note_types import TIPOS

router = APIRouter(
    prefix="/api/notas", tags=["notas"], dependencies=[Depends(require_client_api_key)]
)


def get_cofre(request: Request) -> Cofre:
    cofre: Cofre = request.app.state.cofre
    return cofre


CofreDep = Annotated[Cofre, Depends(get_cofre)]


class NotaEntrada(BaseModel):
    titulo: str = Field(min_length=1, max_length=200)
    tipo: str = "nota"
    tags: list[str] = []
    aliases: list[str] = []
    propriedades: dict[str, Any] = {}
    corpo: str = ""
    pasta: str = ""


class NotaEdicao(BaseModel):
    titulo: str | None = Field(None, min_length=1, max_length=200)
    tipo: str | None = None
    tags: list[str] | None = None
    aliases: list[str] | None = None
    propriedades: dict[str, Any] | None = None
    corpo: str | None = None


def _erro(e: Exception) -> HTTPException:
    if isinstance(e, NotaNaoEncontrada):
        return HTTPException(404, "Nota não encontrada")
    return HTTPException(409, str(e))


@router.get("")
def listar(cofre: CofreDep, q: str = "", tipo: str | None = None, tag: str | None = None) -> Any:
    return cofre.listar(q, tipo, tag)


@router.get("/tipos")
def tipos() -> Any:
    return TIPOS


@router.get("/sugestoes")
def sugestoes(cofre: CofreDep, q: str = "", limite: int = 10) -> Any:
    return cofre.sugerir(q, limite)


@router.get("/analise")
def analise(cofre: CofreDep) -> Any:
    return cofre.analise()


@router.get("/grafo")
def grafo(cofre: CofreDep) -> Any:
    return cofre.grafo()


@router.get("/espelho")
def espelho(cofre: CofreDep) -> Any:
    """Todas as notas completas numa chamada: o app guarda para ler e editar sem conexão."""
    return [cofre.obter(r["id"]) for r in cofre.listar()]


@router.get("/{id_}")
def obter(id_: str, cofre: CofreDep) -> Any:
    try:
        return cofre.obter(id_)
    except NotaNaoEncontrada as e:
        raise _erro(e) from e


@router.post("", status_code=201)
def criar(entrada: NotaEntrada, cofre: CofreDep) -> Any:
    try:
        return cofre.criar(entrada.model_dump())
    except NotaConflito as e:
        raise _erro(e) from e


@router.put("/{id_}")
def atualizar(id_: str, edicao: NotaEdicao, cofre: CofreDep) -> Any:
    try:
        return cofre.atualizar(id_, edicao.model_dump())
    except (NotaNaoEncontrada, NotaConflito) as e:
        raise _erro(e) from e


@router.delete("/{id_}", status_code=204)
def excluir(id_: str, cofre: CofreDep) -> Response:
    try:
        cofre.excluir(id_)
    except NotaNaoEncontrada as e:
        raise _erro(e) from e
    return Response(status_code=204)
