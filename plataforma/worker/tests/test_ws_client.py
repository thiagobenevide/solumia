import json
from typing import Any

from shared.protocol import ChatRequest
from worker import recursos
from worker.core.config import WorkerSettings
from worker.providers.base import Provider
from worker.voz import Voz
from worker.ws_client import WorkerClient


class _StubProvider(Provider):
    def __init__(
        self,
        *,
        chat_result: dict[str, Any] | None = None,
        chat_error: Exception | None = None,
    ) -> None:
        self._chat_result = chat_result
        self._chat_error = chat_error

    async def list_models(self) -> list[str]:
        return ["model-a"]

    async def chat_completion(self, payload: dict[str, Any]) -> dict[str, Any]:
        if self._chat_error is not None:
            raise self._chat_error
        assert self._chat_result is not None
        return self._chat_result


class _FakeWebSocket:
    """Duck-types apenas o método usado por WorkerClient._handle_chat_request: send()."""

    def __init__(self) -> None:
        self.sent: list[dict[str, Any]] = []

    async def send(self, raw: str) -> None:
        self.sent.append(json.loads(raw))


def _make_client(provider: Provider) -> WorkerClient:
    settings = WorkerSettings(api_key="test-key")
    return WorkerClient(settings, provider)


async def test_handle_chat_request_sends_chat_response_on_success() -> None:
    provider = _StubProvider(chat_result={"id": "chatcmpl-1", "choices": []})
    client = _make_client(provider)
    fake_ws = _FakeWebSocket()
    message = ChatRequest(request_id="req-1", payload={"model": "model-a", "messages": []})

    await client._handle_chat_request(fake_ws, message)  # type: ignore[arg-type]

    assert len(fake_ws.sent) == 1
    assert fake_ws.sent[0]["type"] == "chat_response"
    assert fake_ws.sent[0]["request_id"] == "req-1"
    assert fake_ws.sent[0]["payload"]["id"] == "chatcmpl-1"


async def test_handle_chat_request_sends_error_on_provider_failure() -> None:
    provider = _StubProvider(chat_error=RuntimeError("lm studio indisponível"))
    client = _make_client(provider)
    fake_ws = _FakeWebSocket()
    message = ChatRequest(request_id="req-2", payload={"model": "model-a", "messages": []})

    await client._handle_chat_request(fake_ws, message)  # type: ignore[arg-type]

    assert len(fake_ws.sent) == 1
    assert fake_ws.sent[0]["type"] == "error"
    assert fake_ws.sent[0]["request_id"] == "req-2"
    assert "lm studio indisponível" in fake_ws.sent[0]["message"]


class _VozFalsa(Voz):
    async def executar(self, tarefa: str, payload: dict[str, Any]) -> dict[str, Any]:
        return {"texto": f"{tarefa}:{payload['audio_b64']}"}


async def test_tarefa_de_voz_vai_para_a_voz_e_nao_ao_provider() -> None:
    settings = WorkerSettings(api_key="test-key")
    client = WorkerClient(settings, _StubProvider(), _VozFalsa(settings))
    fake_ws = _FakeWebSocket()
    message = ChatRequest(request_id="r", payload={"task": "transcrever", "audio_b64": "QQ=="})

    await client._handle_chat_request(fake_ws, message)  # type: ignore[arg-type]

    assert fake_ws.sent[0]["payload"] == {"texto": "transcrever:QQ=="}


def test_recursos_tem_cpu_ram_e_gpus() -> None:
    uso = recursos.coletar()
    assert set(uso) == {"cpu_pct", "ram_pct", "gpus"}
