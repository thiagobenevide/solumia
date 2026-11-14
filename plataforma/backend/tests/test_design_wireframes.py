import io
import json
import zipfile
from pathlib import Path

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app
from design import wireframe_ia

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
    tela = w["paginas"][0]["id"]
    r = api.put(
        f"/api/design/wireframes/{w['id']}/elementos",
        json={"versao": 1, "elementos": [{**BOTAO, "pagina": tela}]},
    )
    assert r.status_code == 200
    return api.get(f"/api/design/wireframes/{w['id']}").json()


def test_ida_e_volta_preserva_o_documento() -> None:
    doc = {
        "titulo": "ND",
        "paginas": [{**wireframe_ia.tela_padrao(), "id": "t1"}],
        "elementos": [{**BOTAO, "pagina": "t1"}],
    }
    troca = wireframe_ia.para_ia(doc)
    [comp] = troca["telas"][0]["componentes"]
    assert comp["largura"] == 118 and comp["texto"] == "Gerar ND" and "props" not in comp
    volta = wireframe_ia.de_ia(json.loads(json.dumps(troca)))
    assert volta["elementos"] == doc["elementos"]
    assert volta["paginas"][0]["id"] == "t1"


def test_rejeita_tipo_desconhecido_dizendo_onde() -> None:
    troca = wireframe_ia.para_ia({"titulo": "x", "paginas": [], "elementos": []})
    troca["telas"][0]["componentes"] = [{"id": "z", "tipo": "div", "x": 0, "y": 0}]
    with pytest.raises(wireframe_ia.FormatoInvalido, match="componente z"):
        wireframe_ia.de_ia(troca)


def test_le_bloco_json_colado_de_chat() -> None:
    troca = wireframe_ia.para_ia({"titulo": "Chat", "paginas": [], "elementos": []})
    texto = f"Aqui está:\n```json\n{json.dumps(troca)}\n```\n"
    assert wireframe_ia.ler(texto.encode())["titulo"] == "Chat"


def test_exporta_pacote_e_reimporta(api: TestClient) -> None:
    w = _novo(api)
    tela = w["paginas"][0]["id"]
    png = b"\x89PNG\r\n\x1a\n" + b"0" * 20
    url = f"/api/design/wireframes/{w['id']}/telas"
    assert api.post(f"{url}/{tela}/png", files={"arquivo": ("t.png", png)}).status_code == 204
    assert api.post(f"{url}/../png", files={"arquivo": ("t.png", png)}).status_code in (404, 422)
    r = api.get(f"/api/design/wireframes/{w['id']}/ia")
    assert r.headers["content-type"] == "application/zip"
    with zipfile.ZipFile(io.BytesIO(r.content)) as z:
        esperado = {"AGENTS.md", "wireframe.schema.json", "wireframe.json", f"telas/{tela}.png"}
        assert set(z.namelist()) == esperado
        assert z.read(f"telas/{tela}.png") == png
        troca = json.loads(z.read("wireframe.json"))
    assert troca["telas"][0]["imagem"] == f"telas/{tela}.png"
    troca["telas"][0]["componentes"][0]["texto"] = "Gerar Nota"

    arq = {"arquivo": ("wireframe.json", json.dumps(troca).encode(), "application/json")}
    r = api.post(f"/api/design/wireframes/{w['id']}/importar-ia", files=arq)
    assert r.status_code == 200 and r.json()["versao"] == w["versao"] + 1
    [e] = r.json()["elementos"]
    assert e["props"]["texto"] == "Gerar Nota" and e["estado"] == "proposto"

    novo = api.post("/api/design/wireframes/importar-ia", files={"arquivo": ("p.zip", r.content)})
    assert novo.status_code == 422
    novo = api.post("/api/design/wireframes/importar-ia", files=arq)
    assert novo.status_code == 201 and novo.json()["id"] != w["id"]
    assert len(api.get("/api/design/wireframes").json()) == 2
    assert api.get("/api/design/quadros").json() == []
    assert api.delete(f"/api/design/wireframes/{w['id']}").status_code == 204
    assert not list(Path(api.app.state.wireframes_design.raiz).glob("*.anexos"))
