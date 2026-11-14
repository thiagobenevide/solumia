import asyncio
import contextlib
import hmac
import ipaddress
import logging
from pathlib import Path
from typing import Any
from uuid import uuid4

from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from pydantic import ValidationError

from backend.core.config import Settings
from backend.core.worker_registry import WorkerRegistry, WorkerRespondedWithError
from shared.protocol import (
    ChatResponse,
    Heartbeat,
    HeartbeatAck,
    ProtocolError,
    WorkerEvent,
    WorkerHello,
    WorkerHelloAck,
    parse_worker_message,
)

logger = logging.getLogger("gateway.ws.worker")

router = APIRouter(tags=["worker"])

_HELLO_TIMEOUT_SECONDS = 10.0


@router.websocket("/ws/worker")
async def worker_endpoint(websocket: WebSocket) -> None:
    """Handshake + message loop of a connected Worker.

    Not part of the OpenAI-compatible API — it is the transport through which
    the Gateway forwards chat_request/chat_response to the personal machine.
    """
    settings: Settings = websocket.app.state.settings
    registry: WorkerRegistry = websocket.app.state.worker_registry

    await websocket.accept()

    try:
        raw_hello: dict[str, Any] = await asyncio.wait_for(
            websocket.receive_json(), timeout=_HELLO_TIMEOUT_SECONDS
        )
    except (TimeoutError, WebSocketDisconnect):
        await _safe_close(websocket, code=4408, reason="Timeout aguardando worker_hello")
        return

    try:
        hello_message = parse_worker_message(raw_hello)
    except ValidationError as exc:
        logger.warning("worker_hello inválido: %s", exc)
        await _safe_close(websocket, code=4400, reason="Mensagem de hello inválida")
        return

    if not isinstance(hello_message, WorkerHello):
        await _safe_close(websocket, code=4400, reason="Primeira mensagem deve ser worker_hello")
        return

    if not any(
        hmac.compare_digest(hello_message.api_key.encode(), key.encode())
        for key in settings.worker_api_key_list
    ):
        logger.warning(
            "Tentativa de conexão de worker com api_key inválida (worker_name=%s)",
            hello_message.worker_name,
        )
        await _safe_close(websocket, code=4401, reason="api_key inválida")
        return

    worker_id = str(uuid4())
    registry.register(worker_id, websocket, hello_message.available_models)
    _annotate_ip_matches(settings, websocket.client.host if websocket.client else "")

    ack = WorkerHelloAck(
        worker_id=worker_id,
        heartbeat_interval_seconds=settings.worker_heartbeat_interval_seconds,
    )
    await websocket.send_json(ack.model_dump())

    try:
        while True:
            raw_message: dict[str, Any] = await websocket.receive_json()
            try:
                message = parse_worker_message(raw_message)
            except ValidationError as exc:
                logger.warning("Mensagem inválida do worker %s: %s", worker_id, exc)
                continue

            if isinstance(message, Heartbeat):
                registry.touch(worker_id, message.recursos)
                await websocket.send_json(HeartbeatAck().model_dump())
            elif isinstance(message, ChatResponse):
                registry.resolve(message.request_id, message.payload)
            elif isinstance(message, WorkerEvent):
                ouvinte = registry.ouvintes.get(message.canal)
                if ouvinte is not None:
                    ouvinte(message.dados)
            elif isinstance(message, ProtocolError):
                if message.request_id:
                    registry.reject(message.request_id, WorkerRespondedWithError(message.message))
                else:
                    logger.warning("Worker %s reportou erro: %s", worker_id, message.message)
    except WebSocketDisconnect:
        pass
    finally:
        await registry.unregister(worker_id)


def _annotate_ip_matches(settings: Settings, ip: str) -> None:
    """Keeps the public IP the worker connected from: that is where "Ligar o PC" sends the
    Wake-on-LAN. A local/private IP (worker on the same machine, dev) does not count."""
    try:
        if not ipaddress.ip_address(ip).is_global:
            return
        file = Path(settings.wol_ip_arquivo).expanduser()
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(ip)
    except (ValueError, OSError) as e:
        logger.warning("Não foi possível anotar o IP de casa (%s): %s", ip, e)


async def _safe_close(websocket: WebSocket, *, code: int, reason: str) -> None:
    with contextlib.suppress(Exception):
        await websocket.send_json(ProtocolError(message=reason).model_dump())
    with contextlib.suppress(Exception):
        await websocket.close(code=code, reason=reason)
