import logging
import time
import uuid
from typing import Any

from starlette.requests import Request
from starlette.types import ASGIApp

from backend.core.logging import request_id_ctx

logger = logging.getLogger("gateway.access")

REQUEST_ID_HEADER = "X-Request-ID"


class RequestIdMiddleware:
    """Atribui um request_id único a cada requisição, expõe via header de
    resposta e disponibiliza no contexto de logging para correlação de logs.
    Também registra uma linha de acesso com método, path, status e latência.
    """

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Any, receive: Any, send: Any) -> None:  # noqa: ANN401
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        request = Request(scope)
        incoming_id = request.headers.get(REQUEST_ID_HEADER)
        request_id = incoming_id or str(uuid.uuid4())
        token = request_id_ctx.set(request_id)

        start = time.perf_counter()
        status_holder: dict[str, int] = {}

        async def send_wrapper(message: Any) -> None:  # noqa: ANN401
            if message["type"] == "http.response.start":
                status_holder["status"] = message["status"]
                headers = message.setdefault("headers", [])
                headers.append((REQUEST_ID_HEADER.encode("latin-1"), request_id.encode("latin-1")))
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        finally:
            duration_ms = (time.perf_counter() - start) * 1000
            logger.info(
                "%s %s -> %s (%.1fms)",
                request.method,
                request.url.path,
                status_holder.get("status", "?"),
                duration_ms,
            )
            request_id_ctx.reset(token)
