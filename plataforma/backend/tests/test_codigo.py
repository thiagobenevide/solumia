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
from codigo.api import Executor


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
    app.state.pedidos = requests
    # O Código exige sessão do login com código do Authenticator recente (não basta a chave).
    token, _ = issue_token("eu", SEGREDO, 60, {"totp": int(time.time())})
    return TestClient(app, headers={"Authorization": f"Bearer {token}"})


SEGREDO = "s" * 40


def test_codigo_recusa_chave_e_sessao_sem_codigo_recente(api: TestClient) -> None:
    assert api.get("/api/codigo/sessoes", headers=AUTH_HEADERS).status_code == 403
    velho, _ = issue_token("eu", SEGREDO, 60, {"totp": int(time.time()) - 13 * 3600})
    header = {"Authorization": f"Bearer {velho}"}
    r = api.get("/api/codigo/sessoes", headers=header)
    assert r.status_code == 403 and r.json()["error"]["type"] == "totp_required"


def test_aba_recebe_pedido_etapas_e_continua_a_sessao(api: TestClient) -> None:
    aba = api.post("/api/codigo/sessoes", json={"titulo": "Login"}).json()
    png = base64.b64encode(b"\x89PNG").decode()
    r = api.post(
        f"/api/codigo/sessoes/{aba['id']}/mensagens",
        json={"texto": "crie a tela", "imagens": [{"nome": "ref.png", "b64": png}]},
    )
    assert r.status_code == 200 and r.json()["estado"] == "rodando"
    task, payload = api.app.state.pedidos[-1]  # type: ignore[attr-defined]
    assert task == "codigo.enviar" and payload["claude_sessao"] is None
    # Segunda mensagem enquanto roda: recusada.
    assert api.post(
        f"/api/codigo/sessoes/{aba['id']}/mensagens", json={"texto": "x"}
    ).status_code == 409

    # Etapas chegando do worker pelo canal `codigo`.
    ouvinte = api.app.state.worker_registry.ouvintes["codigo"]  # type: ignore[attr-defined]
    ouvinte({"sessao_id": aba["id"], "tipo": "inicio", "claude_sessao": "abc"})
    ouvinte({"sessao_id": aba["id"], "tipo": "ferramenta", "nome": "Bash", "resumo": "ls"})
    ouvinte({"sessao_id": aba["id"], "tipo": "fim", "erro": False, "texto": "pronto"})
    ouvinte({"sessao_id": "0" * 32, "tipo": "fim"})  # aba inexistente: ignorada

    data = api.get(f"/api/codigo/sessoes/{aba['id']}", params={"desde": 1}).json()
    assert [e["tipo"] for e in data["eventos"]] == ["inicio", "ferramenta", "fim"]
    assert data["sessao"]["estado"] == "parada" and data["sessao"]["claude_sessao"] == "abc"
    name = api.get(f"/api/codigo/sessoes/{aba['id']}").json()["eventos"][0]["imagens"][0]
    assert api.get(f"/api/codigo/sessoes/{aba['id']}/imagens/{name}").content == b"\x89PNG"

    api.post(f"/api/codigo/sessoes/{aba['id']}/commit", json={"push": True, "publicar": True})
    _, payload = api.app.state.pedidos[-1]  # type: ignore[attr-defined]
    assert payload["claude_sessao"] == "abc"
    assert "git push" in payload["texto"] and "publicar_app" in payload["texto"]


def test_parar_destrava_aba_sem_processo_no_pc(api: TestClient) -> None:
    aba = api.post("/api/codigo/sessoes", json={}).json()
    api.post(f"/api/codigo/sessoes/{aba['id']}/mensagens", json={"texto": "faça"})
    assert api.post(f"/api/codigo/sessoes/{aba['id']}/parar").json()["estado"] == "erro"
    assert api.get("/api/codigo/git").json()["status"] == "## master"
    api.get("/api/codigo/arquivo", params={"caminho": "a.py", "commit": "abc1"})
    assert api.app.state.pedidos[-1] == (  # type: ignore[attr-defined]
        "codigo.arquivo", {"caminho": "a.py", "commit": "abc1"}
    )
    api.get("/api/codigo/arvore")
    assert api.app.state.pedidos[-1] == ("codigo.arvore", {"commit": ""})  # type: ignore[attr-defined]
    api.get("/api/codigo/busca", params={"termo": "x", "observacoes": True})
    assert api.app.state.pedidos[-1] == (  # type: ignore[attr-defined]
        "codigo.buscar", {"termo": "x", "commit": "", "observacoes": True}
    )
    assert api.delete(f"/api/codigo/sessoes/{aba['id']}").status_code == 204
    assert api.get(f"/api/codigo/sessoes/{aba['id']}").status_code == 404
    assert api.get("/api/codigo/sessoes").json() == []


def test_contas_do_claude_vao_ao_worker(api: TestClient) -> None:
    assert api.get("/api/codigo/contas").status_code == 200
    assert api.post("/api/codigo/contas", json={"nome": "trabalho"}).status_code == 200
    api.post("/api/codigo/contas/trabalho/codigo", json={"codigo": "abc#123"})
    api.post("/api/codigo/contas/trabalho/ativar")
    api.delete("/api/codigo/contas/trabalho")
    assert api.app.state.pedidos == [  # type: ignore[attr-defined]
        ("contas.listar", {}),
        ("contas.entrar", {"nome": "trabalho"}),
        ("contas.codigo", {"nome": "trabalho", "codigo": "abc#123"}),
        ("contas.ativar", {"nome": "trabalho"}),
        ("contas.remover", {"nome": "trabalho"}),
    ]
