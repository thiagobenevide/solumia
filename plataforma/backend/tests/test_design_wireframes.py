import io
import json
import zipfile
from pathlib import Path

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app
from design import ai_wireframe

BOTAO = {
    "id": "b1",
    "tipo": "botao",
    "x": 10,
    "y": 20,
    "w": 118,
    "h": 32,
    "estado": "proposto",
    "props": {"texto": "Gerar ND", "variante": "primario", "nota": 1},
}


@pytest.fixture
def api(tmp_path: Path) -> TestClient:
    s = Settings(client_api_keys=CLIENT_API_KEY, design_dir=str(tmp_path))
    return TestClient(create_app(settings=s), headers=AUTH_HEADERS)


def _novo(api: TestClient) -> dict:
    w = api.post("/api/design/wireframes", json={"titulo": "ND"}).json()
    screen = w["paginas"][0]["id"]
    r = api.put(
        f"/api/design/wireframes/{w['id']}/elementos",
        json={"versao": 1, "elementos": [{**BOTAO, "pagina": screen}]},
    )
    assert r.status_code == 200
    return api.get(f"/api/design/wireframes/{w['id']}").json()


def test_round_trip_keeps_document() -> None:
    doc = {
        "titulo": "ND",
        "paginas": [{**ai_wireframe.screen_default(), "id": "t1"}],
        "elementos": [{**BOTAO, "pagina": "t1"}],
    }
    swap = ai_wireframe.for_ai(doc)
    [comp] = swap["telas"][0]["componentes"]
    assert comp["largura"] == 118 and comp["texto"] == "Gerar ND" and "props" not in comp
    lap = ai_wireframe.of_ai(json.loads(json.dumps(swap)))
    assert lap["elementos"] == doc["elementos"]
    assert lap["paginas"][0]["id"] == "t1"


def test_rejects_unknown_type_saying_where() -> None:
    swap = ai_wireframe.for_ai({"titulo": "x", "paginas": [], "elementos": []})
    swap["telas"][0]["componentes"] = [{"id": "z", "tipo": "div", "x": 0, "y": 0}]
    with pytest.raises(ai_wireframe.FormatInvalid, match="componente z"):
        ai_wireframe.of_ai(swap)


def test_reads_json_block_pasted_from_chat() -> None:
    swap = ai_wireframe.for_ai({"titulo": "Chat", "paginas": [], "elementos": []})
    text = f"Aqui está:\n```json\n{json.dumps(swap)}\n```\n"
    assert ai_wireframe.read(text.encode())["titulo"] == "Chat"


def test_exports_package_and_reimports(api: TestClient) -> None:
    w = _novo(api)
    screen = w["paginas"][0]["id"]
    png = b"\x89PNG\r\n\x1a\n" + b"0" * 20
    url = f"/api/design/wireframes/{w['id']}/telas"
    assert api.post(f"{url}/{screen}/png", files={"arquivo": ("t.png", png)}).status_code == 204
    assert api.post(f"{url}/../png", files={"arquivo": ("t.png", png)}).status_code in (404, 422)
    r = api.get(f"/api/design/wireframes/{w['id']}/ia")
    assert r.headers["content-type"] == "application/zip"
    with zipfile.ZipFile(io.BytesIO(r.content)) as z:
        expected = {"AGENTS.md", "wireframe.schema.json", "wireframe.json", f"telas/{screen}.png"}
        assert set(z.namelist()) == expected
        assert z.read(f"telas/{screen}.png") == png
        swap = json.loads(z.read("wireframe.json"))
    assert swap["telas"][0]["imagem"] == f"telas/{screen}.png"
    swap["telas"][0]["componentes"][0]["texto"] = "Gerar Nota"

    file = {"arquivo": ("wireframe.json", json.dumps(swap).encode(), "application/json")}
    r = api.post(f"/api/design/wireframes/{w['id']}/importar-ia", files=file)
    assert r.status_code == 200 and r.json()["versao"] == w["versao"] + 1
    [e] = r.json()["elementos"]
    assert e["props"]["texto"] == "Gerar Nota" and e["estado"] == "proposto"

    new = api.post("/api/design/wireframes/importar-ia", files={"arquivo": ("p.zip", r.content)})
    assert new.status_code == 422
    new = api.post("/api/design/wireframes/importar-ia", files=file)
    assert new.status_code == 201 and new.json()["id"] != w["id"]
    assert len(api.get("/api/design/wireframes").json()) == 2
    assert api.get("/api/design/quadros").json() == []
    assert api.delete(f"/api/design/wireframes/{w['id']}").status_code == 204
    assert not list(Path(api.app.state.wireframes_design.root).glob("*.anexos"))
