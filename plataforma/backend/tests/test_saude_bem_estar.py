from datetime import date
from pathlib import Path

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app
from saude.spiritual import ANTIGO, NOVO, capitulos, leitura_do_dia
from saude.mental import sequencia


@pytest.fixture
def api(tmp_path: Path) -> TestClient:
    s = Settings(client_api_keys=CLIENT_API_KEY, saude_dir=str(tmp_path))
    return TestClient(create_app(settings=s), headers=AUTH_HEADERS)


def test_sequencia_de_habito() -> None:
    hoje = date(2026, 11, 6)  # sexta
    feitos = {"2026-11-03", "2026-11-04", "2026-11-05"}
    assert sequencia(feitos, [1, 2, 3, 4, 5, 6, 7], hoje) == 3  # hoje em aberto não quebra
    assert sequencia(feitos, [2, 3, 4], hoje) == 3  # dias fora do plano são pulados
    assert sequencia({"2026-11-05"}, [1, 2, 3, 4, 5, 6, 7], hoje) == 1


def test_habitos_foco_e_diario(api: TestClient) -> None:
    r = api.post("/api/saude/mental/habitos", json={"nome": "Meditar 10 min"})
    assert r.status_code == 201
    hid = r.json()["id"]
    hoje = date.today().isoformat()
    r = api.post(f"/api/saude/mental/habitos/{hid}/marcar", json={"data": hoje})
    assert r.json()["sequencia"] == 1 and r.json()["feitos"] == [hoje]
    lista = api.get(f"/api/saude/mental/habitos?de={hoje}&ate={hoje}").json()
    assert lista[0]["feitos"] == [hoje]
    assert api.post("/api/saude/mental/habitos", json={"nome": "x", "tipo": "y"}).status_code == 422

    api.post("/api/saude/mental/foco", json={"minutos": 25, "tarefa": "relatório"})
    api.post("/api/saude/mental/foco", json={"minutos": 10, "concluida": False})
    f = api.get(f"/api/saude/mental/foco?de={hoje}&ate={hoje}").json()
    assert len(f["sessoes"]) == 2 and f["minutos_por_dia"] == {hoje: 25}

    api.put("/api/saude/mental/diario/2026-11-02", json={"humor": 4, "ansiedade": 3})
    api.put("/api/saude/mental/diario/2026-11-02", json={"gratidao": "família"})
    d = api.get("/api/saude/mental/diario?de=2026-11-01&ate=2026-11-30").json()
    assert d == [{"data": "2026-11-02", "humor": 4, "ansiedade": 3, "gratidao": "família"}]
    assert api.put("/api/saude/mental/diario/2026-11-02", json={"humor": 9}).status_code == 422


def test_capitulos_e_divisao_do_plano() -> None:
    assert sum(c for _, c in ANTIGO) == 929 and sum(c for _, c in NOVO) == 260
    assert leitura_do_dia(["Gênesis", "Êxodo"], 3, 0) == ["Gênesis 1–30"]
    assert leitura_do_dia(["Gênesis", "Êxodo"], 3, 1) == ["Gênesis 31–50", "Êxodo 1–10"]
    livros = [n for n, _ in NOVO]
    todos = [t for n in range(90) for t in leitura_do_dia(livros, 90, n)]
    assert todos[0].startswith("Mateus 1") and todos[-1].endswith("22")
    assert len(capitulos(livros)) == 260


def test_plano_biblico(api: TestClient) -> None:
    r = api.post(
        "/api/saude/espiritual/planos", json={"escopo": "nt", "dias": 260, "inicio": "2026-11-02"}
    )
    assert r.status_code == 201
    p = r.json()
    assert (p["nome"], p["capitulos"], p["fim"]) == ("Novo Testamento", 260, "2027-07-19")
    dias = api.get(
        f"/api/saude/espiritual/planos/{p['id']}/leituras?de=2026-11-01&ate=2026-11-03"
    ).json()
    assert [(d["dia"], d["trechos"]) for d in dias] == [(1, ["Mateus 1"]), (2, ["Mateus 2"])]
    r = api.post(f"/api/saude/espiritual/planos/{p['id']}/marcar", json={"data": "2026-11-02"})
    assert r.json()["lidos"] == 1
    assert api.post("/api/saude/espiritual/planos", json={"escopo": "x"}).status_code == 422
