"""Rotas de Saúde › Mental (`/mental`) e Saúde › Espiritual (`/espiritual`), incluídas no router de
Saúde. Os dados ficam em subpastas da pasta de Saúde (a dos treinos)."""

from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from saude.spiritual import ESCOPOS, Espiritual
from saude.mental import Mental
from saude.workouts import Invalido, NaoEncontrado, Treinos

router = APIRouter()


def get_mental(request: Request) -> Mental:
    estado = request.app.state
    if getattr(estado, "mental", None) is None:
        treinos: Treinos = estado.treinos
        estado.mental = Mental(treinos.raiz / "mental")
    mental: Mental = estado.mental
    return mental


def get_espiritual(request: Request) -> Espiritual:
    estado = request.app.state
    if getattr(estado, "espiritual", None) is None:
        treinos: Treinos = estado.treinos
        estado.espiritual = Espiritual(treinos.raiz / "espiritual")
    espiritual: Espiritual = estado.espiritual
    return espiritual


MentalDep = Annotated[Mental, Depends(get_mental)]
EspiritualDep = Annotated[Espiritual, Depends(get_espiritual)]


def _erro(e: Exception) -> HTTPException:
    if isinstance(e, NaoEncontrado):
        return HTTPException(404, "Não encontrado")
    return HTTPException(422, str(e))


# --- mental ---


class HabitoEntrada(BaseModel):
    nome: str = Field(min_length=1, max_length=120)
    tipo: str = "construir"
    dias_semana: list[int] = [1, 2, 3, 4, 5, 6, 7]
    descricao: str = Field("", max_length=1000)


class HabitoEdicao(BaseModel):
    nome: str | None = Field(None, min_length=1, max_length=120)
    tipo: str | None = None
    dias_semana: list[int] | None = None
    descricao: str | None = Field(None, max_length=1000)
    arquivado: bool | None = None


class Marca(BaseModel):
    data: str
    feito: bool = True


class FocoEntrada(BaseModel):
    minutos: int = Field(ge=1, le=600)
    tarefa: str = Field("", max_length=300)
    concluida: bool = True
    distracoes: int = Field(0, ge=0, le=1000)
    inicio: str | None = None


class DiaEntrada(BaseModel):
    humor: int | None = Field(None, ge=1, le=5)
    ansiedade: int | None = Field(None, ge=0, le=10)
    gatilhos: str | None = Field(None, max_length=2000)
    o_que_fiz: str | None = Field(None, max_length=2000)
    gratidao: str | None = Field(None, max_length=2000)
    texto: str | None = Field(None, max_length=10000)


@router.get("/mental/habitos")
def habitos(mental: MentalDep, de: str, ate: str) -> Any:
    try:
        return mental.habitos(de, ate)
    except Invalido as e:
        raise _erro(e) from e


@router.post("/mental/habitos", status_code=201)
def criar_habito(mental: MentalDep, corpo: HabitoEntrada) -> Any:
    try:
        return mental.criar_habito(corpo.model_dump())
    except Invalido as e:
        raise _erro(e) from e


@router.patch("/mental/habitos/{id_}")
def editar_habito(mental: MentalDep, id_: str, corpo: HabitoEdicao) -> Any:
    try:
        return mental.editar_habito(id_, corpo.model_dump(exclude_none=True))
    except (NaoEncontrado, Invalido) as e:
        raise _erro(e) from e


@router.post("/mental/habitos/{id_}/marcar")
def marcar_habito(mental: MentalDep, id_: str, corpo: Marca) -> Any:
    try:
        return mental.marcar_habito(id_, corpo.data, corpo.feito)
    except (NaoEncontrado, Invalido) as e:
        raise _erro(e) from e


@router.delete("/mental/habitos/{id_}", status_code=204)
def excluir_habito(mental: MentalDep, id_: str) -> None:
    try:
        mental.excluir_habito(id_)
    except NaoEncontrado as e:
        raise _erro(e) from e


@router.get("/mental/foco")
def foco(mental: MentalDep, de: str, ate: str) -> Any:
    try:
        return mental.foco(de, ate)
    except Invalido as e:
        raise _erro(e) from e


@router.post("/mental/foco", status_code=201)
def registrar_foco(mental: MentalDep, corpo: FocoEntrada) -> Any:
    try:
        return mental.registrar_foco(corpo.model_dump())
    except Invalido as e:
        raise _erro(e) from e


@router.get("/mental/diario")
def diario(mental: MentalDep, de: str, ate: str) -> Any:
    try:
        return mental.diario(de, ate)
    except Invalido as e:
        raise _erro(e) from e


@router.put("/mental/diario/{dia}")
def salvar_dia(mental: MentalDep, dia: str, corpo: DiaEntrada) -> Any:
    try:
        return mental.salvar_dia(dia, corpo.model_dump(exclude_none=True))
    except Invalido as e:
        raise _erro(e) from e


# --- espiritual ---


class PlanoEntrada(BaseModel):
    escopo: str
    dias: int = Field(365, ge=1, le=3650)
    inicio: str | None = None
    nome: str | None = Field(None, max_length=120)


@router.get("/espiritual/escopos")
def escopos() -> Any:
    return [{"id": k, "nome": nome, "livros": livros} for k, (nome, livros) in ESCOPOS.items()]


@router.get("/espiritual/planos")
def planos(espiritual: EspiritualDep) -> Any:
    return espiritual.planos()


@router.post("/espiritual/planos", status_code=201)
def criar_plano(espiritual: EspiritualDep, corpo: PlanoEntrada) -> Any:
    try:
        return espiritual.criar_plano(corpo.model_dump(exclude_none=True))
    except Invalido as e:
        raise _erro(e) from e


@router.delete("/espiritual/planos/{id_}", status_code=204)
def excluir_plano(espiritual: EspiritualDep, id_: str) -> None:
    try:
        espiritual.excluir_plano(id_)
    except NaoEncontrado as e:
        raise _erro(e) from e


@router.get("/espiritual/planos/{id_}/leituras")
def leituras(espiritual: EspiritualDep, id_: str, de: str, ate: str | None = None) -> Any:
    try:
        return espiritual.leituras(id_, de, ate or de)
    except (NaoEncontrado, Invalido) as e:
        raise _erro(e) from e


@router.post("/espiritual/planos/{id_}/marcar")
def marcar_leitura(espiritual: EspiritualDep, id_: str, corpo: Marca) -> Any:
    try:
        return espiritual.marcar(id_, corpo.data, corpo.feito)
    except (NaoEncontrado, Invalido) as e:
        raise _erro(e) from e
