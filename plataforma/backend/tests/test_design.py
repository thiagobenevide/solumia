from pathlib import Path

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app

TRACO = {"id": "t1", "tipo": "traco", "cor": 4278190080, "espessura": 3, "pontos": [[0, 0, 0.5]]}


@pytest.fixture
def api(tmp_path: Path) -> TestClient:
    s = Settings(client_api_keys=CLIENT_API_KEY, design_dir=str(tmp_path))
    return TestClient(create_app(settings=s), headers=AUTH_HEADERS)


def test_exige_chave(tmp_path: Path) -> None:
    s = Settings(client_api_keys=CLIENT_API_KEY, design_dir=str(tmp_path))
    assert TestClient(create_app(settings=s)).get("/api/design/quadros").status_code == 401


def test_create_save_and_list(api: TestClient) -> None:
    q = api.post("/api/design/quadros", json={"titulo": "Aula 1", "fundo": "grade"}).json()
    assert q["versao"] == 1 and q["elementos"] == []

    url = f"/api/design/quadros/{q['id']}"
    r = api.put(f"{url}/elementos", json={"versao": 1, "elementos": [TRACO]})
    assert r.status_code == 200 and r.json()["versao"] == 2

    [summary] = api.get("/api/design/quadros").json()
    assert summary["total"] == 1 and "elementos" not in summary
    assert api.get(f"/api/design/quadros/{q['id']}").json()["elementos"] == [TRACO]


def test_old_version_conflicts_with_current(api: TestClient) -> None:
    q = api.post("/api/design/quadros", json={}).json()
    url = f"/api/design/quadros/{q['id']}/elementos"
    api.put(url, json={"versao": 1, "elementos": [TRACO]})
    r = api.put(url, json={"versao": 1, "elementos": []})
    assert r.status_code == 409
    assert r.json()["quadro"]["versao"] == 2


def test_validates_elements_and_background(api: TestClient) -> None:
    q = api.post("/api/design/quadros", json={}).json()
    r = api.put(
        f"/api/design/quadros/{q['id']}/elementos",
        json={"versao": 1, "elementos": [{"id": "x", "tipo": "video"}]},
    )
    assert r.status_code == 422
    assert api.patch(f"/api/design/quadros/{q['id']}", json={"fundo": "xadrez"}).status_code == 422


def test_edit_duplicate_and_delete(api: TestClient) -> None:
    q = api.post("/api/design/quadros", json={"titulo": "Esquema"}).json()
    new = api.patch(f"/api/design/quadros/{q['id']}", json={"titulo": "Novo"}).json()
    assert new["titulo"] == "Novo"
    copy = api.post(f"/api/design/quadros/{q['id']}/duplicar").json()
    assert copy["titulo"] == "Novo (cópia)" and copy["id"] != q["id"]
    assert api.delete(f"/api/design/quadros/{q['id']}").status_code == 204
    assert api.get(f"/api/design/quadros/{q['id']}").status_code == 404
    assert api.get("/api/design/quadros/../../etc").status_code == 404


def test_thumbnail(api: TestClient) -> None:
    q = api.post("/api/design/quadros", json={}).json()
    url = f"/api/design/quadros/{q['id']}/miniatura"
    assert api.get(url).status_code == 404
    png = b"\x89PNG\r\n\x1a\n" + b"\0" * 16
    assert api.post(url, files={"arquivo": ("m.png", png)}).status_code == 204
    assert api.get(url).content == png
    assert api.get("/api/design/quadros").json()[0]["miniatura"] is True
    assert api.post(url, files={"arquivo": ("m.png", b"GIF89a")}).status_code == 422
