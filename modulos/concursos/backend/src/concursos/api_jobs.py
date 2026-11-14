"""Rotas das vagas de emprego (seção Vagas do Empreendimento). A plataforma monta o router em
`/api/vagas` e guarda em `app.state.vagas` o [Vagas]; a pesquisa usa a mesma [IA] dos concursos
(Claude Code pelo worker do PC)."""

from typing import Annotated, Any, Literal

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from concursos.api import IADep
from concursos.jobs import Vagas

router = APIRouter(tags=["vagas"])


def get_vagas(request: Request) -> Vagas:
    vagas: Vagas = request.app.state.vagas
    return vagas


VagasDep = Annotated[Vagas, Depends(get_vagas)]


class Perfil(BaseModel):
    areas: list[str] = Field([], max_length=6)
    empresas: list[str] = Field([], max_length=60)
    cargos: str = Field("", max_length=500)
    local: str = Field("", max_length=100)
    modalidades: list[Literal["remoto", "hibrido", "presencial"]] = []
    senioridade: str = Field("", max_length=100)
    observacoes: str = Field("", max_length=2000)


class Marcar(BaseModel):
    estado: Literal["nova", "interesse", "candidatei", "descartada"]


class Curriculo(BaseModel):
    nome: str = Field(..., min_length=1, max_length=200)
    conteudo: str = Field(..., max_length=100_000)


@router.get("")
async def listar(vagas: VagasDep) -> Any:
    await vagas.localizar()
    return vagas.listar()


@router.get("/curriculos")
def curriculos(vagas: VagasDep) -> Any:
    """`{pasta, curriculos: [{id, nome, vaga, em, padrao}]}` (o padrão vem primeiro)."""
    return vagas.curriculos.listar()


@router.post("/curriculos", status_code=201)
def criar_curriculo(corpo: Curriculo, vagas: VagasDep) -> Any:
    return vagas.curriculos.salvar(None, corpo.nome, corpo.conteudo)


@router.get("/curriculos/{cid}")
def ler_curriculo(cid: str, vagas: VagasDep) -> Any:
    c = vagas.curriculos.ler(cid)
    if c is None:
        raise HTTPException(404, "currículo não encontrado")
    return c


@router.put("/curriculos/{cid}")
def salvar_curriculo(cid: str, corpo: Curriculo, vagas: VagasDep) -> Any:
    if not vagas.curriculos.existe(cid):
        raise HTTPException(404, "currículo não encontrado")
    return vagas.curriculos.salvar(cid, corpo.nome, corpo.conteudo)


@router.post("/curriculos/{cid}/padrao")
def curriculo_padrao(cid: str, vagas: VagasDep) -> Any:
    if not vagas.curriculos.definir_padrao(cid):
        raise HTTPException(404, "currículo não encontrado")
    return vagas.curriculos.listar()


@router.delete("/curriculos/{cid}", status_code=204)
def remover_curriculo(cid: str, vagas: VagasDep) -> None:
    if not vagas.curriculos.remover(cid):
        raise HTTPException(404, "currículo não encontrado")


@router.put("/perfil")
def salvar_perfil(corpo: Perfil, vagas: VagasDep) -> Any:
    return vagas.salvar_perfil(corpo.model_dump())


@router.post("/pesquisar", status_code=202)
def pesquisar(vagas: VagasDep, ia: IADep, tarefas: BackgroundTasks) -> Any:
    """Pesquisa na web pelo Claude Code; o app acompanha por `pesquisando`."""
    motivo = ia.disponivel()
    if motivo:
        raise HTTPException(503, motivo)
    if not vagas.pesquisando:
        tarefas.add_task(vagas.pesquisar_claude, ia.executar)
    return {"pesquisando": True}


@router.post("/{vaga_id}/curriculo", status_code=202)
def gerar_curriculo(vaga_id: str, vagas: VagasDep, ia: IADep, tarefas: BackgroundTasks) -> Any:
    """Adapta o currículo padrão à vaga pelo Claude Code; o app acompanha por
    `gerando_curriculo` e `erros_curriculo` da listagem."""
    motivo = ia.disponivel()
    if motivo:
        raise HTTPException(503, motivo)
    if vaga_id not in vagas.gerando:
        vagas.gerando.add(vaga_id)  # já aqui, para dois toques não gerarem duas vezes
        tarefas.add_task(vagas.gerar_curriculo, vaga_id, ia.executar)
    return {"gerando": True}


@router.patch("/{vaga_id}")
def marcar(vaga_id: str, corpo: Marcar, vagas: VagasDep) -> Any:
    vaga = vagas.marcar(vaga_id, corpo.estado)
    if vaga is None:
        raise HTTPException(404, "vaga não encontrada")
    return vaga


@router.delete("/{vaga_id}", status_code=204)
def remover(vaga_id: str, vagas: VagasDep) -> None:
    if not vagas.remover(vaga_id):
        raise HTTPException(404, "vaga não encontrada")
