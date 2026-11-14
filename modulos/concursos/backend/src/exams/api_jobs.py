"""Routes of the job openings (Jobs section of Empreendimento). The platform mounts the router at
`/api/vagas` and stores the jobs store in `app.state`; the search uses the same AI as the exams
(Claude Code through the PC worker)."""

from typing import Annotated, Any, Literal

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from exams.api import AiDep
from exams.jobs import Slots

router = APIRouter(tags=["vagas"])


def get_slots(request: Request) -> Slots:
    slots: Slots = request.app.state.vagas
    return slots


SlotsDep = Annotated[Slots, Depends(get_slots)]


class Profile(BaseModel):
    areas: list[str] = Field([], max_length=6)
    empresas: list[str] = Field([], max_length=60)
    cargos: str = Field("", max_length=500)
    local: str = Field("", max_length=100)
    modalidades: list[Literal["remoto", "hibrido", "presencial"]] = []
    senioridade: str = Field("", max_length=100)
    observacoes: str = Field("", max_length=2000)


class Mark(BaseModel):
    estado: Literal["nova", "interesse", "candidatei", "descartada"]


class Resume(BaseModel):
    nome: str = Field(..., min_length=1, max_length=200)
    conteudo: str = Field(..., max_length=100_000)


@router.get("")
async def list_all(vagas: SlotsDep) -> Any:
    await vagas.locate()
    return vagas.list_all()


@router.get("/curriculos")
def resumes(vagas: SlotsDep) -> Any:
    """`{pasta, curriculos: [{id, nome, vaga, em, padrao}]}` (the default comes first)."""
    return vagas.resumes.list_all()


@router.post("/curriculos", status_code=201)
def create_resume(corpo: Resume, vagas: SlotsDep) -> Any:
    return vagas.resumes.salvar(None, corpo.nome, corpo.conteudo)


@router.get("/curriculos/{cid}")
def read_resume(cid: str, vagas: SlotsDep) -> Any:
    c = vagas.resumes.ler(cid)
    if c is None:
        raise HTTPException(404, "currículo não encontrado")
    return c


@router.put("/curriculos/{cid}")
def save_resume(cid: str, corpo: Resume, vagas: SlotsDep) -> Any:
    if not vagas.resumes.existe(cid):
        raise HTTPException(404, "currículo não encontrado")
    return vagas.resumes.salvar(cid, corpo.nome, corpo.conteudo)


@router.post("/curriculos/{cid}/padrao")
def resume_default(cid: str, vagas: SlotsDep) -> Any:
    if not vagas.resumes.definir_default(cid):
        raise HTTPException(404, "currículo não encontrado")
    return vagas.resumes.list_all()


@router.delete("/curriculos/{cid}", status_code=204)
def remove_resume(cid: str, vagas: SlotsDep) -> None:
    if not vagas.resumes.remover(cid):
        raise HTTPException(404, "currículo não encontrado")


@router.put("/perfil")
def save_profile(corpo: Profile, vagas: SlotsDep) -> Any:
    return vagas.save_profile(corpo.model_dump())


@router.post("/pesquisar", status_code=202)
def search(vagas: SlotsDep, ia: AiDep, tarefas: BackgroundTasks) -> Any:
    """Web search through Claude Code; the app follows through `pesquisando`."""
    reason = ia.disponivel()
    if reason:
        raise HTTPException(503, reason)
    if not vagas.pesquisando:
        tarefas.add_task(vagas.search_claude, ia.executar)
    return {"pesquisando": True}


@router.post("/{vaga_id}/curriculo", status_code=202)
def generate_resume(vaga_id: str, vagas: SlotsDep, ia: AiDep, tarefas: BackgroundTasks) -> Any:
    """Adapts the default résumé to the opening through Claude Code; the app follows through
    `gerando_curriculo` and `erros_curriculo` of the listing."""
    reason = ia.disponivel()
    if reason:
        raise HTTPException(503, reason)
    if vaga_id not in vagas.generating:
        vagas.generating.add(vaga_id)  # right here, so two taps do not generate twice
        tarefas.add_task(vagas.generate_resume, vaga_id, ia.executar)
    return {"gerando": True}


@router.patch("/{vaga_id}")
def mark(vaga_id: str, corpo: Mark, vagas: SlotsDep) -> Any:
    slot = vagas.marcar(vaga_id, corpo.estado)
    if slot is None:
        raise HTTPException(404, "vaga não encontrada")
    return slot


@router.delete("/{vaga_id}", status_code=204)
def remove(vaga_id: str, vagas: SlotsDep) -> None:
    if not vagas.remover(vaga_id):
        raise HTTPException(404, "vaga não encontrada")
