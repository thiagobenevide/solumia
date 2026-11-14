import hmac
import logging
import threading
import time
from typing import Annotated
from urllib.parse import parse_qs, urlsplit

from fastapi import APIRouter, Depends, Request, Response
from pydantic import BaseModel, Field

from backend.api.deps import SettingsDep, require_client_api_key, session_validates
from backend.auth.security import (
    HASH_FICTITIOUS,
    issue_token,
    read_generation,
    upload_generation,
    validate_token,
    verify_password,
    verify_totp,
)
from backend.core.config import Settings
from backend.core.errors import openai_error

logger = logging.getLogger("gateway.auth")

router = APIRouter(prefix="/api/auth", tags=["auth"])


class Attempts:
    """Login failures per IP in a window; past the limit, the IP stays blocked until it closes."""

    def __init__(self) -> None:
        self._failures: dict[str, list[float]] = {}
        self._lock = threading.Lock()
        # Last accepted TOTP step: the same code does not work for a second login (replay).
        self.last_step_totp = -1

    def blocked_by(self, ip: str, maximum: int, window: float) -> float:
        """Seconds of block left (0 = unblocked)."""
        with self._lock:
            now = time.monotonic()
            failures = [t for t in self._failures.get(ip, []) if now - t < window]
            self._failures[ip] = failures
            return window - (now - failures[0]) if len(failures) >= maximum else 0

    def failed(self, ip: str) -> None:
        with self._lock:
            self._failures.setdefault(ip, []).append(time.monotonic())

    def clean(self, ip: str) -> None:
        with self._lock:
            self._failures.pop(ip, None)


def get_attempts(request: Request) -> Attempts:
    attempts: Attempts = request.app.state.tentativas_login
    return attempts


class Credentials(BaseModel):
    usuario: str = Field(min_length=1, max_length=64)
    senha: str = Field(min_length=1, max_length=256)
    codigo: str = Field(min_length=6, max_length=6, pattern=r"^\d{6}$")
    """Código de 6 dígitos do Google Authenticator."""

    lembrar: bool = False
    """Manter conectado: o token vale `jwt_lembrar_dias` em vez de `jwt_expire_minutes`."""


class Session(BaseModel):
    token: str
    tipo: str = "Bearer"
    expira_em: int
    usuario: str


@router.post("/login")
def login(
    credenciais: Credentials,
    request: Request,
    settings: SettingsDep,
    tentativas: Annotated[Attempts, Depends(get_attempts)],
) -> Session:
    if not settings.login_configurado:
        raise openai_error(503, "Login não configurado no servidor.", "auth_not_configured")

    ip = request.client.host if request.client else "?"
    window = settings.login_bloqueio_minutos * 60
    restante = tentativas.blocked_by(ip, settings.login_max_tentativas, window)
    if restante:
        raise openai_error(
            429,
            f"Muitas tentativas. Tente de novo em {int(restante // 60) + 1} min.",
            "too_many_attempts",
        )

    hash_password = settings.admin_senha_hash.get_secret_value()
    user_ok = hmac.compare_digest(credenciais.usuario.encode(), settings.admin_usuario.encode())
    # Check the password even with a wrong user so timing does not reveal whether the user exists.
    password_ok = verify_password(credenciais.senha, hash_password if user_ok else HASH_FICTITIOUS)
    step = verify_totp(settings.admin_totp_segredo.get_secret_value(), credenciais.codigo)
    totp_ok = step is not None and step > tentativas.last_step_totp
    if not (user_ok and password_ok and totp_ok):
        tentativas.failed(ip)
        logger.warning("Login recusado (ip=%s)", ip)
        raise openai_error(401, "Usuário, senha ou código inválidos.", "invalid_credentials")

    tentativas.last_step_totp = step or 0
    tentativas.clean(ip)
    logger.info("Login aceito (ip=%s)", ip)
    return _session(settings, credenciais.lembrar, int(time.time()))


def _session(settings: Settings, lembrar: bool, totp: int) -> Session:
    """Session token with the current generation, the "stay signed in" choice and the time of the
    last TOTP code (the Code module requires a recent one)."""
    minutes = settings.jwt_lembrar_dias * 24 * 60 if lembrar else settings.jwt_expire_minutes
    extras: dict[str, object] = {
        "ger": read_generation(settings.sessoes_geracao_arquivo),
        "lem": lembrar,
        "totp": totp,
    }
    token, expira = issue_token(
        settings.admin_usuario, settings.jwt_secret_key.get_secret_value(), minutes, extras
    )
    return Session(token=token, expira_em=expira, usuario=settings.admin_usuario)


def _session_of_request(request: Request) -> dict[str, object]:
    session = getattr(request.state, "session", None)
    if not isinstance(session, dict):
        raise openai_error(403, "Só com o login do app (não com chave).", "session_required")
    return session


@router.post("/renovar", dependencies=[Depends(require_client_api_key)])
def renew(request: Request, settings: SettingsDep) -> Session:
    """New token with the same "stay signed in" choice and the same last-code time: the app
    calls it on open and once a day, so the session does not expire while in use."""
    session = _session_of_request(request)
    lembrar = session.get("lem")
    if not isinstance(lembrar, bool):  # token from before renewal: infer from the validity
        duration = int(session["exp"]) - int(session["iat"])  # type: ignore[call-overload]
        lembrar = duration > settings.jwt_expire_minutes * 60
    totp = session.get("totp")
    return _session(settings, lembrar, totp if isinstance(totp, int) else 0)


class Code(BaseModel):
    codigo: str = Field(min_length=6, max_length=6, pattern=r"^\d{6}$")


@router.post("/confirmar", status_code=204, dependencies=[Depends(require_client_api_key)])
def confirm(
    corpo: Code,
    request: Request,
    settings: SettingsDep,
    tentativas: Annotated[Attempts, Depends(get_attempts)],
) -> Response:
    """Confirms an Authenticator code on the open session (Code requires a recent one). It is
    recorded on the server for this token (`jti`): the app keeps the same token, without
    reloading."""
    session = _session_of_request(request)
    ip = request.client.host if request.client else "?"
    window = settings.login_bloqueio_minutos * 60
    if tentativas.blocked_by(ip, settings.login_max_tentativas, window):
        raise openai_error(429, "Muitas tentativas. Tente mais tarde.", "too_many_attempts")
    step = verify_totp(settings.admin_totp_segredo.get_secret_value(), corpo.codigo)
    if step is None or step <= tentativas.last_step_totp:
        tentativas.failed(ip)
        raise openai_error(401, "Código inválido.", "invalid_code")
    tentativas.last_step_totp = step
    confirmacoes: dict[str, float] = request.app.state.totp_confirmacoes
    now = time.time()
    validity = settings.codigo_totp_horas * 3600
    for jti in [j for j, when in confirmacoes.items() if now - when > validity]:
        del confirmacoes[jti]
    confirmacoes[str(session.get("jti"))] = now
    return Response(status_code=204)


@router.post("/sair-de-todos", status_code=204, dependencies=[Depends(require_client_api_key)])
def leave_of_all(request: Request, settings: SettingsDep) -> Response:
    """Invalidates every session (every device, this one included): log in again on each one."""
    _session_of_request(request)
    generation = upload_generation(settings.sessoes_geracao_arquivo)
    logger.warning("Sessões revogadas (geração %s)", generation)
    return Response(status_code=204)


class TokenMedia(BaseModel):
    token: str
    expira_em: int


@router.post("/token-midia", dependencies=[Depends(require_client_api_key)])
def token_media(request: Request, settings: SettingsDep) -> TokenMedia:
    """Short token for the `?token=` of the pipeline file URLs (image, video, PDF): valid only on
    `/esteira/` and never on the API, so a leaked URL does not open the rest."""
    session = _session_of_request(request)
    token, expira = issue_token(
        str(session["sub"]),
        settings.jwt_secret_key.get_secret_value(),
        settings.jwt_midia_horas * 60,
        {"esc": "midia", "ger": read_generation(settings.sessoes_geracao_arquivo)},
    )
    return TokenMedia(token=token, expira_em=expira)


@router.get("/sessao", dependencies=[Depends(require_client_api_key)])
def session(request: Request) -> dict[str, str]:
    """Checks whether the token is still valid (the app uses it on open)."""
    return {"usuario": request.state.usuario}


@router.get("/verificar", status_code=204)
def verify(request: Request, settings: SettingsDep) -> Response:
    """nginx `auth_request` subrequest before forwarding `/esteira/` to the PC tunnel.

    Accepts the session token in the header or in `?token=` of the original URI
    (`X-Original-URI`): images, videos and PDFs opened by URL send no header. Only the login JWT
    is valid here.
    """
    token = request.headers.get("authorization", "").removeprefix("Bearer ").strip()
    if not token:
        query = urlsplit(request.headers.get("x-original-uri", "")).query
        token = parse_qs(query).get("token", [""])[0]
    if not token or not _applies_in_esteira(token, settings):
        raise openai_error(401, "Token inválido ou expirado.", "invalid_api_key")
    return Response(status_code=204)


def _applies_in_esteira(token: str, settings: Settings) -> bool:
    """Login session or media token, both from a non-revoked generation."""

    if session_validates(token, settings) is not None:
        return True
    payload = validate_token(token, settings.jwt_secret_key.get_secret_value())
    generation = payload.get("ger", 0) if payload else -1
    return (
        payload is not None
        and payload.get("esc") == "midia"
        and isinstance(generation, int)
        and generation >= read_generation(settings.sessoes_geracao_arquivo)
    )
