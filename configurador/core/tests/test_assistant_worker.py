from __future__ import annotations

import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from solumia_configurador import assistant
from solumia_configurador.api import State, create_app
from solumia_configurador.platform_setup import System
from solumia_configurador.roles import worker
from solumia_configurador.vault import Vault

PORTA = 54321
TOKEN = "t" * 43

MANIFEST = {
    "topologia": {"tipo": "nuvem", "dominio": "solumia.exemplo.com", "email_tls": "a@b.com"},
    "nos": {"vps": {"endereco": "ssh", "ssh": {"host": "203.0.113.5", "usuario": "operador",
                                               "impressao_host": "SHA256:abcdef"},
                    "papeis": ["gateway"]}},
}


@pytest.fixture
def client(tmp_path: Path, vault: Vault, monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setattr(worker, "unit_state", lambda unit: "inactive")
    monkeypatch.setattr(assistant, "unit_state", lambda unit: "inactive")
    state = State(tmp_path / "solumia.toml", vault, System("linux", "x86_64"))
    c = TestClient(create_app(state, TOKEN, PORTA), base_url=f"http://127.0.0.1:{PORTA}")
    c.headers["Authorization"] = f"Bearer {TOKEN}"
    c.put("/manifesto", json=MANIFEST)
    return c


def test_context_never_has_identifying_values(client: TestClient, vault: Vault) -> None:
    vault.definir("gateway.chave_worker", "worker_SEGREDOsecreto123")
    r = client.get("/assistente")
    assert r.status_code == 200
    text = r.json()["contexto"]
    for value in ("solumia.exemplo.com", "203.0.113.5", "operador", "SHA256:abcdef", "worker_SEGREDO"):
        assert value not in text
    assert json.loads(text)["dominio_definido"] is True


def test_question_is_redacted_and_claude_has_no_tools(client: TestClient, vault: Vault,
                                                     monkeypatch: pytest.MonkeyPatch) -> None:
    vault.definir("gateway.chave_worker", "worker_SEGREDOsecreto123")
    sent: dict[str, str] = {}

    def fake_ask(prompt: str, binary: str) -> dict[str, str]:
        sent["prompt"] = prompt
        return {"resposta": "Abra a VPS em 203.0.113.5", "tela": "vps"}

    monkeypatch.setattr(assistant, "find_claude", lambda: "/bin/claude")
    monkeypatch.setattr(assistant, "ask", fake_ask)
    r = client.post("/assistente/perguntar", json={"pergunta": "minha chave worker_SEGREDOsecreto123 no 203.0.113.5"})
    assert r.status_code == 200
    assert "worker_SEGREDO" not in sent["prompt"] and "203.0.113.5" not in sent["prompt"]
    assert "203.0.113.5" not in r.json()["resposta"] and r.json()["tela"] == "vps"
    assert len(client.get("/assistente").json()["historico"]) == 1
    client.post("/assistente/limpar")
    assert client.get("/assistente").json()["historico"] == []

    command = assistant._command("claude")
    assert command[command.index("--tools") + 1] == ""
    assert "--no-session-persistence" in command and "--strict-mcp-config" in command


def test_worker_plan_needs_key_and_keeps_legacy(client: TestClient, vault: Vault) -> None:
    assert client.post("/worker/plano").status_code == 422
    vault.definir("gateway.chave_worker", "worker_SEGREDOsecreto123")
    r = client.post("/worker/plano")
    assert r.status_code == 200
    assert [p["id"] for p in r.json()["passos"]] == ["ambiente", "configuracao", "unidade", "ativar", "conferir"]
    assert "worker_SEGREDO" not in r.text and "solumia.exemplo.com" not in r.text
    assert client.get("/worker").json()["antigo"] == "agent-worker"


def test_update_plan_runs_the_install_script(client: TestClient) -> None:
    r = client.post("/configurador/atualizar/plano")
    assert r.status_code == 200
    assert "empacotar_deb" in r.json()["passos"][0]["detalhe"]
