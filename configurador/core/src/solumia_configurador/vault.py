"""Secret vault: AES-256-GCM, key in the operating system keyring.

- Linux: Secret Service (GNOME Keyring / KWallet); Windows: Credential Manager.
- With no keyring available (server without a graphical session), the key comes from a passphrase
  via scrypt; the passphrase is never stored.
- The file is rewritten in full on every change (atomic, 0600). Values never go to logs: the vault
  `repr` only shows the names.
"""

from __future__ import annotations

import base64
import json
import os
import secrets
import threading
from pathlib import Path

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt

from . import names

_VERSION = 1
_AAD = b"solumia-cofre-v1"


class VaultError(Exception):
    pass


class KeyringUnavailable(VaultError):
    pass


def _b64(data: bytes) -> str:
    return base64.b64encode(data).decode()


def _d64(text: str) -> bytes:
    return base64.b64decode(text)


class KeySource:
    """Where the 32-byte vault key comes from."""

    def obter(self, criar: bool) -> bytes:
        raise NotImplementedError

    def kdf(self) -> dict[str, object] | None:
        return None


class KeyringKey(KeySource):
    def obter(self, criar: bool) -> bytes:
        try:
            import keyring
            from keyring.errors import KeyringError
        except ImportError as e:  # pragma: no cover
            raise KeyringUnavailable("pacote keyring ausente") from e
        try:
            saved = keyring.get_password(names.SERVICO_CHAVEIRO, names.KEYRING_ACCOUNT)
            if saved:
                key = _d64(saved)
                if len(key) != 32:
                    raise VaultError("chave do chaveiro corrompida")
                return key
            if not criar:
                raise VaultError("o cofre existe mas a chave não está no chaveiro deste usuário")
            key = AESGCM.generate_key(bit_length=256)
            keyring.set_password(names.SERVICO_CHAVEIRO, names.KEYRING_ACCOUNT, _b64(key))
            return key
        except KeyringError as e:
            raise KeyringUnavailable(str(e)) from e


class PassphraseKey(KeySource):
    def __init__(self, sentence: str, salt: bytes | None = None) -> None:
        if len(sentence) < 12:
            raise VaultError("frase-senha do cofre: mínimo 12 caracteres")
        self._passphrase = sentence
        self.salt = salt or secrets.token_bytes(16)

    def obter(self, criar: bool) -> bytes:
        return Scrypt(salt=self.salt, length=32, n=2**17, r=8, p=1).derive(self._passphrase.encode())

    def kdf(self) -> dict[str, object]:
        return {"tipo": "scrypt", "n": 2**17, "r": 8, "p": 1, "sal": _b64(self.salt)}


class Vault:
    def __init__(self, path: Path, source: KeySource | None = None) -> None:
        self.path = path
        self._source = source or KeyringKey()
        self._lock = threading.Lock()
        self._data: dict[str, str] = {}
        self._key: bytes | None = None

    def __repr__(self) -> str:
        return f"Cofre({self.path}, nomes={sorted(self._data)})"

    @classmethod
    def with_passphrase(cls, path: Path, sentence: str) -> Vault:
        salt = None
        if path.exists():
            kdf = json.loads(path.read_text()).get("kdf") or {}
            if kdf.get("tipo") != "scrypt":
                raise VaultError("este cofre não usa frase-senha")
            salt = _d64(str(kdf["sal"]))
        return cls(path, PassphraseKey(sentence, salt))

    # --- lifecycle ------------------------------------------------------------------------------
    def open_file(self) -> Vault:
        with self._lock:
            exists = self.path.exists()
            self._key = self._source.obter(criar=not exists)
            if exists:
                raw = json.loads(self.path.read_text())
                if raw.get("v") != _VERSION:
                    raise VaultError(f"versão de cofre desconhecida: {raw.get('v')}")
                try:
                    text = AESGCM(self._key).decrypt(_d64(raw["nonce"]), _d64(raw["dados"]), _AAD)
                except InvalidTag as e:
                    raise VaultError("chave errada ou cofre adulterado") from e
                self._data = json.loads(text)
            else:
                self._data = {}
                self._write()
        return self

    def _write(self) -> None:
        assert self._key is not None
        nonce = secrets.token_bytes(12)
        encrypted = AESGCM(self._key).encrypt(nonce, json.dumps(self._data).encode(), _AAD)
        content = {"v": _VERSION, "kdf": self._source.kdf(), "nonce": _b64(nonce), "dados": _b64(encrypted)}
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_suffix(".tmp")
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(content, f)
        os.replace(temporary, self.path)

    # --- acesso ----------------------------------------------------------------------------------
    def _aberto(self) -> None:
        if self._key is None:
            raise VaultError("cofre fechado")

    def obter(self, name: str) -> str | None:
        self._aberto()
        return self._data.get(name)

    def require(self, name: str) -> str:
        value = self.obter(name)
        if not value:
            raise VaultError(f"segredo ausente no cofre: {name}")
        return value

    def definir(self, name: str, value: str) -> None:
        self._aberto()
        with self._lock:
            self._data[name] = value
            self._write()

    def get_or_generate(self, name: str, generate) -> str:  # noqa: ANN001
        value = self.obter(name)
        if not value:
            value = generate()
            self.definir(name, value)
        return value

    def remove(self, name: str) -> None:
        self._aberto()
        with self._lock:
            if self._data.pop(name, None) is not None:
                self._write()

    def names(self) -> list[str]:
        self._aberto()
        return sorted(self._data)

    def sensitive_values(self) -> list[str]:
        """To mask in logs any vault value that leaks into a command output."""
        self._aberto()
        return [v for v in self._data.values() if len(v) >= 8]
