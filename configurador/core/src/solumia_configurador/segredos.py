"""Geração dos segredos da instalação, feita no host: a senha em claro nunca sai desta máquina.

O formato do hash e do TOTP é o mesmo de `plataforma/backend/src/backend/auth/security.py`
(scrypt N=2^14, r=8, p=1; TOTP SHA1/6 dígitos/30 s), para o gateway aceitar sem mudança.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import secrets
import time
from urllib.parse import quote

from . import nomes

# Nomes dos segredos no cofre.
SENHA_HASH = "conta.senha_hash"
TOTP = "conta.totp"
JWT = "gateway.jwt"
CHAVE_CLIENTE = "gateway.chave_cliente"
CHAVE_WORKER = "gateway.chave_worker"
COLLABORA_SENHA = "collabora.senha_admin"
WOPI = "gateway.wopi"
SSH_CHAVE_PRIVADA = "ssh.{no}.privada"  # ed25519 gerada pelo configurador, por nó
TUNEL_CHAVE_PRIVADA = "tunel.privada"

_N, _R, _P = 2**14, 8, 1


def _b64(dados: bytes) -> str:
    return base64.urlsafe_b64encode(dados).rstrip(b"=").decode()


def validar_senha(senha: str) -> list[str]:
    problemas = []
    if len(senha) < 12:
        problemas.append("mínimo de 12 caracteres")
    if senha.lower() == senha or senha.upper() == senha:
        problemas.append("misture maiúsculas e minúsculas")
    if not any(c.isdigit() for c in senha):
        problemas.append("inclua ao menos um número")
    return problemas


def hash_senha(senha: str) -> str:
    sal = secrets.token_bytes(16)
    chave = hashlib.scrypt(senha.encode(), salt=sal, n=_N, r=_R, p=_P, dklen=32)
    return f"scrypt${_N}${_R}${_P}${_b64(sal)}${_b64(chave)}"


def segredo_totp() -> str:
    return base64.b32encode(secrets.token_bytes(20)).decode()


def uri_totp(segredo: str, usuario: str) -> str:
    emissor = nomes.NOME_EXIBICAO
    return (
        f"otpauth://totp/{quote(emissor)}:{quote(usuario)}"
        f"?secret={segredo}&issuer={quote(emissor)}&algorithm=SHA1&digits=6&period=30"
    )


def codigo_totp(segredo: str, passo: int) -> str:
    chave = base64.b32decode(segredo.upper() + "=" * (-len(segredo) % 8))
    digest = hmac.new(chave, passo.to_bytes(8, "big"), hashlib.sha1).digest()
    d = digest[-1] & 0x0F
    numero = int.from_bytes(digest[d : d + 4], "big") & 0x7FFFFFFF
    return f"{numero % 1_000_000:06d}"


def conferir_totp(segredo: str, codigo: str, agora: float | None = None) -> bool:
    """Usado para reconfirmar ações destrutivas (reinstalar VPS, exportar cofre)."""
    if not segredo or len(codigo) != 6 or not codigo.isdigit():
        return False
    atual = int((time.time() if agora is None else agora) // 30)
    return any(hmac.compare_digest(codigo_totp(segredo, p), codigo) for p in (atual - 1, atual, atual + 1))


def token(prefixo: str = "", tamanho: int = 32) -> str:
    return prefixo + secrets.token_urlsafe(tamanho)


def gerar_chave_ssh() -> tuple[str, str]:
    """(privada em PEM OpenSSH, pública em uma linha)."""
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    chave = Ed25519PrivateKey.generate()
    privada = chave.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.OpenSSH, serialization.NoEncryption()
    ).decode()
    publica = chave.public_key().public_bytes(
        serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH
    ).decode()
    return privada, f"{publica} {nomes.COMENTARIO_CHAVE_SSH}"


def publica_de(privada_pem: str) -> str:
    from cryptography.hazmat.primitives import serialization

    chave = serialization.load_ssh_private_key(privada_pem.encode(), password=None)
    publica = chave.public_key().public_bytes(
        serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH
    ).decode()
    return f"{publica} {nomes.COMENTARIO_CHAVE_SSH}"
