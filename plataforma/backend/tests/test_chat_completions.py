from collections.abc import Iterator
from concurrent.futures import ThreadPoolExecutor

import pytest
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app

_WORKER_API_KEY = "test-worker-key"
_CLIENT_API_KEY = "test-client-key"
_AUTH_HEADERS = {"Authorization": f"Bearer {_CLIENT_API_KEY}"}


@pytest.fixture
def settings() -> Settings:
    return Settings(
        environment="development",
        debug=True,
        log_format="console",
        worker_api_keys=_WORKER_API_KEY,
        client_api_keys=_CLIENT_API_KEY,
        chat_request_timeout_seconds=2.0,
    )


@pytest.fixture
def client(settings: Settings) -> Iterator[TestClient]:
    # Ver comentário equivalente em test_ws_worker.py: precisa ser o mesmo
    # portal/event loop para o WS (fake worker) e o POST concorrente se
    # encontrarem através do asyncio.Future do WorkerRegistry.
    with TestClient(create_app(settings=settings)) as test_client:
        yield test_client


def _hello_message(models: list[str]) -> dict:
    return {
        "type": "worker_hello",
        "api_key": _WORKER_API_KEY,
        "worker_name": "fake-worker",
        "available_models": models,
    }


def test_chat_completion_without_worker_returns_503(client: TestClient) -> None:
    response = client.post(
        "/v1/chat/completions", json={"model": "model-a", "messages": []}, headers=_AUTH_HEADERS
    )

    assert response.status_code == 503
    assert response.json()["error"]["type"] == "no_worker_available"


def test_chat_completion_without_api_key_is_rejected(client: TestClient) -> None:
    response = client.post("/v1/chat/completions", json={"model": "model-a", "messages": []})

    assert response.status_code == 401
    assert response.json()["error"]["type"] == "invalid_api_key"


def test_chat_completion_round_trip(client: TestClient) -> None:
    with client.websocket_connect("/ws/worker") as ws:
        ws.send_json(_hello_message(["model-a"]))
        ws.receive_json()  # ack

        with ThreadPoolExecutor(max_workers=1) as executor:
            future = executor.submit(
                client.post,
                "/v1/chat/completions",
                json={"model": "model-a", "messages": [{"role": "user", "content": "oi"}]},
                headers=_AUTH_HEADERS,
            )

            request_msg = ws.receive_json()
            assert request_msg["type"] == "chat_request"
            assert request_msg["payload"]["model"] == "model-a"
            assert "stream" not in request_msg["payload"]

            ws.send_json(
                {
                    "type": "chat_response",
                    "request_id": request_msg["request_id"],
                    "payload": {
                        "id": "chatcmpl-1",
                        "object": "chat.completion",
                        "model": "model-a",
                        "choices": [
                            {
                                "index": 0,
                                "message": {"role": "assistant", "content": "olá"},
                                "finish_reason": "stop",
                            }
                        ],
                    },
                }
            )

            response = future.result(timeout=5)

    assert response.status_code == 200
    body = response.json()
    assert body["choices"][0]["message"]["content"] == "olá"


def test_chat_completion_stream_wraps_single_sse_chunk(client: TestClient) -> None:
    with client.websocket_connect("/ws/worker") as ws:
        ws.send_json(_hello_message(["model-a"]))
        ws.receive_json()  # ack

        with ThreadPoolExecutor(max_workers=1) as executor:
            future = executor.submit(
                client.post,
                "/v1/chat/completions",
                json={"model": "model-a", "messages": [], "stream": True},
                headers=_AUTH_HEADERS,
            )

            request_msg = ws.receive_json()
            ws.send_json(
                {
                    "type": "chat_response",
                    "request_id": request_msg["request_id"],
                    "payload": {
                        "id": "chatcmpl-2",
                        "model": "model-a",
                        "choices": [
                            {
                                "index": 0,
                                "message": {"role": "assistant", "content": "olá"},
                                "finish_reason": "stop",
                            }
                        ],
                    },
                }
            )

            response = future.result(timeout=5)

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/event-stream")
    assert 'chat.completion.chunk' in response.text
    assert response.text.strip().endswith("data: [DONE]")


def test_chat_completion_timeout_returns_504(client: TestClient) -> None:
    with client.websocket_connect("/ws/worker") as ws:
        ws.send_json(_hello_message(["model-a"]))
        ws.receive_json()  # ack

        response = client.post(
            "/v1/chat/completions", json={"model": "model-a", "messages": []}, headers=_AUTH_HEADERS
        )

    assert response.status_code == 504
    assert response.json()["error"]["type"] == "worker_timeout"
