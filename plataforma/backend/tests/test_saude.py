from pathlib import Path

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app

PNG = b"\x89PNG\r\n\x1a\n" + b"\0" * 32


@pytest.fixture
def api(tmp_path: Path) -> TestClient:
    s = Settings(
        client_api_keys=CLIENT_API_KEY, saude_dir=str(tmp_path), saude_baixar_imagens=False
    )
    return TestClient(create_app(settings=s), headers=AUTH_HEADERS)


def test_exige_chave(tmp_path: Path) -> None:
    s = Settings(client_api_keys=CLIENT_API_KEY, saude_dir=str(tmp_path))
    assert TestClient(create_app(settings=s)).get("/api/saude/exercicios").status_code == 401


def test_catalogo_base_por_area(api: TestClient) -> None:
    j = api.get("/api/saude/exercicios").json()
    areas = {e["area"] for e in j["exercicios"]}
    assert areas == set(j["areas"])
    assert any(e["equipamento"] == "Saco de pancada" for e in j["exercicios"])


def test_criar_exercicio_com_imagem_e_excluir(api: TestClient) -> None:
    r = api.post("/api/saude/exercicios", json={"nome": "Flexão de braço", "area": "Peito"})
    assert r.status_code == 201
    ex = r.json()
    assert ex["id"] == "flexao-de-braco" and ex["personalizado"]
    assert api.get(f"/api/saude/exercicios/{ex['id']}/imagem").status_code == 404

    r = api.post(
        f"/api/saude/exercicios/{ex['id']}/imagem",
        files={"arquivo": ("f.png", PNG, "image/png")},
    )
    assert r.json()["imagem_propria"]
    assert api.get(f"/api/saude/exercicios/{ex['id']}/imagem").content == PNG
    r = api.post(
        f"/api/saude/exercicios/{ex['id']}/imagem",
        files={"arquivo": ("f.txt", b"x", "text/plain")},
    )
    assert r.status_code == 422

    api.post("/api/saude/agenda", json={"data": "2026-11-02", "exercicio_id": ex["id"]})
    assert api.delete(f"/api/saude/exercicios/{ex['id']}").status_code == 204
    assert api.get("/api/saude/agenda?de=2026-11-01&ate=2026-11-30").json() == []


def test_agenda_marcar_editar_copiar(api: TestClient) -> None:
    a = api.post("/api/saude/agenda", json={"data": "2026-11-02", "exercicio_id": "flexao"}).json()
    b = api.post(
        "/api/saude/agenda",
        json={"data": "2026-11-02", "exercicio_id": "prancha", "series": 5},
    ).json()
    assert (a["ordem"], b["ordem"], b["series"], a["repeticoes"]) == (0, 1, 5, "12")

    r = api.patch(f"/api/saude/agenda/{a['id']}", json={"feito": True, "carga_kg": 10})
    assert r.json()["feito"] and r.json()["carga_kg"] == 10
    assert api.patch(f"/api/saude/agenda/{a['id']}", json={"data": "x"}).status_code == 422

    copia = api.post(
        "/api/saude/agenda/copiar",
        json={"de": "2026-11-02", "ate": "2026-11-08", "destino": "2026-11-09"},
    ).json()
    assert [(i["data"], i["feito"]) for i in copia] == [("2026-11-09", False)] * 2

    semana = api.get("/api/saude/agenda?de=2026-11-02&ate=2026-11-08").json()
    assert [i["exercicio_id"] for i in semana] == ["flexao", "prancha"]
    assert api.delete(f"/api/saude/agenda/{b['id']}").status_code == 204
    assert api.post(
        "/api/saude/agenda", json={"data": "2026-11-02", "exercicio_id": "nao-existe"}
    ).status_code == 404
