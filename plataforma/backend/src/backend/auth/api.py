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
    """Falhas de login por IP numa janela; passou do limite, o IP fica bloqueado até ela fechar."""

    def __init__(self) -> None:
        self._falhas: dict[str, list[float]] = {}
        self._trava = threading.Lock()
        # Último passo TOTP aceito: o mesmo código não serve para um segundo login (replay).
        self.ultimo_passo_totp = -1

    def bloqueado_por(self, ip: str, maximum: int, window: float) -> float:
        """Segundos restantes de bloqueio (0 = liberado)."""
        with self._trava:
            now = time.monotonic()
            failures = [t for t in self._falhas.get(ip, []) if now - t < window]
            self._falhas[ip] = failures
            return window - (now - failures[0]) if len(failures) >= maximum else 0

    def falhou(self, ip: str) -> None:
        with self._trava:
            self._falhas.setdefault(ip, []).append(time.monotonic())

    def limpar(self, ip: str) -> None:
        with self._trava:
            self._falhas.pop(ip, None)


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
    restante = tentativas.bloqueado_por(ip, settings.login_max_tentativas, window)
    if restante:
        raise openai_error(
            429,
            f"Muitas tentativas. Tente de novo em {int(restante // 60) + 1} min.",
            "too_many_attempts",
        )

    hash_password = settings.admin_senha_hash.get_secret_value()
    user_ok = hmac.compare_digest(credenciais.usuario.encode(), settings.admin_usuario.encode())
    # Verifica a senha mesmo com usuário errado para não revelar, pelo tempo, se o usuário existe.
    password_ok = verify_password(credenciais.senha, hash_password if user_ok else HASH_FICTITIOUS)
    step = verify_totp(settings.admin_totp_segredo.get_secret_value(), credenciais.codigo)
    totp_ok = step is not None and step > tentativas.ultimo_passo_totp
    if not (user_ok and password_ok and totp_ok):
        tentativas.falhou(ip)
        logger.warning("Login recusado (ip=%s)", ip)
        raise openai_error(401, "Usuário, senha ou código inválidos.", "invalid_credentials")

    tentativas.ultimo_passo_totp = step or 0
    tentativas.limpar(ip)
    logger.info("Login aceito (ip=%s)", ip)
    return _session(settings, credenciais.lembrar, int(time.time()))


def _session(settings: Settings, lembrar: bool, totp: int) -> Session:
    """Token de sessão com a geração atual, o "manter conectado" e a hora do último código TOTP
    (o módulo Código exige um recente)."""
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
    session = getattr(request.state, "sessao", None)
    if not isinstance(session, dict):
        raise openai_error(403, "Só com o login do app (não com chave).", "session_required")
    return session


@router.post("/renovar", dependencies=[Depends(require_client_api_key)])
def renew(request: Request, settings: SettingsDep) -> Session:
    """Token novo com a mesma escolha de "manter conectado" e a mesma hora do último código: o
    app chama ao abrir e uma vez por dia, então a sessão não vence enquanto é usada."""
    session = _session_of_request(request)
    lembrar = session.get("lem")
    if not isinstance(lembrar, bool):  # token de antes da renovação: deduz pela validade
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
    """Confirma um código do Authenticator na sessão aberta (o Código pede um recente). Fica
    anotado no servidor para este token (`jti`): o app segue com o mesmo token, sem recarregar."""
    session = _session_of_request(request)
    ip = request.client.host if request.client else "?"
    window = settings.login_bloqueio_minutos * 60
    if tentativas.bloqueado_por(ip, settings.login_max_tentativas, window):
        raise openai_error(429, "Muitas tentativas. Tente mais tarde.", "too_many_attempts")
    step = verify_totp(settings.admin_totp_segredo.get_secret_value(), corpo.codigo)
    if step is None or step <= tentativas.ultimo_passo_totp:
        tentativas.falhou(ip)
        raise openai_error(401, "Código inválido.", "invalid_code")
    tentativas.ultimo_passo_totp = step
    confirmacoes: dict[str, float] = request.app.state.totp_confirmacoes
    now = time.time()
    validity = settings.codigo_totp_horas * 3600
    for jti in [j for j, when in confirmacoes.items() if now - when > validity]:
        del confirmacoes[jti]
    confirmacoes[str(session.get("jti"))] = now
    return Response(status_code=204)


@router.post("/sair-de-todos", status_code=204, dependencies=[Depends(require_client_api_key)])
def leave_of_all(request: Request, settings: SettingsDep) -> Response:
    """Invalida todas as sessões (todos os aparelhos, este incluído): login de novo em cada um."""
    _session_of_request(request)
    generation = upload_generation(settings.sessoes_geracao_arquivo)
    logger.warning("Sessões revogadas (geração %s)", generation)
    return Response(status_code=204)


class TokenMedia(BaseModel):
    token: str
    expira_em: int


@router.post("/token-midia", dependencies=[Depends(require_client_api_key)])
def token_media(request: Request, settings: SettingsDep) -> TokenMedia:
    """Token curto para o `?token=` das URLs de arquivo da esteira (imagem, vídeo, PDF): vale só
    em `/esteira/` e nunca na API, então uma URL vazada não abre o resto."""
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
    """Confere se o token ainda vale (o app usa ao abrir)."""
    return {"usuario": request.state.usuario}


@router.get("/verificar", status_code=204)
def verify(request: Request, settings: SettingsDep) -> Response:
    """Subpedido `auth_request` do nginx antes de repassar `/esteira/` ao túnel do PC.

    Aceita o token de sessão no cabeçalho ou em `?token=` da URI original (`X-Original-URI`):
    imagem, vídeo e PDF abertos por URL não mandam cabeçalho. Só o JWT do login vale aqui.
    """
    token = request.headers.get("authorization", "").removeprefix("Bearer ").strip()
    if not token:
        query = urlsplit(request.headers.get("x-original-uri", "")).query
        token = parse_qs(query).get("token", [""])[0]
    if not token or not _applies_in_esteira(token, settings):
        raise openai_error(401, "Token inválido ou expirado.", "invalid_api_key")
    return Response(status_code=204)


def _applies_in_esteira(token: str, settings: Settings) -> bool:
    """Sessão do login ou token de mídia, ambos de geração não revogada."""
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
