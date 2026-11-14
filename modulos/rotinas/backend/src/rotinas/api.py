"""Rotas do módulo Rotinas. A plataforma monta o router em `/api/rotinas` com a autenticação, guarda
o [Quadro] em `app.state.quadro` e, em `app.state.rotinas_llm`, a função que manda mensagens de chat
ao LLM (devolve o texto da resposta; levanta [LLMIndisponivel] sem worker)."""

from collections.abc import Awaitable, Callable
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field

from rotinas.quadro import NaoEncontrada, Quadro

router = APIRouter(tags=["rotinas"])

ChatLLM = Callable[[list[dict[str, str]]], Awaitable[str]]

SISTEMA = (
    "Você é o assistente de rotinas do usuário. Responda em português, curto e direto. "
    "Use o quadro Kanban abaixo para responder sobre tarefas, prioridades, prazos e tempo "
    "gasto; se a pergunta for geral, responda normalmente. Não invente tarefas que não "
    "estão no quadro.\n\n"
)


class LLMIndisponivel(Exception):
    pass


def get_quadro(request: Request) -> Quadro:
    quadro: Quadro = request.app.state.quadro
    return quadro


def get_llm(request: Request) -> ChatLLM:
    llm: ChatLLM = request.app.state.rotinas_llm
    return llm


QuadroDep = Annotated[Quadro, Depends(get_quadro)]
LLMDep = Annotated[ChatLLM, Depends(get_llm)]


class TarefaEntrada(BaseModel):
    titulo: str = Field(min_length=1, max_length=200)
    descricao: str = Field("", max_length=8000)
    prioridade: str = "media"
    tags: list[str] = []
    prazo: str | None = None
    coluna: str = "pendente"


class TarefaEdicao(BaseModel):
    titulo: str | None = Field(None, min_length=1, max_length=200)
    descricao: str | None = Field(None, max_length=8000)
    prioridade: str | None = None
    tags: list[str] | None = None
    prazo: str | None = None


class Movimento(BaseModel):
    coluna: str
    ordem: int | None = Field(None, ge=0)


class Mensagem(BaseModel):
    papel: str = Field(pattern="^(usuario|assistente)$")
    texto: str = Field(max_length=8000)


class Pergunta(BaseModel):
    pergunta: str = Field(min_length=1, max_length=4000)
    historico: list[Mensagem] = Field([], max_length=20)


def _erro(e: Exception) -> HTTPException:
    if isinstance(e, NaoEncontrada):
        return HTTPException(404, "Tarefa não encontrada")
    return HTTPException(422, str(e))


@router.get("/tarefas")
def listar(quadro: QuadroDep) -> Any:
    return quadro.listar()


@router.get("/resumo")
def resumo(quadro: QuadroDep) -> Any:
    return quadro.resumo()


@router.post("/tarefas", status_code=201)
def criar(entrada: TarefaEntrada, quadro: QuadroDep) -> Any:
    try:
        return quadro.criar(entrada.model_dump())
    except Exception as e:
        raise _erro(e) from e


@router.patch("/tarefas/{id_}")
def atualizar(id_: str, edicao: TarefaEdicao, quadro: QuadroDep) -> Any:
    try:
        return quadro.atualizar(id_, edicao.model_dump(exclude_unset=True))
    except Exception as e:
        raise _erro(e) from e


@router.post("/tarefas/{id_}/mover")
def mover(id_: str, mov: Movimento, quadro: QuadroDep) -> Any:
    try:
        return quadro.mover(id_, mov.coluna, mov.ordem)
    except Exception as e:
        raise _erro(e) from e


@router.post("/tarefas/{id_}/{acao}")
def cronometro(id_: str, acao: str, quadro: QuadroDep) -> Any:
    acoes = {"iniciar": quadro.iniciar, "pausar": quadro.pausar, "zerar": quadro.zerar}
    if acao not in acoes:
        raise HTTPException(404, "Ação desconhecida")
    try:
        return acoes[acao](id_)
    except Exception as e:
        raise _erro(e) from e


@router.delete("/tarefas/{id_}", status_code=204)
def excluir(id_: str, quadro: QuadroDep) -> Response:
    try:
        quadro.excluir(id_)
    except NaoEncontrada as e:
        raise _erro(e) from e
    return Response(status_code=204)


@router.post("/perguntar")
async def perguntar(p: Pergunta, quadro: QuadroDep, llm: LLMDep) -> Any:
    papeis = {"usuario": "user", "assistente": "assistant"}
    mensagens = [{"role": "system", "content": SISTEMA + quadro.contexto()}]
    mensagens += [{"role": papeis[m.papel], "content": m.texto} for m in p.historico]
    mensagens.append({"role": "user", "content": p.pergunta})
    try:
        return {"resposta": await llm(mensagens)}
    except LLMIndisponivel as e:
        raise HTTPException(503, str(e)) from e
