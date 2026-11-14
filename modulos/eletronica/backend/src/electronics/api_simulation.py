"""SPICE simulation routes (mounted at `/api/eletronica` together with `api.py`)."""

from typing import Annotated, Any

from fastapi import APIRouter, BackgroundTasks, Depends, Request
from fastapi.responses import JSONResponse

from electronics import spice
from electronics.projects import NotFound, Projects
from electronics.simulation import Simulations, Unavailable

router = APIRouter()


def _projects(request: Request) -> Projects:
    return request.app.state.projetos_eletronica  # type: ignore[no-any-return]


def _simulations(request: Request) -> Simulations:
    return request.app.state.simulacoes_eletronica  # type: ignore[no-any-return]


class _Failure(Exception):
    def __init__(self, status: int, mensagem: str) -> None:
        super().__init__(mensagem)
        self.status = status


def _answer(e: _Failure) -> JSONResponse:
    # `detail` is what the simulation screen reads; `error` keeps the format of the rest of the
    # gateway.
    msg = str(e)
    return JSONResponse(
        status_code=e.status, content={"detail": msg, "error": {"message": msg, "type": "error"}}
    )


ProjectsDep = Annotated[Projects, Depends(_projects)]
SimulationsDep = Annotated[Simulations, Depends(_simulations)]


def _generate(
    projects: Projects, id_: str, analysis: str, parameters: dict[str, Any]
) -> dict[str, Any]:
    try:
        project = projects.obter(id_)
    except NotFound as e:
        raise _Failure(404, "Projeto não encontrado") from e
    except Exception as e:
        raise _Failure(422, str(e)) from e
    try:
        return spice.generate(project, projects.symbol, analysis, parameters)
    except ValueError as e:
        raise _Failure(422, str(e)) from e


@router.get("/projetos/{id_}/spice")
def show_spice(id_: str, request: Request, projetos: ProjectsDep, analise: str = "op") -> Any:
    """SPICE netlist; the analysis parameters come in the query
    (`?analise=tran&passo=1u&fim=1m`)."""
    parameters = {k: v for k, v in request.query_params.items() if k != "analise"}
    try:
        g = _generate(projetos, id_, analise, parameters)
    except _Failure as e:
        return _answer(e)
    return {
        "texto": g["texto"],
        "ignorados": g["ignorados"],
        "fontes": g["fontes"],
        "avisos": g["avisos"],
    }


@router.post("/projetos/{id_}/simular", status_code=202)
def simulate(
    id_: str,
    corpo: dict[str, Any],
    fundo: BackgroundTasks,
    projetos: ProjectsDep,
    simulacoes: SimulationsDep,
) -> Any:
    """Flat body `{analise, ...parameters}`: tran (passo, fim), ac (pontos, inicio, fim, per
    decade), dc (fonte, inicio, fim, passo). Answers `{id, estado}`.
    The result comes out at `/simulacoes/{id}`.
    """
    analysis = str(corpo.get("analise", "op"))
    parameters = {k: v for k, v in corpo.items() if k != "analise"}
    try:
        g = _generate(projetos, id_, analysis, parameters)
        t = simulacoes.criar(id_, analysis, g)
    except _Failure as e:
        return _answer(e)
    except Unavailable as e:
        return _answer(_Failure(503, str(e)))
    fundo.add_task(simulacoes.rodar, t["id"])
    return {"id": t["id"], "estado": t["estado"]}


@router.get("/simulacoes/{tarefa}")
def show_simulation(tarefa: str, simulacoes: SimulationsDep) -> Any:
    t = simulacoes.obter(tarefa)
    if t is None:
        return _answer(_Failure(404, "Simulação não encontrada"))
    return t
