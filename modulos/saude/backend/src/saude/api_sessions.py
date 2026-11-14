"""Rotas do guia de treino (`/api/saude/sessoes`): a sessão do dia e os comandos que a controlam
(o celular agora; o relógio depois, pelas mesmas rotas)."""

from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from saude.sessions import DESCANSO_PADRAO, Sessoes
from saude.workouts import Invalido, NaoEncontrado

router = APIRouter(prefix="/sessoes")


def get_sessoes(request: Request) -> Sessoes:
    estado = request.app.state
    if getattr(estado, "sessoes", None) is None or estado.sessoes.treinos is not estado.treinos:
        estado.sessoes = Sessoes(estado.treinos)
    sessoes: Sessoes = estado.sessoes
    return sessoes


SessoesDep = Annotated[Sessoes, Depends(get_sessoes)]


class Inicio(BaseModel):
    data: str
    descanso_s: int = Field(DESCANSO_PADRAO, ge=10, le=600)


class Frequencia(BaseModel):
    media: float | None = None
    maxima: float | None = None
    minima: float | None = None
    amostras: int = 0


class AmostraFc(BaseModel):
    em: str = Field(pattern=r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d")
    bpm: float = Field(ge=0, le=300)


class LoteFc(BaseModel):
    amostras: list[AmostraFc] = Field(max_length=2000)


class Fechamento(BaseModel):
    esforco: int | None = Field(None, ge=1, le=10)
    notas: str | None = Field(None, max_length=4000)
    frequencia: Frequencia | None = None


class Comando(BaseModel):
    acao: Literal[
        "concluir_serie", "pausar", "continuar", "pular_descanso", "somar_descanso", "ir_para",
        "pular_exercicio", "desfazer_serie", "editar_serie", "descanso_padrao",
    ]
    repeticoes: int | None = Field(None, ge=0, le=1000)
    carga_kg: float | None = Field(None, ge=0)
    tempo_s: int | None = Field(None, ge=0, le=36000)
    segundos: int | None = Field(None, ge=-600, le=600)
    indice: int | None = Field(None, ge=0)
    exercicio: int | None = Field(None, ge=0)
    serie: int | None = Field(None, ge=0)


def _erro(e: Exception) -> HTTPException:
    if isinstance(e, NaoEncontrado):
        return HTTPException(404, "Não encontrado")
    return HTTPException(422, str(e))


@router.get("")
def listar(sessoes: SessoesDep, de: str, ate: str) -> Any:
    try:
        return sessoes.listar(de, ate)
    except Invalido as e:
        raise _erro(e) from e


@router.get("/ativa")
def ativa(sessoes: SessoesDep) -> Any:
    return sessoes.ativa()


@router.post("", status_code=201)
def iniciar(sessoes: SessoesDep, corpo: Inicio) -> Any:
    try:
        return sessoes.iniciar(corpo.data, corpo.descanso_s)
    except Invalido as e:
        raise _erro(e) from e


@router.get("/{id_}")
def sessao(sessoes: SessoesDep, id_: str) -> Any:
    try:
        return sessoes.sessao(id_)
    except NaoEncontrado as e:
        raise _erro(e) from e


@router.post("/{id_}/comando")
def comando(sessoes: SessoesDep, id_: str, corpo: Comando) -> Any:
    dados = corpo.model_dump(exclude_none=True)
    acao = dados.pop("acao")
    try:
        return sessoes.comando(id_, acao, dados)
    except (NaoEncontrado, Invalido) as e:
        raise _erro(e) from e


@router.post("/{id_}/fc")
def registrar_fc(sessoes: SessoesDep, id_: str, corpo: LoteFc) -> Any:
    """Frequência cardíaca ao vivo do relógio (lotes de alguns segundos)."""
    try:
        return sessoes.registrar_fc(id_, [a.model_dump() for a in corpo.amostras])
    except (NaoEncontrado, ValueError) as e:
        raise _erro(e) from e


@router.post("/{id_}/concluir")
def concluir(sessoes: SessoesDep, id_: str, corpo: Fechamento) -> Any:
    try:
        return sessoes.concluir(id_, corpo.model_dump(exclude_unset=True))
    except NaoEncontrado as e:
        raise _erro(e) from e


@router.patch("/{id_}")
def editar(sessoes: SessoesDep, id_: str, corpo: Fechamento) -> Any:
    try:
        return sessoes.editar(id_, corpo.model_dump(exclude_unset=True))
    except NaoEncontrado as e:
        raise _erro(e) from e


@router.delete("/{id_}", status_code=204)
def excluir(sessoes: SessoesDep, id_: str) -> None:
    try:
        sessoes.excluir(id_)
    except NaoEncontrado as e:
        raise _erro(e) from e
