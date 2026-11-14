import json
import logging
import time
from collections.abc import AsyncIterator
from typing import Any
from uuid import uuid4

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, StreamingResponse

from backend.api.deps import SettingsDep, WorkerRegistryDep
from backend.core.errors import openai_error
from backend.core.worker_registry import WorkerDisconnected, WorkerRespondedWithError

logger = logging.getLogger("gateway.chat")

router = APIRouter(tags=["chat"])


@router.post("/chat/completions", response_model=None)
async def create_chat_completion(
    request: Request, registry: WorkerRegistryDep, settings: SettingsDep
) -> JSONResponse | StreamingResponse:
    """Encaminha um chat completion OpenAI-compatible para um worker conectado.

    `stream: true` não gera streaming incremental de verdade nesta etapa —
    a resposta completa do worker é embrulhada num único chunk SSE, para que
    clientes que sempre pedem streaming (Cursor, Continue.dev, ...) continuem
    funcionando sem precisar de suporte especial.
    """
    body: dict[str, Any] = await request.json()
    model = body.get("model")
    stream = bool(body.get("stream", False))

    worker = registry.pick_worker(model)
    if worker is None:
        raise openai_error(
            503,
            "Nenhum worker conectado no momento. Verifique se o Worker está rodando na "
            "sua máquina pessoal e conectado a este Gateway.",
            "no_worker_available",
        )

    worker_payload = {key: value for key, value in body.items() if key != "stream"}
    request_id = str(uuid4())

    try:
        response_payload = await registry.send_chat_request(
            worker,
            request_id,
            worker_payload,
            timeout_seconds=settings.chat_request_timeout_seconds,
            origem="API /v1 (ferramentas externas)",
        )
    except TimeoutError:
        raise openai_error(504, "O worker não respondeu a tempo.", "worker_timeout") from None
    except (WorkerDisconnected, WorkerRespondedWithError) as exc:
        raise openai_error(502, str(exc), "worker_error") from exc

    if not stream:
        return JSONResponse(response_payload)

    return StreamingResponse(_fake_stream(response_payload), media_type="text/event-stream")


async def _fake_stream(response_payload: dict[str, Any]) -> AsyncIterator[bytes]:
    chunk = {
        "id": response_payload.get("id", f"chatcmpl-{uuid4().hex}"),
        "object": "chat.completion.chunk",
        "created": response_payload.get("created", int(time.time())),
        "model": response_payload.get("model", ""),
        "choices": [
            {
                "index": choice.get("index", 0),
                "delta": choice.get("message", {}),
                "finish_reason": choice.get("finish_reason"),
            }
            for choice in response_payload.get("choices", [])
        ],
    }
    yield f"data: {json.dumps(chunk, ensure_ascii=False)}\n\n".encode()
    yield b"data: [DONE]\n\n"
