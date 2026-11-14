"""Routes of Health › Mental (`/mental`) and Health › Spiritual (`/espiritual`), included in the
Health router. The data lives in subfolders of the Health folder (the workouts one)."""

from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from health.mental import Mental
from health.spiritual import SCOPES, Espiritual
from health.workouts import Invalid, NotFound, Workouts

router = APIRouter()


def get_mental(request: Request) -> Mental:
    state = request.app.state
    if getattr(state, "mental", None) is None:
        workouts: Workouts = state.workouts
        state.mental = Mental(workouts.root / "mental")
    mental: Mental = state.mental
    return mental


def get_espiritual(request: Request) -> Espiritual:
    state = request.app.state
    if getattr(state, "espiritual", None) is None:
        workouts: Workouts = state.workouts
        state.espiritual = Espiritual(workouts.root / "espiritual")
    espiritual: Espiritual = state.espiritual
    return espiritual


MentalDep = Annotated[Mental, Depends(get_mental)]
EspiritualDep = Annotated[Espiritual, Depends(get_espiritual)]


def _error(e: Exception) -> HTTPException:
    if isinstance(e, NotFound):
        return HTTPException(404, "Não encontrado")
    return HTTPException(422, str(e))


# --- mental ---


class HabitInput(BaseModel):
    nome: str = Field(min_length=1, max_length=120)
    tipo: str = "construir"
    dias_semana: list[int] = [1, 2, 3, 4, 5, 6, 7]
    descricao: str = Field("", max_length=1000)


class HabitEdit(BaseModel):
    nome: str | None = Field(None, min_length=1, max_length=120)
    tipo: str | None = None
    dias_semana: list[int] | None = None
    descricao: str | None = Field(None, max_length=1000)
    arquivado: bool | None = None


class Mark(BaseModel):
    data: str
    feito: bool = True


class FocusInput(BaseModel):
    minutos: int = Field(ge=1, le=600)
    tarefa: str = Field("", max_length=300)
    concluida: bool = True
    distracoes: int = Field(0, ge=0, le=1000)
    inicio: str | None = None


class DayInput(BaseModel):
    humor: int | None = Field(None, ge=1, le=5)
    ansiedade: int | None = Field(None, ge=0, le=10)
    gatilhos: str | None = Field(None, max_length=2000)
    o_que_fiz: str | None = Field(None, max_length=2000)
    gratidao: str | None = Field(None, max_length=2000)
    texto: str | None = Field(None, max_length=10000)


@router.get("/mental/habitos")
def habits(mental: MentalDep, de: str, ate: str) -> Any:
    try:
        return mental.habits(de, ate)
    except Invalid as e:
        raise _error(e) from e


@router.post("/mental/habitos", status_code=201)
def create_habit(mental: MentalDep, corpo: HabitInput) -> Any:
    try:
        return mental.create_habit(corpo.model_dump())
    except Invalid as e:
        raise _error(e) from e


@router.patch("/mental/habitos/{id_}")
def edit_habit(mental: MentalDep, id_: str, corpo: HabitEdit) -> Any:
    try:
        return mental.edit_habit(id_, corpo.model_dump(exclude_none=True))
    except (NotFound, Invalid) as e:
        raise _error(e) from e


@router.post("/mental/habitos/{id_}/marcar")
def mark_habit(mental: MentalDep, id_: str, corpo: Mark) -> Any:
    try:
        return mental.mark_habit(id_, corpo.data, corpo.feito)
    except (NotFound, Invalid) as e:
        raise _error(e) from e


@router.delete("/mental/habitos/{id_}", status_code=204)
def delete_habit(mental: MentalDep, id_: str) -> None:
    try:
        mental.delete_habit(id_)
    except NotFound as e:
        raise _error(e) from e


@router.get("/mental/foco")
def focus(mental: MentalDep, de: str, ate: str) -> Any:
    try:
        return mental.focus(de, ate)
    except Invalid as e:
        raise _error(e) from e


@router.post("/mental/foco", status_code=201)
def register_focus(mental: MentalDep, corpo: FocusInput) -> Any:
    try:
        return mental.register_focus(corpo.model_dump())
    except Invalid as e:
        raise _error(e) from e


@router.get("/mental/diario")
def daily(mental: MentalDep, de: str, ate: str) -> Any:
    try:
        return mental.daily(de, ate)
    except Invalid as e:
        raise _error(e) from e


@router.put("/mental/diario/{dia}")
def save_day(mental: MentalDep, dia: str, corpo: DayInput) -> Any:
    try:
        return mental.save_day(dia, corpo.model_dump(exclude_none=True))
    except Invalid as e:
        raise _error(e) from e


# --- espiritual ---


class PlanInput(BaseModel):
    escopo: str
    dias: int = Field(365, ge=1, le=3650)
    inicio: str | None = None
    nome: str | None = Field(None, max_length=120)


@router.get("/espiritual/escopos")
def scopes() -> Any:
    return [{"id": k, "nome": name, "livros": books} for k, (name, books) in SCOPES.items()]


@router.get("/espiritual/planos")
def plans(espiritual: EspiritualDep) -> Any:
    return espiritual.plans()


@router.post("/espiritual/planos", status_code=201)
def create_plan(espiritual: EspiritualDep, corpo: PlanInput) -> Any:
    try:
        return espiritual.create_plan(corpo.model_dump(exclude_none=True))
    except Invalid as e:
        raise _error(e) from e


@router.delete("/espiritual/planos/{id_}", status_code=204)
def delete_plan(espiritual: EspiritualDep, id_: str) -> None:
    try:
        espiritual.delete_plan(id_)
    except NotFound as e:
        raise _error(e) from e


@router.get("/espiritual/planos/{id_}/leituras")
def readings(espiritual: EspiritualDep, id_: str, de: str, ate: str | None = None) -> Any:
    try:
        return espiritual.readings(id_, de, ate or de)
    except (NotFound, Invalid) as e:
        raise _error(e) from e


@router.post("/espiritual/planos/{id_}/marcar")
def mark_reading(espiritual: EspiritualDep, id_: str, corpo: Mark) -> Any:
    try:
        return espiritual.marcar(id_, corpo.data, corpo.feito)
    except (NotFound, Invalid) as e:
        raise _error(e) from e
