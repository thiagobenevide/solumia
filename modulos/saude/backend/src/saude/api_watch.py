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
from saude.watch import Relogio
from saude.workouts import Invalido, Treinos

router = APIRouter(prefix="/relogio")


def get_relogio(request: Request) -> Relogio:
    estado = request.app.state
    if getattr(estado, "relogio", None) is None:
        treinos: Treinos = estado.treinos
        estado.relogio = Relogio(treinos.raiz / "relogio")
    relogio: Relogio = estado.relogio
    return relogio


RelogioDep = Annotated[Relogio, Depends(get_relogio)]


def _periodo(de: str, ate: str) -> tuple[str, str]:
    try:
        return date.fromisoformat(de).isoformat(), date.fromisoformat(ate).isoformat()
    except ValueError as e:
        raise HTTPException(422, "Datas no formato AAAA-MM-DD") from e


class Dias(BaseModel):
    dias: list[dict[str, Any]] = Field(max_length=800)


class PedidoAnalise(BaseModel):
    dias: int = Field(30, ge=3, le=365)
    pergunta: str = Field("", max_length=2000)


@router.get("/dias")
def dias(relogio: RelogioDep, de: str, ate: str) -> Any:
    return relogio.dias(*_periodo(de, ate))


@router.put("/dias")
def enviar_dias(corpo: Dias, relogio: RelogioDep) -> Any:
    """Dias somados pelo app a partir do Health Connect; substituem os valores guardados."""
    try:
        return {"dias": relogio.atualizar(corpo.dias, origem="health_connect")}
    except Invalido as e:
        raise HTTPException(422, str(e)) from e


@router.get("/resumo")
def resumo(relogio: RelogioDep, de: str, ate: str) -> Any:
    return relogio.resumo(*_periodo(de, ate))


@router.get("/estado")
def estado(relogio: RelogioDep) -> Any:
    return relogio.estado()


@router.post("/importar")
def importar(relogio: RelogioDep, arquivo: Annotated[UploadFile, File()]) -> Any:
    """Zip de Samsung Health › Configurações › Baixar dados pessoais."""
    try:
        return relogio.importar_samsung(arquivo.file)
    except Invalido as e:
        raise HTTPException(422, str(e)) from e


@router.get("/analises")
def analises(relogio: RelogioDep) -> Any:
    return relogio.analises()


@router.post("/analises")
async def analisar(
    pedido: PedidoAnalise, request: Request, relogio: RelogioDep, mental: MentalDep
) -> Any:
    llm = getattr(request.app.state, "saude_llm", None)
    if llm is None:
        raise HTTPException(503, "LLM local indisponível")
    try:
        return await analysis.analisar(
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
