import base64
import time
from pathlib import Path
from typing import Any

import pytest
from conftest import AUTH_HEADERS, CLIENT_API_KEY
from fastapi.testclient import TestClient

from backend.auth.security import issue_token
from backend.core.config import Settings
from backend.main import create_app
from coding.api import Executor


@pytest.fixture
def api(tmp_path: Path) -> TestClient:
    s = Settings(
        client_api_keys=CLIENT_API_KEY,
        codigo_dir=str(tmp_path),
        jwt_secret_key=SEGREDO,
        sessoes_geracao_arquivo=str(tmp_path / "geracao"),
    )
    app = create_app(settings=s)
    requests: list[tuple[str, dict[str, Any]]] = []

    async def pedir(tarefa: str, payload: dict[str, Any]) -> dict[str, Any]:
        requests.append((tarefa, payload))
        return {"ok": tarefa != "codigo.parar", "status": "## master"}

    app.state.executor_codigo = Executor(pedir, lambda: None)
    app.state.requests = requests
    # Code requires a login session with a recent Authenticator code (the key is not enough).
    token, _ = issue_token("eu", SEGREDO, 60, {"totp": int(time.time())})
    return TestClient(app, headers={"Authorization": f"Bearer {token}"})


SEGREDO = "s" * 40


def test_code_refuses_key_and_session_without_recent_code(api: TestClient) -> None:
    assert api.get("/api/codigo/sessoes", headers=AUTH_HEADERS).status_code == 403
    velho, _ = issue_token("eu", SEGREDO, 60, {"totp": int(time.time()) - 13 * 3600})
    header = {"Authorization": f"Bearer {velho}"}
    r = api.get("/api/codigo/sessoes", headers=header)
    assert r.status_code == 403 and r.json()["error"]["type"] == "totp_required"


def test_tab_receives_request_steps_and_continues_session(api: TestClient) -> None:
    aba = api.post("/api/codigo/sessoes", json={"titulo": "Login"}).json()
    png = base64.b64encode(b"\x89PNG").decode()
    r = api.post(
        f"/api/codigo/sessoes/{aba['id']}/mensagens",
        json={"texto": "crie a tela", "imagens": [{"nome": "ref.png", "b64": png}]},
    )
    assert r.status_code == 200 and r.json()["estado"] == "rodando"
    task, payload = api.app.state.requests[-1]  # type: ignore[attr-defined]
    assert task == "codigo.enviar" and payload["claude_sessao"] is None
    # Second message while running: refused.
    assert api.post(
        f"/api/codigo/sessoes/{aba['id']}/mensagens", json={"texto": "x"}
    ).status_code == 409

    # Steps arriving from the worker through the `codigo` channel.
    ouvinte = api.app.state.worker_registry.ouvintes["codigo"]  # type: ignore[attr-defined]
    ouvinte({"sessao_id": aba["id"], "tipo": "inicio", "claude_sessao": "abc"})
    ouvinte({"sessao_id": aba["id"], "tipo": "ferramenta", "nome": "Bash", "resumo": "ls"})
    ouvinte({"sessao_id": aba["id"], "tipo": "fim", "erro": False, "texto": "pronto"})
    ouvinte({"sessao_id": "0" * 32, "tipo": "fim"})  # missing tab: ignored

    data = api.get(f"/api/codigo/sessoes/{aba['id']}", params={"desde": 1}).json()
    assert [e["tipo"] for e in data["eventos"]] == ["inicio", "ferramenta", "fim"]
    assert data["sessao"]["estado"] == "parada" and data["sessao"]["claude_sessao"] == "abc"
    name = api.get(f"/api/codigo/sessoes/{aba['id']}").json()["eventos"][0]["imagens"][0]
    assert api.get(f"/api/codigo/sessoes/{aba['id']}/imagens/{name}").content == b"\x89PNG"

    api.post(f"/api/codigo/sessoes/{aba['id']}/commit", json={"push": True, "publicar": True})
    _, payload = api.app.state.requests[-1]  # type: ignore[attr-defined]
    assert payload["claude_sessao"] == "abc"
    assert "git push" in payload["texto"] and "publicar_app" in payload["texto"]


def test_stop_unlocks_tab_without_process_on_pc(api: TestClient) -> None:
    aba = api.post("/api/codigo/sessoes", json={}).json()
    api.post(f"/api/codigo/sessoes/{aba['id']}/mensagens", json={"texto": "faça"})
    assert api.post(f"/api/codigo/sessoes/{aba['id']}/parar").json()["estado"] == "erro"
    assert api.get("/api/codigo/git").json()["status"] == "## master"
    api.get("/api/codigo/arquivo", params={"caminho": "a.py", "commit": "abc1"})
    assert api.app.state.requests[-1] == (  # type: ignore[attr-defined]
        "codigo.arquivo", {"caminho": "a.py", "commit": "abc1"}
    )
    api.get("/api/codigo/arvore")
    assert api.app.state.requests[-1] == ("codigo.arvore", {"commit": ""})  # type: ignore[attr-defined]
    api.get("/api/codigo/busca", params={"termo": "x", "observacoes": True})
    assert api.app.state.requests[-1] == (  # type: ignore[attr-defined]
        "codigo.buscar", {"termo": "x", "commit": "", "observacoes": True}
    )
    assert api.delete(f"/api/codigo/sessoes/{aba['id']}").status_code == 204
    assert api.get(f"/api/codigo/sessoes/{aba['id']}").status_code == 404
    assert api.get("/api/codigo/sessoes").json() == []


def test_claude_accounts_go_to_worker(api: TestClient) -> None:
    assert api.get("/api/codigo/contas").status_code == 200
    assert api.post("/api/codigo/contas", json={"nome": "trabalho"}).status_code == 200
    api.post("/api/codigo/contas/trabalho/codigo", json={"codigo": "abc#123"})
    api.post("/api/codigo/contas/trabalho/ativar")
    api.delete("/api/codigo/contas/trabalho")
    assert api.app.state.requests == [  # type: ignore[attr-defined]
        ("contas.listar", {}),
        ("contas.entrar", {"nome": "trabalho"}),
        ("contas.codigo", {"nome": "trabalho", "codigo": "abc#123"}),
        ("contas.ativar", {"nome": "trabalho"}),
        ("contas.remover", {"nome": "trabalho"}),
    ]
