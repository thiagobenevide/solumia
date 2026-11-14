"""Rotas das vagas de emprego (seção Vagas do Empreendimento). A plataforma monta o router em
`/api/vagas` e guarda em `app.state.vagas` o [Vagas]; a pesquisa usa a mesma [IA] dos concursos
(Claude Code pelo worker do PC)."""

from typing import Annotated, Any, Literal

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from concursos.api import AiDep
from concursos.jobs import Slots

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
    await vagas.localizar()
    return vagas.listar()


@router.get("/curriculos")
def resumes(vagas: SlotsDep) -> Any:
    """`{pasta, curriculos: [{id, nome, vaga, em, padrao}]}` (o padrão vem primeiro)."""
    return vagas.curriculos.listar()


@router.post("/curriculos", status_code=201)
def create_resume(corpo: Resume, vagas: SlotsDep) -> Any:
    return vagas.curriculos.salvar(None, corpo.nome, corpo.conteudo)


@router.get("/curriculos/{cid}")
def read_resume(cid: str, vagas: SlotsDep) -> Any:
    c = vagas.curriculos.ler(cid)
    if c is None:
        raise HTTPException(404, "currículo não encontrado")
    return c


@router.put("/curriculos/{cid}")
def save_resume(cid: str, corpo: Resume, vagas: SlotsDep) -> Any:
    if not vagas.curriculos.existe(cid):
        raise HTTPException(404, "currículo não encontrado")
    return vagas.curriculos.salvar(cid, corpo.nome, corpo.conteudo)


@router.post("/curriculos/{cid}/padrao")
def resume_default(cid: str, vagas: SlotsDep) -> Any:
    if not vagas.curriculos.definir_padrao(cid):
        raise HTTPException(404, "currículo não encontrado")
    return vagas.curriculos.listar()


@router.delete("/curriculos/{cid}", status_code=204)
def remove_resume(cid: str, vagas: SlotsDep) -> None:
    if not vagas.curriculos.remover(cid):
        raise HTTPException(404, "currículo não encontrado")


@router.put("/perfil")
def save_profile(corpo: Profile, vagas: SlotsDep) -> Any:
    return vagas.salvar_perfil(corpo.model_dump())


@router.post("/pesquisar", status_code=202)
def search(vagas: SlotsDep, ia: AiDep, tarefas: BackgroundTasks) -> Any:
    """Pesquisa na web pelo Claude Code; o app acompanha por `pesquisando`."""
    reason = ia.disponivel()
    if reason:
        raise HTTPException(503, reason)
    if not vagas.pesquisando:
        tarefas.add_task(vagas.pesquisar_claude, ia.executar)
    return {"pesquisando": True}


@router.post("/{vaga_id}/curriculo", status_code=202)
def generate_resume(vaga_id: str, vagas: SlotsDep, ia: AiDep, tarefas: BackgroundTasks) -> Any:
    """Adapta o currículo padrão à vaga pelo Claude Code; o app acompanha por
    `gerando_curriculo` e `erros_curriculo` da listagem."""
    reason = ia.disponivel()
    if reason:
        raise HTTPException(503, reason)
    if vaga_id not in vagas.gerando:
        vagas.gerando.add(vaga_id)  # já aqui, para dois toques não gerarem duas vezes
        tarefas.add_task(vagas.gerar_curriculo, vaga_id, ia.executar)
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
