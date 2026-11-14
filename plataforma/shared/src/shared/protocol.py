"""WebSocket message protocol between the Worker and the Gateway.

Each message is a JSON object with a `type` field that identifies its schema. The two unions
below (`WorkerToGatewayMessage` and `GatewayToWorkerMessage`) describe what each side can *send*,
which is useful to validate the message direction on each end.

Field names and `type` values are the wire format, so they stay as they are.
"""

from typing import Annotated, Any, Literal

from pydantic import BaseModel, Field, TypeAdapter


class WorkerHello(BaseModel):
    """First message sent by the Worker when it connects: credential + available models."""

    type: Literal["worker_hello"] = "worker_hello"
    api_key: str
    worker_name: str
    available_models: list[str]


class WorkerHelloAck(BaseModel):
    """Gateway answer confirming the Worker registration."""

    type: Literal["worker_hello_ack"] = "worker_hello_ack"
    worker_id: str
    heartbeat_interval_seconds: int


class Heartbeat(BaseModel):
    type: Literal["heartbeat"] = "heartbeat"
    recursos: dict[str, Any] | None = None
    """Usage of the Worker machine (CPU, RAM, GPUs), shown on the LLM dashboard."""


class HeartbeatAck(BaseModel):
    type: Literal["heartbeat_ack"] = "heartbeat_ack"


class ChatRequest(BaseModel):
    """Forwarded by the Gateway to the Worker: raw (OpenAI-compatible) chat completion body.

    With `payload["task"]` it is another Worker task, answered in the same `chat_response`:
    `transcrever` (`audio_b64`, `mime`, optional `idioma` -> `{"texto", "idioma"}`) and
    `falar` (`texto` -> `{"audio_b64", "mime"}`).
    """

    type: Literal["chat_request"] = "chat_request"
    request_id: str
    payload: dict[str, Any]


class ChatResponse(BaseModel):
    """Worker answer: raw (OpenAI-compatible) body returned by the local provider."""

    type: Literal["chat_response"] = "chat_response"
    request_id: str
    payload: dict[str, Any]


class WorkerEvent(BaseModel):
    """Notice from the Worker with no request attached, delivered to the [canal] (channel) listener
    on the Gateway. E.g. `codigo`: steps of a Claude Code session (`dados["sessao_id"]`)."""

    type: Literal["evento"] = "evento"
    canal: str
    dados: dict[str, Any]


class ProtocolError(BaseModel):
    """Error reported by either side, optionally tied to a request_id."""

    type: Literal["error"] = "error"
    request_id: str | None = None
    message: str
    error_type: str = "worker_error"


WorkerToGatewayMessage = Annotated[
    WorkerHello | Heartbeat | ChatResponse | WorkerEvent | ProtocolError,
    Field(discriminator="type"),
]

GatewayToWorkerMessage = Annotated[
    WorkerHelloAck | HeartbeatAck | ChatRequest,
    Field(discriminator="type"),
]

_worker_to_gateway_adapter: TypeAdapter[WorkerToGatewayMessage] = TypeAdapter(
    WorkerToGatewayMessage
)
_gateway_to_worker_adapter: TypeAdapter[GatewayToWorkerMessage] = TypeAdapter(
    GatewayToWorkerMessage
)


def parse_worker_message(data: dict[str, Any]) -> WorkerToGatewayMessage:
    """Validates and converts a message received from the Worker (Gateway side)."""
    return _worker_to_gateway_adapter.validate_python(data)


def parse_gateway_message(data: dict[str, Any]) -> GatewayToWorkerMessage:
    """Validates and converts a message received from the Gateway (Worker side)."""
    return _gateway_to_worker_adapter.validate_python(data)
