"""SSH access to the VPS.

Security rules:
- **Server key**: never accepted on its own. The first contact only reads the fingerprint (SHA256) and
  hands it to the person to confirm on screen; from then on any mismatch drops the connection
  (possible man-in-the-middle attack).
- **VPS password**: used only for the first access and to install the configurator key; it stays
  in memory during the run and is never stored (neither in the vault nor in the run log).
- **Configurator key**: ed25519 generated on the host, private key only in the vault.
- Every command is built with `shlex.quote`; the output goes through the secret mask.
"""

from __future__ import annotations

import base64
import hashlib
import io
import shlex
import socket
import time
from collections.abc import Callable
from dataclasses import dataclass

import paramiko


class SSHError(Exception):
    pass


class ServerKeyChanged(SSHError):
    pass


def fingerprint(key: paramiko.PKey) -> str:
    return "SHA256:" + base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip("=")


def read_server_fingerprint(host: str, porta: int = 22, timeout: float = 10.0) -> dict[str, str]:
    """Only negotiates the key, without authenticating. Returns what the screen shows for the person to confirm."""
    with socket.create_connection((host, porta), timeout=timeout) as s:
        t = paramiko.Transport(s)
        try:
            t.start_client(timeout=timeout)
            key = t.get_remote_server_key()
            return {"tipo": key.get_name(), "impressao": fingerprint(key), "versao": t.remote_version or ""}
        finally:
            t.close()


class _CheckFingerprint(paramiko.MissingHostKeyPolicy):
    def __init__(self, expected: str) -> None:
        self.expected = expected

    def missing_host_key(self, client, hostname, key) -> None:  # noqa: ANN001
        obtained = fingerprint(key)
        if not self.expected:
            raise SSHError(f"impressão digital do servidor não confirmada (servidor apresentou {obtained})")
        if obtained != self.expected:
            raise ServerKeyChanged(
                f"A chave do servidor MUDOU: esperada {self.expected}, recebida {obtained}. "
                "Conexão recusada. Se você reinstalou a VPS, confirme a nova impressão na tela VPS."
            )


@dataclass
class Credentials:
    usuario: str
    host: str
    porta: int
    impressao_host: str
    chave_privada: str | None = None  # PEM OpenSSH
    senha: str | None = None  # memory only
    senha_sudo: str | None = None


class Session:
    def __init__(self, cred: Credentials, mask: Callable[[str], str] = lambda s: s) -> None:
        self.cred = cred
        self._mask = mask
        self._cliente: paramiko.SSHClient | None = None

    # --- connection -----------------------------------------------------------------------------
    def conectar(self, usar_senha: bool = False, timeout: float = 15.0) -> Session:
        c = paramiko.SSHClient()
        c.set_missing_host_key_policy(_CheckFingerprint(self.cred.impressao_host))
        args: dict = {
            "hostname": self.cred.host, "port": self.cred.porta, "username": self.cred.usuario,
            "timeout": timeout, "banner_timeout": timeout, "auth_timeout": timeout,
            "allow_agent": False, "look_for_keys": False,
        }
        if usar_senha:
            if not self.cred.senha:
                raise SSHError("senha não informada")
            args["password"] = self.cred.senha
        else:
            if not self.cred.chave_privada:
                raise SSHError("chave do configurador ausente")
            args["pkey"] = paramiko.Ed25519Key.from_private_key(io.StringIO(self.cred.chave_privada))
        try:
            c.connect(**args)
        except paramiko.AuthenticationException as e:
            raise SSHError("autenticação recusada pela VPS") from e
        except (OSError, paramiko.SSHException) as e:
            if isinstance(e, SSHError):
                raise
            raise SSHError(f"sem conexão com {self.cred.host}:{self.cred.porta}: {e}") from e
        transport = c.get_transport()
        if transport is not None:
            transport.set_keepalive(20)
        self._cliente = c
        return self

    def fechar(self) -> None:
        if self._cliente is not None:
            self._cliente.close()
            self._cliente = None

    def __enter__(self) -> Session:
        return self

    def __exit__(self, *exc: object) -> None:
        self.fechar()

    @property
    def root(self) -> bool:
        return self.cred.usuario == "root"

    # --- comandos ------------------------------------------------------------------------------
    def rodar(self, command: str, *, sudo: bool = False, entry: str | None = None,
              log: Callable[[str], None] | None = None, timeout: float = 1800, checar: bool = True) -> tuple[int, str]:
        """Runs `command` in `bash -lc`. Returns (exit code, combined output already masked)."""
        if self._cliente is None:
            raise SSHError("sessão fechada")
        cmd = f"bash -c {shlex.quote(command)}"
        stdin_extra = ""
        if sudo and not self.root:
            if self.cred.senha_sudo:
                cmd = f"sudo -S -p '' {cmd}"
                stdin_extra = self.cred.senha_sudo + "\n"
            else:
                cmd = f"sudo -n {cmd}"
        channel = self._cliente.get_transport().open_session()  # type: ignore[union-attr]
        channel.set_combine_stderr(True)
        channel.settimeout(timeout)
        channel.exec_command(cmd)
        if stdin_extra or entry:
            channel.sendall((stdin_extra + (entry or "")).encode())
        channel.shutdown_write()
        parts: list[str] = []
        pending = ""
        start = time.monotonic()
        while True:
            if channel.recv_ready():
                block = channel.recv(65536).decode(errors="replace")
                parts.append(block)
                pending += block
                *lines, pending = pending.split("\n")
                if log:
                    for line in lines:
                        log(self._mask(line))
            elif channel.exit_status_ready():
                break
            elif time.monotonic() - start > timeout:
                channel.close()
                raise SSHError(f"comando passou de {int(timeout)} s")
            else:
                time.sleep(0.05)
        while channel.recv_ready():
            block = channel.recv(65536).decode(errors="replace")
            parts.append(block)
            pending += block
        if log and pending.strip():
            for line in pending.split("\n"):
                log(self._mask(line))
        code = channel.recv_exit_status()
        output = self._mask("".join(parts))
        if checar and code != 0:
            raise SSHError(f"comando falhou (código {code}): {output.strip()[-400:]}")
        return code, output

    def send(self, content: bytes, destination: str, mode: int = 0o644, owner: str = "root:root") -> None:
        """Writes `content` to `destination` with owner and mode, via a temporary file + `install` (atomic)."""
        if self._cliente is None:
            raise SSHError("sessão fechada")
        q = shlex.quote
        # Own temporary folder (mktemp -d, 0700): unpredictable name, no symlink race in /tmp.
        _, folder = self.rodar("umask 077; mktemp -d")
        folder = folder.strip().splitlines()[-1]
        if not folder.startswith("/tmp/"):  # noqa: S108 — only checks the mktemp output
            raise SSHError("mktemp devolveu caminho inesperado")
        tmp = f"{folder}/arquivo"
        sftp = self._cliente.open_sftp()
        try:
            with sftp.file(tmp, "wb") as f:
                f.set_pipelined(True)
                f.write(content)
        finally:
            sftp.close()
        user, group = owner.split(":")
        self.rodar(
            f"install -D -m {mode:o} -o {q(user)} -g {q(group)} {q(tmp)} {q(destination)}; rc=$?; "
            f"rm -rf {q(folder)}; exit $rc",
            sudo=True,
        )

    def ler(self, path: str) -> str | None:
        code, output = self.rodar(f"cat {shlex.quote(path)} 2>/dev/null", sudo=True, checar=False)
        return output if code == 0 else None
