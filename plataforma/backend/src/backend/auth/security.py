"""Hash de senha (scrypt), segundo fator TOTP (Google Authenticator) e token de sessão (JWT HS256),
só com a biblioteca padrão.

Gerar as variáveis do login (hash da senha, segredo TOTP e chave do JWT):

    .venv/bin/python -m backend.auth.security
"""

import base64
import hashlib
import hmac
import json
import secrets
import time
from pathlib import Path

# Custo do scrypt (~16 MiB de memória por verificação): caro para força bruta, rápido para um login.
_N, _R, _P = 2**14, 8, 1
SIZE_MINIMUM_SECRET = 32


def generate_hash_password(password: str) -> str:
    sal = secrets.token_bytes(16)
    key = hashlib.scrypt(password.encode(), salt=sal, n=_N, r=_R, p=_P, dklen=32)
    return f"scrypt${_N}${_R}${_P}${_b64(sal)}${_b64(key)}"


def verify_password(password: str, hash_salvo: str) -> bool:
    try:
        algoritmo, n, r, p, sal, expected = hash_salvo.split("$")
        if algoritmo != "scrypt":
            return False
        key = hashlib.scrypt(
            password.encode(), salt=_d64(sal), n=int(n), r=int(r), p=int(p), dklen=32
        )
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(key, _d64(expected))


def issue_token(
    subject: str, secret: str, minutos: int, extras: dict[str, object] | None = None
) -> tuple[str, int]:
    """Devolve o token e o instante (epoch) em que expira. [extras]: claims a mais (geração,
    escopo, hora do último código TOTP...)."""
    now = int(time.time())
    expira = now + minutos * 60
    cabecalho = {"alg": "HS256", "typ": "JWT"}
    body = {
        **(extras or {}),
        "sub": subject,
        "iat": now,
        "exp": expira,
        "jti": secrets.token_urlsafe(12),
    }
    base = f"{_b64(_json(cabecalho))}.{_b64(_json(body))}"
    return f"{base}.{_b64(_sign(base, secret))}", expira


def validate_token(token: str, secret: str) -> dict[str, object] | None:
    """Payload do token se a assinatura e a validade conferem; senão None."""
    if len(secret) < SIZE_MINIMUM_SECRET:
        return None
    try:
        header, body, signature = token.split(".")
        if not hmac.compare_digest(_d64(signature), _sign(f"{header}.{body}", secret)):
            return None
        # Só HS256: impede o truque de trocar o "alg" (ex.: "none").
        if json.loads(_d64(header)).get("alg") != "HS256":
            return None
        payload: dict[str, object] = json.loads(_d64(body))
    except (ValueError, TypeError):
        return None
    exp = payload.get("exp")
    if not isinstance(exp, int) or exp <= time.time() or not isinstance(payload.get("sub"), str):
        return None
    return payload


def read_generation(arquivo: str) -> int:
    """Geração atual das sessões (0 sem o arquivo ou com conteúdo inválido)."""
    try:
        return int(Path(arquivo).expanduser().read_text().strip() or 0)
    except (OSError, ValueError):
        return 0


def upload_generation(arquivo: str) -> int:
    """Invalida todos os tokens emitidos até agora; devolve a geração nova."""
    path = Path(arquivo).expanduser()
    new = read_generation(arquivo) + 1
    path.parent.mkdir(parents=True, exist_ok=True)
    temporario = path.with_suffix(".novo")
    temporario.write_text(str(new))
    temporario.replace(path)
    return new


def generate_secret_totp() -> str:
    return base64.b32encode(secrets.token_bytes(20)).decode()


def uri_totp(secret: str, usuario: str, emissor: str = "Agent") -> str:
    """URI `otpauth://` para cadastrar no Google Authenticator (QR code ou chave manual)."""
    from urllib.parse import quote

    return (
        f"otpauth://totp/{quote(emissor)}:{quote(usuario)}"
        f"?secret={secret}&issuer={quote(emissor)}&algorithm=SHA1&digits=6&period=30"
    )


def code_totp(secret: str, step: int) -> str:
    key = base64.b32decode(secret.upper() + "=" * (-len(secret) % 8))
    digest = hmac.new(key, step.to_bytes(8, "big"), hashlib.sha1).digest()
    deslocamento = digest[-1] & 0x0F
    number = int.from_bytes(digest[deslocamento : deslocamento + 4], "big") & 0x7FFFFFFF
    return f"{number % 1_000_000:06d}"


def verify_totp(secret: str, codigo: str, agora: float | None = None) -> int | None:
    """Passo de tempo (janela de 30 s) em que o código confere, com ±1 de folga; senão None."""
    if not secret or len(codigo) != 6 or not codigo.isdigit():
        return None
    current = int((time.time() if agora is None else agora) // 30)
    try:
        for step in (current - 1, current, current + 1):
            if hmac.compare_digest(code_totp(secret, step), codigo):
                return step
    except ValueError:
        return None
    return None


def _sign(base: str, secret: str) -> bytes:
    return hmac.new(secret.encode(), base.encode(), hashlib.sha256).digest()


def _json(dados: dict[str, object]) -> bytes:
    return json.dumps(dados, separators=(",", ":")).encode()


def _b64(dados: bytes) -> str:
    return base64.urlsafe_b64encode(dados).rstrip(b"=").decode()


def _d64(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


# Hash de uma senha aleatória: usuário inexistente gasta o mesmo tempo que um existente.
HASH_FICTITIOUS = generate_hash_password(secrets.token_urlsafe(16))


if __name__ == "__main__":
    import getpass

    password = getpass.getpass("Senha: ")
    if len(password) < 12:
        raise SystemExit("Use ao menos 12 caracteres.")
    if password != getpass.getpass("Repita: "):
        raise SystemExit("As senhas não conferem.")
    user = input("Usuário [admin]: ").strip() or "admin"
    totp = generate_secret_totp()
    print(f"\nGATEWAY_ADMIN_USUARIO={user}")
    print(f"GATEWAY_ADMIN_SENHA_HASH='{generate_hash_password(password)}'")
    print(f"GATEWAY_ADMIN_TOTP_SEGREDO={totp}")
    print(f"GATEWAY_JWT_SECRET_KEY={secrets.token_hex(32)}")
    print("\nGoogle Authenticator → + → 'Inserir chave de configuração' com a chave acima,")
    print(f"ou gere um QR code desta URI:\n{uri_totp(totp, user)}")
