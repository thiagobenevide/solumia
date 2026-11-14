from pathlib import Path

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app

TRACO = {"id": "t1", "tipo": "traco", "cor": 4278190080, "espessura": 3, "pontos": [[0, 0, 0.5]]}
PAPEL = {"fundo": "linhas", "espaco": 28, "largura": 794, "altura": 1123, "cor": 4294967295}


@pytest.fixture
def api(tmp_path: Path) -> TestClient:
    s = Settings(client_api_keys=CLIENT_API_KEY, design_dir=str(tmp_path))
    return TestClient(create_app(settings=s), headers=AUTH_HEADERS)


def test_caderno_separado_dos_quadros_e_guarda_o_papel(api: TestClient) -> None:
    c = api.post("/api/design/cadernos", json={}).json()
    assert c["titulo"] == "Caderno sem título"
    assert api.get("/api/design/quadros").json() == []

    url = f"/api/design/cadernos/{c['id']}"
    pages = [{"id": "p0", "nome": "Folha 1", "papel": PAPEL}]
    assert api.patch(url, json={"paginas": pages}).status_code == 200
    r = api.put(f"{url}/elementos", json={"versao": 1, "elementos": [{**TRACO, "pagina": "p0"}]})
    assert r.status_code == 200 and r.json()["versao"] == 2

    [summary] = api.get("/api/design/cadernos").json()
    assert summary["total"] == 1 and summary["paginas"][0]["papel"] == PAPEL
    assert api.put(f"{url}/elementos", json={"versao": 1, "elementos": []}).status_code == 409
    assert api.post(f"{url}/duplicar").status_code == 201
    assert api.delete(url).status_code == 204
    assert api.get(url).status_code == 404
