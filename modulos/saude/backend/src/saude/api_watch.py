"""Rotas de Saúde › Relógio (`/relogio`): dados do Galaxy Watch e análise pela LLM local.

A plataforma põe em `app.state.saude_llm` o chat da LLM local (worker do PC) e, opcionalmente, em
`app.state.saude_contexto` uma função (de, ate) -> texto com dados dos outros módulos.
"""

from datetime import date
from typing import Annotated, Any

from fastapi import APIRouter, Depends, File, HTTPException, Request, UploadFile
from pydantic import BaseModel, Field

from saude import analysis
from saude.api_wellbeing import MentalDep
from saude.watch import Clock
from saude.workouts import Invalid, Workouts

router = APIRouter(prefix="/relogio")


def get_clock(request: Request) -> Clock:
    state = request.app.state
    if getattr(state, "relogio", None) is None:
        workouts: Workouts = state.treinos
        state.relogio = Clock(workouts.raiz / "relogio")
    clock: Clock = state.relogio
    return clock


ClockDep = Annotated[Clock, Depends(get_clock)]


def _period(de: str, ate: str) -> tuple[str, str]:
    try:
        return date.fromisoformat(de).isoformat(), date.fromisoformat(ate).isoformat()
    except ValueError as e:
        raise HTTPException(422, "Datas no formato AAAA-MM-DD") from e


class Days(BaseModel):
    dias: list[dict[str, Any]] = Field(max_length=800)


class RequestAnalysis(BaseModel):
    dias: int = Field(30, ge=3, le=365)
    pergunta: str = Field("", max_length=2000)


@router.get("/dias")
def days(relogio: ClockDep, de: str, ate: str) -> Any:
    return relogio.dias(*_period(de, ate))


@router.put("/dias")
def send_days(corpo: Days, relogio: ClockDep) -> Any:
    """Dias somados pelo app a partir do Health Connect; substituem os valores guardados."""
    try:
        return {"dias": relogio.atualizar(corpo.dias, origem="health_connect")}
    except Invalid as e:
        raise HTTPException(422, str(e)) from e


@router.get("/resumo")
def summary(relogio: ClockDep, de: str, ate: str) -> Any:
    return relogio.resumo(*_period(de, ate))


@router.get("/estado")
def state(relogio: ClockDep) -> Any:
    return relogio.estado()


@router.post("/importar")
def run_import(relogio: ClockDep, arquivo: Annotated[UploadFile, File()]) -> Any:
    """Zip de Samsung Health › Configurações › Baixar dados pessoais."""
    try:
        return relogio.importar_samsung(arquivo.file)
    except Invalid as e:
        raise HTTPException(422, str(e)) from e


@router.get("/analises")
def analyses(relogio: ClockDep) -> Any:
    return relogio.analises()


@router.post("/analises")
async def analyze(
    pedido: RequestAnalysis, request: Request, relogio: ClockDep, mental: MentalDep
) -> Any:
    llm = getattr(request.app.state, "saude_llm", None)
    if llm is None:
        raise HTTPException(503, "LLM local indisponível")
    try:
        return await analysis.analyze(
            llm,
            relogio,
            mental,
            request.app.state.treinos,
            dias=pedido.dias,
            pergunta=pedido.pergunta,
            extra=getattr(request.app.state, "saude_contexto", None),
        )
    except Exception as e:  # o chat da plataforma levanta LLMIndisponivel (sem worker, timeout)
        raise HTTPException(503, str(e)) from e
