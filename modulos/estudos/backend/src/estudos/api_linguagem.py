"""Rotas de `/api/estudos/linguagem` (montadas pelo router de Estudos). A plataforma guarda a
[Linguagem] em `app.state.linguagem`, com a LLM local e a voz do worker."""

import logging
from typing import Annotated, Any

from fastapi import (
    APIRouter,
    BackgroundTasks,
    Depends,
    File,
    Form,
    HTTPException,
    Request,
    UploadFile,
)
from pydantic import BaseModel, Field

from estudos.estudos import Invalido, NaoEncontrado
from estudos.linguagem import Indisponivel, Linguagem

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/linguagem")

IDIOMA = Field(pattern="^(en|es|fr|pt)$")


def get_linguagem(request: Request) -> Linguagem:
    linguagem: Linguagem = request.app.state.linguagem
    return linguagem


LinguagemDep = Annotated[Linguagem, Depends(get_linguagem)]


def _erro(e: Exception) -> HTTPException:
    if isinstance(e, NaoEncontrado):
        return HTTPException(404, "Não encontrado")
    if isinstance(e, Indisponivel):
        return HTTPException(503, str(e))
    return HTTPException(422, str(e))


ERROS = (NaoEncontrado, Invalido, Indisponivel)


class PedidoFala(BaseModel):
    texto: str = Field(min_length=1, max_length=2000)
    idioma: str = IDIOMA
    velocidade: float = Field(1.0, ge=0.5, le=2.0)


@router.post("/fala")
async def fala(linguagem: LinguagemDep, corpo: PedidoFala) -> Any:
    """Fala da frase (base64) com o tempo de cada palavra, para a leitura guiada."""
    try:
        return await linguagem.fala(corpo.texto, corpo.idioma, round(corpo.velocidade, 2))
    except ERROS as e:
        raise _erro(e) from e


class PedidoTraducao(BaseModel):
    termo: str = Field(min_length=1, max_length=1000)
    frase: str = Field("", max_length=3000)
    idioma: str = IDIOMA
    destino: str = Field("pt", pattern="^(en|es|fr|pt)$")


@router.post("/traduzir")
async def traduzir(linguagem: LinguagemDep, corpo: PedidoTraducao) -> Any:
    try:
        return await linguagem.traduzir(corpo.termo, corpo.frase, corpo.idioma, corpo.destino)
    except ERROS as e:
        raise _erro(e) from e


@router.get("/vocabulario")
def vocabulario(linguagem: LinguagemDep, idioma: str | None = None, devidas: bool = False) -> Any:
    return linguagem.listar_vocabulario(idioma, devidas)


class NovaPalavra(BaseModel):
    termo: str = Field(min_length=1, max_length=300)
    idioma: str = IDIOMA
    contexto: str = Field("", max_length=3000)
    traducao: str = Field("", max_length=500)
    classe: str = Field("", max_length=40)
    ipa: str = Field("", max_length=200)
    arquivo_id: str | None = None
    titulo: str = Field("", max_length=300)
    pagina: int | None = Field(None, ge=0)
    gerar: bool = True
    """Cria as frases e exercícios pela LLM local depois de responder."""


async def _gerar_em_segundo_plano(linguagem: Linguagem, id_: str) -> None:
    try:
        await linguagem.gerar_pratica(id_)
    except ERROS as e:  # o erro fica no item (`erro`) e o app oferece gerar de novo
        logger.info("Prática de %s não gerada: %s", id_, e)


@router.post("/vocabulario", status_code=201)
def criar_palavra(linguagem: LinguagemDep, corpo: NovaPalavra, tarefas: BackgroundTasks) -> Any:
    try:
        item = linguagem.criar_vocabulario(corpo.model_dump())
    except ERROS as e:
        raise _erro(e) from e
    if corpo.gerar and not item.get("exercicios"):
        item = linguagem.vocabulario.editar(item["id"], {"gerando": True})
        tarefas.add_task(_gerar_em_segundo_plano, linguagem, item["id"])
    return item


@router.post("/vocabulario/{id_}/gerar")
async def gerar(linguagem: LinguagemDep, id_: str) -> Any:
    try:
        return await linguagem.gerar_pratica(id_)
    except ERROS as e:
        raise _erro(e) from e


class Revisao(BaseModel):
    nota: int = Field(ge=1, le=4)


@router.post("/vocabulario/{id_}/revisar")
def revisar(linguagem: LinguagemDep, id_: str, corpo: Revisao) -> Any:
    try:
        return linguagem.revisar_vocabulario(id_, corpo.nota)
    except ERROS as e:
        raise _erro(e) from e


class Resposta(BaseModel):
    indice: int = Field(ge=0)
    resposta: str = Field(min_length=1, max_length=5000)


@router.post("/vocabulario/{id_}/responder")
async def responder_exercicio(linguagem: LinguagemDep, id_: str, corpo: Resposta) -> Any:
    try:
        return await linguagem.responder_exercicio(id_, corpo.indice, corpo.resposta)
    except ERROS as e:
        raise _erro(e) from e


@router.delete("/vocabulario/{id_}", status_code=204)
def excluir_palavra(linguagem: LinguagemDep, id_: str) -> None:
    try:
        linguagem.vocabulario.excluir(id_)
    except ERROS as e:
        raise _erro(e) from e


@router.get("/escritas")
def escritas(linguagem: LinguagemDep, idioma: str | None = None) -> Any:
    return linguagem.listar_escritas(idioma)


class NovaEscrita(BaseModel):
    idioma: str = IDIOMA
    nivel: str | None = Field(None, pattern="^(A1|A2|B1|B2|C1|C2)$")
    arquivo_id: str | None = None
    titulo_arquivo: str = Field("", max_length=300)
    texto: str = Field("", max_length=20_000)


@router.post("/escritas", status_code=201)
async def criar_escrita(linguagem: LinguagemDep, corpo: NovaEscrita) -> Any:
    try:
        return await linguagem.criar_escrita(corpo.model_dump())
    except ERROS as e:
        raise _erro(e) from e


class RespostaEscrita(BaseModel):
    indice: int = Field(ge=0)
    resposta: str = Field(min_length=1, max_length=20_000)


@router.post("/escritas/{id_}/responder")
async def responder_escrita(linguagem: LinguagemDep, id_: str, corpo: RespostaEscrita) -> Any:
    try:
        return await linguagem.responder_escrita(id_, corpo.indice, corpo.resposta)
    except ERROS as e:
        raise _erro(e) from e


@router.delete("/escritas/{id_}", status_code=204)
def excluir_escrita(linguagem: LinguagemDep, id_: str) -> None:
    try:
        linguagem.escritas.excluir(id_)
    except ERROS as e:
        raise _erro(e) from e


@router.get("/leituras-voz")
def leituras_voz(linguagem: LinguagemDep, idioma: str | None = None) -> Any:
    return linguagem.listar_leituras_voz(idioma)


@router.post("/leituras-voz", status_code=201)
async def avaliar_leitura(
    linguagem: LinguagemDep,
    audio: Annotated[UploadFile, File()],
    idioma: Annotated[str, Form(pattern="^(en|es|fr|pt)$")],
    referencia: Annotated[str, Form(min_length=1, max_length=20_000)],
    arquivo_id: Annotated[str | None, Form()] = None,
    titulo: Annotated[str, Form(max_length=300)] = "",
    pagina: Annotated[int | None, Form(ge=0)] = None,
) -> Any:
    """Gravação da pessoa lendo [referencia] em voz alta → avaliação guardada."""
    dados = await audio.read()
    if len(dados) > 50 * 1024 * 1024:
        raise HTTPException(413, "Gravação grande demais (máx. 50 MB).")
    try:
        return await linguagem.avaliar_leitura(
            dados,
            audio.content_type or "audio/wav",
            idioma,
            referencia,
            {"arquivo_id": arquivo_id, "titulo": titulo, "pagina": pagina},
        )
    except ERROS as e:
        raise _erro(e) from e


@router.delete("/leituras-voz/{id_}", status_code=204)
def excluir_leitura_voz(linguagem: LinguagemDep, id_: str) -> None:
    try:
        linguagem.leituras_voz.excluir(id_)
    except ERROS as e:
        raise _erro(e) from e


class Atividade(BaseModel):
    tipo: str = Field(pattern="^(leitura_guiada|vocabulario|escrita|leitura_voz)$")
    idioma: str = IDIOMA
    minutos: int = Field(ge=0, le=600)
    detalhes: dict[str, int | float | str] = {}


@router.post("/atividades", status_code=201)
def registrar_atividade(linguagem: LinguagemDep, corpo: Atividade) -> Any:
    try:
        return linguagem.registrar_atividade(corpo.model_dump())
    except ERROS as e:
        raise _erro(e) from e


@router.get("/progresso")
def progresso(linguagem: LinguagemDep, idioma: str = "en") -> Any:
    try:
        return linguagem.progresso(idioma)
    except ERROS as e:
        raise _erro(e) from e
