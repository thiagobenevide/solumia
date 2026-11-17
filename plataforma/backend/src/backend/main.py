import asyncio
import base64
import contextlib
import json
import logging
import shutil
import socket
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager
from datetime import date
from pathlib import Path
from typing import Any
from uuid import uuid4

from fastapi import Depends, FastAPI, HTTPException, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from backend import __version__
from backend.api.deps import require_client_api_key, require_totp_recent
from backend.api.health import router as health_router
from backend.api.llm import router as llm_router
from backend.api.updates import router as atualizacoes_router
from backend.api.v1.router import router as v1_router
from backend.api.ws.worker import router as ws_router
from backend.auth.api import Attempts
from backend.auth.api import router as auth_router
from backend.core.config import Settings, get_settings
from backend.core.llm_model import ModelLLM
from backend.core.logging import configure_logging
from backend.core.worker_registry import (
    WorkerDisconnected,
    WorkerRegistry,
    WorkerRespondedWithError,
)
from backend.files.api import router as arquivos_router
from backend.files.library import Collection
from backend.files.mapping import router as mapeamento_router
from backend.files.rewrite import Rewrite, text_of_document
from backend.files.rewrite import router as reescrita_router
from backend.files.wopi import router as wopi_router
from backend.internet import Internet
from backend.middleware.headers import HeadersSecurityMiddleware
from backend.middleware.request_id import RequestIdMiddleware
from backend.notes.api import router as notas_router
from backend.notes.vault import Vault
from coding.api import Executor as ExecutorCodigo
from coding.api import router as codigo_router
from coding.sessions import SessionNotFound, Sessions
from design.ai_wireframe import KINDS as TIPOS_WIREFRAME
from design.api import router as design_router
from design.boards import Frames
from design.images import Images
from design.notebooks import router as cadernos_router
from electronics.api import router as eletronica_router
from electronics.api_simulation import router as eletronica_simulacao_router
from electronics.libraries import Libraries as BibliotecasEletronica
from electronics.projects import Projects
from electronics.simulation import Simulations
from exams.api import IA as ConcursosIA
from exams.api import router as concursos_router
from exams.api_jobs import router as vagas_router
from exams.exams import Exams
from exams.jobs import Slots
from exams.radar import Radar
from exams.rumors import Rumors
from finance.api import router as financas_router
from finance.warehouse import Warehouse
from health.api import router as saude_router
from health.coach import Ai as HealthCoachAi
from health.workouts import Workouts
from panel.api import LLMUnavailable as PainelLLMIndisponivel
from panel.api import Sources, Voice
from panel.api import router as painel_router
from panel.meter import Meter
from panel.nagger import Nagger
from panel.notifier import Notifier
from routines.api import LLMUnavailable
from routines.api import router as rotinas_router
from routines.board import Frame
from shared.claude_code import claude_json, rewrite
from shared.ngspice import run_ngspice
from studies.api import router as estudos_router
from studies.language import Language, extract_json
from studies.studies import Invalid, Studies
from youtube.api import router as youtube_router
from youtube.channels import Youtube

logger = logging.getLogger("gateway")


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    settings: Settings = app.state.settings
    registry: WorkerRegistry = app.state.worker_registry
    logger.info(
        "%s v%s iniciado (environment=%s, debug=%s)",
        settings.app_name,
        __version__,
        settings.environment,
        settings.debug,
    )
    sweeper_task = asyncio.create_task(
        registry.run_staleness_sweeper(
            interval=settings.worker_heartbeat_interval_seconds,
            stale_after=settings.worker_stale_after_seconds,
        )
    )
    tasks = [sweeper_task]
    if settings.painel_ntfy_url:
        notifier = Notifier(
            app.state.nagger,
            app.state.quadro.list_all,
            settings.painel_ntfy_url,
            settings.painel_ntfy_token.get_secret_value(),
            extras=lambda: app.state.concursos.alerts() + app.state.concursos_rumores.alerts(),
        )
        interval = 60 * settings.painel_cobranca_minutos
        tasks.append(asyncio.create_task(notifier.rodar(interval)))
    if settings.concursos_radar_horas > 0:
        radar = app.state.concursos_radar
        tasks.append(asyncio.create_task(radar.rodar(3600 * settings.concursos_radar_horas)))
        # followed rumors: Claude looks for news once a day
        rumors = app.state.concursos_rumores
        tasks.append(asyncio.create_task(rumors.rodar(app.state.concursos_ia.executar, 86400)))
    yield
    for task in tasks:
        task.cancel()
    logger.info("%s finalizado", settings.app_name)


def _chat_llm(
    registry: WorkerRegistry,
    settings: Settings,
    model_llm: ModelLLM,
    origem: str,
    timeout: float | None = None,
    pensar: bool = True,
    max_tokens: int | None = None,
) -> Callable[[list[dict[str, str]]], Awaitable[str]]:
    """Chat function used by the modules: sends the messages to a worker and returns the text.

    The model is the one chosen in the app right now; the origin (the module) blocks switching
    while it answers. think=False turns the model reasoning off (gemma/qwen): voice conversation
    drops from ~19 s to ~2 s.
    """

    async def chat(messages: list[dict[str, str]]) -> str:
        model = model_llm.atual or None
        worker = registry.pick_worker(model)
        if worker is None:
            raise LLMUnavailable("Nenhum worker de LLM conectado. Ligue o Worker no PC.")
        payload: dict[str, object] = {"messages": messages}
        if not pensar:
            payload["chat_template_kwargs"] = {"enable_thinking": False}
        if max_tokens:
            payload["max_tokens"] = max_tokens
        if model:
            payload["model"] = model
        try:
            answer = await registry.send_chat_request(
                worker,
                str(uuid4()),
                payload,
                timeout or settings.chat_request_timeout_seconds,
                origem,
            )
        except TimeoutError as e:
            raise LLMUnavailable("O worker não respondeu a tempo.") from e
        except (WorkerDisconnected, WorkerRespondedWithError) as e:
            raise LLMUnavailable(str(e)) from e
        return str(answer["choices"][0]["message"]["content"]).strip()

    return chat


def _context_health(estado: Any) -> Callable[[date, date], str]:
    """Data of the other modules in the period, for the health analysis to cross with sleep and
    activity."""

    def contexto(de: date, ate: date) -> str:
        d1, d2 = de.isoformat(), ate.isoformat()
        parts: list[str] = []
        with contextlib.suppress(Exception):
            gastos: dict[str, float] = {}
            for t in estado.financas.todos("transacoes"):
                day = str(t.get("data") or "")[:10]
                if d1 <= day <= d2 and (t.get("valor") or 0) < 0:
                    gastos[day] = gastos.get(day, 0) - t["valor"]
            if gastos:
                parts.append("## Gastos por dia (R$)")
                parts += [f"- {d}: {v:.2f}" for d, v in sorted(gastos.items())]
        with contextlib.suppress(Exception):
            parts += ["## Rotinas (quadro de tarefas agora)", estado.quadro.contexto()[:2500]]
        with contextlib.suppress(Exception):
            lendo = estado.studies.list_readings(status="lendo")
            if lendo:
                parts.append("## Estudos: lendo agora")
                parts += [f"- {x['titulo']}" for x in lendo[:10]]
        return "\n".join(parts)

    return contexto


def _llms_panel(
    local: Callable[[list[dict[str, str]]], Awaitable[str]], settings: Settings, meter: Meter
) -> dict[str, Callable[[list[dict[str, str]]], Awaitable[str]]]:
    """Nagger chat providers: only the local worker (Claude only through `claude -p` on the
    worker)."""

    async def via_worker(messages: list[dict[str, str]]) -> str:
        try:
            return await local(messages)
        except LLMUnavailable as e:
            raise PainelLLMIndisponivel(str(e)) from e

    return {"local": via_worker}


def _simulations_electronics(registry: WorkerRegistry, settings: Settings) -> Simulations:
    """SPICE simulation as a worker task (`simular_spice`); without a worker, ngspice on the
    backend."""
    timeout = settings.eletronica_simulacao_timeout_s

    def disponivel() -> str | None:
        local = shutil.which(settings.eletronica_ngspice_bin)
        if registry.pick_worker(None) is None and local is None:
            return (
                "Nenhum worker conectado e o ngspice não está instalado no servidor. "
                "Ligue o Worker no PC (com o ngspice) ou instale o ngspice."
            )
        return None

    async def executar(netlist: str) -> dict[str, object]:
        worker = registry.pick_worker(None)
        if worker is None:
            return await run_ngspice(netlist, timeout, settings.eletronica_ngspice_bin)
        try:
            return await registry.send_chat_request(
                worker,
                str(uuid4()),
                {"task": "simular_spice", "netlist": netlist, "timeout_s": timeout},
                timeout + 15,
                "Eletrônica (simulação)",
            )
        except TimeoutError as e:
            raise RuntimeError("O worker não respondeu a tempo.") from e

    return Simulations(executar, disponivel)


def _rewrite_files(registry: WorkerRegistry) -> Rewrite:
    """Rewrite through Claude Code (worker task `reescrever`, with the PC subscription); without a
    worker, this computer's `claude`. Never the Anthropic API."""

    def disponivel() -> str | None:
        if registry.pick_worker(None) is None and shutil.which("claude") is None:
            return "Nenhum worker conectado. Ligue o Worker no PC (com o Claude Code logado)."
        return None

    async def executar(request: dict[str, object]) -> dict[str, object]:
        worker = registry.pick_worker(None)
        if worker is None:
            return await rewrite(request)
        try:
            return await registry.send_chat_request(
                worker, str(uuid4()), {**request, "task": "reescrever"}, 295, "Arquivos (reescrita)"
            )
        except TimeoutError as e:
            raise RuntimeError("O worker não respondeu a tempo.") from e
        except (WorkerDisconnected, WorkerRespondedWithError) as e:
            raise RuntimeError(str(e)) from e

    async def executar_json(request: dict[str, Any]) -> dict[str, Any]:
        limit = float(request.get("limite_s", 280))
        worker = registry.pick_worker(None)
        if worker is None:
            return await claude_json(
                str(request["prompt"]),
                str(request["sistema"]),
                request["esquema"],
                timeout_s=limit,
                effort=str(request.get("effort") or "high"),
            )
        try:
            return await registry.send_chat_request(
                worker,
                str(uuid4()),
                {**request, "task": "claude_json"},
                limit + 30,
                "Arquivos (tradução)",
            )
        except TimeoutError as e:
            raise RuntimeError("O worker não respondeu a tempo.") from e
        except (WorkerDisconnected, WorkerRespondedWithError) as e:
            raise RuntimeError(str(e)) from e

    return Rewrite(executar, disponivel, executar_json)


def _exams_ai(registry: WorkerRegistry) -> ConcursosIA:
    """Study plan through Claude Code (worker task `claude_json`, PC subscription); without a
    worker, this computer's `claude`. Never the Anthropic API."""

    def disponivel() -> str | None:
        if registry.pick_worker(None) is None and shutil.which("claude") is None:
            return "Nenhum worker conectado. Ligue o Worker no PC (com o Claude Code logado)."
        return None

    async def executar(request: dict[str, Any]) -> dict[str, Any]:
        limit = float(request.get("limite_s", 280))
        worker = registry.pick_worker(None)
        if worker is None:
            return await claude_json(
                str(request["prompt"]),
                str(request["sistema"]),
                request["esquema"],
                timeout_s=limit,
                effort=str(request.get("effort") or "high"),
                tools=str(request.get("ferramentas") or ""),
            )
        try:
            return await registry.send_chat_request(
                worker,
                str(uuid4()),
                {**request, "task": "claude_json"},
                limit + 30,
                "Concursos (plano)",
            )
        except TimeoutError as e:
            raise RuntimeError("O worker não respondeu a tempo.") from e
        except (WorkerDisconnected, WorkerRespondedWithError) as e:
            raise RuntimeError(str(e)) from e

    return ConcursosIA(executar, disponivel)


def _executor_code(registry: WorkerRegistry, sessions: Sessions) -> ExecutorCodigo:
    """`codigo.*` tasks on the PC worker (Claude Code logged in there, inside the repository); the
    steps come back through the `codigo` channel and go into the tab."""

    def ao_evento(dados: dict[str, Any]) -> None:
        dados = dict(dados)
        # Tab deleted while Claude was finishing: the step is discarded.
        with contextlib.suppress(SessionNotFound):
            sessions.adicionar(str(dados.pop("sessao_id", "")), dados)

    registry.ouvintes["codigo"] = ao_evento

    def disponivel() -> str | None:
        if registry.pick_worker(None) is None:
            return "Nenhum worker conectado. Ligue o Worker no PC (com o Claude Code logado)."
        return None

    async def pedir(task: str, payload: dict[str, Any]) -> dict[str, Any]:
        worker = registry.pick_worker(None)
        if worker is None:
            raise RuntimeError(disponivel() or "")
        try:
            return await registry.send_chat_request(
                worker, str(uuid4()), {**payload, "task": task}, 60, "Código"
            )
        except TimeoutError as e:
            raise RuntimeError("O worker não respondeu a tempo.") from e
        except (WorkerDisconnected, WorkerRespondedWithError) as e:
            raise RuntimeError(str(e)) from e

    return ExecutorCodigo(pedir, disponivel)


def _fetch_on_pc(registry: WorkerRegistry) -> Any:
    """Web search through the worker (home IP, which search engines do not block like the VPS one).
    None if there is no worker or it fails: then the VPS tries on its own."""

    async def buscar(query: str) -> dict[str, Any] | None:
        worker = registry.pick_worker(None)
        if worker is None:
            return None
        try:
            r = await registry.send_chat_request(
                worker, str(uuid4()), {"task": "buscar_web", "consulta": query}, 40, "Busca"
            )
        except (TimeoutError, WorkerDisconnected, WorkerRespondedWithError) as e:
            logger.info("Busca pelo PC falhou (%s); tentando pela VPS", e)
            return None
        return r if r.get("resultados") else None

    return buscar


def _actions_modules(estado: Any) -> dict[str, Any]:
    """What the Nagger can create in the other modules through the chat (see `panel.agent`)."""
    from design import flows

    async def caderno(a: dict[str, Any], _llm: Any) -> str:
        c = estado.cadernos_design.criar({"titulo": str(a.get("titulo") or "Caderno")[:200]})
        return f"Caderno criado no Design: {c['titulo']}"

    async def quadro(a: dict[str, Any], _llm: Any) -> str:
        q = estado.quadros_design.criar({"titulo": str(a.get("titulo") or "Quadro")[:200]})
        return f"Quadro criado no Design: {q['titulo']}"

    async def fluxograma(a: dict[str, Any], llm: Any) -> str:
        request = str(a.get("descricao") or a.get("titulo") or "")
        flow = await flows.generate(llm, request)
        title = str(a.get("titulo") or flow.get("titulo") or "Fluxograma")[:200]
        q = estado.quadros_design.criar(
            {"titulo": title, "elementos": flows.elements(flow, uuid4().hex[:8])}
        )
        return f"Fluxograma criado no Design: {q['titulo']} ({len(flow['nos'])} blocos)"

    async def projeto(a: dict[str, Any], _llm: Any) -> str:
        secoes = [str(x)[:200] for x in a.get("secoes") or []][:30]
        p = estado.studies.create_project(
            {
                "nome": str(a.get("nome") or a.get("titulo") or "Projeto")[:200],
                "descricao": str(a.get("descricao") or "")[:4000],
                "secoes": secoes,
            }
        )
        return f"Projeto de estudo criado: {p['nome']}"

    async def leitura(a: dict[str, Any], _llm: Any) -> str:
        data = {
            "titulo": str(a["titulo"])[:300],
            "autor": str(a.get("autor") or "")[:200],
            "area": str(a.get("area") or "Geral")[:60],
            # `tipo` is the action's; the text's comes in `tipo_texto`
            "tipo": a.get("tipo_texto") if a.get("tipo_texto") in ("livro", "artigo") else "livro",
        }
        x = estado.studies.create_reading(data)
        return f"Leitura adicionada em Estudos: {x['titulo']}"

    return {
        "criar_caderno": ('{"tipo": "criar_caderno", "titulo": "..."}', caderno),
        "criar_quadro": ('{"tipo": "criar_quadro", "titulo": "..."}', quadro),
        "criar_fluxograma": (
            '{"tipo": "criar_fluxograma", "titulo": "...", "descricao": "etapas e decisões"}',
            fluxograma,
        ),
        "criar_projeto_estudo": (
            '{"tipo": "criar_projeto_estudo", "nome": "...", "descricao": "...", '
            '"secoes": ["..."]}',
            projeto,
        ),
        "criar_leitura": (
            '{"tipo": "criar_leitura", "titulo": "...", "autor": "...", "area": "Economia", '
            '"tipo_texto": "livro|artigo"}',
            leitura,
        ),
    }


def _voice_panel(registry: WorkerRegistry, settings: Settings) -> Voice:
    """Nagger transcription and speech as worker tasks (`payload.task`)."""

    async def tarefa(payload: dict[str, object]) -> dict[str, object]:
        worker = registry.pick_worker(None)
        if worker is None:
            raise PainelLLMIndisponivel("Nenhum worker conectado para a voz. Ligue o Worker no PC.")
        try:
            return await registry.send_chat_request(
                worker,
                str(uuid4()),
                payload,
                settings.chat_request_timeout_seconds,
                "Painel (voz)",
            )
        except TimeoutError as e:
            raise PainelLLMIndisponivel("O worker não respondeu a tempo.") from e
        except (WorkerDisconnected, WorkerRespondedWithError) as e:
            raise PainelLLMIndisponivel(str(e)) from e

    async def transcrever(audio: bytes, mime: str, language: str) -> str:
        r = await tarefa(
            {
                "task": "transcrever",
                "audio_b64": base64.b64encode(audio).decode(),
                "mime": mime,
                "idioma": language,
            }
        )
        return str(r["texto"])

    async def falar(text: str, span: int | None = None) -> bytes:
        request: dict[str, Any] = {"task": "falar", "texto": text}
        if span is not None:
            request["trecho"] = span
        r = await tarefa(request)
        return base64.b64decode(str(r["audio_b64"]))

    return Voice(transcrever, falar)


def _content_with_images(request: dict[str, Any]) -> Any:
    """Plain prompt, or OpenAI-style parts with the images (`imagens`) for a vision model."""
    images = request.get("imagens") or []
    if not images:
        return str(request["prompt"])
    parts: list[dict[str, Any]] = [{"type": "text", "text": str(request["prompt"])}]
    for image in images:
        url = f"data:{image.get('tipo') or 'image/jpeg'};base64,{image['base64']}"
        parts.append({"type": "image_url", "image_url": {"url": url}})
    return parts


def _health_coach(
    registry: WorkerRegistry, local_chat: Callable[[list[dict[str, str]]], Awaitable[str]]
) -> HealthCoachAi:
    """Health coach (week workout, meal photos): the user chose Claude Code (worker task
    `claude_json`, PC subscription; without a worker, this computer's `claude`), with the local
    LLM as an option. Never the Anthropic API."""
    local = _json_local(local_chat)

    def disponivel(provider: str) -> str | None:
        if registry.pick_worker(None) is not None:
            return None
        if provider == "claude" and shutil.which("claude") is not None:
            return None
        return "Nenhum worker conectado. Ligue o Worker no PC."

    async def executar(request: dict[str, Any], provider: str) -> dict[str, Any]:
        if provider == "local":
            return await local(request)
        limit = float(request.get("limite_s", 280))
        worker = registry.pick_worker(None)
        if worker is None:
            return await claude_json(
                str(request["prompt"]),
                str(request["sistema"]),
                request["esquema"],
                timeout_s=limit,
                effort=str(request.get("effort") or "high"),
                images=request.get("imagens"),
            )
        try:
            return await registry.send_chat_request(
                worker,
                str(uuid4()),
                {**request, "task": "claude_json"},
                limit + 30,
                "Saúde (treinador)",
            )
        except TimeoutError as e:
            raise RuntimeError("O worker não respondeu a tempo.") from e
        except (WorkerDisconnected, WorkerRespondedWithError) as e:
            raise RuntimeError(str(e)) from e

    return HealthCoachAi(executar, disponivel)


def _json_local(
    chat: Callable[[list[dict[str, str]]], Awaitable[str]],
) -> Callable[[dict[str, Any]], Awaitable[dict[str, Any]]]:
    """The same `claude_json` request (prompt, system, schema) through the local LLM: the Files
    reader translation does not go through Claude."""

    async def executar(request: dict[str, Any]) -> dict[str, Any]:
        system = (
            f"{request['sistema']}\n\nRespond ONLY with a valid JSON object in this schema:\n"
            f"{json.dumps(request['esquema'], ensure_ascii=False)}"
        )
        messages: list[dict[str, Any]] = [
            {"role": "system", "content": system},
            {"role": "user", "content": _content_with_images(request)},
        ]
        try:
            answer = await chat(messages)
            try:
                return extract_json(answer)
            except Invalid:
                messages += [
                    {"role": "assistant", "content": answer[:3000]},
                    {"role": "user", "content": "Respond again ONLY with the JSON."},
                ]
                return extract_json(await chat(messages))
        except (LLMUnavailable, Invalid) as e:
            raise RuntimeError(str(e)) from e

    return executar


def _language(app: FastAPI, settings: Settings) -> Language:
    """Studies › Language: local LLM without reasoning (answers in seconds) and the worker voice
    (`falar_marcado`, `avaliar_leitura`). Never Claude."""
    registry: WorkerRegistry = app.state.worker_registry
    local = _chat_llm(registry, settings, app.state.modelo_llm, "Estudos (idiomas)", 600, False)

    async def chat(messages: list[dict[str, str]]) -> str:
        try:
            return await local(messages)
        except LLMUnavailable as e:
            raise RuntimeError(str(e)) from e

    async def tarefa(nome: str, payload: dict[str, Any]) -> dict[str, Any]:
        worker = registry.pick_worker(None)
        if worker is None:
            raise RuntimeError("Nenhum worker conectado para a voz. Ligue o Worker no PC.")
        try:
            return await registry.send_chat_request(
                worker, str(uuid4()), {**payload, "task": nome}, 300, "Estudos (voz)"
            )
        except TimeoutError as e:
            raise RuntimeError("O worker não respondeu a tempo.") from e
        except (WorkerDisconnected, WorkerRespondedWithError) as e:
            raise RuntimeError(str(e)) from e

    return Language(
        settings.estudos_dir,
        chat=chat,
        worker=tarefa,
        texto_do_arquivo=lambda id_: text_of_document(app.state.collection, id_),
        somar_minutos=app.state.studies.add_up_minutes,
    )


def _enable_pc(settings: Settings) -> None:
    """Wake-on-LAN over the internet: magic packet (6×FF + MAC 16×) over UDP to the home DDNS."""
    destination = settings.wol_destino
    if not destination:
        file = Path(settings.wol_ip_arquivo).expanduser()
        destination = file.read_text().strip() if file.is_file() else ""
    if not destination:
        raise RuntimeError("IP de casa desconhecido: ligue o PC uma vez para o worker registrá-lo.")
    package = b"\xff" * 6 + bytes.fromhex(settings.wol_mac.replace(":", "")) * 16
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.sendto(package, (destination, settings.wol_porta))


def _pc_panel(
    registry: WorkerRegistry, settings: Settings
) -> Callable[[dict[str, Any]], Awaitable[dict[str, Any]]]:
    """PC commands (worker task `pc`): open site/program, search, shut down; turning on goes
    through Wake-on-LAN, since with the PC off there is no worker."""

    async def pc(request: dict[str, Any]) -> dict[str, Any]:
        if request.get("acao") == "ligar":
            await asyncio.to_thread(_enable_pc, settings)
            return {"detalhe": "Sinal de ligar enviado; o PC deve ligar em instantes."}
        worker = registry.pick_worker(None)
        if worker is None:
            raise RuntimeError("Nenhum worker conectado: o PC está desligado ou o Worker parado.")
        try:
            return await registry.send_chat_request(
                worker, str(uuid4()), {**request, "task": "pc"}, 30, "Painel (PC)"
            )
        except TimeoutError as e:
            raise RuntimeError("O worker não respondeu a tempo.") from e
        except (WorkerDisconnected, WorkerRespondedWithError) as e:
            raise RuntimeError(str(e)) from e

    return pc


def create_app(settings: Settings | None = None) -> FastAPI:
    """Gateway application factory.

    Takes `settings` explicitly to make testing easier; in production the
    default through `get_settings()` (read from the environment/.env) is enough.
    """
    settings = settings or get_settings()
    configure_logging(settings)

    app = FastAPI(
        title=settings.app_name,
        version=__version__,
        debug=settings.debug,
        lifespan=lifespan,
        # In production the API does not publish the endpoint map.
        docs_url=None if settings.environment == "production" else "/docs",
        redoc_url=None if settings.environment == "production" else "/redoc",
        openapi_url=None if settings.environment == "production" else "/openapi.json",
    )
    app.state.settings = settings
    app.state.worker_registry = WorkerRegistry()
    app.state.tentativas_login = Attempts()
    # session jti → time of the last confirmed Authenticator code (Code module).
    app.state.totp_confirmacoes = {}
    app.state.cofre = Vault(settings.notas_dir)
    app.state.collection = Collection(
        settings.arquivos_dir, settings.soffice_bin, settings.pdftoppm_bin
    )
    app.state.concursos = Exams(settings.concursos_dir)
    app.state.concursos_ia = _exams_ai(app.state.worker_registry)
    app.state.vagas = Slots(settings.concursos_dir)
    app.state.quadro = Frame(settings.rotinas_dir)
    app.state.modelo_llm = ModelLLM(settings.llm_config, settings.rotinas_modelo)
    app.state.rotinas_llm = _chat_llm(
        app.state.worker_registry, settings, app.state.modelo_llm, "Rotinas"
    )
    app.state.quadros_design = Frames(settings.design_dir)
    app.state.wireframes_design = Frames(settings.design_dir, "wireframes", TIPOS_WIREFRAME)
    app.state.cadernos_design = Frames(settings.design_dir, "cadernos")
    app.state.imagens_design = Images(
        settings.design_dir, settings.google_busca_chave, settings.google_busca_cx
    )
    app.state.bibliotecas_eletronica = BibliotecasEletronica(settings.eletronica_dir)
    app.state.projetos_eletronica = Projects(
        settings.eletronica_dir, app.state.bibliotecas_eletronica.obter
    )
    app.state.eletronica_kicad_versao = settings.eletronica_kicad_versao
    app.state.simulacoes_eletronica = _simulations_electronics(app.state.worker_registry, settings)
    app.state.reescrita = _rewrite_files(app.state.worker_registry)
    app.state.reescrita.traducao_json = _json_local(
        _chat_llm(
            app.state.worker_registry,
            settings,
            app.state.modelo_llm,
            "Arquivos (tradução)",
            600,
            pensar=False,
        )
    )
    app.state.sessoes_codigo = Sessions(settings.codigo_dir)
    app.state.executor_codigo = _executor_code(
        app.state.worker_registry, app.state.sessoes_codigo
    )
    app.state.workouts = Workouts(settings.saude_dir, settings.saude_baixar_imagens)
    # health data is personal: the analyses use only the local LLM; the coach (workout and meals)
    # uses Claude Code by the user's choice (`_health_coach`)
    app.state.saude_llm = _chat_llm(
        app.state.worker_registry, settings, app.state.modelo_llm, "Saúde", timeout=600
    )
    app.state.saude_contexto = _context_health(app.state)
    app.state.saude_coach_ia = _health_coach(app.state.worker_registry, app.state.saude_llm)
    app.state.financas = Warehouse(settings.financas_dir)
    app.state.studies = Studies(
        settings.estudos_dir, marcacoes=app.state.collection.markings_of_project
    )
    app.state.linguagem = _language(app, settings)
    app.state.youtube = Youtube(app.state.cofre, settings.youtube_vault)
    app.state.nagger = Nagger(settings.painel_dir, settings.painel_fuso)
    app.state.painel_fontes = Sources(
        tarefas=app.state.quadro.list_all,
        buscar_notas=lambda q: app.state.cofre.list_all(q),
        ler_nota=app.state.cofre.obter,
        criar_nota=app.state.cofre.criar,
        criar_tarefa=app.state.quadro.criar,
        mover_tarefa=app.state.quadro.mover,
    )
    app.state.painel_fontes.modulos = _actions_modules(app.state)
    app.state.medidor = Meter(settings.painel_dir)
    app.state.worker_registry.to_measure = app.state.medidor.registrar
    app.state.painel_workers = app.state.worker_registry.describe
    # Nagger (text and voice): no reasoning and a token cap, to answer in seconds.
    panel_local = _chat_llm(
        app.state.worker_registry,
        settings,
        app.state.modelo_llm,
        "Painel",
        pensar=False,
        # short answers come back (and start being spoken) sooner; actions still fit
        max_tokens=1024,
    )
    app.state.painel_llms = _llms_panel(panel_local, settings, app.state.medidor)
    # A flow from large code can take minutes on the local LLM (the answer goes through a task).
    design_local = _chat_llm(
        app.state.worker_registry, settings, app.state.modelo_llm, "Design", timeout=600
    )
    app.state.design_llms = _llms_panel(design_local, settings, app.state.medidor)
    financas_local = _chat_llm(
        app.state.worker_registry, settings, app.state.modelo_llm, "Finanças", timeout=600
    )
    app.state.financas_llms = _llms_panel(financas_local, settings, app.state.medidor)
    # Scenarios conversation (text/voice): no reasoning, to answer in seconds.
    financas_rapido = _chat_llm(
        app.state.worker_registry, settings, app.state.modelo_llm, "Finanças", pensar=False
    )
    app.state.financas_llms["local_rapido"] = _llms_panel(
        financas_rapido, settings, app.state.medidor
    )["local"]
    # Real-time data (FIPE, currencies, stocks, central bank, search) for the modules' local AI.
    app.state.internet = Internet(buscar_no_pc=_fetch_on_pc(app.state.worker_registry))
    # Exams: local LLM without reasoning extracts radar data and classifies materials
    app.state.concursos_llm = _chat_llm(
        app.state.worker_registry, settings, app.state.modelo_llm, "Concursos", 600, pensar=False
    )
    internet = app.state.internet

    async def concursos_busca(query: str) -> dict[str, Any]:
        return await internet.use("buscar_web", {"consulta": query})

    app.state.concursos_busca = concursos_busca
    app.state.concursos_radar = Radar(
        settings.concursos_dir,
        app.state.concursos_llm,
        (settings.concursos_origem_cidade, settings.concursos_origem_uf),
    )
    app.state.concursos_rumores = Rumors(settings.concursos_dir)
    # the jobs map uses the municipalities (IBGE) already downloaded by the radar
    app.state.vagas.geo = app.state.concursos_radar.geo
    app.state.painel_voz = _voice_panel(app.state.worker_registry, settings)
    app.state.painel_pc = _pc_panel(app.state.worker_registry, settings)

    app.add_middleware(RequestIdMiddleware)
    app.add_middleware(HeadersSecurityMiddleware, hsts=settings.environment == "production")
    # Authentication is by Bearer header, not cookie: no credentials in CORS.
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origin_list,
        allow_credentials=False,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    @app.exception_handler(HTTPException)
    async def http_exception_handler(request: Request, exc: HTTPException) -> JSONResponse:
        detail = exc.detail
        error_body = (
            detail if isinstance(detail, dict) else {"message": str(detail), "type": "error"}
        )
        return JSONResponse(status_code=exc.status_code, content={"error": error_body})

    @app.exception_handler(Exception)
    async def unhandled_exception_handler(request: Request, exc: Exception) -> JSONResponse:
        logger.exception("Erro não tratado em %s %s", request.method, request.url.path)
        return JSONResponse(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            content={"error": {"message": "Internal server error", "type": "internal_error"}},
        )

    app.include_router(health_router)
    app.include_router(atualizacoes_router)
    app.include_router(llm_router)
    app.include_router(auth_router)
    app.include_router(v1_router)
    app.include_router(ws_router)
    app.include_router(notas_router)
    app.include_router(reescrita_router)  # first: /reescrita must not fall into /{id_}
    app.include_router(mapeamento_router)  # reading project document → citations
    app.include_router(arquivos_router)
    app.include_router(wopi_router)
    app.include_router(
        saude_router, prefix="/api/saude", dependencies=[Depends(require_client_api_key)]
    )
    app.include_router(
        estudos_router, prefix="/api/estudos", dependencies=[Depends(require_client_api_key)]
    )
    app.include_router(
        rotinas_router, prefix="/api/rotinas", dependencies=[Depends(require_client_api_key)]
    )
    app.include_router(
        concursos_router, prefix="/api/concursos", dependencies=[Depends(require_client_api_key)]
    )
    app.include_router(
        vagas_router, prefix="/api/vagas", dependencies=[Depends(require_client_api_key)]
    )
    app.include_router(
        financas_router, prefix="/api/financas", dependencies=[Depends(require_client_api_key)]
    )
    app.include_router(
        design_router, prefix="/api/design", dependencies=[Depends(require_client_api_key)]
    )
    app.include_router(
        cadernos_router, prefix="/api/design", dependencies=[Depends(require_client_api_key)]
    )
    app.include_router(
        eletronica_router,
        prefix="/api/eletronica",
        dependencies=[Depends(require_client_api_key)],
    )
    app.include_router(
        eletronica_simulacao_router,
        prefix="/api/eletronica",
        dependencies=[Depends(require_client_api_key)],
    )
    app.include_router(
        codigo_router,
        prefix="/api/codigo",
        # PC commands: besides the token, a recent Authenticator code (see deps).
        dependencies=[Depends(require_client_api_key), Depends(require_totp_recent)],
    )
    app.include_router(
        painel_router, prefix="/api/painel", dependencies=[Depends(require_client_api_key)]
    )
    app.include_router(
        youtube_router, prefix="/api/youtube", dependencies=[Depends(require_client_api_key)]
    )

    return app


app = create_app()


def run() -> None:
    """Entry point used by `python -m backend.main` / the development script."""
    import uvicorn

    settings = get_settings()
    uvicorn.run(
        "backend.main:app",
        host=settings.host,
        port=settings.port,
        reload=settings.debug,
        log_config=None,
    )


if __name__ == "__main__":
    run()
