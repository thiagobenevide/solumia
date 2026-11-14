import json
from pathlib import Path

from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app


def _api(pasta: Path, **kw) -> TestClient:
    s = Settings(client_api_keys=CLIENT_API_KEY, atualizacoes_dir=str(pasta))
    return TestClient(create_app(settings=s), **kw)


def test_sem_publicacao_e_exige_chave(tmp_path: Path) -> None:
    assert _api(tmp_path).get("/api/atualizacoes").status_code == 401
    api = _api(tmp_path, headers=AUTH_HEADERS)
    assert api.get("/api/atualizacoes").json() == {"build": 0, "plataformas": []}
    assert api.get("/api/atualizacoes/android").status_code == 404


def test_versao_e_pacotes_publicados(tmp_path: Path) -> None:
    (tmp_path / "versao.json").write_text(json.dumps({"build": 2610281200, "versao": "0.1.0"}))
    (tmp_path / "agent.apk").write_bytes(b"apk")
    api = _api(tmp_path, headers=AUTH_HEADERS)
    assert api.get("/api/atualizacoes").json() == {
        "build": 2610281200, "versao": "0.1.0", "plataformas": ["android"]}
    assert api.get("/api/atualizacoes/android").content == b"apk"
    assert api.get("/api/atualizacoes/linux").status_code == 404
    assert api.get("/api/atualizacoes/..%2Fversao.json").status_code == 404
