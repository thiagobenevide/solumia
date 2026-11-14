from __future__ import annotations

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from solumia_configurador import segredos
from solumia_configurador.api import Estado, criar_app
from solumia_configurador.cofre import Cofre
from solumia_configurador.plataforma import Sistema

PORTA = 54321
TOKEN = "t" * 43


@pytest.fixture
def cliente(tmp_path: Path, cofre: Cofre) -> TestClient:
    estado = Estado(tmp_path / "solumia.toml", cofre, Sistema("linux", "x86_64"))
    c = TestClient(criar_app(estado, TOKEN, PORTA), base_url=f"http://127.0.0.1:{PORTA}")
    c.headers["Authorization"] = f"Bearer {TOKEN}"
    c.estado = estado  # type: ignore[attr-defined]
    return c


def test_exige_token(cliente: TestClient) -> None:
    assert cliente.get("/saude").status_code == 200
    assert cliente.get("/saude", headers={"Authorization": "Bearer errado"}).status_code == 401
    assert cliente.get("/saude", headers={"Authorization": ""}).status_code == 401


def test_bloqueia_dns_rebinding_e_navegador(cliente: TestClient) -> None:
    assert cliente.get("/saude", headers={"Host": "evil.example.com"}).status_code == 421
    assert cliente.get("/saude", headers={"Host": "127.0.0.1:1"}).status_code == 421
    assert cliente.get("/saude", headers={"Origin": "https://evil.example.com"}).status_code == 403


def test_conta_nunca_devolve_hash_e_totp_so_uma_vez(cliente: TestClient) -> None:
    fraca = cliente.post("/conta", json={"usuario": "dono", "senha": "123"})
    assert fraca.status_code == 422
    r = cliente.post("/conta", json={"usuario": "dono", "senha": "SenhaForte123"}).json()
    assert r["totp_novo"] and r["totp_uri"].startswith("otpauth://totp/Solumia:dono")
    r2 = cliente.post("/conta", json={"usuario": "dono", "senha": "OutraSenha456"}).json()
    assert "totp_uri" not in r2
    corpo = cliente.get("/cofre").text + cliente.get("/manifesto").text
    assert "scrypt$" not in corpo
    assert set(cliente.get("/cofre").json()["segredos"]) == {segredos.SENHA_HASH, segredos.TOTP}


def test_aplicar_exige_hash_mostrado(cliente: TestClient) -> None:
    cliente.put("/manifesto", json={"nos": {"casa": {"papeis": ["gateway"],
                                                      "pastas": {"imagens": "/tmp/s/i", "videos": "/tmp/s/v",
                                                                 "audio": "/tmp/s/a", "producao": "/tmp/s/p",
                                                                 "produzidos": "/tmp/s/o"}}}})
    plano = cliente.post("/pastas/casa/plano").json()
    assert cliente.post(f"/planos/{plano['id']}/aplicar", json={"hash": "outro"}).status_code == 409
    # o plano é consumido na 1ª tentativa: precisa gerar de novo
    assert cliente.post(f"/planos/{plano['id']}/aplicar", json={"hash": plano["hash"]}).status_code == 404


def test_vps_sem_impressao_confirmada_recusa(cliente: TestClient) -> None:
    cliente.put("/manifesto", json={
        "topologia": {"tipo": "nuvem", "dominio": "solumia.exemplo.com", "email_tls": "a@b.com"},
        "nos": {"vps": {"endereco": "ssh", "ssh": {"host": "203.0.113.5"}, "papeis": ["gateway", "worker"]}}})
    cliente.post("/conta", json={"usuario": "dono", "senha": "SenhaForte123"})
    r = cliente.post("/vps/plano", json={"senha": "x"})
    assert r.status_code == 422 and "impressão digital" in r.json()["detail"]


def test_vps_plano_completo_sem_vazar_senha(cliente: TestClient) -> None:
    cliente.put("/manifesto", json={
        "topologia": {"tipo": "nuvem", "dominio": "solumia.exemplo.com", "email_tls": "a@b.com"},
        "nos": {"vps": {"endereco": "ssh", "ssh": {"host": "203.0.113.5", "impressao_host": "SHA256:abc"},
                        "papeis": ["gateway", "worker"]}}})
    cliente.post("/conta", json={"usuario": "dono", "senha": "SenhaForte123"})
    r = cliente.post("/vps/plano", json={"senha": "SenhaDaVPS-999"})
    assert r.status_code == 200
    ids = [p["id"] for p in r.json()["passos"]]
    assert ids[:3] == ["conectar", "sistema", "chave"] and ids[-2:] == ["endurecer", "conferir"]
    assert "SenhaDaVPS" not in r.text


def test_craft_apps_lista_links(cliente: TestClient) -> None:
    apps = {a["id"]: a for a in cliente.get("/craft-apps").json()["apps"]}
    assert apps["filmcraft"]["github"] == "https://github.com/storytold/filmcraft"
    assert cliente.post("/craft-apps/naoexiste/plano", json={}).status_code == 404
