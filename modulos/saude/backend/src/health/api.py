"""Routes of the Health module. The platform mounts the router at `/api/saude` with authentication
and stores the [Workouts] in `app.state.workouts`."""

import mimetypes
from typing import Annotated, Any

from fastapi import APIRouter, Depends, File, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from health.api_coach import router as coach_router
from health.api_consumption import router as consumo_router
from health.api_sessions import router as sessoes_router
from health.api_watch import router as relogio_router
from health.api_wellbeing import router as bem_estar_router
from health.catalog import AREAS
from health.workouts import Invalid, NotFound, Workouts

router = APIRouter(tags=["saude"])


def get_workouts(request: Request) -> Workouts:
    workouts: Workouts = request.app.state.workouts
    return workouts


WorkoutsDep = Annotated[Workouts, Depends(get_workouts)]


class ExerciseInput(BaseModel):
    nome: str = Field(min_length=1, max_length=120)
    area: str = Field(min_length=1, max_length=60)
    grupo: str = Field("", max_length=60)
    equipamento: str = Field("", max_length=60)
    series: int = Field(3, ge=1, le=50)
    repeticoes: str = Field("10", max_length=30)
    carga_kg: float | None = Field(None, ge=0)
    instrucoes: str = Field("", max_length=4000)


class ExerciseEdit(BaseModel):
    nome: str | None = Field(None, min_length=1, max_length=120)
    area: str | None = Field(None, min_length=1, max_length=60)
    grupo: str | None = Field(None, max_length=60)
    equipamento: str | None = Field(None, max_length=60)
    series: int | None = Field(None, ge=1, le=50)
    repeticoes: str | None = Field(None, max_length=30)
    carga_kg: float | None = Field(None, ge=0)
    instrucoes: str | None = Field(None, max_length=4000)


class ItemInput(BaseModel):
    data: str
    exercicio_id: str
    series: int | None = Field(None, ge=1, le=50)
    repeticoes: str | None = Field(None, max_length=30)
    carga_kg: float | None = Field(None, ge=0)
    observacao: str | None = Field(None, max_length=2000)


class ItemEdit(BaseModel):
    data: str | None = None
    ordem: int | None = Field(None, ge=0)
    series: int | None = Field(None, ge=1, le=50)
    repeticoes: str | None = Field(None, max_length=30)
    carga_kg: float | None = Field(None, ge=0)
    observacao: str | None = Field(None, max_length=2000)
    feito: bool | None = None


class Copy(BaseModel):
    de: str
    ate: str
    destino: str


def _error(e: Exception) -> HTTPException:
    if isinstance(e, NotFound):
        return HTTPException(404, "Não encontrado")
    return HTTPException(422, str(e))


@router.get("/exercicios")
def list_exercises(treinos: WorkoutsDep) -> Any:
    return {"areas": AREAS, "exercicios": treinos.list_exercises()}


@router.post("/exercicios", status_code=201)
def create_exercise(treinos: WorkoutsDep, corpo: ExerciseInput) -> Any:
    return treinos.create_exercise(corpo.model_dump())


@router.patch("/exercicios/{id_}")
def edit_exercise(treinos: WorkoutsDep, id_: str, corpo: ExerciseEdit) -> Any:
    try:
        return treinos.edit_exercise(id_, corpo.model_dump(exclude_unset=True))
    except NotFound as e:
        raise _error(e) from e


@router.delete("/exercicios/{id_}", status_code=204)
def delete_exercise(treinos: WorkoutsDep, id_: str) -> None:
    try:
        treinos.delete_exercise(id_)
    except NotFound as e:
        raise _error(e) from e


@router.get("/exercicios/{id_}/imagem")
def image(treinos: WorkoutsDep, id_: str, n: int = 0) -> FileResponse:
    try:
        path = treinos.imagem(id_, n)
    except NotFound as e:
        raise _error(e) from e
    return FileResponse(path, headers={"Cache-Control": "max-age=86400"})


@router.post("/exercicios/{id_}/imagem")
async def send_image(
    treinos: WorkoutsDep, id_: str, arquivo: Annotated[UploadFile, File()]
) -> Any:
    try:
        # the app sends multipart without a type (octet-stream): the name extension decides
        kind = arquivo.content_type or ""
        if not kind.startswith("image/"):
            kind = mimetypes.guess_type(arquivo.filename or "")[0] or ""
        return treinos.save_image(id_, kind, await arquivo.read())
    except (NotFound, Invalid) as e:
        raise _error(e) from e


@router.delete("/exercicios/{id_}/imagem")
def remove_image(treinos: WorkoutsDep, id_: str) -> Any:
    try:
        return treinos.remove_image(id_)
    except NotFound as e:
        raise _error(e) from e


@router.get("/agenda")
def agenda(treinos: WorkoutsDep, de: str, ate: str) -> Any:
    try:
        return treinos.agenda(de, ate)
    except Invalid as e:
        raise _error(e) from e


@router.post("/agenda", status_code=201)
def mark(treinos: WorkoutsDep, corpo: ItemInput) -> Any:
    try:
        return treinos.marcar(corpo.model_dump())
    except (NotFound, Invalid) as e:
        raise _error(e) from e


@router.patch("/agenda/{id_}")
def edit_item(treinos: WorkoutsDep, id_: str, corpo: ItemEdit) -> Any:
    try:
        return treinos.edit_item(id_, corpo.model_dump(exclude_unset=True))
    except (NotFound, Invalid) as e:
        raise _error(e) from e


@router.delete("/agenda/{id_}", status_code=204)
def unmark(treinos: WorkoutsDep, id_: str) -> None:
    try:
        treinos.unmark(id_)
    except NotFound as e:
        raise _error(e) from e


@router.post("/agenda/copiar", status_code=201)
def copy(treinos: WorkoutsDep, corpo: Copy) -> Any:
    try:
        return treinos.copy(corpo.de, corpo.ate, corpo.destino)
    except Invalid as e:
        raise _error(e) from e


router.include_router(bem_estar_router)
router.include_router(relogio_router)
router.include_router(consumo_router)
router.include_router(sessoes_router)
router.include_router(coach_router)
