"""Cofre de segredos: AES-256-GCM, chave no chaveiro do sistema operacional.

- Linux: Secret Service (GNOME Keyring / KWallet); Windows: Credential Manager.
- Sem chaveiro disponível (servidor sem sessão gráfica), a chave sai de uma frase-senha via scrypt;
  a frase nunca é gravada.
- O arquivo é reescrito inteiro a cada mudança (atômico, 0600). Valores nunca vão para logs: `repr`
  do cofre só mostra os nomes.
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

from . import nomes

_VERSAO = 1
_AAD = b"solumia-cofre-v1"


class CofreErro(Exception):
    pass


class ChaveiroIndisponivel(CofreErro):
    pass


def _b64(dados: bytes) -> str:
    return base64.b64encode(dados).decode()


def _d64(texto: str) -> bytes:
    return base64.b64decode(texto)


class FonteChave:
    """De onde vem a chave de 32 bytes do cofre."""

    def obter(self, criar: bool) -> bytes:
        raise NotImplementedError

    def kdf(self) -> dict[str, object] | None:
        return None


class ChaveDoChaveiro(FonteChave):
    def obter(self, criar: bool) -> bytes:
        try:
            import keyring
            from keyring.errors import KeyringError
        except ImportError as e:  # pragma: no cover
            raise ChaveiroIndisponivel("pacote keyring ausente") from e
        try:
            salva = keyring.get_password(nomes.SERVICO_CHAVEIRO, nomes.CONTA_CHAVEIRO)
            if salva:
                chave = _d64(salva)
                if len(chave) != 32:
                    raise CofreErro("chave do chaveiro corrompida")
                return chave
            if not criar:
                raise CofreErro("o cofre existe mas a chave não está no chaveiro deste usuário")
            chave = AESGCM.generate_key(bit_length=256)
            keyring.set_password(nomes.SERVICO_CHAVEIRO, nomes.CONTA_CHAVEIRO, _b64(chave))
            return chave
        except KeyringError as e:
            raise ChaveiroIndisponivel(str(e)) from e


class ChaveDeFrase(FonteChave):
    def __init__(self, frase: str, sal: bytes | None = None) -> None:
        if len(frase) < 12:
            raise CofreErro("frase-senha do cofre: mínimo 12 caracteres")
        self._frase = frase
        self.sal = sal or secrets.token_bytes(16)

    def obter(self, criar: bool) -> bytes:
        return Scrypt(salt=self.sal, length=32, n=2**17, r=8, p=1).derive(self._frase.encode())

    def kdf(self) -> dict[str, object]:
        return {"tipo": "scrypt", "n": 2**17, "r": 8, "p": 1, "sal": _b64(self.sal)}


class Cofre:
    def __init__(self, caminho: Path, fonte: FonteChave | None = None) -> None:
        self.caminho = caminho
        self._fonte = fonte or ChaveDoChaveiro()
        self._lock = threading.Lock()
        self._dados: dict[str, str] = {}
        self._chave: bytes | None = None

    def __repr__(self) -> str:
        return f"Cofre({self.caminho}, nomes={sorted(self._dados)})"

    @classmethod
    def com_frase(cls, caminho: Path, frase: str) -> Cofre:
        sal = None
        if caminho.exists():
            kdf = json.loads(caminho.read_text()).get("kdf") or {}
            if kdf.get("tipo") != "scrypt":
                raise CofreErro("este cofre não usa frase-senha")
            sal = _d64(str(kdf["sal"]))
        return cls(caminho, ChaveDeFrase(frase, sal))

    # --- ciclo de vida -------------------------------------------------------------------------
    def abrir(self) -> Cofre:
        with self._lock:
            existe = self.caminho.exists()
            self._chave = self._fonte.obter(criar=not existe)
            if existe:
                bruto = json.loads(self.caminho.read_text())
                if bruto.get("v") != _VERSAO:
                    raise CofreErro(f"versão de cofre desconhecida: {bruto.get('v')}")
                try:
                    texto = AESGCM(self._chave).decrypt(_d64(bruto["nonce"]), _d64(bruto["dados"]), _AAD)
                except InvalidTag as e:
                    raise CofreErro("chave errada ou cofre adulterado") from e
                self._dados = json.loads(texto)
            else:
                self._dados = {}
                self._gravar()
        return self

    def _gravar(self) -> None:
        assert self._chave is not None
        nonce = secrets.token_bytes(12)
        cifrado = AESGCM(self._chave).encrypt(nonce, json.dumps(self._dados).encode(), _AAD)
        conteudo = {"v": _VERSAO, "kdf": self._fonte.kdf(), "nonce": _b64(nonce), "dados": _b64(cifrado)}
        self.caminho.parent.mkdir(parents=True, exist_ok=True)
        temporario = self.caminho.with_suffix(".tmp")
        fd = os.open(temporario, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(conteudo, f)
        os.replace(temporario, self.caminho)

    # --- acesso ----------------------------------------------------------------------------------
    def _aberto(self) -> None:
        if self._chave is None:
            raise CofreErro("cofre fechado")

    def obter(self, nome: str) -> str | None:
        self._aberto()
        return self._dados.get(nome)

    def exigir(self, nome: str) -> str:
        valor = self.obter(nome)
        if not valor:
            raise CofreErro(f"segredo ausente no cofre: {nome}")
        return valor

    def definir(self, nome: str, valor: str) -> None:
        self._aberto()
        with self._lock:
            self._dados[nome] = valor
            self._gravar()

    def obter_ou_gerar(self, nome: str, gerar) -> str:  # noqa: ANN001
        valor = self.obter(nome)
        if not valor:
            valor = gerar()
            self.definir(nome, valor)
        return valor

    def remover(self, nome: str) -> None:
        self._aberto()
        with self._lock:
            if self._dados.pop(nome, None) is not None:
                self._gravar()

    def nomes(self) -> list[str]:
        self._aberto()
        return sorted(self._dados)

    def valores_sensiveis(self) -> list[str]:
        """Para mascarar em logs qualquer valor do cofre que escape para uma saída de comando."""
        self._aberto()
        return [v for v in self._dados.values() if len(v) >= 8]
