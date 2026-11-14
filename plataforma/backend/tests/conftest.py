import pytest
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app

CLIENT_API_KEY = "test-client-key"
AUTH_HEADERS = {"Authorization": f"Bearer {CLIENT_API_KEY}"}


@pytest.fixture
def settings() -> Settings:
    return Settings(
        environment="development",
        debug=True,
        log_format="console",
        client_api_keys=CLIENT_API_KEY,
    )


@pytest.fixture
def client(settings: Settings) -> TestClient:
    return TestClient(create_app(settings=settings))
