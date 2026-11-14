from __future__ import annotations

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from solumia_configurador import secret_store
from solumia_configurador.api import State, create_app
from solumia_configurador.platform_setup import System
from solumia_configurador.vault import Vault

PORTA = 54321
TOKEN = "t" * 43


@pytest.fixture
def client(tmp_path: Path, vault: Vault) -> TestClient:
    state = State(tmp_path / "solumia.toml", vault, System("linux", "x86_64"))
    c = TestClient(create_app(state, TOKEN, PORTA), base_url=f"http://127.0.0.1:{PORTA}")
    c.headers["Authorization"] = f"Bearer {TOKEN}"
    c.state = state  # type: ignore[attr-defined]
    return c


def test_requires_token(client: TestClient) -> None:
    assert client.get("/saude").status_code == 200
    assert client.get("/saude", headers={"Authorization": "Bearer errado"}).status_code == 401
    assert client.get("/saude", headers={"Authorization": ""}).status_code == 401


def test_blocks_dns_rebinding_and_browser(client: TestClient) -> None:
    assert client.get("/saude", headers={"Host": "evil.example.com"}).status_code == 421
    assert client.get("/saude", headers={"Host": "127.0.0.1:1"}).status_code == 421
    assert client.get("/saude", headers={"Origin": "https://evil.example.com"}).status_code == 403


def test_account_never_returns_hash_and_totp_only_once(client: TestClient) -> None:
    weak = client.post("/conta", json={"usuario": "dono", "senha": "123"})
    assert weak.status_code == 422
    r = client.post("/conta", json={"usuario": "dono", "senha": "SenhaForte123"}).json()
    assert r["totp_novo"] and r["totp_uri"].startswith("otpauth://totp/Solumia:dono")
    r2 = client.post("/conta", json={"usuario": "dono", "senha": "OutraSenha456"}).json()
    assert "totp_uri" not in r2
    body = client.get("/cofre").text + client.get("/manifesto").text
    assert "scrypt$" not in body
    assert set(client.get("/cofre").json()["segredos"]) == {secret_store.PASSWORD_HASH, secret_store.TOTP}


def test_apply_requires_shown_hash(client: TestClient) -> None:
    client.put("/manifesto", json={"nos": {"casa": {"papeis": ["gateway"],
                                                      "pastas": {"imagens": "/tmp/s/i", "videos": "/tmp/s/v",
                                                                 "audio": "/tmp/s/a", "producao": "/tmp/s/p",
                                                                 "produzidos": "/tmp/s/o"}}}})
    plan = client.post("/pastas/casa/plano").json()
    assert client.post(f"/planos/{plan['id']}/aplicar", json={"hash": "outro"}).status_code == 409
    # o plano é consumido na 1ª tentativa: precisa gerar de novo
    assert client.post(f"/planos/{plan['id']}/aplicar", json={"hash": plan["hash"]}).status_code == 404


def test_vps_without_confirmed_fingerprint_refused(client: TestClient) -> None:
    client.put("/manifesto", json={
        "topologia": {"tipo": "nuvem", "dominio": "solumia.exemplo.com", "email_tls": "a@b.com"},
        "nos": {"vps": {"endereco": "ssh", "ssh": {"host": "203.0.113.5"}, "papeis": ["gateway", "worker"]}}})
    client.post("/conta", json={"usuario": "dono", "senha": "SenhaForte123"})
    r = client.post("/vps/plano", json={"senha": "x"})
    assert r.status_code == 422 and "impressão digital" in r.json()["detail"]


def test_vps_full_plan_without_leaking_password(client: TestClient) -> None:
    client.put("/manifesto", json={
        "topologia": {"tipo": "nuvem", "dominio": "solumia.exemplo.com", "email_tls": "a@b.com"},
        "nos": {"vps": {"endereco": "ssh", "ssh": {"host": "203.0.113.5", "impressao_host": "SHA256:abc"},
                        "papeis": ["gateway", "worker"]}}})
    client.post("/conta", json={"usuario": "dono", "senha": "SenhaForte123"})
    r = client.post("/vps/plano", json={"senha": "SenhaDaVPS-999"})
    assert r.status_code == 200
    ids = [p["id"] for p in r.json()["passos"]]
    assert ids[:3] == ["conectar", "sistema", "chave"] and ids[-2:] == ["endurecer", "conferir"]
    assert "SenhaDaVPS" not in r.text


def test_craft_apps_lists_links(client: TestClient) -> None:
    apps = {a["id"]: a for a in client.get("/craft-apps").json()["apps"]}
    assert apps["filmcraft"]["github"] == "https://github.com/storytold/filmcraft"
    assert client.post("/craft-apps/naoexiste/plano", json={}).status_code == 404
