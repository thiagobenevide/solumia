"""Rotas do módulo Concursos. A plataforma monta o router em `/api/concursos` com a autenticação e
guarda em `app.state.concursos` o [Concursos] e em `app.state.concursos_ia` a [IA] (Claude Code
pelo worker do PC, tarefa `claude_json`; nunca a API da Anthropic).

Fluxo: criar concurso → enviar o edital (PDF ou link) → `POST /{id}/plano` (o Claude lê o edital em
segundo plano; o app consulta `geracao.estado`) → tarefas diárias até a prova, prazos e alertas."""

import asyncio
import ipaddress
import logging
import socket
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Annotated, Any

from fastapi import (
    APIRouter,
    BackgroundTasks,
    Depends,
    File,
    HTTPException,
    Request,
    Response,
    UploadFile,
)
from pydantic import BaseModel, Field

from concursos import ai_plan
from concursos.exams import Concursos, Invalido, NaoEncontrado
from concursos.study import Invalido as EstudoInvalido
from concursos.radar import Radar
from concursos.rumors import Rumores

logger = logging.getLogger("concursos")
router = APIRouter(tags=["concursos"])

LIMITE_PDF = 40 << 20


@dataclass
class IA:
    executar: Callable[[dict[str, Any]], Awaitable[dict[str, Any]]]
    """Recebe `{prompt, sistema, esquema, limite_s}` e devolve o JSON do esquema."""
    disponivel: Callable[[], str | None]
    """Motivo de não dar para gerar agora (sem worker e sem `claude` aqui), ou None."""


def get_concursos(request: Request) -> Concursos:
    concursos: Concursos = request.app.state.concursos
    return concursos


def get_ia(request: Request) -> IA:
    ia: IA = request.app.state.concursos_ia
    return ia


def get_radar(request: Request) -> Radar:
    radar: Radar = request.app.state.concursos_radar
    return radar


def get_rumores(request: Request) -> Rumores:
    rumores: Rumores = request.app.state.concursos_rumores
    return rumores


ConcursosDep = Annotated[Concursos, Depends(get_concursos)]
RumoresDep = Annotated[Rumores, Depends(get_rumores)]
RadarDep = Annotated[Radar, Depends(get_radar)]
IADep = Annotated[IA, Depends(get_ia)]


class ConcursoEntrada(BaseModel):
    nome: str = Field(min_length=1, max_length=200)
    cargo: str = Field(min_length=1, max_length=200)
    banca: str = Field("", max_length=100)
    data_prova: str | None = Field(None, pattern=r"^\d{4}-\d{2}-\d{2}$")
    minutos_util: int = Field(120, ge=0, le=960)
    minutos_fds: int = Field(240, ge=0, le=960)
    observacoes: str = Field("", max_length=4000)
    edital_url: str = Field("", max_length=1000)


class ConcursoEdicao(BaseModel):
    nome: str | None = Field(None, min_length=1, max_length=200)
    cargo: str | None = Field(None, min_length=1, max_length=200)
    banca: str | None = Field(None, max_length=100)
    data_prova: str | None = Field(None, pattern=r"^\d{4}-\d{2}-\d{2}$")
    minutos_util: int | None = Field(None, ge=0, le=960)
    minutos_fds: int | None = Field(None, ge=0, le=960)
    observacoes: str | None = Field(None, max_length=4000)


class EditalLink(BaseModel):
    url: str = Field(pattern=r"^https?://", max_length=1000)


class Marcacao(BaseModel):
    feito: bool


class PrazoEntrada(BaseModel):
    titulo: str = Field(min_length=1, max_length=200)
    data: str = Field(pattern=r"^\d{4}-\d{2}-\d{2}$")
    hora: str = Field("", pattern=r"^(\d{2}:\d{2})?$")
    tipo: str = "outro"
    detalhe: str = Field("", max_length=2000)


def _obter(concursos: Concursos, id_: str) -> dict[str, Any]:
    try:
        return concursos.obter(id_)
    except NaoEncontrado as e:
        raise HTTPException(404, "Concurso não encontrado") from e


@router.get("")
def listar(concursos: ConcursosDep) -> Any:
    return concursos.listar()


@router.get("/alertas")
def alertas(concursos: ConcursosDep) -> Any:
    return concursos.alertas()


# ---------- radar de concursos de TI ----------


@router.get("/radar")
def radar_listar(radar: RadarDep) -> Any:
    return radar.listar()


@router.post("/radar/atualizar", status_code=202)
def radar_atualizar(radar: RadarDep, tarefas: BackgroundTasks) -> Any:
    """Coleta agora (além da coleta periódica); o app acompanha por `coletando`."""
    if not radar.coletando:
        tarefas.add_task(radar.atualizar)
    return {"coletando": True}


@router.post("/radar/claude", status_code=202)
def radar_claude(radar: RadarDep, ia: IADep, tarefas: BackgroundTasks) -> Any:
    """Pesquisa na web pelo Claude Code (abertos e previstos); o app acompanha por
    `pesquisando_claude`."""
    motivo = ia.disponivel()
    if motivo:
        raise HTTPException(503, motivo)
    if not radar.pesquisando_claude:
        tarefas.add_task(radar.pesquisar_claude, ia.executar)
    return {"pesquisando_claude": True}


@router.get("/rumores")
def rumores_listar(rumores: RumoresDep) -> Any:
    return rumores.listar()


@router.post("/rumores/pesquisar", status_code=202)
def rumores_pesquisar(
    rumores: RumoresDep, ia: IADep, tarefas: BackgroundTasks, dados: dict[str, Any] | None = None
) -> Any:
    """Busca rumores de concursos de TI pelo Claude Code (`{consulta}` opcional) e reverifica os
    acompanhados; o app acompanha por `pesquisando`."""
    motivo = ia.disponivel()
    if motivo:
        raise HTTPException(503, motivo)
    if not rumores.pesquisando:
        tarefas.add_task(rumores.pesquisar, ia.executar, str((dados or {}).get("consulta", "")))
    return {"pesquisando": True}


@router.put("/rumores/{rumor_id}/acompanhar")
def rumores_acompanhar(rumor_id: str, dados: dict[str, Any], rumores: RumoresDep) -> Any:
    item = rumores.acompanhar(rumor_id, bool(dados.get("acompanhar", True)))
    if item is None:
        raise HTTPException(404, "Rumor não encontrado.")
    return item


@router.get("/radar/{item_id}/rota")
async def radar_rota(item_id: str, radar: RadarDep) -> Any:
    rota = await radar.rota(item_id)
    if rota is None:
        raise HTTPException(404, "Sem local de prova conhecido para este concurso.")
    return rota


class Acompanhar(BaseModel):
    cargo: str = Field(min_length=1, max_length=200)
    minutos_util: int = Field(120, ge=0, le=960)
    minutos_fds: int = Field(240, ge=0, le=960)


@router.post("/radar/{item_id}/acompanhar", status_code=201)
async def radar_acompanhar(
    item_id: str,
    pedido: Acompanhar,
    radar: RadarDep,
    concursos: ConcursosDep,
    ia: IADep,
    tarefas: BackgroundTasks,
) -> Any:
    """Vira um concurso acompanhado: baixa o edital e já pede o fluxo de estudo ao Claude."""
    item = radar.item(item_id)
    if not item:
        raise HTTPException(404, "Concurso não está no radar.")
    vaga = next((v for v in item.get("vagas_ti", []) if v["cargo"] == pedido.cargo), None)
    c = concursos.criar(
        {
            "nome": item["orgao"],
            "banca": item.get("banca", ""),
            "cargo": pedido.cargo,
            "data_prova": item.get("data_prova") or None,
            "minutos_util": pedido.minutos_util,
            "minutos_fds": pedido.minutos_fds,
            "edital_url": item.get("edital_url", ""),
            "radar": {
                "id": item_id,
                "url": item["url"],
                "vaga": vaga,
                "inscricoes_inicio": item.get("inscricoes_inicio"),
                "inscricoes_fim": item.get("inscricoes_fim"),
                "horario_prova": item.get("horario_prova"),
                "link_inscricao": item.get("link_inscricao"),
                "taxa": item.get("taxa"),
                "mais_proximo": item.get("mais_proximo"),
                "provas_url": item.get("provas_url"),
                "sede": item.get("sede"),
            },
        }
    )
    fim = item.get("inscricoes_fim")
    if fim:
        concursos.adicionar_prazo(
            c["id"], {"titulo": "Fim das inscrições (radar)", "data": fim, "tipo": "inscricao"}
        )
    if not item.get("edital_url"):
        return concursos.obter(c["id"])
    try:
        conteudo = await asyncio.to_thread(_baixar, item["edital_url"])
        concursos.salvar_edital(
            c["id"], item["edital_url"].rsplit("/", 1)[-1][:120] or "edital.pdf", conteudo
        )
    except (OSError, Invalido) as e:
        logger.warning("Edital do radar %s: %s", item_id, e)
        return concursos.obter(c["id"])
    if ia.disponivel() is None:
        prompt = ai_plan.montar_prompt(
            concursos.obter(c["id"]), concursos.texto_edital(c["id"]), concursos.hoje().isoformat()
        )
        concursos.marcar_geracao(c["id"], "gerando")
        tarefas.add_task(_gerar, concursos, ia, c["id"], prompt)
    return concursos.obter(c["id"])


@router.post("", status_code=201)
def criar(entrada: ConcursoEntrada, concursos: ConcursosDep) -> Any:
    return concursos.obter(concursos.criar(entrada.model_dump())["id"])


@router.get("/{id_}")
def obter(id_: str, concursos: ConcursosDep) -> Any:
    return _obter(concursos, id_)


@router.patch("/{id_}")
def atualizar(id_: str, edicao: ConcursoEdicao, concursos: ConcursosDep) -> Any:
    _obter(concursos, id_)
    return concursos.atualizar(id_, edicao.model_dump(exclude_unset=True))


@router.delete("/{id_}", status_code=204)
def excluir(id_: str, concursos: ConcursosDep) -> Response:
    _obter(concursos, id_)
    concursos.excluir(id_)
    return Response(status_code=204)


def _salvar_edital(concursos: Concursos, id_: str, nome: str, conteudo: bytes) -> Any:
    _obter(concursos, id_)
    if len(conteudo) > LIMITE_PDF:
        raise HTTPException(413, "PDF maior que 40 MB.")
    try:
        return concursos.salvar_edital(id_, nome, conteudo)
    except Invalido as e:
        raise HTTPException(422, str(e)) from e


@router.post("/{id_}/edital")
async def enviar_edital(
    id_: str, concursos: ConcursosDep, arquivo: Annotated[UploadFile, File()]
) -> Any:
    conteudo = await arquivo.read(LIMITE_PDF + 1)
    return _salvar_edital(concursos, id_, arquivo.filename or "edital.pdf", conteudo)


def _so_internet(url: str) -> None:
    """Recusa esquema diferente de http(s) e endereço da rede interna: o link (do app ou de um site
    raspado pelo radar) não pode fazer a VPS acessar os serviços dela (SSRF)."""
    partes = urllib.parse.urlsplit(url)
    if partes.scheme not in ("http", "https") or not partes.hostname:
        raise urllib.error.URLError("endereço inválido")
    enderecos = socket.getaddrinfo(partes.hostname, None)
    if any(not ipaddress.ip_address(e[4][0]).is_global for e in enderecos):
        raise urllib.error.URLError("endereço interno não é permitido")


class _RedirecionamentoSeguro(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[no-untyped-def]
        _so_internet(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _baixar(url: str) -> bytes:
    _so_internet(url)
    pedido = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (agent concursos)"})
    abridor = urllib.request.build_opener(_RedirecionamentoSeguro)
    with abridor.open(pedido, timeout=60) as r:
        dados: bytes = r.read(LIMITE_PDF + 1)
        return dados


@router.post("/{id_}/edital/link")
async def edital_por_link(id_: str, link: EditalLink, concursos: ConcursosDep) -> Any:
    _obter(concursos, id_)
    try:
        conteudo = await asyncio.to_thread(_baixar, link.url)
    except OSError as e:
        raise HTTPException(502, f"Não foi possível baixar o edital: {e}") from e
    concursos.atualizar(id_, {"edital_url": link.url})
    return _salvar_edital(concursos, id_, link.url.rsplit("/", 1)[-1] or "edital.pdf", conteudo)


async def _gerar(concursos: Concursos, ia: IA, id_: str, prompt: str) -> None:
    try:
        estrutura = await ia.executar(
            {
                "prompt": prompt,
                "sistema": ai_plan.SISTEMA,
                "esquema": ai_plan.ESQUEMA,
                "limite_s": 840,
            }
        )
        concursos.aplicar_estrutura(id_, estrutura)
    except Exception as e:  # o erro fica no concurso para o app mostrar
        logger.exception("Falha ao gerar o plano do concurso %s", id_)
        concursos.marcar_geracao(id_, "erro", str(e) or type(e).__name__)


@router.post("/{id_}/plano", status_code=202)
def gerar_plano(id_: str, concursos: ConcursosDep, ia: IADep, tarefas: BackgroundTasks) -> Any:
    """Pede ao Claude a estrutura do edital (leva alguns minutos); o app acompanha pelo GET."""
    c = _obter(concursos, id_)
    if c["geracao"]["estado"] == "gerando":
        raise HTTPException(409, "O plano já está sendo gerado.")
    try:
        edital = concursos.texto_edital(id_)
    except Invalido as e:
        raise HTTPException(422, str(e)) from e
    motivo = ia.disponivel()
    if motivo:
        raise HTTPException(503, motivo)
    prompt = ai_plan.montar_prompt(c, edital, concursos.hoje().isoformat())
    concursos.marcar_geracao(id_, "gerando")
    tarefas.add_task(_gerar, concursos, ia, id_, prompt)
    return _obter(concursos, id_)


@router.post("/{id_}/replanejar")
def replanejar(id_: str, concursos: ConcursosDep) -> Any:
    """Redistribui o que não foi feito (e o atrasado) de hoje até a prova, sem chamar o Claude."""
    _obter(concursos, id_)
    try:
        return concursos.replanejar(id_)
    except Invalido as e:
        raise HTTPException(422, str(e)) from e


@router.patch("/{id_}/tarefas/{tarefa_id}")
def marcar(id_: str, tarefa_id: str, marcacao: Marcacao, concursos: ConcursosDep) -> Any:
    _obter(concursos, id_)
    try:
        return concursos.marcar_tarefa(id_, tarefa_id, marcacao.feito)
    except NaoEncontrado as e:
        raise HTTPException(404, "Tarefa não encontrada") from e


@router.post("/{id_}/prazos", status_code=201)
def adicionar_prazo(id_: str, prazo: PrazoEntrada, concursos: ConcursosDep) -> Any:
    _obter(concursos, id_)
    try:
        return concursos.adicionar_prazo(id_, prazo.model_dump())
    except Invalido as e:
        raise HTTPException(422, str(e)) from e


@router.delete("/{id_}/prazos/{prazo_id}", status_code=204)
def remover_prazo(id_: str, prazo_id: str, concursos: ConcursosDep) -> Response:
    _obter(concursos, id_)
    try:
        concursos.remover_prazo(id_, prazo_id)
    except NaoEncontrado as e:
        raise HTTPException(404, "Prazo não encontrado") from e
    return Response(status_code=204)


# ---------- simulados ----------


class PedidoSimulado(BaseModel):
    questoes: int = Field(20, ge=5, le=80)
    disciplina: str = ""


class Respostas(BaseModel):
    respostas: list[int | None]
    segundos: int = Field(0, ge=0)


async def _gerar_simulado(
    concursos: Concursos, ia: IA, id_: str, sid: str, prompt: str, n: int
) -> None:
    try:
        dados = await ia.executar(
            {
                "prompt": prompt,
                "sistema": ai_plan.SISTEMA_SIMULADO,
                "esquema": ai_plan.ESQUEMA_SIMULADO,
                "limite_s": min(840, 120 + n * 12),
            }
        )
        concursos.estudo.concluir_simulado(id_, sid, dados)
    except Exception as e:
        logger.exception("Falha ao gerar simulado %s", sid)
        concursos.estudo.falha_simulado(id_, sid, str(e) or type(e).__name__)


@router.get("/{id_}/simulados")
def simulados(id_: str, concursos: ConcursosDep) -> Any:
    _obter(concursos, id_)
    return {
        "simulados": concursos.estudo.simulados(id_),
        "desempenho": concursos.estudo.desempenho(id_),
    }


@router.post("/{id_}/simulados", status_code=202)
def novo_simulado(
    id_: str, pedido: PedidoSimulado, concursos: ConcursosDep, ia: IADep, tarefas: BackgroundTasks
) -> Any:
    """O Claude cria questões inéditas no estilo da banca (1–4 min); o app acompanha pelo GET."""
    c = _obter(concursos, id_)
    motivo = ia.disponivel()
    if motivo:
        raise HTTPException(503, motivo)
    try:
        registro, prompt = concursos.estudo.pedido_simulado(c, pedido.questoes, pedido.disciplina)
    except EstudoInvalido as e:
        raise HTTPException(422, str(e)) from e
    tarefas.add_task(_gerar_simulado, concursos, ia, id_, registro["id"], prompt, pedido.questoes)
    return registro


@router.post("/{id_}/simulados/{sid}/respostas")
def responder(id_: str, sid: str, r: Respostas, concursos: ConcursosDep) -> Any:
    _obter(concursos, id_)
    try:
        return concursos.estudo.responder(id_, sid, r.respostas, r.segundos)
    except KeyError as e:
        raise HTTPException(404, "Simulado não encontrado") from e
    except EstudoInvalido as e:
        raise HTTPException(422, str(e)) from e


@router.delete("/{id_}/simulados/{sid}", status_code=204)
def excluir_simulado(id_: str, sid: str, concursos: ConcursosDep) -> Response:
    _obter(concursos, id_)
    concursos.estudo.excluir_simulado(id_, sid)
    return Response(status_code=204)


# ---------- materiais ----------


async def _buscar_materiais(concursos: Concursos, request_state: Any, id_: str) -> None:
    try:
        await concursos.estudo.buscar_materiais(
            concursos.obter(id_),
            request_state.concursos_busca,
            getattr(request_state, "concursos_llm", None),
        )
    except Exception as e:
        logger.exception("Falha ao buscar materiais %s", id_)
        concursos.estudo.marcar_materiais(id_, "erro", str(e) or type(e).__name__)


@router.get("/{id_}/materiais")
def materiais(id_: str, concursos: ConcursosDep) -> Any:
    _obter(concursos, id_)
    return concursos.estudo.materiais(id_)


@router.post("/{id_}/materiais/buscar", status_code=202)
def buscar_materiais(
    id_: str, request: Request, concursos: ConcursosDep, tarefas: BackgroundTasks
) -> Any:
    """Provas anteriores da banca, questões, apostilas e vídeos (busca na web + LLM local)."""
    _obter(concursos, id_)
    concursos.estudo.marcar_materiais(id_, "buscando")
    tarefas.add_task(_buscar_materiais, concursos, request.app.state, id_)
    return concursos.estudo.materiais(id_)
