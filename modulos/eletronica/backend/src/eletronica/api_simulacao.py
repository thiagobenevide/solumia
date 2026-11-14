"""Rotas de simulação SPICE (montadas em `/api/eletronica` junto com `api.py`)."""

from typing import Annotated, Any

from fastapi import APIRouter, BackgroundTasks, Depends, Request
from fastapi.responses import JSONResponse

from eletronica import spice
from eletronica.projetos import NaoEncontrado, Projetos
from eletronica.simulacao import Indisponivel, Simulacoes

router = APIRouter()


def _projetos(request: Request) -> Projetos:
    return request.app.state.projetos_eletronica  # type: ignore[no-any-return]


def _simulacoes(request: Request) -> Simulacoes:
    return request.app.state.simulacoes_eletronica  # type: ignore[no-any-return]


class _Falha(Exception):
    def __init__(self, status: int, mensagem: str) -> None:
        super().__init__(mensagem)
        self.status = status


def _resposta(e: _Falha) -> JSONResponse:
    # `detail` é o que a tela de simulação lê; `error` mantém o formato do resto do gateway.
    msg = str(e)
    return JSONResponse(
        status_code=e.status, content={"detail": msg, "error": {"message": msg, "type": "error"}}
    )


ProjetosDep = Annotated[Projetos, Depends(_projetos)]
SimulacoesDep = Annotated[Simulacoes, Depends(_simulacoes)]


def _gerar(
    projetos: Projetos, id_: str, analise: str, parametros: dict[str, Any]
) -> dict[str, Any]:
    try:
        projeto = projetos.obter(id_)
    except NaoEncontrado as e:
        raise _Falha(404, "Projeto não encontrado") from e
    except Exception as e:
        raise _Falha(422, str(e)) from e
    try:
        return spice.gerar(projeto, projetos.simbolo, analise, parametros)
    except ValueError as e:
        raise _Falha(422, str(e)) from e


@router.get("/projetos/{id_}/spice")
def ver_spice(id_: str, request: Request, projetos: ProjetosDep, analise: str = "op") -> Any:
    """Netlist SPICE; os parâmetros da análise vêm na query (`?analise=tran&passo=1u&fim=1m`)."""
    parametros = {k: v for k, v in request.query_params.items() if k != "analise"}
    try:
        g = _gerar(projetos, id_, analise, parametros)
    except _Falha as e:
        return _resposta(e)
    return {
        "texto": g["texto"],
        "ignorados": g["ignorados"],
        "fontes": g["fontes"],
        "avisos": g["avisos"],
    }


@router.post("/projetos/{id_}/simular", status_code=202)
def simular(
    id_: str,
    corpo: dict[str, Any],
    fundo: BackgroundTasks,
    projetos: ProjetosDep,
    simulacoes: SimulacoesDep,
) -> Any:
    """Corpo plano `{analise, ...parâmetros}`: tran (passo, fim), ac (pontos, inicio, fim, por
    década), dc (fonte, inicio, fim, passo). Responde `{id, estado}`.
    O resultado sai em `/simulacoes/{id}`.
    """
    analise = str(corpo.get("analise", "op"))
    parametros = {k: v for k, v in corpo.items() if k != "analise"}
    try:
        g = _gerar(projetos, id_, analise, parametros)
        t = simulacoes.criar(id_, analise, g)
    except _Falha as e:
        return _resposta(e)
    except Indisponivel as e:
        return _resposta(_Falha(503, str(e)))
    fundo.add_task(simulacoes.rodar, t["id"])
    return {"id": t["id"], "estado": t["estado"]}


@router.get("/simulacoes/{tarefa}")
def ver_simulacao(tarefa: str, simulacoes: SimulacoesDep) -> Any:
    t = simulacoes.obter(tarefa)
    if t is None:
        return _resposta(_Falha(404, "Simulação não encontrada"))
    return t
