from datetime import date
from pathlib import Path

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app
from backend.notes.vault import Vault


@pytest.fixture
def api(tmp_path: Path) -> TestClient:
    s = Settings(client_api_keys=CLIENT_API_KEY, notas_dir=str(tmp_path))
    return TestClient(create_app(settings=s), headers=AUTH_HEADERS)


def test_exige_chave(tmp_path: Path) -> None:
    s = Settings(client_api_keys=CLIENT_API_KEY, notas_dir=str(tmp_path))
    assert TestClient(create_app(settings=s)).get("/api/notas").status_code == 401


def test_backlinks_relacoes_e_renomear(api: TestClient, tmp_path: Path) -> None:
    a = api.post("/api/notas", json={"titulo": "Ação", "tipo": "meta"}).json()
    b = api.post(
        "/api/notas",
        json={
            "titulo": "B",
            "corpo": "ver [[acao|a meta]] hoje",
            "propriedades": {"cobra": ["[[Ação]]"]},
        },
    ).json()
    assert api.post("/api/notas", json={"titulo": "ação"}).status_code == 409
    note = api.get(f"/api/notas/{a['id']}").json()
    assert {e["tipo"] for e in note["entradas"]} == {"cobra", "menciona"}
    assert api.get("/api/notas/sugestoes", params={"q": "ac"}).json()[0]["titulo"] == "Ação"

    api.put(f"/api/notas/{a['id']}", json={"titulo": "Meta 1"})
    b2 = api.get(f"/api/notas/{b['id']}").json()
    assert "[[Meta 1|a meta]]" in b2["corpo"] and b2["propriedades"]["cobra"] == ["[[Meta 1]]"]
    assert (tmp_path / "Meta 1.md").exists() and not (tmp_path / "Ação.md").exists()

    assert api.delete(f"/api/notas/{a['id']}").status_code == 204
    assert api.get(f"/api/notas/{a['id']}").status_code == 404


def test_le_vault_e_analisa(tmp_path: Path) -> None:
    (tmp_path / "Velha.md").write_text(
        "---\ntipo: tarefa\nstatus: aberta\nprazo: 2026-01-10\n---\n[[Nada]]\n"
    )
    (tmp_path / "Solta.md").write_text("sem frontmatter")
    an = Vault(tmp_path).analysis(hoje=date(2026, 2, 1))
    assert an["total"] == 2
    assert [v["titulo"] for v in an["vencidas"]] == ["Velha"]
    assert an["quebrados"][0]["trecho"] == "Nada"
    assert {o["titulo"] for o in an["orfas"]} == {
        "Solta",
        "Velha",
    }


def test_espelho_traz_notas_completas(api: TestClient) -> None:
    api.post("/api/notas", json={"titulo": "A", "corpo": "ver [[B]]"})
    api.post("/api/notas", json={"titulo": "B"})
    notes = {n["titulo"]: n for n in api.get("/api/notas/espelho").json()}
    assert notes["A"]["corpo"] == "ver [[B]]"
    assert [e["titulo"] for e in notes["B"]["entradas"]] == ["A"]


def test_filtra_tipos_do_vault(tmp_path: Path) -> None:
    (tmp_path / "Tarefa.md").write_text("---\ntype: task\nstatus: todo\n---\n")
    (tmp_path / "Todo.md").write_text("---\nstatus: todo\n---\n")
    (tmp_path / "Roteiro.md").write_text("---\ntipo: roteiro\n---\n")
    (tmp_path / "Solta.md").write_text("sem frontmatter")
    c = Vault(tmp_path)
    assert {n["titulo"] for n in c.list_all(tipo="tarefa")} == {"Tarefa", "Todo"}
    assert {n["titulo"] for n in c.list_all(tipo="nota")} == {"Roteiro", "Solta"}
    [r] = c.list_all(tipo="roteiro")
    c.atualizar(r["id"], {"corpo": "x"})
    assert "tipo: roteiro" in (tmp_path / "Roteiro.md").read_text()
