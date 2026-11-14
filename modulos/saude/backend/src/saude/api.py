"""Rotas do módulo Saúde. A plataforma monta o router em `/api/saude` com a autenticação e guarda
os [Treinos] em `app.state.treinos`."""

import mimetypes
from typing import Annotated, Any

from fastapi import APIRouter, Depends, File, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from saude.api_bem_estar import router as bem_estar_router
from saude.api_consumo import router as consumo_router
from saude.api_relogio import router as relogio_router
from saude.api_sessoes import router as sessoes_router
from saude.catalogo import AREAS
from saude.treinos import Invalido, NaoEncontrado, Treinos

router = APIRouter(tags=["saude"])


def get_treinos(request: Request) -> Treinos:
    treinos: Treinos = request.app.state.treinos
    return treinos


TreinosDep = Annotated[Treinos, Depends(get_treinos)]


class ExercicioEntrada(BaseModel):
    nome: str = Field(min_length=1, max_length=120)
    area: str = Field(min_length=1, max_length=60)
    grupo: str = Field("", max_length=60)
    equipamento: str = Field("", max_length=60)
    series: int = Field(3, ge=1, le=50)
    repeticoes: str = Field("10", max_length=30)
    carga_kg: float | None = Field(None, ge=0)
    instrucoes: str = Field("", max_length=4000)


class ExercicioEdicao(BaseModel):
    nome: str | None = Field(None, min_length=1, max_length=120)
    area: str | None = Field(None, min_length=1, max_length=60)
    grupo: str | None = Field(None, max_length=60)
    equipamento: str | None = Field(None, max_length=60)
    series: int | None = Field(None, ge=1, le=50)
    repeticoes: str | None = Field(None, max_length=30)
    carga_kg: float | None = Field(None, ge=0)
    instrucoes: str | None = Field(None, max_length=4000)


class ItemEntrada(BaseModel):
    data: str
    exercicio_id: str
    series: int | None = Field(None, ge=1, le=50)
    repeticoes: str | None = Field(None, max_length=30)
    carga_kg: float | None = Field(None, ge=0)
    observacao: str | None = Field(None, max_length=2000)


class ItemEdicao(BaseModel):
    data: str | None = None
    ordem: int | None = Field(None, ge=0)
    series: int | None = Field(None, ge=1, le=50)
    repeticoes: str | None = Field(None, max_length=30)
    carga_kg: float | None = Field(None, ge=0)
    observacao: str | None = Field(None, max_length=2000)
    feito: bool | None = None


class Copia(BaseModel):
    de: str
    ate: str
    destino: str


def _erro(e: Exception) -> HTTPException:
    if isinstance(e, NaoEncontrado):
        return HTTPException(404, "Não encontrado")
    return HTTPException(422, str(e))


@router.get("/exercicios")
def listar_exercicios(treinos: TreinosDep) -> Any:
    return {"areas": AREAS, "exercicios": treinos.listar_exercicios()}


@router.post("/exercicios", status_code=201)
def criar_exercicio(treinos: TreinosDep, corpo: ExercicioEntrada) -> Any:
    return treinos.criar_exercicio(corpo.model_dump())


@router.patch("/exercicios/{id_}")
def editar_exercicio(treinos: TreinosDep, id_: str, corpo: ExercicioEdicao) -> Any:
    try:
        return treinos.editar_exercicio(id_, corpo.model_dump(exclude_unset=True))
    except NaoEncontrado as e:
        raise _erro(e) from e


@router.delete("/exercicios/{id_}", status_code=204)
def excluir_exercicio(treinos: TreinosDep, id_: str) -> None:
    try:
        treinos.excluir_exercicio(id_)
    except NaoEncontrado as e:
        raise _erro(e) from e


@router.get("/exercicios/{id_}/imagem")
def imagem(treinos: TreinosDep, id_: str, n: int = 0) -> FileResponse:
    try:
        caminho = treinos.imagem(id_, n)
    except NaoEncontrado as e:
        raise _erro(e) from e
    return FileResponse(caminho, headers={"Cache-Control": "max-age=86400"})


@router.post("/exercicios/{id_}/imagem")
async def enviar_imagem(
    treinos: TreinosDep, id_: str, arquivo: Annotated[UploadFile, File()]
) -> Any:
    try:
        # o app manda multipart sem tipo (octet-stream): vale a extensão do nome
        tipo = arquivo.content_type or ""
        if not tipo.startswith("image/"):
            tipo = mimetypes.guess_type(arquivo.filename or "")[0] or ""
        return treinos.salvar_imagem(id_, tipo, await arquivo.read())
    except (NaoEncontrado, Invalido) as e:
        raise _erro(e) from e


@router.delete("/exercicios/{id_}/imagem")
def remover_imagem(treinos: TreinosDep, id_: str) -> Any:
    try:
        return treinos.remover_imagem(id_)
    except NaoEncontrado as e:
        raise _erro(e) from e


@router.get("/agenda")
def agenda(treinos: TreinosDep, de: str, ate: str) -> Any:
    try:
        return treinos.agenda(de, ate)
    except Invalido as e:
        raise _erro(e) from e


@router.post("/agenda", status_code=201)
def marcar(treinos: TreinosDep, corpo: ItemEntrada) -> Any:
    try:
        return treinos.marcar(corpo.model_dump())
    except (NaoEncontrado, Invalido) as e:
        raise _erro(e) from e


@router.patch("/agenda/{id_}")
def editar_item(treinos: TreinosDep, id_: str, corpo: ItemEdicao) -> Any:
    try:
        return treinos.editar_item(id_, corpo.model_dump(exclude_unset=True))
    except (NaoEncontrado, Invalido) as e:
        raise _erro(e) from e


@router.delete("/agenda/{id_}", status_code=204)
def desmarcar(treinos: TreinosDep, id_: str) -> None:
    try:
        treinos.desmarcar(id_)
    except NaoEncontrado as e:
        raise _erro(e) from e


@router.post("/agenda/copiar", status_code=201)
def copiar(treinos: TreinosDep, corpo: Copia) -> Any:
    try:
        return treinos.copiar(corpo.de, corpo.ate, corpo.destino)
    except Invalido as e:
        raise _erro(e) from e


router.include_router(bem_estar_router)
router.include_router(relogio_router)
router.include_router(consumo_router)
router.include_router(sessoes_router)
