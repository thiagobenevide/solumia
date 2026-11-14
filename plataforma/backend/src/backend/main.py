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
from backend.api.updates import router as atualizacoes_router
from backend.api.deps import require_totp_recent, require_client_api_key
from backend.api.health import router as health_router
from backend.api.llm import router as llm_router
from backend.api.v1.router import router as v1_router
from backend.api.ws.worker import router as ws_router
from backend.files.api import router as arquivos_router
from backend.files.library import Collection
from backend.files.mapping import router as mapeamento_router
from backend.files.rewrite import Rewrite, text_of_document
from backend.files.rewrite import router as reescrita_router
from backend.files.wopi import router as wopi_router
from backend.auth.api import Attempts
from backend.auth.api import router as auth_router
from backend.core.config import Settings, get_settings
from backend.core.logging import configure_logging
from backend.core.llm_model import ModelLLM
from backend.core.worker_registry import (
    WorkerDisconnected,
    WorkerRegistry,
    WorkerRespondedWithError,
)
from backend.internet import Internet
from backend.middleware.headers import HeadersSecurityMiddleware
from backend.middleware.request_id import RequestIdMiddleware
from backend.notes.api import router as notas_router
from backend.notes.vault import Vault
from codigo.api import Executor as ExecutorCodigo
from codigo.api import router as codigo_router
from codigo.sessions import SessionNotFound, Sessions
from concursos.api import IA as ConcursosIA
from concursos.api import router as concursos_router
from concursos.api_jobs import router as vagas_router
from concursos.exams import Exams
from concursos.radar import Radar
from concursos.rumors import Rumors
from concursos.jobs import Slots
from design.api import router as design_router
from design.notebooks import router as cadernos_router
from design.images import Images
from design.boards import Frames
from design.ai_wireframe import KINDS as TIPOS_WIREFRAME
from eletronica.api import router as eletronica_router
from eletronica.api_simulation import router as eletronica_simulacao_router
from eletronica.libraries import Libraries as BibliotecasEletronica
from eletronica.projects import Projects
from eletronica.simulation import Simulations
from estudos.api import router as estudos_router
from estudos.studies import Studies, Invalid
from estudos.language import Language, extract_json
from financas.api import router as financas_router
from financas.warehouse import Warehouse
from painel.api import Sources, Voice
from painel.api import LLMUnavailable as PainelLLMIndisponivel
from painel.api import router as painel_router
from painel.nagger import Nagger
from painel.meter import Meter
from painel.notifier import Notifier
from rotinas.api import LLMUnavailable
from rotinas.api import router as rotinas_router
from rotinas.board import Frame
from saude.api import router as saude_router
from saude.workouts import Workouts
from shared.claude_code import claude_json, rewrite
from shared.ngspice import run_ngspice
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
        # rumores acompanhados: o Claude procura novidades 1x por dia
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
    """Função de chat usada pelos módulos: manda as mensagens a um worker e devolve o texto.

    O modelo é o escolhido no app agora; [origem] (o módulo) bloqueia a troca enquanto responde.
    [pensar]=False desliga o raciocínio do modelo (gemma/qwen): a conversa por voz cai de ~19 s
    para ~2 s.
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
    """Dados dos outros módulos no período, para a análise de saúde cruzar com sono e atividade."""

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
    """Provedores do chat do cobrador: só o worker local (Claude só via `claude -p` no worker)."""

    async def via_worker(messages: list[dict[str, str]]) -> str:
        try:
            return await local(messages)
        except LLMUnavailable as e:
            raise PainelLLMIndisponivel(str(e)) from e

    return {"local": via_worker}


def _simulations_electronics(registry: WorkerRegistry, settings: Settings) -> Simulations:
    """Simulação SPICE como tarefa do worker (`simular_spice`); sem worker, ngspice no backend."""
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
    """Reescrita pelo Claude Code (tarefa `reescrever` do worker, com a assinatura do PC); sem
    worker, o `claude` deste computador. Nunca a API da Anthropic."""

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
    """Plano de estudos pelo Claude Code (tarefa `claude_json` do worker, assinatura do PC); sem
    worker, o `claude` deste computador. Nunca a API da Anthropic."""

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
    """Tarefas `codigo.*` no worker do PC (Claude Code logado lá, dentro do repositório); as
    etapas voltam pelo canal `codigo` e entram na aba."""

    def ao_evento(dados: dict[str, Any]) -> None:
        dados = dict(dados)
        # Aba excluída enquanto o Claude terminava: a etapa é descartada.
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
    """Busca na web pelo worker (IP de casa, que os buscadores não barram como o da VPS).
    None se não houver worker ou ele falhar: aí a VPS tenta sozinha."""

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
    """O que o Cobrador consegue criar nos outros módulos pelo chat (ver `painel.agent`)."""
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
            # `tipo` é o da ação; o do texto vem em `tipo_texto`
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
    """Transcrição e fala do cobrador como tarefas do worker (`payload.task`)."""

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


def _json_local(
    chat: Callable[[list[dict[str, str]]], Awaitable[str]],
) -> Callable[[dict[str, Any]], Awaitable[dict[str, Any]]]:
    """O mesmo pedido do `claude_json` (prompt, sistema, esquema) pela LLM local: a tradução do
    leitor dos Arquivos não passa pelo Claude."""

    async def executar(request: dict[str, Any]) -> dict[str, Any]:
        system = (
            f"{request['sistema']}\n\nResponda SOMENTE com um objeto JSON válido neste esquema:\n"
            f"{json.dumps(request['esquema'], ensure_ascii=False)}"
        )
        messages = [
            {"role": "system", "content": system},
            {"role": "user", "content": str(request["prompt"])},
        ]
        try:
            answer = await chat(messages)
            try:
                return extract_json(answer)
            except Invalid:
                messages += [
                    {"role": "assistant", "content": answer[:3000]},
                    {"role": "user", "content": "Responda de novo SOMENTE com o JSON."},
                ]
                return extract_json(await chat(messages))
        except (LLMUnavailable, Invalid) as e:
            raise RuntimeError(str(e)) from e

    return executar


def _language(app: FastAPI, settings: Settings) -> Language:
    """Estudos › Linguagem: LLM local sem raciocínio (respostas em segundos) e a voz do worker
    (`falar_marcado`, `avaliar_leitura`). Nunca o Claude."""
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
    """Wake-on-LAN pela internet: magic packet (6×FF + MAC 16×) em UDP para o DDNS de casa."""
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
    """Comandos no PC (tarefa `pc` do worker): abrir site/programa, pesquisar, desligar; ligar vai
    por Wake-on-LAN, já que com o PC desligado não há worker."""

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
    """Application factory do Gateway.

    Recebe `settings` explicitamente para facilitar testes; em produção o
    padrão via `get_settings()` (lido do ambiente/.env) é suficiente.
    """
    settings = settings or get_settings()
    configure_logging(settings)

    app = FastAPI(
        title=settings.app_name,
        version=__version__,
        debug=settings.debug,
        lifespan=lifespan,
        # Em produção a API não publica o mapa dos endpoints.
        docs_url=None if settings.environment == "production" else "/docs",
        redoc_url=None if settings.environment == "production" else "/redoc",
        openapi_url=None if settings.environment == "production" else "/openapi.json",
    )
    app.state.settings = settings
    app.state.worker_registry = WorkerRegistry()
    app.state.tentativas_login = Attempts()
    # jti da sessão → hora do último código do Authenticator confirmado (módulo Código).
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
    # dados de saúde são pessoais: só a LLM local, nunca o Claude
    app.state.saude_llm = _chat_llm(
        app.state.worker_registry, settings, app.state.modelo_llm, "Saúde", timeout=600
    )
    app.state.saude_contexto = _context_health(app.state)
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
    # Cobrador (texto e voz): sem raciocínio e com teto de tokens, para responder em segundos.
    panel_local = _chat_llm(
        app.state.worker_registry,
        settings,
        app.state.modelo_llm,
        "Painel",
        pensar=False,
        max_tokens=2048,
    )
    app.state.painel_llms = _llms_panel(panel_local, settings, app.state.medidor)
    # Fluxo a partir de código grande pode levar minutos no LLM local (a resposta é por tarefa).
    design_local = _chat_llm(
        app.state.worker_registry, settings, app.state.modelo_llm, "Design", timeout=600
    )
    app.state.design_llms = _llms_panel(design_local, settings, app.state.medidor)
    financas_local = _chat_llm(
        app.state.worker_registry, settings, app.state.modelo_llm, "Finanças", timeout=600
    )
    app.state.financas_llms = _llms_panel(financas_local, settings, app.state.medidor)
    # Conversa dos Cenários (texto/voz): sem raciocínio, para responder em segundos.
    financas_rapido = _chat_llm(
        app.state.worker_registry, settings, app.state.modelo_llm, "Finanças", pensar=False
    )
    app.state.financas_llms["local_rapido"] = _llms_panel(
        financas_rapido, settings, app.state.medidor
    )["local"]
    # Dados em tempo real (FIPE, moedas, ações, BC, busca) para a IA local dos módulos.
    app.state.internet = Internet(buscar_no_pc=_fetch_on_pc(app.state.worker_registry))
    # Concursos: LLM local sem raciocínio extrai dados do radar e classifica materiais
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
    # o mapa das vagas usa os municípios (IBGE) já baixados pelo radar
    app.state.vagas.geo = app.state.concursos_radar.geo
    app.state.painel_voz = _voice_panel(app.state.worker_registry, settings)
    app.state.painel_pc = _pc_panel(app.state.worker_registry, settings)

    app.add_middleware(RequestIdMiddleware)
    app.add_middleware(HeadersSecurityMiddleware, hsts=settings.environment == "production")
    # Autenticação é por cabeçalho Bearer, não por cookie: sem credenciais no CORS.
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
    app.include_router(reescrita_router)  # antes: /reescrita não pode cair em /{id_}
    app.include_router(mapeamento_router)  # documento do projeto de leitura → citações
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
        # Comandos no PC: além do token, um código do Authenticator recente (ver deps).
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
    """Entrypoint usado por `python -m backend.main` / script de desenvolvimento."""
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
