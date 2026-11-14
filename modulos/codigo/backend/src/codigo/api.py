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

from codigo.sessoes import SessaoNaoEncontrada, Sessoes


@dataclass
class Executor:
    pedir: Callable[[str, dict[str, Any]], Awaitable[dict[str, Any]]]
    """Manda a tarefa (`codigo.enviar`, `codigo.parar`, `codigo.git`) ao worker.
    Falha → RuntimeError."""
    disponivel: Callable[[], str | None]
    """Motivo de não dar para pedir agora (sem worker conectado), ou None."""


class NovaSessao(BaseModel):
    titulo: str = Field("", max_length=120)


class Imagem(BaseModel):
    nome: str = Field(max_length=200)
    b64: str = Field(max_length=15_000_000)


class Mensagem(BaseModel):
    texto: str = Field(min_length=1, max_length=100_000)
    imagens: list[Imagem] = Field(default_factory=list, max_length=10)
    modelo: str = ""


class Commit(BaseModel):
    mensagem: str = Field("", max_length=2_000)
    push: bool = True
    publicar: bool = False


router = APIRouter(tags=["codigo"])


def get_sessoes(request: Request) -> Sessoes:
    sessoes: Sessoes = request.app.state.sessoes_codigo
    return sessoes


def get_executor(request: Request) -> Executor:
    executor: Executor = request.app.state.executor_codigo
    return executor


SessoesDep = Annotated[Sessoes, Depends(get_sessoes)]
ExecutorDep = Annotated[Executor, Depends(get_executor)]


def prompt_commit(pedido: Commit) -> str:
    partes = [
        "Faça commit só dos arquivos que você alterou nesta sessão (git add com os caminhos, nunca "
        "`-A`), com mensagem no padrão dos commits recentes do repositório."
    ]
    if pedido.mensagem.strip():
        partes.append(f"Use como base esta mensagem: {pedido.mensagem.strip()}")
    if pedido.push:
        # A VPS só puxa o master: o commit tem de chegar lá, seja qual for a branch local.
        partes.append(
            "Depois faça `git push` da branch atual. Se ela não for `master`, traga o "
            "`origin/master` para ela (`git merge origin/master`) e envie também para o master "
            "com `git push origin HEAD:master`."
        )
    if pedido.publicar:
        partes.append(
            "Depois publique a nova versão do app com `infra/scripts/publicar_app` e diga o build."
        )
    partes.append("Se não houver nada seu para commitar, só diga isso.")
    return "\n".join(partes)


def _obter(sessoes: Sessoes, id_: str) -> dict[str, Any]:
    try:
        return sessoes.obter(id_)
    except SessaoNaoEncontrada as e:
        raise HTTPException(404, "Aba não encontrada") from e


async def _enviar(
    sessoes: Sessoes, executor: Executor, id_: str, texto: str, imagens: list[Imagem], **extra: Any
) -> dict[str, Any]:
    meta = _obter(sessoes, id_)
    if meta["estado"] == "rodando":
        raise HTTPException(409, "Esta aba ainda está trabalhando. Pare ou espere terminar.")
    motivo = executor.disponivel()
    if motivo:
        raise HTTPException(503, motivo)
    try:
        brutos = [(i.nome, base64.b64decode(i.b64, validate=True)) for i in imagens]
    except binascii.Error as e:
        raise HTTPException(422, "Imagem inválida") from e
    nomes = [sessoes.guardar_imagem(id_, nome, dados) for nome, dados in brutos]
    meta = sessoes.adicionar(id_, {"tipo": "pedido", "texto": texto, "imagens": nomes, **extra})
    try:
        await executor.pedir(
            "codigo.enviar",
            {
                "sessao_id": id_,
                "texto": texto,
                "imagens": [i.model_dump() for i in imagens],
                "claude_sessao": meta["claude_sessao"],
                "modelo": extra.get("modelo", ""),
            },
        )
    except RuntimeError as e:
        sessoes.adicionar(id_, {"tipo": "fim", "erro": True, "texto": str(e)})
        raise HTTPException(502, str(e)) from e
    return sessoes.obter(id_)


@router.get("/estado")
def estado(executor: ExecutorDep) -> Any:
    return {"indisponivel": executor.disponivel()}


@router.get("/sessoes")
def listar(sessoes: SessoesDep) -> Any:
    return sessoes.listar()


@router.post("/sessoes", status_code=201)
def criar(pedido: NovaSessao, sessoes: SessoesDep) -> Any:
    return sessoes.criar(pedido.titulo)


@router.get("/sessoes/{id_}")
def obter(id_: str, sessoes: SessoesDep, desde: int = 0) -> Any:
    meta = _obter(sessoes, id_)
    return {"sessao": meta, "eventos": sessoes.eventos(id_, max(desde, 0))}


@router.patch("/sessoes/{id_}")
def editar(id_: str, pedido: NovaSessao, sessoes: SessoesDep) -> Any:
    _obter(sessoes, id_)
    return sessoes.editar(id_, pedido.titulo)


@router.delete("/sessoes/{id_}", status_code=204)
async def excluir(id_: str, sessoes: SessoesDep, executor: ExecutorDep) -> None:
    if _obter(sessoes, id_)["estado"] == "rodando" and not executor.disponivel():
        with contextlib.suppress(RuntimeError):
            await executor.pedir("codigo.parar", {"sessao_id": id_})
    sessoes.excluir(id_)


@router.post("/sessoes/{id_}/mensagens")
async def mensagem(id_: str, pedido: Mensagem, sessoes: SessoesDep, executor: ExecutorDep) -> Any:
    return await _enviar(
        sessoes, executor, id_, pedido.texto, pedido.imagens, modelo=pedido.modelo
    )


@router.post("/sessoes/{id_}/commit")
async def commit(id_: str, pedido: Commit, sessoes: SessoesDep, executor: ExecutorDep) -> Any:
    return await _enviar(sessoes, executor, id_, prompt_commit(pedido), [], commit=True)


@router.post("/sessoes/{id_}/parar")
async def parar(id_: str, sessoes: SessoesDep, executor: ExecutorDep) -> Any:
    _obter(sessoes, id_)
    resposta: dict[str, Any] = {"ok": False}
    if not executor.disponivel():
        with contextlib.suppress(RuntimeError):
            resposta = await executor.pedir("codigo.parar", {"sessao_id": id_})
    if not resposta.get("ok") and sessoes.obter(id_)["estado"] == "rodando":
        # Nada rodando no PC (worker reiniciou ou desconectou): destrava a aba.
        sessoes.adicionar(id_, {"tipo": "fim", "erro": True, "texto": "Nada rodando no PC."})
    return sessoes.obter(id_)


@router.get("/sessoes/{id_}/imagens/{nome}")
def imagem(id_: str, nome: str, sessoes: SessoesDep) -> FileResponse:
    try:
        return FileResponse(sessoes.caminho_imagem(id_, nome))
    except SessaoNaoEncontrada as e:
        raise HTTPException(404, "Imagem não encontrada") from e


async def _consultar(executor: Executor, tarefa: str, payload: dict[str, Any]) -> Any:
    """Consulta ao repositório no PC: sem worker → 503; falha do git lá → 502."""
    motivo = executor.disponivel()
    if motivo:
        raise HTTPException(503, motivo)
    try:
        return await executor.pedir(tarefa, payload)
    except RuntimeError as e:
        raise HTTPException(502, str(e)) from e


@router.get("/git")
async def git(executor: ExecutorDep) -> Any:
    return await _consultar(executor, "codigo.git", {})


# Navegador de código (só leitura): árvore e arquivos do repositório no PC num commit, com o que
# esse commit mudou. `commit` vazio = HEAD.
@router.get("/arvore")
async def arvore(executor: ExecutorDep, commit: str = "") -> Any:
    return await _consultar(executor, "codigo.arvore", {"commit": commit})


@router.get("/arquivo")
async def arquivo(executor: ExecutorDep, caminho: str, commit: str = "") -> Any:
    return await _consultar(executor, "codigo.arquivo", {"caminho": caminho, "commit": commit})


@router.get("/busca")
async def busca(
    executor: ExecutorDep, termo: str = "", commit: str = "", observacoes: bool = False
) -> Any:
    """Linhas com o termo no repositório (`observacoes`: só em comentários)."""
    pedido = {"termo": termo, "commit": commit, "observacoes": observacoes}
    return await _consultar(executor, "codigo.buscar", pedido)


# Contas do Claude Code no PC (tarefas `contas.*` do worker): trocar quando uma bate o limite da
# janela. Login: `entrar` devolve o link de autorização e `codigo` cola o código mostrado.
class NovaConta(BaseModel):
    nome: str = Field(min_length=1, max_length=31)


class CodigoLogin(BaseModel):
    codigo: str = Field(min_length=1, max_length=2_000)


@router.get("/contas")
async def contas(executor: ExecutorDep) -> Any:
    return await _consultar(executor, "contas.listar", {})


@router.post("/contas")
async def entrar(pedido: NovaConta, executor: ExecutorDep) -> Any:
    return await _consultar(executor, "contas.entrar", {"nome": pedido.nome})


@router.post("/contas/{nome}/codigo")
async def codigo_login(nome: str, pedido: CodigoLogin, executor: ExecutorDep) -> Any:
    return await _consultar(executor, "contas.codigo", {"nome": nome, "codigo": pedido.codigo})


@router.post("/contas/{nome}/ativar")
async def ativar(nome: str, executor: ExecutorDep) -> Any:
    return await _consultar(executor, "contas.ativar", {"nome": nome})


@router.delete("/contas/{nome}")
async def remover(nome: str, executor: ExecutorDep) -> Any:
    return await _consultar(executor, "contas.remover", {"nome": nome})
