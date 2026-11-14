import hmac
import time
from typing import Annotated

from fastapi import Depends, Request

from backend.auth.security import read_generation, validate_token
from backend.core.config import Settings
from backend.core.errors import openai_error
from backend.core.worker_registry import WorkerRegistry


def get_settings(request: Request) -> Settings:
    """Settings do app atual (`app.state.settings`), não o singleton de processo.

    `create_app(settings=...)` permite instanciar o app com Settings
    explícitas (usado pelos testes) — resolver via `request.app.state`
    garante que essas settings sejam realmente usadas pelos endpoints, em
    vez do singleton `gateway.core.config.get_settings()` cacheado a partir
    do ambiente/.env do processo.
    """
    settings: Settings = request.app.state.settings
    return settings


SettingsDep = Annotated[Settings, Depends(get_settings)]


def require_client_api_key(request: Request, settings: SettingsDep) -> None:
    """Exige `Authorization: Bearer <token>`: o token de sessão do login do app (JWT) ou uma das
    chaves de cliente de GATEWAY_CLIENT_API_KEYS (ferramentas OpenAI-compatible em /v1).

    Fail-secure: sem chave nem login configurados, todo pedido é negado. Em sucesso, o usuário
    fica em `request.state.usuario`.
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
        request.state.sessao = payload
        return
    # Compara com todas as chaves em tempo constante (sem `in`, que para no primeiro acerto).
    scope = None
    for key, esc in settings.client_api_key_escopos.items():
        if token and hmac.compare_digest(token.encode(), key.encode()):
            scope = esc
    if scope is not None and _scope_allows(scope, request.url.path):
        request.state.usuario = "api-key"
        request.state.sessao = None
        return
    raise openai_error(401, "Token inválido ou expirado.", "invalid_api_key")


# Rotas de cada escopo de chave (`escopo:chave` em GATEWAY_CLIENT_API_KEYS).
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
        return True  # chave sem prefixo: acesso completo (como antes)
    return any(caminho.startswith(p) for p in SCOPES.get(scope, ()))


def session_validates(token: str, settings: Settings) -> dict[str, object] | None:
    """Payload do token de sessão do login: assinatura e validade ok, sem escopo (o de mídia não
    abre a API) e de geração não revogada por "sair de todos os aparelhos"."""
    payload = validate_token(token, settings.jwt_secret_key.get_secret_value()) if token else None
    if payload is None or payload.get("esc"):
        return None
    generation = payload.get("ger", 0)
    if not isinstance(generation, int) or generation < read_generation(settings.sessoes_geracao_arquivo):
        return None
    return payload


def require_totp_recent(request: Request, settings: SettingsDep) -> None:
    """Para rotas que executam comandos no PC (módulo Código): além do token, um código do
    Authenticator digitado nas últimas `codigo_totp_horas` (claim `totp` do token de sessão)."""
    session = getattr(request.state, "sessao", None)
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
