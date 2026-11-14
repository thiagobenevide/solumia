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
TAMANHO_MINIMO_SEGREDO = 32


def gerar_hash_senha(senha: str) -> str:
    sal = secrets.token_bytes(16)
    chave = hashlib.scrypt(senha.encode(), salt=sal, n=_N, r=_R, p=_P, dklen=32)
    return f"scrypt${_N}${_R}${_P}${_b64(sal)}${_b64(chave)}"


def verificar_senha(senha: str, hash_salvo: str) -> bool:
    try:
        algoritmo, n, r, p, sal, esperado = hash_salvo.split("$")
        if algoritmo != "scrypt":
            return False
        chave = hashlib.scrypt(
            senha.encode(), salt=_d64(sal), n=int(n), r=int(r), p=int(p), dklen=32
        )
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(chave, _d64(esperado))


def emitir_token(
    sujeito: str, segredo: str, minutos: int, extras: dict[str, object] | None = None
) -> tuple[str, int]:
    """Devolve o token e o instante (epoch) em que expira. [extras]: claims a mais (geração,
    escopo, hora do último código TOTP...)."""
    agora = int(time.time())
    expira = agora + minutos * 60
    cabecalho = {"alg": "HS256", "typ": "JWT"}
    corpo = {
        **(extras or {}),
        "sub": sujeito,
        "iat": agora,
        "exp": expira,
        "jti": secrets.token_urlsafe(12),
    }
    base = f"{_b64(_json(cabecalho))}.{_b64(_json(corpo))}"
    return f"{base}.{_b64(_assinar(base, segredo))}", expira


def validar_token(token: str, segredo: str) -> dict[str, object] | None:
    """Payload do token se a assinatura e a validade conferem; senão None."""
    if len(segredo) < TAMANHO_MINIMO_SEGREDO:
        return None
    try:
        cab, corpo, assinatura = token.split(".")
        if not hmac.compare_digest(_d64(assinatura), _assinar(f"{cab}.{corpo}", segredo)):
            return None
        # Só HS256: impede o truque de trocar o "alg" (ex.: "none").
        if json.loads(_d64(cab)).get("alg") != "HS256":
            return None
        payload: dict[str, object] = json.loads(_d64(corpo))
    except (ValueError, TypeError):
        return None
    exp = payload.get("exp")
    if not isinstance(exp, int) or exp <= time.time() or not isinstance(payload.get("sub"), str):
        return None
    return payload


def ler_geracao(arquivo: str) -> int:
    """Geração atual das sessões (0 sem o arquivo ou com conteúdo inválido)."""
    try:
        return int(Path(arquivo).expanduser().read_text().strip() or 0)
    except (OSError, ValueError):
        return 0


def subir_geracao(arquivo: str) -> int:
    """Invalida todos os tokens emitidos até agora; devolve a geração nova."""
    caminho = Path(arquivo).expanduser()
    nova = ler_geracao(arquivo) + 1
    caminho.parent.mkdir(parents=True, exist_ok=True)
    temporario = caminho.with_suffix(".novo")
    temporario.write_text(str(nova))
    temporario.replace(caminho)
    return nova


def gerar_segredo_totp() -> str:
    return base64.b32encode(secrets.token_bytes(20)).decode()


def uri_totp(segredo: str, usuario: str, emissor: str = "Agent") -> str:
    """URI `otpauth://` para cadastrar no Google Authenticator (QR code ou chave manual)."""
    from urllib.parse import quote

    return (
        f"otpauth://totp/{quote(emissor)}:{quote(usuario)}"
        f"?secret={segredo}&issuer={quote(emissor)}&algorithm=SHA1&digits=6&period=30"
    )


def codigo_totp(segredo: str, passo: int) -> str:
    chave = base64.b32decode(segredo.upper() + "=" * (-len(segredo) % 8))
    digest = hmac.new(chave, passo.to_bytes(8, "big"), hashlib.sha1).digest()
    deslocamento = digest[-1] & 0x0F
    numero = int.from_bytes(digest[deslocamento : deslocamento + 4], "big") & 0x7FFFFFFF
    return f"{numero % 1_000_000:06d}"


def verificar_totp(segredo: str, codigo: str, agora: float | None = None) -> int | None:
    """Passo de tempo (janela de 30 s) em que o código confere, com ±1 de folga; senão None."""
    if not segredo or len(codigo) != 6 or not codigo.isdigit():
        return None
    atual = int((time.time() if agora is None else agora) // 30)
    try:
        for passo in (atual - 1, atual, atual + 1):
            if hmac.compare_digest(codigo_totp(segredo, passo), codigo):
                return passo
    except ValueError:
        return None
    return None


def _assinar(base: str, segredo: str) -> bytes:
    return hmac.new(segredo.encode(), base.encode(), hashlib.sha256).digest()


def _json(dados: dict[str, object]) -> bytes:
    return json.dumps(dados, separators=(",", ":")).encode()


def _b64(dados: bytes) -> str:
    return base64.urlsafe_b64encode(dados).rstrip(b"=").decode()


def _d64(texto: str) -> bytes:
    return base64.urlsafe_b64decode(texto + "=" * (-len(texto) % 4))


# Hash de uma senha aleatória: usuário inexistente gasta o mesmo tempo que um existente.
HASH_FICTICIO = gerar_hash_senha(secrets.token_urlsafe(16))


if __name__ == "__main__":
    import getpass

    senha = getpass.getpass("Senha: ")
    if len(senha) < 12:
        raise SystemExit("Use ao menos 12 caracteres.")
    if senha != getpass.getpass("Repita: "):
        raise SystemExit("As senhas não conferem.")
    usuario = input("Usuário [admin]: ").strip() or "admin"
    totp = gerar_segredo_totp()
    print(f"\nGATEWAY_ADMIN_USUARIO={usuario}")
    print(f"GATEWAY_ADMIN_SENHA_HASH='{gerar_hash_senha(senha)}'")
    print(f"GATEWAY_ADMIN_TOTP_SEGREDO={totp}")
    print(f"GATEWAY_JWT_SECRET_KEY={secrets.token_hex(32)}")
    print("\nGoogle Authenticator → + → 'Inserir chave de configuração' com a chave acima,")
    print(f"ou gere um QR code desta URI:\n{uri_totp(totp, usuario)}")
