from fastapi.testclient import TestClient

from backend import __version__


def test_health_returns_ok(client: TestClient) -> None:
    response = client.get("/health")

    assert response.status_code == 200
    body = response.json()
    assert body == {
        "status": "ok",
        "app_name": "LLM Gateway",
        "version": __version__,
        "environment": "development",
    }


def test_health_response_includes_request_id_header(client: TestClient) -> None:
    response = client.get("/health")

    assert "X-Request-ID" in response.headers


def test_health_echoes_incoming_request_id(client: TestClient) -> None:
    response = client.get("/health", headers={"X-Request-ID": "test-request-id"})

    assert response.headers["X-Request-ID"] == "test-request-id"
