import asyncio
import json
import logging

import httpx
import websockets
from pydantic import ValidationError

from shared import web_search
from shared.claude_code import claude_json, rewrite
from shared.ngspice import run_ngspice
from shared.protocol import (
    ChatRequest,
    ChatResponse,
    Heartbeat,
    ProtocolError,
    WorkerEvent,
    WorkerHello,
    WorkerHelloAck,
    parse_gateway_message,
)
from worker import pc, resources
from worker.claude_accounts import TASKS as TAREFAS_CONTAS
from worker.claude_accounts import Accounts
from worker.coding import TASKS as TAREFAS_CODIGO
from worker.coding import Code
from worker.core.config import WorkerSettings
from worker.providers.base import Provider
from worker.voice import TASKS, Voice

logger = logging.getLogger("worker.ws_client")

_HELLO_ACK_TIMEOUT_SECONDS = 10.0


class WorkerClient:
    """Keeps the WebSocket connection with the Gateway: handshake, heartbeat, dispatch
    of chat_request to the local Provider, and reconnection with exponential backoff.
    """

    def __init__(
        self, settings: WorkerSettings, provider: Provider, voice: Voice | None = None
    ) -> None:
        self._settings = settings
        self._provider = provider
        self._voice = voice or Voice(settings)
        self._background_tasks: set[asyncio.Task[None]] = set()
        self._websocket: websockets.WebSocketClientProtocol | None = None
        # Claude Code sessions survive reconnections: each step goes through the current connection.
        self._codigo = Code(settings, self._issue_code)
        # active Claude Code account (switched from the app): applies to every `claude` of this
        # process
        self._contas = Accounts(settings.claude_contas_dir, settings.codigo_claude_bin)

    async def run_forever(self) -> None:
        backoff = self._settings.reconnect_min_backoff_seconds
        if self._settings.whisper_aquecer:
            aquecer = asyncio.create_task(self._voice.aquecer())
            self._background_tasks.add(aquecer)
            aquecer.add_done_callback(self._background_tasks.discard)
        while True:
            try:
                await self._run_once()
                backoff = self._settings.reconnect_min_backoff_seconds
            except asyncio.CancelledError:
                raise
            except Exception:
                logger.exception(
                    "Conexão com o Gateway caiu ou falhou, tentando de novo em %.1fs", backoff
                )
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, self._settings.reconnect_max_backoff_seconds)

    async def _run_once(self) -> None:
        logger.info("Conectando ao Gateway em %s", self._settings.gateway_url)
        async with websockets.connect(self._settings.gateway_url, max_size=16 * 2**20) as websocket:
            available_models = await self._provider.list_models()
            hello = WorkerHello(
                api_key=self._settings.api_key.get_secret_value(),
                worker_name=self._settings.name,
                available_models=available_models,
            )
            await websocket.send(hello.model_dump_json())

            raw_ack = await asyncio.wait_for(websocket.recv(), timeout=_HELLO_ACK_TIMEOUT_SECONDS)
            ack_message = parse_gateway_message(json.loads(raw_ack))
            if isinstance(ack_message, ProtocolError):
                raise RuntimeError(f"Gateway rejeitou a conexão: {ack_message.message}")
            if not isinstance(ack_message, WorkerHelloAck):
                raise RuntimeError("Resposta inesperada do Gateway ao worker_hello")

            logger.info(
                "Conectado ao Gateway (worker_id=%s, modelos=%s)",
                ack_message.worker_id,
                available_models,
            )

            self._websocket = websocket
            async with asyncio.TaskGroup() as task_group:
                task_group.create_task(self._heartbeat_loop(websocket))
                task_group.create_task(self._receive_loop(websocket))

    async def _issue_code(self, dados: dict) -> None:
        if self._websocket is None:
            raise RuntimeError("sem conexão com o Gateway")
        await self._websocket.send(WorkerEvent(canal="codigo", dados=dados).model_dump_json())

    async def _heartbeat_loop(self, websocket: websockets.WebSocketClientProtocol) -> None:
        interval = self._settings.heartbeat_interval_seconds
        while True:
            await asyncio.sleep(interval)
            usage = await asyncio.to_thread(resources.collect)
            await websocket.send(Heartbeat(recursos=usage).model_dump_json())

    async def _receive_loop(self, websocket: websockets.WebSocketClientProtocol) -> None:
        async for raw_message in websocket:
            try:
                message = parse_gateway_message(json.loads(raw_message))
            except ValidationError as exc:
                logger.warning("Mensagem inválida recebida do Gateway: %s", exc)
                continue

            if isinstance(message, ChatRequest):
                task = asyncio.create_task(self._handle_chat_request(websocket, message))
                self._background_tasks.add(task)
                task.add_done_callback(self._background_tasks.discard)
            # HeartbeatAck: nothing to do, it only confirms the connection is alive.

    async def _handle_chat_request(
        self, websocket: websockets.WebSocketClientProtocol, message: ChatRequest
    ) -> None:
        try:
            task = message.payload.get("task")
            if task in TASKS:
                payload = await self._voice.executar(task, message.payload)
            elif task in TAREFAS_CODIGO:
                payload = await self._codigo.executar(task, message.payload)
            elif task in TAREFAS_CONTAS:
                payload = await self._contas.executar(task, message.payload)
            elif task == pc.TASK:
                payload = await pc.execute(message.payload)
            elif task == "carregar_modelo":
                payload = await self._provider.load(str(message.payload["modelo"]))
            elif task == "simular_spice":
                payload = await run_ngspice(
                    str(message.payload["netlist"]), float(message.payload.get("timeout_s", 120))
                )
            elif task == "reescrever":
                # Claude Code with the subscription logged in on this PC (never the Anthropic API)
                payload = await rewrite(message.payload)
            elif task == "claude_json":
                # generic (e.g. Concursos plan): prompt, system and schema come from the backend
                p = message.payload
                payload = await claude_json(
                    str(p["prompt"]),
                    str(p["sistema"]),
                    p["esquema"],
                    timeout_s=float(p.get("limite_s", 280)),
                    model=str(p.get("modelo") or "") or None,
                    effort=str(p.get("effort") or "high"),
                    tools=str(p.get("ferramentas") or ""),
                )
            elif task == "buscar_web":
                # from the home IP: search engines block the VPS one (see shared.web_search)

                async with httpx.AsyncClient(follow_redirects=True) as cliente:
                    payload = await web_search.search(cliente, str(message.payload["consulta"]))
            elif task == "listar_modelos":
                payload = await self._provider.estado()
            else:
                payload = await self._provider.chat_completion(message.payload)
            response = ChatResponse(request_id=message.request_id, payload=payload)
            await websocket.send(response.model_dump_json())
        except Exception as exc:
            logger.exception("Falha ao processar chat_request %s", message.request_id)
            error = ProtocolError(request_id=message.request_id, message=str(exc))
            await websocket.send(error.model_dump_json())
