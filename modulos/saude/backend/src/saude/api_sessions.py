"""Rotas do guia de treino (`/api/saude/sessoes`): a sessão do dia e os comandos que a controlam
(o celular agora; o relógio depois, pelas mesmas rotas)."""

from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from saude.sessions import REST_DEFAULT, Sessions
from saude.workouts import Invalid, NotFound

router = APIRouter(prefix="/sessoes")


def get_sessions(request: Request) -> Sessions:
    state = request.app.state
    if getattr(state, "sessoes", None) is None or state.sessoes.workouts is not state.workouts:
        state.sessoes = Sessions(state.workouts)
    sessions: Sessions = state.sessoes
    return sessions


SessionsDep = Annotated[Sessions, Depends(get_sessions)]


class Start(BaseModel):
    data: str
    descanso_s: int = Field(REST_DEFAULT, ge=10, le=600)


class Frequency(BaseModel):
    media: float | None = None
    maxima: float | None = None
    minima: float | None = None
    amostras: int = 0


class SampleFc(BaseModel):
    em: str = Field(pattern=r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d")
    bpm: float = Field(ge=0, le=300)


class BatchFc(BaseModel):
    amostras: list[SampleFc] = Field(max_length=2000)


class Closing(BaseModel):
    esforco: int | None = Field(None, ge=1, le=10)
    notas: str | None = Field(None, max_length=4000)
    frequencia: Frequency | None = None


class Command(BaseModel):
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


def _error(e: Exception) -> HTTPException:
    if isinstance(e, NotFound):
        return HTTPException(404, "Não encontrado")
    return HTTPException(422, str(e))


@router.get("")
def list_all(sessoes: SessionsDep, de: str, ate: str) -> Any:
    try:
        return sessoes.list_all(de, ate)
    except Invalid as e:
        raise _error(e) from e


@router.get("/ativa")
def active(sessoes: SessionsDep) -> Any:
    return sessoes.ativa()


@router.post("", status_code=201)
def start(sessoes: SessionsDep, corpo: Start) -> Any:
    try:
        return sessoes.iniciar(corpo.data, corpo.descanso_s)
    except Invalid as e:
        raise _error(e) from e


@router.get("/{id_}")
def session(sessoes: SessionsDep, id_: str) -> Any:
    try:
        return sessoes.session(id_)
    except NotFound as e:
        raise _error(e) from e


@router.post("/{id_}/comando")
def command(sessoes: SessionsDep, id_: str, corpo: Command) -> Any:
    data = corpo.model_dump(exclude_none=True)
    action = data.pop("acao")
    try:
        return sessoes.command(id_, action, data)
    except (NotFound, Invalid) as e:
        raise _error(e) from e


@router.post("/{id_}/fc")
def register_fc(sessoes: SessionsDep, id_: str, corpo: BatchFc) -> Any:
    """Frequência cardíaca ao vivo do relógio (lotes de alguns segundos)."""
    try:
        return sessoes.register_fc(id_, [a.model_dump() for a in corpo.amostras])
    except (NotFound, ValueError) as e:
        raise _error(e) from e


@router.post("/{id_}/concluir")
def finish(sessoes: SessionsDep, id_: str, corpo: Closing) -> Any:
    try:
        return sessoes.finish(id_, corpo.model_dump(exclude_unset=True))
    except NotFound as e:
        raise _error(e) from e


@router.patch("/{id_}")
def edit(sessoes: SessionsDep, id_: str, corpo: Closing) -> Any:
    try:
        return sessoes.edit(id_, corpo.model_dump(exclude_unset=True))
    except NotFound as e:
        raise _error(e) from e


@router.delete("/{id_}", status_code=204)
def delete(sessoes: SessionsDep, id_: str) -> None:
    try:
        sessoes.excluir(id_)
    except NotFound as e:
        raise _error(e) from e
