from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app


def test_list_models_returns_openai_compatible_shape(client: TestClient) -> None:
    response = client.get("/v1/models", headers=AUTH_HEADERS)

    assert response.status_code == 200
    body = response.json()
    assert body["object"] == "list"
    assert len(body["data"]) > 0
    for model in body["data"]:
        assert set(model.keys()) == {"id", "object", "owned_by"}
        assert model["object"] == "model"


def test_list_models_includes_expected_ids(client: TestClient) -> None:
    response = client.get("/v1/models", headers=AUTH_HEADERS)

    ids = {model["id"] for model in response.json()["data"]}
    assert "openai/gpt-oss-20b" in ids
    assert "text-embedding-nomic-embed-text-v1.5" in ids


def test_list_models_without_api_key_is_rejected(client: TestClient) -> None:
    response = client.get("/v1/models")

    assert response.status_code == 401
    assert response.json()["error"]["type"] == "invalid_api_key"


def test_list_models_reflects_connected_worker_and_replaces_mock() -> None:
    settings = Settings(
        environment="development",
        debug=True,
        log_format="console",
        worker_api_keys="test-worker-key",
        client_api_keys=CLIENT_API_KEY,
    )
    # `with` fixa o TestClient num único portal/event loop, compartilhado
    # entre a conexão WS (fake worker) e o GET concorrente — ver comentário
    # equivalente em test_ws_worker.py.
    with (
        TestClient(create_app(settings=settings)) as client,
        client.websocket_connect("/ws/worker") as ws,
    ):
        ws.send_json(
            {
                "type": "worker_hello",
                "api_key": "test-worker-key",
                "worker_name": "fake-worker",
                "available_models": ["model-a", "model-b"],
            }
        )
        ws.receive_json()  # ack

        response = client.get("/v1/models", headers=AUTH_HEADERS)

    ids = {model["id"] for model in response.json()["data"]}
    assert ids == {"model-a", "model-b"}
