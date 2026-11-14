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
from concursos.exams import Exams, Invalid, NotFound
from concursos.study import Invalid as EstudoInvalido
from concursos.radar import Radar
from concursos.rumors import Rumors

logger = logging.getLogger("concursos")
router = APIRouter(tags=["concursos"])

LIMIT_PDF = 40 << 20


@dataclass
class IA:
    executar: Callable[[dict[str, Any]], Awaitable[dict[str, Any]]]
    """Recebe `{prompt, sistema, esquema, limite_s}` e devolve o JSON do esquema."""
    disponivel: Callable[[], str | None]
    """Motivo de não dar para gerar agora (sem worker e sem `claude` aqui), ou None."""


def get_exams(request: Request) -> Exams:
    exams: Exams = request.app.state.concursos
    return exams


def get_ai(request: Request) -> IA:
    ia: IA = request.app.state.concursos_ia
    return ia


def get_radar(request: Request) -> Radar:
    radar: Radar = request.app.state.concursos_radar
    return radar


def get_rumors(request: Request) -> Rumors:
    rumors: Rumors = request.app.state.concursos_rumores
    return rumors


ExamsDep = Annotated[Exams, Depends(get_exams)]
RumorsDep = Annotated[Rumors, Depends(get_rumors)]
RadarDep = Annotated[Radar, Depends(get_radar)]
AiDep = Annotated[IA, Depends(get_ai)]


class ExamInput(BaseModel):
    nome: str = Field(min_length=1, max_length=200)
    cargo: str = Field(min_length=1, max_length=200)
    banca: str = Field("", max_length=100)
    data_prova: str | None = Field(None, pattern=r"^\d{4}-\d{2}-\d{2}$")
    minutos_util: int = Field(120, ge=0, le=960)
    minutos_fds: int = Field(240, ge=0, le=960)
    observacoes: str = Field("", max_length=4000)
    edital_url: str = Field("", max_length=1000)


class ExamEdit(BaseModel):
    nome: str | None = Field(None, min_length=1, max_length=200)
    cargo: str | None = Field(None, min_length=1, max_length=200)
    banca: str | None = Field(None, max_length=100)
    data_prova: str | None = Field(None, pattern=r"^\d{4}-\d{2}-\d{2}$")
    minutos_util: int | None = Field(None, ge=0, le=960)
    minutos_fds: int | None = Field(None, ge=0, le=960)
    observacoes: str | None = Field(None, max_length=4000)


class NoticeLink(BaseModel):
    url: str = Field(pattern=r"^https?://", max_length=1000)


class Marking(BaseModel):
    feito: bool


class DeadlineInput(BaseModel):
    titulo: str = Field(min_length=1, max_length=200)
    data: str = Field(pattern=r"^\d{4}-\d{2}-\d{2}$")
    hora: str = Field("", pattern=r"^(\d{2}:\d{2})?$")
    tipo: str = "outro"
    detalhe: str = Field("", max_length=2000)


def _get(exams: Exams, id_: str) -> dict[str, Any]:
    try:
        return exams.obter(id_)
    except NotFound as e:
        raise HTTPException(404, "Concurso não encontrado") from e


@router.get("")
def list_all(concursos: ExamsDep) -> Any:
    return concursos.list_all()


@router.get("/alertas")
def alerts(concursos: ExamsDep) -> Any:
    return concursos.alerts()


# ---------- radar de concursos de TI ----------


@router.get("/radar")
def radar_list(radar: RadarDep) -> Any:
    return radar.list_all()


@router.post("/radar/atualizar", status_code=202)
def radar_update(radar: RadarDep, tarefas: BackgroundTasks) -> Any:
    """Coleta agora (além da coleta periódica); o app acompanha por `coletando`."""
    if not radar.coletando:
        tarefas.add_task(radar.atualizar)
    return {"coletando": True}


@router.post("/radar/claude", status_code=202)
def radar_claude(radar: RadarDep, ia: AiDep, tarefas: BackgroundTasks) -> Any:
    """Pesquisa na web pelo Claude Code (abertos e previstos); o app acompanha por
    `pesquisando_claude`."""
    reason = ia.disponivel()
    if reason:
        raise HTTPException(503, reason)
    if not radar.pesquisando_claude:
        tarefas.add_task(radar.search_claude, ia.executar)
    return {"pesquisando_claude": True}


@router.get("/rumores")
def rumors_list(rumores: RumorsDep) -> Any:
    return rumores.list_all()


@router.post("/rumores/pesquisar", status_code=202)
def rumors_search(
    rumores: RumorsDep, ia: AiDep, tarefas: BackgroundTasks, dados: dict[str, Any] | None = None
) -> Any:
    """Busca rumores de concursos de TI pelo Claude Code (`{consulta}` opcional) e reverifica os
    acompanhados; o app acompanha por `pesquisando`."""
    reason = ia.disponivel()
    if reason:
        raise HTTPException(503, reason)
    if not rumores.pesquisando:
        tarefas.add_task(rumores.pesquisar, ia.executar, str((dados or {}).get("consulta", "")))
    return {"pesquisando": True}


@router.put("/rumores/{rumor_id}/acompanhar")
def rumors_track(rumor_id: str, dados: dict[str, Any], rumores: RumorsDep) -> Any:
    item = rumores.track(rumor_id, bool(dados.get("acompanhar", True)))
    if item is None:
        raise HTTPException(404, "Rumor não encontrado.")
    return item


@router.get("/radar/{item_id}/rota")
async def radar_route(item_id: str, radar: RadarDep) -> Any:
    route = await radar.route(item_id)
    if route is None:
        raise HTTPException(404, "Sem local de prova conhecido para este concurso.")
    return route


class Track(BaseModel):
    cargo: str = Field(min_length=1, max_length=200)
    minutos_util: int = Field(120, ge=0, le=960)
    minutos_fds: int = Field(240, ge=0, le=960)


@router.post("/radar/{item_id}/acompanhar", status_code=201)
async def radar_track(
    item_id: str,
    pedido: Track,
    radar: RadarDep,
    concursos: ExamsDep,
    ia: AiDep,
    tarefas: BackgroundTasks,
) -> Any:
    """Vira um concurso acompanhado: baixa o edital e já pede o fluxo de estudo ao Claude."""
    item = radar.item(item_id)
    if not item:
        raise HTTPException(404, "Concurso não está no radar.")
    slot = next((v for v in item.get("vagas_ti", []) if v["cargo"] == pedido.cargo), None)
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
                "vaga": slot,
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
    end = item.get("inscricoes_fim")
    if end:
        concursos.add_deadline(
            c["id"], {"titulo": "Fim das inscrições (radar)", "data": end, "tipo": "inscricao"}
        )
    if not item.get("edital_url"):
        return concursos.obter(c["id"])
    try:
        content = await asyncio.to_thread(_download, item["edital_url"])
        concursos.save_notice(
            c["id"], item["edital_url"].rsplit("/", 1)[-1][:120] or "edital.pdf", content
        )
    except (OSError, Invalid) as e:
        logger.warning("Edital do radar %s: %s", item_id, e)
        return concursos.obter(c["id"])
    if ia.disponivel() is None:
        prompt = ai_plan.assemble_prompt(
            concursos.obter(c["id"]), concursos.text_notice(c["id"]), concursos.hoje().isoformat()
        )
        concursos.mark_generation(c["id"], "gerando")
        tarefas.add_task(_generate, concursos, ia, c["id"], prompt)
    return concursos.obter(c["id"])


@router.post("", status_code=201)
def create(entrada: ExamInput, concursos: ExamsDep) -> Any:
    return concursos.obter(concursos.criar(entrada.model_dump())["id"])


@router.get("/{id_}")
def get(id_: str, concursos: ExamsDep) -> Any:
    return _get(concursos, id_)


@router.patch("/{id_}")
def update(id_: str, edicao: ExamEdit, concursos: ExamsDep) -> Any:
    _get(concursos, id_)
    return concursos.atualizar(id_, edicao.model_dump(exclude_unset=True))


@router.delete("/{id_}", status_code=204)
def delete(id_: str, concursos: ExamsDep) -> Response:
    _get(concursos, id_)
    concursos.excluir(id_)
    return Response(status_code=204)


def _save_notice(exams: Exams, id_: str, nome: str, content: bytes) -> Any:
    _get(exams, id_)
    if len(content) > LIMIT_PDF:
        raise HTTPException(413, "PDF maior que 40 MB.")
    try:
        return exams.save_notice(id_, nome, content)
    except Invalid as e:
        raise HTTPException(422, str(e)) from e


@router.post("/{id_}/edital")
async def send_notice(
    id_: str, concursos: ExamsDep, arquivo: Annotated[UploadFile, File()]
) -> Any:
    content = await arquivo.read(LIMIT_PDF + 1)
    return _save_notice(concursos, id_, arquivo.filename or "edital.pdf", content)


def _only_internet(url: str) -> None:
    """Recusa esquema diferente de http(s) e endereço da rede interna: o link (do app ou de um site
    raspado pelo radar) não pode fazer a VPS acessar os serviços dela (SSRF)."""
    parts = urllib.parse.urlsplit(url)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        raise urllib.error.URLError("endereço inválido")
    enderecos = socket.getaddrinfo(parts.hostname, None)
    if any(not ipaddress.ip_address(e[4][0]).is_global for e in enderecos):
        raise urllib.error.URLError("endereço interno não é permitido")


class _RedirectSafe(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[no-untyped-def]
        _only_internet(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _download(url: str) -> bytes:
    _only_internet(url)
    request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (agent concursos)"})
    abridor = urllib.request.build_opener(_RedirectSafe)
    with abridor.open(request, timeout=60) as r:
        data: bytes = r.read(LIMIT_PDF + 1)
        return data


@router.post("/{id_}/edital/link")
async def notice_by_link(id_: str, link: NoticeLink, concursos: ExamsDep) -> Any:
    _get(concursos, id_)
    try:
        content = await asyncio.to_thread(_download, link.url)
    except OSError as e:
        raise HTTPException(502, f"Não foi possível baixar o edital: {e}") from e
    concursos.atualizar(id_, {"edital_url": link.url})
    return _save_notice(concursos, id_, link.url.rsplit("/", 1)[-1] or "edital.pdf", content)


async def _generate(exams: Exams, ia: IA, id_: str, prompt: str) -> None:
    try:
        structure = await ia.executar(
            {
                "prompt": prompt,
                "sistema": ai_plan.SYSTEM,
                "esquema": ai_plan.SCHEMA,
                "limite_s": 840,
            }
        )
        exams.apply_structure(id_, structure)
    except Exception as e:  # o erro fica no concurso para o app mostrar
        logger.exception("Falha ao gerar o plano do concurso %s", id_)
        exams.mark_generation(id_, "erro", str(e) or type(e).__name__)


@router.post("/{id_}/plano", status_code=202)
def generate_plan(id_: str, concursos: ExamsDep, ia: AiDep, tarefas: BackgroundTasks) -> Any:
    """Pede ao Claude a estrutura do edital (leva alguns minutos); o app acompanha pelo GET."""
    c = _get(concursos, id_)
    if c["geracao"]["estado"] == "gerando":
        raise HTTPException(409, "O plano já está sendo gerado.")
    try:
        notice = concursos.text_notice(id_)
    except Invalid as e:
        raise HTTPException(422, str(e)) from e
    reason = ia.disponivel()
    if reason:
        raise HTTPException(503, reason)
    prompt = ai_plan.assemble_prompt(c, notice, concursos.hoje().isoformat())
    concursos.mark_generation(id_, "gerando")
    tarefas.add_task(_generate, concursos, ia, id_, prompt)
    return _get(concursos, id_)


@router.post("/{id_}/replanejar")
def replan(id_: str, concursos: ExamsDep) -> Any:
    """Redistribui o que não foi feito (e o atrasado) de hoje até a prova, sem chamar o Claude."""
    _get(concursos, id_)
    try:
        return concursos.replan(id_)
    except Invalid as e:
        raise HTTPException(422, str(e)) from e


@router.patch("/{id_}/tarefas/{tarefa_id}")
def mark(id_: str, tarefa_id: str, marcacao: Marking, concursos: ExamsDep) -> Any:
    _get(concursos, id_)
    try:
        return concursos.mark_task(id_, tarefa_id, marcacao.feito)
    except NotFound as e:
        raise HTTPException(404, "Tarefa não encontrada") from e


@router.post("/{id_}/prazos", status_code=201)
def add_deadline(id_: str, prazo: DeadlineInput, concursos: ExamsDep) -> Any:
    _get(concursos, id_)
    try:
        return concursos.add_deadline(id_, prazo.model_dump())
    except Invalid as e:
        raise HTTPException(422, str(e)) from e


@router.delete("/{id_}/prazos/{prazo_id}", status_code=204)
def remove_deadline(id_: str, prazo_id: str, concursos: ExamsDep) -> Response:
    _get(concursos, id_)
    try:
        concursos.remove_deadline(id_, prazo_id)
    except NotFound as e:
        raise HTTPException(404, "Prazo não encontrado") from e
    return Response(status_code=204)


# ---------- simulados ----------


class RequestMockExam(BaseModel):
    questoes: int = Field(20, ge=5, le=80)
    disciplina: str = ""


class Answers(BaseModel):
    respostas: list[int | None]
    segundos: int = Field(0, ge=0)


async def _generate_mock_exam(
    exams: Exams, ia: IA, id_: str, sid: str, prompt: str, n: int
) -> None:
    try:
        data = await ia.executar(
            {
                "prompt": prompt,
                "sistema": ai_plan.SYSTEM_MOCK_EXAM,
                "esquema": ai_plan.SCHEMA_MOCK_EXAM,
                "limite_s": min(840, 120 + n * 12),
            }
        )
        exams.study.finish_mock_exam(id_, sid, data)
    except Exception as e:
        logger.exception("Falha ao gerar simulado %s", sid)
        exams.study.failure_mock_exam(id_, sid, str(e) or type(e).__name__)


@router.get("/{id_}/simulados")
def mock_exams(id_: str, concursos: ExamsDep) -> Any:
    _get(concursos, id_)
    return {
        "simulados": concursos.study.mock_exams(id_),
        "desempenho": concursos.study.performance(id_),
    }


@router.post("/{id_}/simulados", status_code=202)
def new_mock_exam(
    id_: str, pedido: RequestMockExam, concursos: ExamsDep, ia: AiDep, tarefas: BackgroundTasks
) -> Any:
    """O Claude cria questões inéditas no estilo da banca (1–4 min); o app acompanha pelo GET."""
    c = _get(concursos, id_)
    reason = ia.disponivel()
    if reason:
        raise HTTPException(503, reason)
    try:
        record, prompt = concursos.study.request_mock_exam(c, pedido.questoes, pedido.disciplina)
    except EstudoInvalido as e:
        raise HTTPException(422, str(e)) from e
    tarefas.add_task(_generate_mock_exam, concursos, ia, id_, record["id"], prompt, pedido.questoes)
    return record


@router.post("/{id_}/simulados/{sid}/respostas")
def answer(id_: str, sid: str, r: Answers, concursos: ExamsDep) -> Any:
    _get(concursos, id_)
    try:
        return concursos.study.answer(id_, sid, r.respostas, r.segundos)
    except KeyError as e:
        raise HTTPException(404, "Simulado não encontrado") from e
    except EstudoInvalido as e:
        raise HTTPException(422, str(e)) from e


@router.delete("/{id_}/simulados/{sid}", status_code=204)
def delete_mock_exam(id_: str, sid: str, concursos: ExamsDep) -> Response:
    _get(concursos, id_)
    concursos.study.delete_mock_exam(id_, sid)
    return Response(status_code=204)


# ---------- materiais ----------


async def _fetch_materials(exams: Exams, request_state: Any, id_: str) -> None:
    try:
        await exams.study.fetch_materials(
            exams.obter(id_),
            request_state.concursos_busca,
            getattr(request_state, "concursos_llm", None),
        )
    except Exception as e:
        logger.exception("Falha ao buscar materiais %s", id_)
        exams.study.mark_materials(id_, "erro", str(e) or type(e).__name__)


@router.get("/{id_}/materiais")
def materials(id_: str, concursos: ExamsDep) -> Any:
    _get(concursos, id_)
    return concursos.study.materials(id_)


@router.post("/{id_}/materiais/buscar", status_code=202)
def fetch_materials(
    id_: str, request: Request, concursos: ExamsDep, tarefas: BackgroundTasks
) -> Any:
    """Provas anteriores da banca, questões, apostilas e vídeos (busca na web + LLM local)."""
    _get(concursos, id_)
    concursos.study.mark_materials(id_, "buscando")
    tarefas.add_task(_fetch_materials, concursos, request.app.state, id_)
    return concursos.study.materials(id_)
