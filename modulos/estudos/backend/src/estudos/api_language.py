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

from estudos.studies import Invalid, NotFound
from estudos.language import Unavailable, Language

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/linguagem")

LANGUAGE = Field(pattern="^(en|es|fr|pt)$")


def get_language(request: Request) -> Language:
    language: Language = request.app.state.linguagem
    return language


LanguageDep = Annotated[Language, Depends(get_language)]


def _error(e: Exception) -> HTTPException:
    if isinstance(e, NotFound):
        return HTTPException(404, "Não encontrado")
    if isinstance(e, Unavailable):
        return HTTPException(503, str(e))
    return HTTPException(422, str(e))


ERRORS = (NotFound, Invalid, Unavailable)


class RequestSpeech(BaseModel):
    texto: str = Field(min_length=1, max_length=2000)
    idioma: str = LANGUAGE
    velocidade: float = Field(1.0, ge=0.5, le=2.0)


@router.post("/fala")
async def speech(linguagem: LanguageDep, corpo: RequestSpeech) -> Any:
    """Fala da frase (base64) com o tempo de cada palavra, para a leitura guiada."""
    try:
        return await linguagem.speech(corpo.texto, corpo.idioma, round(corpo.velocidade, 2))
    except ERRORS as e:
        raise _error(e) from e


class RequestTranslation(BaseModel):
    termo: str = Field(min_length=1, max_length=1000)
    frase: str = Field("", max_length=3000)
    idioma: str = LANGUAGE
    destino: str = Field("pt", pattern="^(en|es|fr|pt)$")


@router.post("/traduzir")
async def translate(linguagem: LanguageDep, corpo: RequestTranslation) -> Any:
    try:
        return await linguagem.translate(corpo.termo, corpo.frase, corpo.idioma, corpo.destino)
    except ERRORS as e:
        raise _error(e) from e


@router.get("/vocabulario")
def vocabulary(linguagem: LanguageDep, idioma: str | None = None, devidas: bool = False) -> Any:
    return linguagem.list_vocabulary(idioma, devidas)


class NewWord(BaseModel):
    termo: str = Field(min_length=1, max_length=300)
    idioma: str = LANGUAGE
    contexto: str = Field("", max_length=3000)
    traducao: str = Field("", max_length=500)
    classe: str = Field("", max_length=40)
    ipa: str = Field("", max_length=200)
    arquivo_id: str | None = None
    titulo: str = Field("", max_length=300)
    pagina: int | None = Field(None, ge=0)
    gerar: bool = True
    """Cria as frases e exercícios pela LLM local depois de responder."""


async def _generate_in_background(language: Language, id_: str) -> None:
    try:
        await language.generate_practice(id_)
    except ERRORS as e:  # o erro fica no item (`erro`) e o app oferece gerar de novo
        logger.info("Prática de %s não gerada: %s", id_, e)


@router.post("/vocabulario", status_code=201)
def create_word(linguagem: LanguageDep, corpo: NewWord, tarefas: BackgroundTasks) -> Any:
    try:
        item = linguagem.create_vocabulary(corpo.model_dump())
    except ERRORS as e:
        raise _error(e) from e
    if corpo.gerar and not item.get("exercicios"):
        item = linguagem.vocabulary.edit(item["id"], {"gerando": True})
        tarefas.add_task(_generate_in_background, linguagem, item["id"])
    return item


@router.post("/vocabulario/{id_}/gerar")
async def generate(linguagem: LanguageDep, id_: str) -> Any:
    try:
        return await linguagem.generate_practice(id_)
    except ERRORS as e:
        raise _error(e) from e


class Review(BaseModel):
    nota: int = Field(ge=1, le=4)


@router.post("/vocabulario/{id_}/revisar")
def review(linguagem: LanguageDep, id_: str, corpo: Review) -> Any:
    try:
        return linguagem.review_vocabulary(id_, corpo.nota)
    except ERRORS as e:
        raise _error(e) from e


class Answer(BaseModel):
    indice: int = Field(ge=0)
    resposta: str = Field(min_length=1, max_length=5000)


@router.post("/vocabulario/{id_}/responder")
async def answer_exercise(linguagem: LanguageDep, id_: str, corpo: Answer) -> Any:
    try:
        return await linguagem.answer_exercise(id_, corpo.indice, corpo.resposta)
    except ERRORS as e:
        raise _error(e) from e


@router.delete("/vocabulario/{id_}", status_code=204)
def delete_word(linguagem: LanguageDep, id_: str) -> None:
    try:
        linguagem.vocabulary.excluir(id_)
    except ERRORS as e:
        raise _error(e) from e


@router.get("/escritas")
def writes(linguagem: LanguageDep, idioma: str | None = None) -> Any:
    return linguagem.list_writes(idioma)


class NewWriting(BaseModel):
    idioma: str = LANGUAGE
    nivel: str | None = Field(None, pattern="^(A1|A2|B1|B2|C1|C2)$")
    arquivo_id: str | None = None
    titulo_arquivo: str = Field("", max_length=300)
    texto: str = Field("", max_length=20_000)


@router.post("/escritas", status_code=201)
async def create_writing(linguagem: LanguageDep, corpo: NewWriting) -> Any:
    try:
        return await linguagem.create_writing(corpo.model_dump())
    except ERRORS as e:
        raise _error(e) from e


class AnswerWriting(BaseModel):
    indice: int = Field(ge=0)
    resposta: str = Field(min_length=1, max_length=20_000)


@router.post("/escritas/{id_}/responder")
async def answer_writing(linguagem: LanguageDep, id_: str, corpo: AnswerWriting) -> Any:
    try:
        return await linguagem.answer_writing(id_, corpo.indice, corpo.resposta)
    except ERRORS as e:
        raise _error(e) from e


@router.delete("/escritas/{id_}", status_code=204)
def delete_writing(linguagem: LanguageDep, id_: str) -> None:
    try:
        linguagem.writes.excluir(id_)
    except ERRORS as e:
        raise _error(e) from e


@router.get("/leituras-voz")
def readings_voice(linguagem: LanguageDep, idioma: str | None = None) -> Any:
    return linguagem.list_readings_voice(idioma)


@router.post("/leituras-voz", status_code=201)
async def evaluate_reading(
    linguagem: LanguageDep,
    audio: Annotated[UploadFile, File()],
    idioma: Annotated[str, Form(pattern="^(en|es|fr|pt)$")],
    referencia: Annotated[str, Form(min_length=1, max_length=20_000)],
    arquivo_id: Annotated[str | None, Form()] = None,
    titulo: Annotated[str, Form(max_length=300)] = "",
    pagina: Annotated[int | None, Form(ge=0)] = None,
) -> Any:
    """Gravação da pessoa lendo [referencia] em voz alta → avaliação guardada."""
    data = await audio.read()
    if len(data) > 50 * 1024 * 1024:
        raise HTTPException(413, "Gravação grande demais (máx. 50 MB).")
    try:
        return await linguagem.evaluate_reading(
            data,
            audio.content_type or "audio/wav",
            idioma,
            referencia,
            {"arquivo_id": arquivo_id, "titulo": titulo, "pagina": pagina},
        )
    except ERRORS as e:
        raise _error(e) from e


@router.delete("/leituras-voz/{id_}", status_code=204)
def delete_reading_voice(linguagem: LanguageDep, id_: str) -> None:
    try:
        linguagem.readings_voice.excluir(id_)
    except ERRORS as e:
        raise _error(e) from e


class Activity(BaseModel):
    tipo: str = Field(pattern="^(leitura_guiada|vocabulario|escrita|leitura_voz)$")
    idioma: str = LANGUAGE
    minutos: int = Field(ge=0, le=600)
    detalhes: dict[str, int | float | str] = {}


@router.post("/atividades", status_code=201)
def register_activity(linguagem: LanguageDep, corpo: Activity) -> Any:
    try:
        return linguagem.register_activity(corpo.model_dump())
    except ERRORS as e:
        raise _error(e) from e


@router.get("/progresso")
def progress(linguagem: LanguageDep, idioma: str = "en") -> Any:
    try:
        return linguagem.progress(idioma)
    except ERRORS as e:
        raise _error(e) from e
