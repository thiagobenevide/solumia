import time
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock

from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.core.modelo_llm import ModeloLLM
from backend.core.worker_registry import WorkerRegistry
from backend.main import create_app


def _cliente(tmp_path: Path) -> tuple[TestClient, WorkerRegistry]:
    settings = Settings(
        environment="development",
        client_api_keys=CLIENT_API_KEY,
        llm_config=str(tmp_path / "llm.json"),
        rotinas_modelo="padrao",
    )
    app = create_app(settings=settings)
    return TestClient(app), app.state.worker_registry


def _worker(registry: WorkerRegistry, ocupados: list[str] | None = None) -> AsyncMock:
    ws = MagicMock()
    ws.send_json = AsyncMock()
    worker = registry.register("w1", ws, ["a", "b"])

    async def responder(_worker, request_id, payload, _timeout, origem=""):  # type: ignore[no-untyped-def]
        if payload["task"] == "listar_modelos":
            return {"modelos": ["a", "b"], "carregados": ["a"], "ocupados": ocupados or []}
        return {"modelo": payload["modelo"]}

    registry.send_chat_request = AsyncMock(side_effect=responder)  # type: ignore[method-assign]
    return worker


def test_sem_escolha_usa_o_padrao_do_env(tmp_path: Path) -> None:
    client, _ = _cliente(tmp_path)
    r = client.get("/api/llm", headers=AUTH_HEADERS)
    assert r.status_code == 200
    assert r.json() == {
        "modelo": "padrao",
        "carregados": [],
        "disponiveis": [],
        "workers": 0,
        "em_uso": [],
    }


def test_troca_carrega_no_worker_e_salva(tmp_path: Path) -> None:
    client, registry = _cliente(tmp_path)
    _worker(registry)
    r = client.put("/api/llm", json={"modelo": "b"}, headers=AUTH_HEADERS)
    assert r.status_code == 200
    assert r.json()["modelo"] == "b"
    assert ModeloLLM(str(tmp_path / "llm.json")).atual == "b"


def test_troca_proibida_com_outro_modulo_usando(tmp_path: Path) -> None:
    client, registry = _cliente(tmp_path)
    _worker(registry)
    registry._em_uso["x"] = {
        "origem": "Rotinas",
        "tarefa": "chat",
        "modelo": "a",
        "inicio": time.monotonic(),
    }
    r = client.put("/api/llm", json={"modelo": "b"}, headers=AUTH_HEADERS)
    assert r.status_code == 409
    erro = r.json()["error"]
    assert erro["type"] == "llm_em_uso"
    assert erro["em_uso"][0]["origem"] == "Rotinas"
    assert "Rotinas" in erro["message"]
    assert ModeloLLM(str(tmp_path / "llm.json"), "padrao").atual == "padrao"


def test_modelo_inexistente(tmp_path: Path) -> None:
    client, registry = _cliente(tmp_path)
    _worker(registry)
    r = client.put("/api/llm", json={"modelo": "z"}, headers=AUTH_HEADERS)
    assert r.status_code == 422


def test_troca_proibida_com_a_esteira_usando_direto(tmp_path: Path) -> None:
    client, registry = _cliente(tmp_path)
    _worker(registry, ocupados=["a"])
    assert client.get("/api/llm", headers=AUTH_HEADERS).json()["em_uso"][0]["origem"] == (
        "Esteira (empreendimento)"
    )
    r = client.put("/api/llm", json={"modelo": "b"}, headers=AUTH_HEADERS)
    assert r.status_code == 409
    assert "Esteira" in r.json()["error"]["message"]
