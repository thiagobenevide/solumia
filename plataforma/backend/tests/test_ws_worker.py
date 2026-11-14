from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient
from starlette.testclient import WebSocketDisconnect

from backend.core.config import Settings
from backend.main import create_app

_WORKER_API_KEY = "test-worker-key"


@pytest.fixture
def settings() -> Settings:
    return Settings(
        environment="development",
        debug=True,
        log_format="console",
        worker_api_keys=_WORKER_API_KEY,
    )


@pytest.fixture
def client(settings: Settings) -> Iterator[TestClient]:
    # Entering through `with` pins the TestClient to a single portal/event loop
    # for the whole test — needed so the WS connection and concurrent HTTP calls
    # share the same loop (asyncio.Future is not thread-safe across loops).
    # Without it, each call would open its own ephemeral portal and the two ends
    # would never meet.
    with TestClient(create_app(settings=settings)) as test_client:
        yield test_client


def test_worker_hello_with_valid_key_gets_ack(client: TestClient) -> None:
    with client.websocket_connect("/ws/worker") as ws:
        ws.send_json(
            {
                "type": "worker_hello",
                "api_key": _WORKER_API_KEY,
                "worker_name": "test-worker",
                "available_models": ["model-a"],
            }
        )
        ack = ws.receive_json()

    assert ack["type"] == "worker_hello_ack"
    assert ack["worker_id"]
    assert ack["heartbeat_interval_seconds"] == 20


def test_worker_hello_with_invalid_key_is_rejected(client: TestClient) -> None:
    with client.websocket_connect("/ws/worker") as ws:
        ws.send_json(
            {
                "type": "worker_hello",
                "api_key": "wrong-key",
                "worker_name": "test-worker",
                "available_models": [],
            }
        )
        error = ws.receive_json()
        assert error["type"] == "error"

        with pytest.raises(WebSocketDisconnect):
            ws.receive_json()


def test_heartbeat_gets_ack(client: TestClient) -> None:
    with client.websocket_connect("/ws/worker") as ws:
        ws.send_json(
            {
                "type": "worker_hello",
                "api_key": _WORKER_API_KEY,
                "worker_name": "test-worker",
                "available_models": [],
            }
        )
        ws.receive_json()  # ack

        ws.send_json({"type": "heartbeat"})
        heartbeat_ack = ws.receive_json()

    assert heartbeat_ack["type"] == "heartbeat_ack"
