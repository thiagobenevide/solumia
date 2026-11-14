import hmac
import logging
import threading
import time
from typing import Annotated
from urllib.parse import parse_qs, urlsplit

from fastapi import APIRouter, Depends, Request, Response
from pydantic import BaseModel, Field

from backend.api.deps import SettingsDep, require_client_api_key, sessao_valida
from backend.auth.seguranca import (
    HASH_FICTICIO,
    emitir_token,
    ler_geracao,
    subir_geracao,
    validar_token,
    verificar_senha,
    verificar_totp,
)
from backend.core.config import Settings
from backend.core.errors import openai_error

logger = logging.getLogger("gateway.auth")

router = APIRouter(prefix="/api/auth", tags=["auth"])


class Tentativas:
    """Falhas de login por IP numa janela; passou do limite, o IP fica bloqueado até ela fechar."""

    def __init__(self) -> None:
        self._falhas: dict[str, list[float]] = {}
        self._trava = threading.Lock()
        # Último passo TOTP aceito: o mesmo código não serve para um segundo login (replay).
        self.ultimo_passo_totp = -1

    def bloqueado_por(self, ip: str, maximo: int, janela: float) -> float:
        """Segundos restantes de bloqueio (0 = liberado)."""
        with self._trava:
            agora = time.monotonic()
            falhas = [t for t in self._falhas.get(ip, []) if agora - t < janela]
            self._falhas[ip] = falhas
            return janela - (agora - falhas[0]) if len(falhas) >= maximo else 0

    def falhou(self, ip: str) -> None:
        with self._trava:
            self._falhas.setdefault(ip, []).append(time.monotonic())

    def limpar(self, ip: str) -> None:
        with self._trava:
            self._falhas.pop(ip, None)


def get_tentativas(request: Request) -> Tentativas:
    tentativas: Tentativas = request.app.state.tentativas_login
    return tentativas


class Credenciais(BaseModel):
    usuario: str = Field(min_length=1, max_length=64)
    senha: str = Field(min_length=1, max_length=256)
    codigo: str = Field(min_length=6, max_length=6, pattern=r"^\d{6}$")
    """Código de 6 dígitos do Google Authenticator."""

    lembrar: bool = False
    """Manter conectado: o token vale `jwt_lembrar_dias` em vez de `jwt_expire_minutes`."""


class Sessao(BaseModel):
    token: str
    tipo: str = "Bearer"
    expira_em: int
    usuario: str


@router.post("/login")
def login(
    credenciais: Credenciais,
    request: Request,
    settings: SettingsDep,
    tentativas: Annotated[Tentativas, Depends(get_tentativas)],
) -> Sessao:
    if not settings.login_configurado:
        raise openai_error(503, "Login não configurado no servidor.", "auth_not_configured")

    ip = request.client.host if request.client else "?"
    janela = settings.login_bloqueio_minutos * 60
    restante = tentativas.bloqueado_por(ip, settings.login_max_tentativas, janela)
    if restante:
        raise openai_error(
            429,
            f"Muitas tentativas. Tente de novo em {int(restante // 60) + 1} min.",
            "too_many_attempts",
        )

    hash_senha = settings.admin_senha_hash.get_secret_value()
    usuario_ok = hmac.compare_digest(credenciais.usuario.encode(), settings.admin_usuario.encode())
    # Verifica a senha mesmo com usuário errado para não revelar, pelo tempo, se o usuário existe.
    senha_ok = verificar_senha(credenciais.senha, hash_senha if usuario_ok else HASH_FICTICIO)
    passo = verificar_totp(settings.admin_totp_segredo.get_secret_value(), credenciais.codigo)
    totp_ok = passo is not None and passo > tentativas.ultimo_passo_totp
    if not (usuario_ok and senha_ok and totp_ok):
        tentativas.falhou(ip)
        logger.warning("Login recusado (ip=%s)", ip)
        raise openai_error(401, "Usuário, senha ou código inválidos.", "invalid_credentials")

    tentativas.ultimo_passo_totp = passo or 0
    tentativas.limpar(ip)
    logger.info("Login aceito (ip=%s)", ip)
    return _sessao(settings, credenciais.lembrar, int(time.time()))


def _sessao(settings: Settings, lembrar: bool, totp: int) -> Sessao:
    """Token de sessão com a geração atual, o "manter conectado" e a hora do último código TOTP
    (o módulo Código exige um recente)."""
    minutos = settings.jwt_lembrar_dias * 24 * 60 if lembrar else settings.jwt_expire_minutes
    extras: dict[str, object] = {
        "ger": ler_geracao(settings.sessoes_geracao_arquivo),
        "lem": lembrar,
        "totp": totp,
    }
    token, expira = emitir_token(
        settings.admin_usuario, settings.jwt_secret_key.get_secret_value(), minutos, extras
    )
    return Sessao(token=token, expira_em=expira, usuario=settings.admin_usuario)


def _sessao_do_pedido(request: Request) -> dict[str, object]:
    sessao = getattr(request.state, "sessao", None)
    if not isinstance(sessao, dict):
        raise openai_error(403, "Só com o login do app (não com chave).", "session_required")
    return sessao


@router.post("/renovar", dependencies=[Depends(require_client_api_key)])
def renovar(request: Request, settings: SettingsDep) -> Sessao:
    """Token novo com a mesma escolha de "manter conectado" e a mesma hora do último código: o
    app chama ao abrir e uma vez por dia, então a sessão não vence enquanto é usada."""
    sessao = _sessao_do_pedido(request)
    lembrar = sessao.get("lem")
    if not isinstance(lembrar, bool):  # token de antes da renovação: deduz pela validade
        duracao = int(sessao["exp"]) - int(sessao["iat"])  # type: ignore[call-overload]
        lembrar = duracao > settings.jwt_expire_minutes * 60
    totp = sessao.get("totp")
    return _sessao(settings, lembrar, totp if isinstance(totp, int) else 0)


class Codigo(BaseModel):
    codigo: str = Field(min_length=6, max_length=6, pattern=r"^\d{6}$")


@router.post("/confirmar", status_code=204, dependencies=[Depends(require_client_api_key)])
def confirmar(
    corpo: Codigo,
    request: Request,
    settings: SettingsDep,
    tentativas: Annotated[Tentativas, Depends(get_tentativas)],
) -> Response:
    """Confirma um código do Authenticator na sessão aberta (o Código pede um recente). Fica
    anotado no servidor para este token (`jti`): o app segue com o mesmo token, sem recarregar."""
    sessao = _sessao_do_pedido(request)
    ip = request.client.host if request.client else "?"
    janela = settings.login_bloqueio_minutos * 60
    if tentativas.bloqueado_por(ip, settings.login_max_tentativas, janela):
        raise openai_error(429, "Muitas tentativas. Tente mais tarde.", "too_many_attempts")
    passo = verificar_totp(settings.admin_totp_segredo.get_secret_value(), corpo.codigo)
    if passo is None or passo <= tentativas.ultimo_passo_totp:
        tentativas.falhou(ip)
        raise openai_error(401, "Código inválido.", "invalid_code")
    tentativas.ultimo_passo_totp = passo
    confirmacoes: dict[str, float] = request.app.state.totp_confirmacoes
    agora = time.time()
    validade = settings.codigo_totp_horas * 3600
    for jti in [j for j, quando in confirmacoes.items() if agora - quando > validade]:
        del confirmacoes[jti]
    confirmacoes[str(sessao.get("jti"))] = agora
    return Response(status_code=204)


@router.post("/sair-de-todos", status_code=204, dependencies=[Depends(require_client_api_key)])
def sair_de_todos(request: Request, settings: SettingsDep) -> Response:
    """Invalida todas as sessões (todos os aparelhos, este incluído): login de novo em cada um."""
    _sessao_do_pedido(request)
    geracao = subir_geracao(settings.sessoes_geracao_arquivo)
    logger.warning("Sessões revogadas (geração %s)", geracao)
    return Response(status_code=204)


class TokenMidia(BaseModel):
    token: str
    expira_em: int


@router.post("/token-midia", dependencies=[Depends(require_client_api_key)])
def token_midia(request: Request, settings: SettingsDep) -> TokenMidia:
    """Token curto para o `?token=` das URLs de arquivo da esteira (imagem, vídeo, PDF): vale só
    em `/esteira/` e nunca na API, então uma URL vazada não abre o resto."""
    sessao = _sessao_do_pedido(request)
    token, expira = emitir_token(
        str(sessao["sub"]),
        settings.jwt_secret_key.get_secret_value(),
        settings.jwt_midia_horas * 60,
        {"esc": "midia", "ger": ler_geracao(settings.sessoes_geracao_arquivo)},
    )
    return TokenMidia(token=token, expira_em=expira)


@router.get("/sessao", dependencies=[Depends(require_client_api_key)])
def sessao(request: Request) -> dict[str, str]:
    """Confere se o token ainda vale (o app usa ao abrir)."""
    return {"usuario": request.state.usuario}


@router.get("/verificar", status_code=204)
def verificar(request: Request, settings: SettingsDep) -> Response:
    """Subpedido `auth_request` do nginx antes de repassar `/esteira/` ao túnel do PC.

    Aceita o token de sessão no cabeçalho ou em `?token=` da URI original (`X-Original-URI`):
    imagem, vídeo e PDF abertos por URL não mandam cabeçalho. Só o JWT do login vale aqui.
    """
    token = request.headers.get("authorization", "").removeprefix("Bearer ").strip()
    if not token:
        consulta = urlsplit(request.headers.get("x-original-uri", "")).query
        token = parse_qs(consulta).get("token", [""])[0]
    if not token or not _vale_na_esteira(token, settings):
        raise openai_error(401, "Token inválido ou expirado.", "invalid_api_key")
    return Response(status_code=204)


def _vale_na_esteira(token: str, settings: Settings) -> bool:
    """Sessão do login ou token de mídia, ambos de geração não revogada."""
    if sessao_valida(token, settings) is not None:
        return True
    payload = validar_token(token, settings.jwt_secret_key.get_secret_value())
    geracao = payload.get("ger", 0) if payload else -1
    return (
        payload is not None
        and payload.get("esc") == "midia"
        and isinstance(geracao, int)
        and geracao >= ler_geracao(settings.sessoes_geracao_arquivo)
    )
