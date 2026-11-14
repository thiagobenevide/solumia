"""Rotas de `/api/codigo`: abas de pedidos ao Claude Code que roda no PC (tarefas `codigo.*` do
worker). As etapas chegam pelo canal `codigo` do WebSocket e o app as lê com `?desde=`."""

import base64
import binascii
import contextlib
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from codigo.sessions import SessionNotFound, Sessions


@dataclass
class Executor:
    pedir: Callable[[str, dict[str, Any]], Awaitable[dict[str, Any]]]
    """Manda a tarefa (`codigo.enviar`, `codigo.parar`, `codigo.git`) ao worker.
    Falha → RuntimeError."""
    disponivel: Callable[[], str | None]
    """Motivo de não dar para pedir agora (sem worker conectado), ou None."""


class NewSession(BaseModel):
    titulo: str = Field("", max_length=120)


class Image(BaseModel):
    nome: str = Field(max_length=200)
    b64: str = Field(max_length=15_000_000)


class Message(BaseModel):
    texto: str = Field(min_length=1, max_length=100_000)
    imagens: list[Image] = Field(default_factory=list, max_length=10)
    modelo: str = ""


class Commit(BaseModel):
    mensagem: str = Field("", max_length=2_000)
    push: bool = True
    publicar: bool = False


router = APIRouter(tags=["codigo"])


def get_sessions(request: Request) -> Sessions:
    sessions: Sessions = request.app.state.sessoes_codigo
    return sessions


def get_executor(request: Request) -> Executor:
    executor: Executor = request.app.state.executor_codigo
    return executor


SessionsDep = Annotated[Sessions, Depends(get_sessions)]
ExecutorDep = Annotated[Executor, Depends(get_executor)]


def prompt_commit(request: Commit) -> str:
    parts = [
        "Faça commit só dos arquivos que você alterou nesta sessão (git add com os caminhos, nunca "
        "`-A`), com mensagem no padrão dos commits recentes do repositório."
    ]
    if request.mensagem.strip():
        parts.append(f"Use como base esta mensagem: {request.mensagem.strip()}")
    if request.push:
        # A VPS só puxa o master: o commit tem de chegar lá, seja qual for a branch local.
        parts.append(
            "Depois faça `git push` da branch atual. Se ela não for `master`, traga o "
            "`origin/master` para ela (`git merge origin/master`) e envie também para o master "
            "com `git push origin HEAD:master`."
        )
    if request.publicar:
        parts.append(
            "Depois publique a nova versão do app com `infra/scripts/publicar_app` e diga o build."
        )
    parts.append("Se não houver nada seu para commitar, só diga isso.")
    return "\n".join(parts)


def _get(sessions: Sessions, id_: str) -> dict[str, Any]:
    try:
        return sessions.obter(id_)
    except SessionNotFound as e:
        raise HTTPException(404, "Aba não encontrada") from e


async def _send(
    sessions: Sessions, executor: Executor, id_: str, text: str, images: list[Image], **extra: Any
) -> dict[str, Any]:
    meta = _get(sessions, id_)
    if meta["estado"] == "rodando":
        raise HTTPException(409, "Esta aba ainda está trabalhando. Pare ou espere terminar.")
    reason = executor.disponivel()
    if reason:
        raise HTTPException(503, reason)
    try:
        raw = [(i.nome, base64.b64decode(i.b64, validate=True)) for i in images]
    except binascii.Error as e:
        raise HTTPException(422, "Imagem inválida") from e
    names = [sessions.guardar_imagem(id_, name, data) for name, data in raw]
    meta = sessions.adicionar(id_, {"tipo": "pedido", "texto": text, "imagens": names, **extra})
    try:
        await executor.pedir(
            "codigo.enviar",
            {
                "sessao_id": id_,
                "texto": text,
                "imagens": [i.model_dump() for i in images],
                "claude_sessao": meta["claude_sessao"],
                "modelo": extra.get("modelo", ""),
            },
        )
    except RuntimeError as e:
        sessions.adicionar(id_, {"tipo": "fim", "erro": True, "texto": str(e)})
        raise HTTPException(502, str(e)) from e
    return sessions.obter(id_)


@router.get("/estado")
def state(executor: ExecutorDep) -> Any:
    return {"indisponivel": executor.disponivel()}


@router.get("/sessoes")
def list_all(sessoes: SessionsDep) -> Any:
    return sessoes.listar()


@router.post("/sessoes", status_code=201)
def create(pedido: NewSession, sessoes: SessionsDep) -> Any:
    return sessoes.criar(pedido.titulo)


@router.get("/sessoes/{id_}")
def get(id_: str, sessoes: SessionsDep, desde: int = 0) -> Any:
    meta = _get(sessoes, id_)
    return {"sessao": meta, "eventos": sessoes.eventos(id_, max(desde, 0))}


@router.patch("/sessoes/{id_}")
def edit(id_: str, pedido: NewSession, sessoes: SessionsDep) -> Any:
    _get(sessoes, id_)
    return sessoes.editar(id_, pedido.titulo)


@router.delete("/sessoes/{id_}", status_code=204)
async def delete(id_: str, sessoes: SessionsDep, executor: ExecutorDep) -> None:
    if _get(sessoes, id_)["estado"] == "rodando" and not executor.disponivel():
        with contextlib.suppress(RuntimeError):
            await executor.pedir("codigo.parar", {"sessao_id": id_})
    sessoes.excluir(id_)


@router.post("/sessoes/{id_}/mensagens")
async def message(id_: str, pedido: Message, sessoes: SessionsDep, executor: ExecutorDep) -> Any:
    return await _send(
        sessoes, executor, id_, pedido.texto, pedido.imagens, modelo=pedido.modelo
    )


@router.post("/sessoes/{id_}/commit")
async def commit(id_: str, pedido: Commit, sessoes: SessionsDep, executor: ExecutorDep) -> Any:
    return await _send(sessoes, executor, id_, prompt_commit(pedido), [], commit=True)


@router.post("/sessoes/{id_}/parar")
async def stop(id_: str, sessoes: SessionsDep, executor: ExecutorDep) -> Any:
    _get(sessoes, id_)
    answer: dict[str, Any] = {"ok": False}
    if not executor.disponivel():
        with contextlib.suppress(RuntimeError):
            answer = await executor.pedir("codigo.parar", {"sessao_id": id_})
    if not answer.get("ok") and sessoes.obter(id_)["estado"] == "rodando":
        # Nada rodando no PC (worker reiniciou ou desconectou): destrava a aba.
        sessoes.adicionar(id_, {"tipo": "fim", "erro": True, "texto": "Nada rodando no PC."})
    return sessoes.obter(id_)


@router.get("/sessoes/{id_}/imagens/{nome}")
def image(id_: str, nome: str, sessoes: SessionsDep) -> FileResponse:
    try:
        return FileResponse(sessoes.caminho_imagem(id_, nome))
    except SessionNotFound as e:
        raise HTTPException(404, "Imagem não encontrada") from e


async def _query(executor: Executor, task: str, payload: dict[str, Any]) -> Any:
    """Consulta ao repositório no PC: sem worker → 503; falha do git lá → 502."""
    reason = executor.disponivel()
    if reason:
        raise HTTPException(503, reason)
    try:
        return await executor.pedir(task, payload)
    except RuntimeError as e:
        raise HTTPException(502, str(e)) from e


@router.get("/git")
async def git(executor: ExecutorDep) -> Any:
    return await _query(executor, "codigo.git", {})


# Navegador de código (só leitura): árvore e arquivos do repositório no PC num commit, com o que
# esse commit mudou. `commit` vazio = HEAD.
@router.get("/arvore")
async def tree(executor: ExecutorDep, commit: str = "") -> Any:
    return await _query(executor, "codigo.arvore", {"commit": commit})


@router.get("/arquivo")
async def file(executor: ExecutorDep, caminho: str, commit: str = "") -> Any:
    return await _query(executor, "codigo.arquivo", {"caminho": caminho, "commit": commit})


@router.get("/busca")
async def search(
    executor: ExecutorDep, termo: str = "", commit: str = "", observacoes: bool = False
) -> Any:
    """Linhas com o termo no repositório (`observacoes`: só em comentários)."""
    request = {"termo": termo, "commit": commit, "observacoes": observacoes}
    return await _query(executor, "codigo.buscar", request)


# Contas do Claude Code no PC (tarefas `contas.*` do worker): trocar quando uma bate o limite da
# janela. Login: `entrar` devolve o link de autorização e `codigo` cola o código mostrado.
class NewAccount(BaseModel):
    nome: str = Field(min_length=1, max_length=31)


class CodeLogin(BaseModel):
    codigo: str = Field(min_length=1, max_length=2_000)


@router.get("/contas")
async def accounts(executor: ExecutorDep) -> Any:
    return await _query(executor, "contas.listar", {})


@router.post("/contas")
async def enter(pedido: NewAccount, executor: ExecutorDep) -> Any:
    return await _query(executor, "contas.entrar", {"nome": pedido.nome})


@router.post("/contas/{nome}/codigo")
async def code_login(nome: str, pedido: CodeLogin, executor: ExecutorDep) -> Any:
    return await _query(executor, "contas.codigo", {"nome": nome, "codigo": pedido.codigo})


@router.post("/contas/{nome}/ativar")
async def activate(nome: str, executor: ExecutorDep) -> Any:
    return await _query(executor, "contas.ativar", {"nome": nome})


@router.delete("/contas/{nome}")
async def remove(nome: str, executor: ExecutorDep) -> Any:
    return await _query(executor, "contas.remover", {"nome": nome})
