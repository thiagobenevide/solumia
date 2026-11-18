"""Routes of Health › Coach (`/coach`): profile and equipment, daily weight, meals with photo and
the week's workout built by the AI (Claude or local). The platform puts the [Ai] in
`app.state.saude_coach_ia`."""

import mimetypes
from datetime import date, timedelta
from typing import Annotated, Any

from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from health.coach import PROVIDERS, Ai, Coach, week_end
from health.workouts import Invalid, NotFound, Workouts

router = APIRouter(prefix="/coach")


def get_coach(request: Request) -> Coach:
    state = request.app.state
    if getattr(state, "coach", None) is None:
        workouts: Workouts = state.workouts
        state.coach = Coach(workouts)
    coach: Coach = state.coach
    return coach


CoachDep = Annotated[Coach, Depends(get_coach)]


def _ai(request: Request, coach: Coach, ia: str | None) -> tuple[Ai, str]:
    provider = ia or coach.perfil()["ia"]
    if provider not in PROVIDERS:
        raise HTTPException(400, "IA deve ser 'claude' ou 'local'")
    ai: Ai | None = getattr(request.app.state, "saude_coach_ia", None)
    if ai is None:
        raise HTTPException(503, "IA do treinador indisponível")
    reason = ai.disponivel(provider)
    if reason:
        raise HTTPException(503, reason)
    return ai, provider


async def _run(ai: Ai, request: dict[str, Any], provider: str) -> dict[str, Any]:
    try:
        return await ai.executar(request, provider)
    except Exception as e:  # no worker, timeout, Claude not logged in, invalid JSON
        raise HTTPException(503, str(e)) from e


# --- profile ---


class ProfileInput(BaseModel):
    altura_cm: float | None = Field(None, gt=50, lt=260)
    idade: int | None = Field(None, gt=5, lt=120)
    sexo: str | None = Field(None, pattern="^[MF]$")
    nivel: str | None = Field(None, max_length=40)
    objetivo_principal: str | None = Field(None, max_length=200)
    objetivo_secundario: str | None = Field(None, max_length=200)
    dias_semana: int | None = Field(None, ge=1, le=7)
    minutos_sessao: int | None = Field(None, ge=10, le=240)
    restricoes: str | None = Field(None, max_length=2000)
    observacoes: str | None = Field(None, max_length=4000)
    materiais: list[str] | None = Field(None, max_length=60)
    ia: str | None = None
    meta_kcal: int | None = Field(None, ge=800, le=6000)
    meta_proteina_g: int | None = Field(None, ge=20, le=400)


@router.get("/perfil")
def profile(coach: CoachDep) -> Any:
    return coach.perfil()


@router.patch("/perfil")
def save_profile(dados: ProfileInput, coach: CoachDep) -> Any:
    try:
        return coach.save_profile(dados.model_dump(exclude_unset=True))
    except Invalid as e:
        raise HTTPException(400, str(e)) from e


# --- weight ---


class WeightInput(BaseModel):
    peso_kg: float = Field(gt=20, lt=400)
    gordura_pct: float | None = Field(None, ge=1, le=70)
    cintura_cm: float | None = Field(None, ge=30, le=250)
    observacao: str | None = Field(None, max_length=500)


@router.get("/peso")
def weights(de: str, ate: str, coach: CoachDep) -> Any:
    try:
        return coach.weights(de, ate)
    except Invalid as e:
        raise HTTPException(400, str(e)) from e


@router.put("/peso/{data}")
def save_weight(data: str, dados: WeightInput, coach: CoachDep) -> Any:
    try:
        return coach.save_weight(data, dados.model_dump(exclude_unset=True))
    except Invalid as e:
        raise HTTPException(400, str(e)) from e


@router.delete("/peso/{data}", status_code=204)
def remove_weight(data: str, coach: CoachDep) -> None:
    try:
        coach.remove_weight(data)
    except (Invalid, NotFound) as e:
        raise HTTPException(404, "Registro não encontrado") from e


# --- meals ---


@router.get("/refeicoes")
def meals(de: str, ate: str, coach: CoachDep) -> Any:
    try:
        return coach.meals(de, ate)
    except Invalid as e:
        raise HTTPException(400, str(e)) from e


@router.get("/dia/{data}")
def day_summary(data: str, coach: CoachDep) -> Any:
    try:
        return coach.day_summary(data)
    except Invalid as e:
        raise HTTPException(400, str(e)) from e


@router.post("/refeicoes")
async def add_meal(
    request: Request,
    coach: CoachDep,
    data: Annotated[str | None, Form()] = None,
    hora: Annotated[str, Form(max_length=5)] = "",
    tipo: Annotated[str, Form(max_length=40)] = "",
    descricao: Annotated[str, Form(max_length=2000)] = "",
    ia: Annotated[str | None, Form()] = None,
    analisar: Annotated[bool, Form()] = True,
    foto: Annotated[UploadFile | None, File()] = None,
) -> Any:
    """Stores the meal (photo and/or description); with `analisar`, estimates kcal and macros."""
    content = await foto.read() if foto else None
    tipo_foto = foto.content_type or "" if foto else ""
    dados = {"data": data or date.today().isoformat(), "hora": hora, "tipo": tipo,
             "descricao": descricao}
    try:
        m = coach.add_meal(dados, content, tipo_foto)
    except Invalid as e:
        raise HTTPException(400, str(e)) from e
    if not analisar:
        return m
    return await _analyze_meal(request, coach, m, ia, "")


class MealAnalysis(BaseModel):
    correcao: str = Field("", max_length=2000)
    ia: str | None = None


@router.post("/refeicoes/{id_}/analisar")
async def analyze_meal(
    id_: str, pedido: MealAnalysis, request: Request, coach: CoachDep
) -> Any:
    try:
        m = coach.meal(id_)
    except NotFound as e:
        raise HTTPException(404, "Refeição não encontrada") from e
    return await _analyze_meal(request, coach, m, pedido.ia, pedido.correcao)


async def _analyze_meal(
    request: Request, coach: Coach, m: dict[str, Any], ia: str | None, correcao: str
) -> dict[str, Any]:
    ai, provider = _ai(request, coach, ia)
    analysis = await _run(ai, coach.meal_request(m, correcao), provider)
    analysis["ia"] = provider
    return coach.edit_meal(m["id"], {"analise": analysis})


class MealEdit(BaseModel):
    data: str | None = None
    hora: str | None = Field(None, max_length=5)
    tipo: str | None = Field(None, max_length=40)
    descricao: str | None = Field(None, max_length=2000)


@router.patch("/refeicoes/{id_}")
def edit_meal(id_: str, dados: MealEdit, coach: CoachDep) -> Any:
    try:
        return coach.edit_meal(id_, dados.model_dump(exclude_unset=True))
    except NotFound as e:
        raise HTTPException(404, "Refeição não encontrada") from e
    except Invalid as e:
        raise HTTPException(400, str(e)) from e


@router.delete("/refeicoes/{id_}", status_code=204)
def remove_meal(id_: str, coach: CoachDep) -> None:
    try:
        coach.remove_meal(id_)
    except NotFound as e:
        raise HTTPException(404, "Refeição não encontrada") from e


@router.get("/refeicoes/{id_}/foto")
def meal_photo(id_: str, coach: CoachDep) -> FileResponse:
    try:
        path = coach.photo(id_)
    except NotFound as e:
        raise HTTPException(404, "Sem foto") from e
    return FileResponse(path, media_type=mimetypes.guess_type(path.name)[0] or "image/jpeg")


# --- week plan ---


class PlanRequest(BaseModel):
    inicio: str | None = None
    fim: str | None = None
    # chosen days (e.g. only today, or one Thursday); without them, `inicio`..`fim`
    datas: list[str] | None = Field(None, min_length=1, max_length=14)
    # the user's local date: the server clock (UTC) is already "tomorrow" at night in Brazil
    hoje: str | None = None
    pedido: str = Field("", max_length=4000)
    ia: str | None = None
    substituir: bool = True


@router.get("/planos")
def plans(coach: CoachDep) -> Any:
    return coach.plans()


@router.post("/planos")
async def generate_plan(pedido: PlanRequest, request: Request, coach: CoachDep) -> Any:
    """Builds the workout of the chosen days (default: today to Sunday) and writes it into the
    agenda; the other days stay as they are."""
    try:
        hoje = date.fromisoformat(pedido.hoje) if pedido.hoje else date.today()
        dias = _plan_days(pedido, hoje)
    except ValueError as e:
        raise HTTPException(400, "Data inválida") from e
    if (dias[-1] - dias[0]).days > 13:
        raise HTTPException(400, "Escolha dias dentro de 14 dias")
    ai, provider = _ai(request, coach, pedido.ia)
    plan = await _run(ai, coach.plan_request(dias, pedido.pedido, hoje), provider)
    return coach.apply_plan(plan, dias, pedido.substituir, provider)


def _plan_days(pedido: PlanRequest, hoje: date) -> list[date]:
    if pedido.datas:
        unique = set()
        for d in pedido.datas:
            unique.add(date.fromisoformat(d))
        return sorted(unique)
    inicio = date.fromisoformat(pedido.inicio) if pedido.inicio else hoje
    fim = date.fromisoformat(pedido.fim) if pedido.fim else week_end(inicio)
    if fim < inicio:
        raise ValueError("fim before inicio")
    dias = []
    current = inicio
    while current <= fim:
        dias.append(current)
        current += timedelta(days=1)
    return dias
