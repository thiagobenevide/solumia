"""Routes of the Studies module. The platform mounts the router at `/api/estudos` with
authentication and stores the studies store in `app.state.studies`. The knowledge graph comes from
`/api/notas/grafo`."""

import unicodedata
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field

from studies.api_language import router as linguagem_router
from studies.knowledge import ItemNonexistent
from studies.languages import LANGUAGES, LEVELS
from studies.projects import KINDS_CONTENT, KINDS_QUOTE, STATUS_USAGE, export_xlsx
from studies.studies import AREAS, STATUS_READING, Invalid, NotFound, Studies

router = APIRouter(tags=["estudos"])
router.include_router(linguagem_router)


def get_studies(request: Request) -> Studies:
    studies: Studies = request.app.state.studies
    return studies


StudiesDep = Annotated[Studies, Depends(get_studies)]


class ReadingInput(BaseModel):
    titulo: str = Field(min_length=1, max_length=300)
    autor: str = Field("", max_length=200)
    tipo: str = Field("livro", pattern="^(livro|artigo)$")
    area: str = Field(min_length=1, max_length=60)
    status: str = "quero ler"
    paginas: int | None = Field(None, ge=1)
    pagina_atual: int = Field(0, ge=0)
    nota_id: str | None = None
    arquivo_id: str | None = None
    tags: list[str] = []
    url: str = Field("", max_length=2000)
    ano: str | None = Field(None, max_length=20)
    referencia: str | None = Field(None, max_length=3000)
    tipo_publicacao: str | None = Field(None, max_length=100)
    veiculo: str | None = Field(None, max_length=300)
    doi: str | None = Field(None, max_length=2000)
    idioma: str | None = Field(None, max_length=40)


class ReadingEdit(BaseModel):
    titulo: str | None = Field(None, min_length=1, max_length=300)
    autor: str | None = Field(None, max_length=200)
    tipo: str | None = Field(None, pattern="^(livro|artigo)$")
    area: str | None = Field(None, min_length=1, max_length=60)
    status: str | None = None
    paginas: int | None = Field(None, ge=1)
    pagina_atual: int | None = Field(None, ge=0)
    nota_id: str | None = None
    arquivo_id: str | None = None
    tags: list[str] | None = None
    url: str | None = Field(None, max_length=2000)
    ano: str | None = Field(None, max_length=20)
    referencia: str | None = Field(None, max_length=3000)
    tipo_publicacao: str | None = Field(None, max_length=100)
    veiculo: str | None = Field(None, max_length=300)
    doi: str | None = Field(None, max_length=2000)
    idioma: str | None = Field(None, max_length=40)


class TrackInput(BaseModel):
    idioma: str
    nivel_inicial: str = "A1"
    nivel_alvo: str = "C2"
    minutos_por_dia: int = Field(45, ge=10, le=600)
    dias_semana: list[int] = [1, 2, 3, 4, 5, 6]
    inicio: str | None = None


class TrackEdit(BaseModel):
    nivel_inicial: str | None = None
    nivel_alvo: str | None = None
    minutos_por_dia: int | None = Field(None, ge=10, le=600)
    dias_semana: list[int] | None = None
    inicio: str | None = None


class Session(BaseModel):
    data: str
    minutos: int = Field(ge=0, le=1440)


def _error(e: Exception) -> HTTPException:
    if isinstance(e, NotFound | ItemNonexistent):
        return HTTPException(404, "Não encontrado")
    return HTTPException(422, str(e))


@router.get("/opcoes")
def read_options() -> Any:
    return {
        "areas": AREAS,
        "status": STATUS_READING,
        "idiomas": LANGUAGES,
        "niveis": LEVELS,
        "tipos_citacao": KINDS_QUOTE,
        "tipos_conteudo": KINDS_CONTENT,
        "status_uso": STATUS_USAGE,
    }


@router.get("/leituras")
def list_readings(estudos: StudiesDep, area: str | None = None, status: str | None = None) -> Any:
    return estudos.list_readings(area, status)


@router.post("/leituras", status_code=201)
def create_reading(estudos: StudiesDep, corpo: ReadingInput) -> Any:
    try:
        return estudos.create_reading(corpo.model_dump())
    except Invalid as e:
        raise _error(e) from e


@router.patch("/leituras/{id_}")
def edit_reading(estudos: StudiesDep, id_: str, corpo: ReadingEdit) -> Any:
    try:
        return estudos.edit_reading(id_, corpo.model_dump(exclude_unset=True))
    except (NotFound, Invalid) as e:
        raise _error(e) from e


@router.delete("/leituras/{id_}", status_code=204)
def delete_reading(estudos: StudiesDep, id_: str) -> None:
    try:
        estudos.readings.excluir(id_)
    except NotFound as e:
        raise _error(e) from e


@router.get("/idiomas")
def list_tracks(estudos: StudiesDep) -> Any:
    return estudos.list_tracks()


@router.post("/idiomas", status_code=201)
def create_track(estudos: StudiesDep, corpo: TrackInput) -> Any:
    try:
        return estudos.create_track(corpo.model_dump(exclude_none=True))
    except Invalid as e:
        raise _error(e) from e


@router.get("/idiomas/{id_}")
def track(estudos: StudiesDep, id_: str) -> Any:
    try:
        return estudos.trilha(id_)
    except NotFound as e:
        raise _error(e) from e


@router.patch("/idiomas/{id_}")
def edit_track(estudos: StudiesDep, id_: str, corpo: TrackEdit) -> Any:
    try:
        return estudos.edit_track(id_, corpo.model_dump(exclude_none=True))
    except (NotFound, Invalid) as e:
        raise _error(e) from e


@router.delete("/idiomas/{id_}", status_code=204)
def delete_track(estudos: StudiesDep, id_: str) -> None:
    try:
        estudos.tracks.excluir(id_)
    except NotFound as e:
        raise _error(e) from e


@router.get("/idiomas/{id_}/cronograma")
def schedule(estudos: StudiesDep, id_: str, de: str, ate: str) -> Any:
    try:
        return estudos.schedule(id_, de, ate)
    except (NotFound, Invalid) as e:
        raise _error(e) from e


@router.post("/idiomas/{id_}/sessoes")
def register_session(estudos: StudiesDep, id_: str, corpo: Session) -> Any:
    try:
        return estudos.register_session(id_, corpo.data, corpo.minutos)
    except (NotFound, Invalid) as e:
        raise _error(e) from e


class BookEdit(BaseModel):
    tenho: bool


class MarkStage(BaseModel):
    leitura: int | None = Field(None, ge=0)
    feita: bool = True
    pratica: bool | None = None
    nota_id: str | None = Field(None, max_length=200)


@router.get("/conhecimento/trilhas")
def tracks_knowledge(estudos: StudiesDep) -> Any:
    return estudos.knowledge.list_tracks()


@router.get("/conhecimento/trilhas/{id_}")
def track_knowledge(estudos: StudiesDep, id_: str, frente: str | None = None) -> Any:
    try:
        return estudos.knowledge.trilha(id_, frente)
    except ItemNonexistent as e:
        raise _error(e) from e


@router.post("/conhecimento/trilhas/{id_}/etapas/{etapa}")
def mark_stage(estudos: StudiesDep, id_: str, etapa: str, corpo: MarkStage) -> Any:
    try:
        return estudos.knowledge.marcar(id_, etapa, corpo.model_dump())
    except ItemNonexistent as e:
        raise _error(e) from e


@router.get("/conhecimento/livros")
def books_knowledge(estudos: StudiesDep) -> Any:
    return estudos.knowledge.livros()


@router.patch("/conhecimento/livros/{id_}")
def edit_book(estudos: StudiesDep, id_: str, corpo: BookEdit) -> Any:
    try:
        return estudos.knowledge.edit_book(id_, corpo.tenho)
    except ItemNonexistent as e:
        raise _error(e) from e


@router.post("/conhecimento/livros/{id_}/leitura")
def link_reading(estudos: StudiesDep, id_: str) -> Any:
    """Links the book to a reading (creates one if missing) to read and highlight in the Readings
    tab."""
    try:
        return estudos.knowledge.link_reading(id_)
    except ItemNonexistent as e:
        raise _error(e) from e


class ProjectInput(BaseModel):
    nome: str = Field(min_length=1, max_length=200)
    descricao: str = Field("", max_length=4000)
    cor: int | None = None
    secoes: list[str] = []


class ProjectEdit(BaseModel):
    nome: str | None = Field(None, min_length=1, max_length=200)
    descricao: str | None = Field(None, max_length=4000)
    cor: int | None = None
    secoes: list[str] | None = None


class Classification(BaseModel):
    secao: str | None = Field(None, max_length=300)
    tipo_citacao: str | None = Field(None, max_length=100)
    tipo_conteudo: str | None = Field(None, max_length=100)
    palavras_chave: str | None = Field(None, max_length=1000)
    status_uso: str | None = Field(None, max_length=40)
    parafrase: str | None = Field(None, max_length=20_000)
    observacoes: str | None = Field(None, max_length=10_000)


@router.get("/projetos")
def list_projects(estudos: StudiesDep) -> Any:
    return estudos.list_projects()


@router.post("/projetos", status_code=201)
def create_project(estudos: StudiesDep, corpo: ProjectInput) -> Any:
    return estudos.create_project(corpo.model_dump(exclude_none=True))


@router.patch("/projetos/{id_}")
def edit_project(estudos: StudiesDep, id_: str, corpo: ProjectEdit) -> Any:
    try:
        return estudos.edit_project(id_, corpo.model_dump(exclude_none=True))
    except NotFound as e:
        raise _error(e) from e


@router.delete("/projetos/{id_}", status_code=204)
def delete_project(estudos: StudiesDep, id_: str) -> None:
    try:
        estudos.projects.excluir(id_)
    except NotFound as e:
        raise _error(e) from e


@router.get("/projetos/{id_}/matriz")
def matrix(estudos: StudiesDep, id_: str) -> Any:
    try:
        return estudos.matrix(id_)
    except NotFound as e:
        raise _error(e) from e


@router.patch("/projetos/{id_}/itens/{item_id}")
def classify(estudos: StudiesDep, id_: str, item_id: str, corpo: Classification) -> Any:
    try:
        return estudos.classify(id_, item_id, corpo.model_dump(exclude_none=True))
    except NotFound as e:
        raise _error(e) from e


@router.get("/projetos/{id_}/exportar")
def export(estudos: StudiesDep, id_: str) -> Response:
    try:
        m = estudos.matrix(id_)
    except NotFound as e:
        raise _error(e) from e
    plain_ = unicodedata.normalize("NFKD", m["projeto"]["nome"]).encode("ascii", "ignore").decode()
    name = "".join(c for c in plain_ if c.isalnum() or c in " -_").strip() or "projeto"
    return Response(
        export_xlsx(m),
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers={"Content-Disposition": f'attachment; filename="Matriz - {name}.xlsx"'},
    )
