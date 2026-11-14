"""Password hash (scrypt), TOTP second factor (Google Authenticator) and session token
(JWT HS256), with the standard library only.

Generate the login variables (password hash, TOTP secret and JWT key):

    .venv/bin/python -m backend.auth.security
"""

import base64
import hashlib
import hmac
import json
import secrets
import time
from pathlib import Path

# scrypt cost (~16 MiB of memory per check): expensive for brute force, fast for one login.
_N, _R, _P = 2**14, 8, 1
SIZE_MINIMUM_SECRET = 32


def generate_hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    key = hashlib.scrypt(password.encode(), salt=salt, n=_N, r=_R, p=_P, dklen=32)
    return f"scrypt${_N}${_R}${_P}${_b64(salt)}${_b64(key)}"


def verify_password(password: str, hash_salvo: str) -> bool:
    try:
        algoritmo, n, r, p, salt, expected = hash_salvo.split("$")
        if algoritmo != "scrypt":
            return False
        key = hashlib.scrypt(
            password.encode(), salt=_d64(salt), n=int(n), r=int(r), p=int(p), dklen=32
        )
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(key, _d64(expected))


def issue_token(
    subject: str, secret: str, minutos: int, extras: dict[str, object] | None = None
) -> tuple[str, int]:
    """Returns the token and the instant (epoch) it expires. Extras: additional claims
    (generation, scope, time of the last TOTP code...)."""
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
    """Token payload if the signature and the validity check out; otherwise None."""
    if len(secret) < SIZE_MINIMUM_SECRET:
        return None
    try:
        header, body, signature = token.split(".")
        if not hmac.compare_digest(_d64(signature), _sign(f"{header}.{body}", secret)):
            return None
        # Only HS256: prevents the "alg" swap trick (e.g. "none").
        if json.loads(_d64(header)).get("alg") != "HS256":
            return None
        payload: dict[str, object] = json.loads(_d64(body))
    except (ValueError, TypeError):
        return None
    exp = payload.get("exp")
    if not isinstance(exp, int) or exp <= time.time() or not isinstance(payload.get("sub"), str):
        return None
    return payload


def read_generation(file: str) -> int:
    """Current session generation (0 without the file or with invalid content)."""
    try:
        return int(Path(file).expanduser().read_text().strip() or 0)
    except (OSError, ValueError):
        return 0


def upload_generation(file: str) -> int:
    """Invalidates every token issued so far; returns the new generation."""
    path = Path(file).expanduser()
    new = read_generation(file) + 1
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".novo")
    temporary.write_text(str(new))
    temporary.replace(path)
    return new


def generate_secret_totp() -> str:
    return base64.b32encode(secrets.token_bytes(20)).decode()


def uri_totp(secret: str, usuario: str, issuer: str = "Agent") -> str:
    """`otpauth://` URI to register in Google Authenticator (QR code or manual key)."""
    from urllib.parse import quote

    return (
        f"otpauth://totp/{quote(issuer)}:{quote(usuario)}"
        f"?secret={secret}&issuer={quote(issuer)}&algorithm=SHA1&digits=6&period=30"
    )


def code_totp(secret: str, step: int) -> str:
    key = base64.b32decode(secret.upper() + "=" * (-len(secret) % 8))
    digest = hmac.new(key, step.to_bytes(8, "big"), hashlib.sha1).digest()
    deslocamento = digest[-1] & 0x0F
    number = int.from_bytes(digest[deslocamento : deslocamento + 4], "big") & 0x7FFFFFFF
    return f"{number % 1_000_000:06d}"


def verify_totp(secret: str, code: str, now: float | None = None) -> int | None:
    """Time step (30 s window) in which the code matches, with ±1 tolerance; otherwise None."""
    if not secret or len(code) != 6 or not code.isdigit():
        return None
    current = int((time.time() if now is None else now) // 30)
    try:
        for step in (current - 1, current, current + 1):
            if hmac.compare_digest(code_totp(secret, step), code):
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


# Hash of a random password: a missing user takes the same time as an existing one.
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
