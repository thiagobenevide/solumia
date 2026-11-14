import hmac
import time
from typing import Annotated

from fastapi import Depends, Request

from backend.auth.security import read_generation, validate_token
from backend.core.config import Settings
from backend.core.errors import openai_error
from backend.core.worker_registry import WorkerRegistry


def get_settings(request: Request) -> Settings:
    """Settings of the current app (`app.state.settings`), not the process singleton.

    `create_app(settings=...)` allows instantiating the app with explicit
    Settings (used by the tests) — resolving through `request.app.state`
    makes sure those settings are really used by the endpoints, instead of
    the `backend.core.config.get_settings()` singleton cached from the
    process environment/.env.
    """
    settings: Settings = request.app.state.settings
    return settings


SettingsDep = Annotated[Settings, Depends(get_settings)]


def require_client_api_key(request: Request, settings: SettingsDep) -> None:
    """Requires `Authorization: Bearer <token>`: the app login session token (JWT) or one of the
    client keys in GATEWAY_CLIENT_API_KEYS (OpenAI-compatible tools on /v1).

    Fail-secure: with no key and no login configured, every request is denied. On success, the
    user goes into `request.state.usuario`.
    """
    auth_header = request.headers.get("authorization", "")
    if not auth_header.startswith("Bearer "):
        raise openai_error(
            401,
            "Cabeçalho Authorization ausente. Use: Authorization: Bearer <token>",
            "invalid_api_key",
        )
    token = auth_header.removeprefix("Bearer ").strip()
    payload = session_validates(token, settings)
    if payload is not None:
        request.state.usuario = payload["sub"]
        request.state.session = payload
        return
    # Compare with every key in constant time (no `in`, which stops at the first match).
    scope = None
    for key, esc in settings.client_api_key_scopes.items():
        if token and hmac.compare_digest(token.encode(), key.encode()):
            scope = esc
    if scope is not None and _scope_allows(scope, request.url.path):
        request.state.usuario = "api-key"
        request.state.session = None
        return
    raise openai_error(401, "Token inválido ou expirado.", "invalid_api_key")


# Routes of each key scope (`escopo:chave` in GATEWAY_CLIENT_API_KEYS).
SCOPES: dict[str, tuple[str, ...]] = {
    "relogio": (
        "/api/saude/",
        "/api/painel/disciplina",
        "/api/painel/agenda/",
        "/api/painel/voz",
        "/api/painel/falar",
        "/api/atualizacoes",
    ),
}


def _scope_allows(scope: str, caminho: str) -> bool:
    if not scope:
        return True  # key without a prefix: full access (as before)
    return any(caminho.startswith(p) for p in SCOPES.get(scope, ()))


def session_validates(token: str, settings: Settings) -> dict[str, object] | None:
    """Payload of the login session token: signature and validity ok, no scope (the media one does
    not open the API) and from a generation not revoked by "sign out of all devices"."""
    payload = validate_token(token, settings.jwt_secret_key.get_secret_value()) if token else None
    if payload is None or payload.get("esc"):
        return None
    generation = payload.get("ger", 0)
    if not isinstance(generation, int) or generation < read_generation(
        settings.sessoes_geracao_arquivo
    ):
        return None
    return payload


def require_totp_recent(request: Request, settings: SettingsDep) -> None:
    """For routes that run commands on the PC (Code module): besides the token, an Authenticator
    code typed within the last `codigo_totp_horas` (claim `totp` of the session token)."""
    session = getattr(request.state, "session", None)
    if not isinstance(session, dict):
        raise openai_error(403, "O Código só abre com o login do app.", "totp_required")
    totp = session.get("totp")
    confirmed = request.app.state.totp_confirmacoes.get(str(session.get("jti")), 0.0)
    last = max(totp if isinstance(totp, int) else 0, confirmed)
    if time.time() - last > settings.codigo_totp_horas * 3600:
        raise openai_error(
            403, "Digite o código do Authenticator para usar o Código.", "totp_required"
        )


def get_worker_registry(request: Request) -> WorkerRegistry:
    registry: WorkerRegistry = request.app.state.worker_registry
    return registry


WorkerRegistryDep = Annotated[WorkerRegistry, Depends(get_worker_registry)]
