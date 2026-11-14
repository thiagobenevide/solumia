import time

import pytest
from fastapi.testclient import TestClient

from backend.auth.security import (
    code_totp,
    issue_token,
    generate_hash_password,
    generate_secret_totp,
)
from backend.core.config import Settings
from backend.main import create_app

SENHA = "senha-forte-de-teste"
SEGREDO_JWT = "x" * 40
TOTP = generate_secret_totp()
HASH = generate_hash_password(SENHA)


def _codigo() -> str:
    return code_totp(TOTP, int(time.time() // 30))


@pytest.fixture
def cliente(tmp_path) -> TestClient:  # type: ignore[no-untyped-def]
    settings = Settings(
        sessoes_geracao_arquivo=str(tmp_path / "geracao"),
        environment="development",
        client_api_keys="chave-cli,relogio:chave-relogio",
        jwt_secret_key=SEGREDO_JWT,
        admin_usuario="eu",
        admin_senha_hash=HASH,
        admin_totp_segredo=TOTP,
        login_max_tentativas=3,
    )
    return TestClient(create_app(settings=settings))


def _login(c: TestClient, senha: str = SENHA, codigo: str | None = None, usuario: str = "eu"):
    body = {"usuario": usuario, "senha": senha, "codigo": codigo or _codigo()}
    return c.post("/api/auth/login", json=body)


def test_login_com_senha_e_codigo_libera_as_rotas(cliente: TestClient) -> None:
    r = _login(cliente)
    assert r.status_code == 200
    token = r.json()["token"]
    header = {"Authorization": f"Bearer {token}"}
    assert cliente.get("/api/auth/sessao", headers=header).json() == {"usuario": "eu"}


@pytest.mark.parametrize(
    ("usuario", "senha", "codigo"),
    [("eu", "errada", None), ("outro", SENHA, None), ("eu", SENHA, "000000")],
)
def test_login_recusa_qualquer_fator_errado(
    cliente: TestClient, usuario: str, senha: str, codigo: str | None
) -> None:
    if codigo == _codigo():
        codigo = "111111"
    assert _login(cliente, senha, codigo, usuario).status_code == 401


def test_mesmo_codigo_nao_serve_duas_vezes(cliente: TestClient) -> None:
    code = _codigo()
    assert _login(cliente, codigo=code).status_code == 200
    assert _login(cliente, codigo=code).status_code == 401


def test_bloqueia_depois_de_muitas_falhas(cliente: TestClient) -> None:
    for _ in range(3):
        assert _login(cliente, "errada").status_code == 401
    assert _login(cliente).status_code == 429


def test_rotas_exigem_token_valido(cliente: TestClient) -> None:
    assert cliente.get("/api/auth/sessao").status_code == 401
    lixo = {"Authorization": "Bearer lixo"}
    assert cliente.get("/api/auth/sessao", headers=lixo).status_code == 401
    vencido, _ = issue_token("eu", SEGREDO_JWT, -1)
    header = {"Authorization": f"Bearer {vencido}"}
    assert cliente.get("/api/auth/sessao", headers=header).status_code == 401
    falso, _ = issue_token("eu", "y" * 40, 10)
    header = {"Authorization": f"Bearer {falso}"}
    assert cliente.get("/api/auth/sessao", headers=header).status_code == 401


def test_chave_de_cliente_continua_valendo(cliente: TestClient) -> None:
    r = cliente.get("/api/auth/sessao", headers={"Authorization": "Bearer chave-cli"})
    assert r.status_code == 200


def test_login_desligado_sem_configuracao() -> None:
    c = TestClient(create_app(settings=Settings(environment="development")))
    assert _login(c).status_code == 503


def test_cabecalhos_de_seguranca(cliente: TestClient) -> None:
    r = cliente.get("/health")
    assert r.headers["X-Content-Type-Options"] == "nosniff"
    assert r.headers["X-Frame-Options"] == "DENY"
    assert _login(cliente).headers["Cache-Control"] == "no-store"


def test_verificar_aceita_jwt_no_cabecalho_ou_na_uri(cliente: TestClient) -> None:
    token = _login(cliente).json()["token"]

    def status(**cab: str) -> int:
        return cliente.get("/api/auth/verificar", headers=cab).status_code

    assert status(Authorization=f"Bearer {token}") == 204
    assert status(**{"X-Original-URI": f"/esteira/arquivos/v.mp4?token={token}"}) == 204
    assert status() == 401
    assert status(**{"X-Original-URI": "/esteira/?token=x"}) == 401
    # A chave de cliente (/v1) não abre a esteira.
    assert status(Authorization="Bearer chave-cli") == 401


def test_manter_conectado_estende_a_sessao(cliente: TestClient) -> None:
    body = {"usuario": "eu", "senha": SENHA, "codigo": _codigo(), "lembrar": True}
    r = cliente.post("/api/auth/login", json=body)
    assert r.status_code == 200
    # 30 dias (renovados com o uso), contra as 12 h do login comum
    assert r.json()["expira_em"] - time.time() > 29 * 24 * 3600


def _cab(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def test_renovar_mantem_lembrar_e_hora_do_codigo(cliente: TestClient) -> None:
    body = {"usuario": "eu", "senha": SENHA, "codigo": _codigo(), "lembrar": True}
    token = cliente.post("/api/auth/login", json=body).json()["token"]
    r = cliente.post("/api/auth/renovar", headers=_cab(token))
    assert r.status_code == 200
    assert r.json()["expira_em"] - time.time() > 29 * 24 * 3600
    # Chave de cliente não renova (não é sessão).
    assert cliente.post("/api/auth/renovar", headers=_cab("chave-cli")).status_code == 403


def test_renovar_aceita_token_antigo_sem_claims_novas(cliente: TestClient) -> None:
    old, _ = issue_token("eu", SEGREDO_JWT, 90 * 24 * 60)
    assert cliente.get("/api/auth/sessao", headers=_cab(old)).status_code == 200
    r = cliente.post("/api/auth/renovar", headers=_cab(old))
    assert r.status_code == 200 and r.json()["expira_em"] - time.time() > 29 * 24 * 3600


def test_sair_de_todos_invalida_as_sessoes(cliente: TestClient) -> None:
    token = _login(cliente).json()["token"]
    old, _ = issue_token("eu", SEGREDO_JWT, 60)
    assert cliente.post("/api/auth/sair-de-todos", headers=_cab(token)).status_code == 204
    for t in (token, old):
        assert cliente.get("/api/auth/sessao", headers=_cab(t)).status_code == 401
    # Token emitido depois (geração nova) volta a valer.
    new, _ = issue_token("eu", SEGREDO_JWT, 60, {"ger": 1})
    assert cliente.get("/api/auth/sessao", headers=_cab(new)).status_code == 200


def test_token_de_midia_so_vale_na_esteira(cliente: TestClient) -> None:
    token = _login(cliente).json()["token"]
    media = cliente.post("/api/auth/token-midia", headers=_cab(token)).json()["token"]
    assert cliente.get("/api/auth/sessao", headers=_cab(media)).status_code == 401
    header = {"X-Original-URI": f"/esteira/arquivo.mp4?token={media}"}
    assert cliente.get("/api/auth/verificar", headers=header).status_code == 204
    lixo = {"X-Original-URI": "/x?token=lixo"}
    assert cliente.get("/api/auth/verificar", headers=lixo).status_code == 401


def test_chave_de_escopo_relogio_so_abre_as_rotas_do_relogio(cliente: TestClient) -> None:
    header = _cab("chave-relogio")
    assert cliente.get("/api/saude/sessoes/ativa", headers=header).status_code != 401
    assert cliente.get("/api/notas", headers=header).status_code == 401
    assert cliente.get("/api/notas", headers=_cab("chave-cli")).status_code != 401


def test_codigo_pede_codigo_recente_e_aceita_depois_de_confirmar(cliente: TestClient) -> None:
    velho, _ = issue_token("eu", SEGREDO_JWT, 60, {"totp": int(time.time()) - 13 * 3600})
    r = cliente.get("/api/codigo/sessoes", headers=_cab(velho))
    assert r.status_code == 403 and r.json()["error"]["type"] == "totp_required"
    errado = cliente.post("/api/auth/confirmar", json={"codigo": "000000"}, headers=_cab(velho))
    assert errado.status_code == 401
    ok = cliente.post("/api/auth/confirmar", json={"codigo": _codigo()}, headers=_cab(velho))
    assert ok.status_code == 204
    assert cliente.get("/api/codigo/sessoes", headers=_cab(velho)).status_code != 403
