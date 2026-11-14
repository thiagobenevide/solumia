"""Rotas do módulo Rotinas. A plataforma monta o router em `/api/rotinas` com a autenticação, guarda
o [Quadro] em `app.state.quadro` e, em `app.state.rotinas_llm`, a função que manda mensagens de chat
ao LLM (devolve o texto da resposta; levanta [LLMIndisponivel] sem worker)."""

from collections.abc import Awaitable, Callable
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field

from rotinas.board import NotFound, Frame

router = APIRouter(tags=["rotinas"])

ChatLLM = Callable[[list[dict[str, str]]], Awaitable[str]]

SYSTEM = (
    "Você é o assistente de rotinas do usuário. Responda em português, curto e direto. "
    "Use o quadro Kanban abaixo para responder sobre tarefas, prioridades, prazos e tempo "
    "gasto; se a pergunta for geral, responda normalmente. Não invente tarefas que não "
    "estão no quadro.\n\n"
)


class LLMUnavailable(Exception):
    pass


def get_frame(request: Request) -> Frame:
    frame: Frame = request.app.state.quadro
    return frame


def get_llm(request: Request) -> ChatLLM:
    llm: ChatLLM = request.app.state.rotinas_llm
    return llm


FrameDep = Annotated[Frame, Depends(get_frame)]
LLMDep = Annotated[ChatLLM, Depends(get_llm)]


class TaskInput(BaseModel):
    titulo: str = Field(min_length=1, max_length=200)
    descricao: str = Field("", max_length=8000)
    prioridade: str = "media"
    tags: list[str] = []
    prazo: str | None = None
    coluna: str = "pendente"


class TaskEdit(BaseModel):
    titulo: str | None = Field(None, min_length=1, max_length=200)
    descricao: str | None = Field(None, max_length=8000)
    prioridade: str | None = None
    tags: list[str] | None = None
    prazo: str | None = None


class Motion(BaseModel):
    coluna: str
    ordem: int | None = Field(None, ge=0)


class Message(BaseModel):
    papel: str = Field(pattern="^(usuario|assistente)$")
    texto: str = Field(max_length=8000)


class Question(BaseModel):
    pergunta: str = Field(min_length=1, max_length=4000)
    historico: list[Message] = Field([], max_length=20)


def _error(e: Exception) -> HTTPException:
    if isinstance(e, NotFound):
        return HTTPException(404, "Tarefa não encontrada")
    return HTTPException(422, str(e))


@router.get("/tarefas")
def list_all(quadro: FrameDep) -> Any:
    return quadro.listar()


@router.get("/resumo")
def summary(quadro: FrameDep) -> Any:
    return quadro.resumo()


@router.post("/tarefas", status_code=201)
def create(entrada: TaskInput, quadro: FrameDep) -> Any:
    try:
        return quadro.criar(entrada.model_dump())
    except Exception as e:
        raise _error(e) from e


@router.patch("/tarefas/{id_}")
def update(id_: str, edicao: TaskEdit, quadro: FrameDep) -> Any:
    try:
        return quadro.atualizar(id_, edicao.model_dump(exclude_unset=True))
    except Exception as e:
        raise _error(e) from e


@router.post("/tarefas/{id_}/mover")
def move(id_: str, mov: Motion, quadro: FrameDep) -> Any:
    try:
        return quadro.mover(id_, mov.coluna, mov.ordem)
    except Exception as e:
        raise _error(e) from e


@router.post("/tarefas/{id_}/{acao}")
def stopwatch(id_: str, acao: str, quadro: FrameDep) -> Any:
    actions = {"iniciar": quadro.iniciar, "pausar": quadro.pausar, "zerar": quadro.zerar}
    if acao not in actions:
        raise HTTPException(404, "Ação desconhecida")
    try:
        return actions[acao](id_)
    except Exception as e:
        raise _error(e) from e


@router.delete("/tarefas/{id_}", status_code=204)
def delete(id_: str, quadro: FrameDep) -> Response:
    try:
        quadro.excluir(id_)
    except NotFound as e:
        raise _error(e) from e
    return Response(status_code=204)


@router.post("/perguntar")
async def ask(p: Question, quadro: FrameDep, llm: LLMDep) -> Any:
    roles = {"usuario": "user", "assistente": "assistant"}
    messages = [{"role": "system", "content": SYSTEM + quadro.contexto()}]
    messages += [{"role": roles[m.papel], "content": m.texto} for m in p.historico]
    messages.append({"role": "user", "content": p.pergunta})
    try:
        return {"resposta": await llm(messages)}
    except LLMUnavailable as e:
        raise HTTPException(503, str(e)) from e
