import time

import pytest
from fastapi.testclient import TestClient

from backend.auth.security import (
    code_totp,
    generate_hash_password,
    generate_secret_totp,
    issue_token,
)
from backend.core.config import Settings
from backend.main import create_app

SENHA = "senha-forte-de-teste"
SEGREDO_JWT = "x" * 40
TOTP = generate_secret_totp()
HASH = generate_hash_password(SENHA)


def _code() -> str:
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
    body = {"usuario": usuario, "senha": senha, "codigo": codigo or _code()}
    return c.post("/api/auth/login", json=body)


def test_login_with_password_and_code_opens_routes(cliente: TestClient) -> None:
    r = _login(cliente)
    assert r.status_code == 200
    token = r.json()["token"]
    header = {"Authorization": f"Bearer {token}"}
    assert cliente.get("/api/auth/sessao", headers=header).json() == {"usuario": "eu"}


@pytest.mark.parametrize(
    ("usuario", "senha", "codigo"),
    [("eu", "errada", None), ("outro", SENHA, None), ("eu", SENHA, "000000")],
)
def test_login_refuses_any_wrong_factor(
    cliente: TestClient, usuario: str, senha: str, codigo: str | None
) -> None:
    if codigo == _code():
        codigo = "111111"
    assert _login(cliente, senha, codigo, usuario).status_code == 401


def test_same_code_does_not_work_twice(cliente: TestClient) -> None:
    code = _code()
    assert _login(cliente, codigo=code).status_code == 200
    assert _login(cliente, codigo=code).status_code == 401


def test_blocks_after_many_failures(cliente: TestClient) -> None:
    for _ in range(3):
        assert _login(cliente, "errada").status_code == 401
    assert _login(cliente).status_code == 429


def test_routes_require_valid_token(cliente: TestClient) -> None:
    assert cliente.get("/api/auth/sessao").status_code == 401
    lixo = {"Authorization": "Bearer lixo"}
    assert cliente.get("/api/auth/sessao", headers=lixo).status_code == 401
    vencido, _ = issue_token("eu", SEGREDO_JWT, -1)
    header = {"Authorization": f"Bearer {vencido}"}
    assert cliente.get("/api/auth/sessao", headers=header).status_code == 401
    falso, _ = issue_token("eu", "y" * 40, 10)
    header = {"Authorization": f"Bearer {falso}"}
    assert cliente.get("/api/auth/sessao", headers=header).status_code == 401


def test_client_key_still_valid(cliente: TestClient) -> None:
    r = cliente.get("/api/auth/sessao", headers={"Authorization": "Bearer chave-cli"})
    assert r.status_code == 200


def test_login_off_without_configuration() -> None:
    c = TestClient(create_app(settings=Settings(environment="development")))
    assert _login(c).status_code == 503


def test_security_headers(cliente: TestClient) -> None:
    r = cliente.get("/health")
    assert r.headers["X-Content-Type-Options"] == "nosniff"
    assert r.headers["X-Frame-Options"] == "DENY"
    assert _login(cliente).headers["Cache-Control"] == "no-store"


def test_verify_accepts_jwt_in_header_or_uri(cliente: TestClient) -> None:
    token = _login(cliente).json()["token"]

    def status(**cab: str) -> int:
        return cliente.get("/api/auth/verificar", headers=cab).status_code

    assert status(Authorization=f"Bearer {token}") == 204
    assert status(**{"X-Original-URI": f"/esteira/arquivos/v.mp4?token={token}"}) == 204
    assert status() == 401
    assert status(**{"X-Original-URI": "/esteira/?token=x"}) == 401
    # The client key (/v1) does not open the pipeline.
    assert status(Authorization="Bearer chave-cli") == 401


def test_stay_signed_in_extends_session(cliente: TestClient) -> None:
    body = {"usuario": "eu", "senha": SENHA, "codigo": _code(), "lembrar": True}
    r = cliente.post("/api/auth/login", json=body)
    assert r.status_code == 200
    # 30 days (renewed with use), against the 12 h of a regular login
    assert r.json()["expira_em"] - time.time() > 29 * 24 * 3600


def _header(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def test_renew_keeps_remember_and_code_time(cliente: TestClient) -> None:
    body = {"usuario": "eu", "senha": SENHA, "codigo": _code(), "lembrar": True}
    token = cliente.post("/api/auth/login", json=body).json()["token"]
    r = cliente.post("/api/auth/renovar", headers=_header(token))
    assert r.status_code == 200
    assert r.json()["expira_em"] - time.time() > 29 * 24 * 3600
    # A client key does not renew (it is not a session).
    assert cliente.post("/api/auth/renovar", headers=_header("chave-cli")).status_code == 403


def test_renew_accepts_old_token_without_new_claims(cliente: TestClient) -> None:
    old, _ = issue_token("eu", SEGREDO_JWT, 90 * 24 * 60)
    assert cliente.get("/api/auth/sessao", headers=_header(old)).status_code == 200
    r = cliente.post("/api/auth/renovar", headers=_header(old))
    assert r.status_code == 200 and r.json()["expira_em"] - time.time() > 29 * 24 * 3600


def test_sign_out_everywhere_invalidates_sessions(cliente: TestClient) -> None:
    token = _login(cliente).json()["token"]
    old, _ = issue_token("eu", SEGREDO_JWT, 60)
    assert cliente.post("/api/auth/sair-de-todos", headers=_header(token)).status_code == 204
    for t in (token, old):
        assert cliente.get("/api/auth/sessao", headers=_header(t)).status_code == 401
    # A token issued later (new generation) is valid again.
    new, _ = issue_token("eu", SEGREDO_JWT, 60, {"ger": 1})
    assert cliente.get("/api/auth/sessao", headers=_header(new)).status_code == 200


def test_media_token_only_valid_on_pipeline(cliente: TestClient) -> None:
    token = _login(cliente).json()["token"]
    media = cliente.post("/api/auth/token-midia", headers=_header(token)).json()["token"]
    assert cliente.get("/api/auth/sessao", headers=_header(media)).status_code == 401
    header = {"X-Original-URI": f"/esteira/arquivo.mp4?token={media}"}
    assert cliente.get("/api/auth/verificar", headers=header).status_code == 204
    lixo = {"X-Original-URI": "/x?token=lixo"}
    assert cliente.get("/api/auth/verificar", headers=lixo).status_code == 401


def test_watch_scope_key_only_opens_watch_routes(cliente: TestClient) -> None:
    header = _header("chave-relogio")
    assert cliente.get("/api/saude/sessoes/ativa", headers=header).status_code != 401
    assert cliente.get("/api/notas", headers=header).status_code == 401
    assert cliente.get("/api/notas", headers=_header("chave-cli")).status_code != 401


def test_code_requires_recent_code_and_accepts_after_confirm(cliente: TestClient) -> None:
    velho, _ = issue_token("eu", SEGREDO_JWT, 60, {"totp": int(time.time()) - 13 * 3600})
    r = cliente.get("/api/codigo/sessoes", headers=_header(velho))
    assert r.status_code == 403 and r.json()["error"]["type"] == "totp_required"
    errado = cliente.post("/api/auth/confirmar", json={"codigo": "000000"}, headers=_header(velho))
    assert errado.status_code == 401
    ok = cliente.post("/api/auth/confirmar", json={"codigo": _code()}, headers=_header(velho))
    assert ok.status_code == 204
    assert cliente.get("/api/codigo/sessoes", headers=_header(velho)).status_code != 403
