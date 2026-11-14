from pathlib import Path

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.core.config import Settings
from backend.main import create_app
from rotinas.api import LLMUnavailable


@pytest.fixture
def api(tmp_path: Path) -> TestClient:
    s = Settings(client_api_keys=CLIENT_API_KEY, rotinas_dir=str(tmp_path))
    return TestClient(create_app(settings=s), headers=AUTH_HEADERS)


def test_exige_chave(tmp_path: Path) -> None:
    s = Settings(client_api_keys=CLIENT_API_KEY, rotinas_dir=str(tmp_path))
    assert TestClient(create_app(settings=s)).get("/api/rotinas/tarefas").status_code == 401


def test_kanban_e_cronometro(api: TestClient) -> None:
    a = api.post("/api/rotinas/tarefas", json={"titulo": "A", "prioridade": "alta"}).json()
    b = api.post("/api/rotinas/tarefas", json={"titulo": "B"}).json()
    assert (a["coluna"], a["ordem"], b["ordem"]) == ("pendente", 0, 1)
    invalid = {"titulo": "C", "prioridade": "x"}
    assert api.post("/api/rotinas/tarefas", json=invalid).status_code == 422

    # iniciar leva para execução; iniciar outra pausa a primeira
    a = api.post(f"/api/rotinas/tarefas/{a['id']}/iniciar").json()
    assert a["coluna"] == "execucao" and a["rodando_desde"]
    api.post(f"/api/rotinas/tarefas/{b['id']}/iniciar")
    assert api.get("/api/rotinas/resumo").json()["rodando"] == b["id"]
    items = {t["id"]: t for t in api.get("/api/rotinas/tarefas").json()}
    assert items[a["id"]]["rodando_desde"] is None and items[b["id"]]["ordem"] == 0

    # reordenar dentro da coluna e concluir (para o cronômetro)
    b = api.post(f"/api/rotinas/tarefas/{b['id']}/mover", json={"coluna": "execucao", "ordem": 0})
    assert b.json()["ordem"] == 0
    url = f"/api/rotinas/tarefas/{b.json()['id']}"
    b = api.post(f"{url}/mover", json={"coluna": "concluida"}).json()
    assert b["rodando_desde"] is None and b["concluida_em"]
    assert api.post(f"/api/rotinas/tarefas/{b['id']}/iniciar").status_code == 422
    assert api.get("/api/rotinas/resumo").json()["colunas"] == {
        "pendente": 0,
        "execucao": 1,
        "concluida": 1,
    }

    a = api.patch(f"/api/rotinas/tarefas/{a['id']}", json={"titulo": "A2", "prazo": ""}).json()
    assert a["titulo"] == "A2" and a["prazo"] is None
    assert api.delete(f"/api/rotinas/tarefas/{a['id']}").status_code == 204
    assert api.patch(f"/api/rotinas/tarefas/{a['id']}", json={"titulo": "x"}).status_code == 404


def test_perguntar_usa_quadro(api: TestClient) -> None:
    recebidas: list[list[dict[str, str]]] = []

    async def falso(mensagens: list[dict[str, str]]) -> str:
        recebidas.append(mensagens)
        return "Faça o relatório."

    api.post("/api/rotinas/tarefas", json={"titulo": "Relatório mensal"})
    api.app.state.rotinas_llm = falso  # type: ignore[attr-defined]
    r = api.post(
        "/api/rotinas/perguntar",
        json={"pergunta": "o que faço?", "historico": [{"papel": "usuario", "texto": "oi"}]},
    )
    assert r.json() == {"resposta": "Faça o relatório."}
    system, history, question = recebidas[0]
    assert "Relatório mensal" in system["content"]
    assert history == {"role": "user", "content": "oi"}
    assert question["content"] == "o que faço?"


def test_perguntar_sem_worker(api: TestClient) -> None:
    async def fora(_: list[dict[str, str]]) -> str:
        raise LLMUnavailable("sem worker")

    assert api.post("/api/rotinas/perguntar", json={"pergunta": "?"}).status_code == 503
    api.app.state.rotinas_llm = fora  # type: ignore[attr-defined]
    assert api.post("/api/rotinas/perguntar", json={"pergunta": "?"}).status_code == 503
