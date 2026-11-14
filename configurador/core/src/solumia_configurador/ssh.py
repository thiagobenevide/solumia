"""Acesso SSH à VPS.

Regras de segurança:
- **Chave do servidor**: nunca aceita sozinha. O 1º contato só lê a impressão digital (SHA256) e a
  devolve para a pessoa confirmar na tela; dali em diante qualquer divergência derruba a conexão
  (possível ataque de intermediário).
- **Senha da VPS**: usada só para o primeiro acesso e para instalar a chave do configurador; fica
  em memória durante a execução e nunca é gravada (nem no cofre, nem no registro).
- **Chave do configurador**: ed25519 gerada no host, privada só no cofre.
- Todo comando é montado com `shlex.quote`; a saída passa pela máscara de segredos.
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


class SSHErro(Exception):
    pass


class ChaveDoServidorMudou(SSHErro):
    pass


def impressao(chave: paramiko.PKey) -> str:
    return "SHA256:" + base64.b64encode(hashlib.sha256(chave.asbytes()).digest()).decode().rstrip("=")


def ler_impressao_servidor(host: str, porta: int = 22, timeout: float = 10.0) -> dict[str, str]:
    """Só negocia a chave, sem autenticar. Devolve o que a tela mostra para a pessoa confirmar."""
    with socket.create_connection((host, porta), timeout=timeout) as s:
        t = paramiko.Transport(s)
        try:
            t.start_client(timeout=timeout)
            chave = t.get_remote_server_key()
            return {"tipo": chave.get_name(), "impressao": impressao(chave), "versao": t.remote_version or ""}
        finally:
            t.close()


class _ConferirImpressao(paramiko.MissingHostKeyPolicy):
    def __init__(self, esperada: str) -> None:
        self.esperada = esperada

    def missing_host_key(self, client, hostname, key) -> None:  # noqa: ANN001
        obtida = impressao(key)
        if not self.esperada:
            raise SSHErro(f"impressão digital do servidor não confirmada (servidor apresentou {obtida})")
        if obtida != self.esperada:
            raise ChaveDoServidorMudou(
                f"A chave do servidor MUDOU: esperada {self.esperada}, recebida {obtida}. "
                "Conexão recusada. Se você reinstalou a VPS, confirme a nova impressão na tela VPS."
            )


@dataclass
class Credenciais:
    usuario: str
    host: str
    porta: int
    impressao_host: str
    chave_privada: str | None = None  # PEM OpenSSH
    senha: str | None = None  # só em memória
    senha_sudo: str | None = None


class Sessao:
    def __init__(self, cred: Credenciais, mascara: Callable[[str], str] = lambda s: s) -> None:
        self.cred = cred
        self._mascara = mascara
        self._cliente: paramiko.SSHClient | None = None

    # --- conexão -------------------------------------------------------------------------------
    def conectar(self, usar_senha: bool = False, timeout: float = 15.0) -> Sessao:
        c = paramiko.SSHClient()
        c.set_missing_host_key_policy(_ConferirImpressao(self.cred.impressao_host))
        args: dict = {
            "hostname": self.cred.host, "port": self.cred.porta, "username": self.cred.usuario,
            "timeout": timeout, "banner_timeout": timeout, "auth_timeout": timeout,
            "allow_agent": False, "look_for_keys": False,
        }
        if usar_senha:
            if not self.cred.senha:
                raise SSHErro("senha não informada")
            args["password"] = self.cred.senha
        else:
            if not self.cred.chave_privada:
                raise SSHErro("chave do configurador ausente")
            args["pkey"] = paramiko.Ed25519Key.from_private_key(io.StringIO(self.cred.chave_privada))
        try:
            c.connect(**args)
        except paramiko.AuthenticationException as e:
            raise SSHErro("autenticação recusada pela VPS") from e
        except (OSError, paramiko.SSHException) as e:
            if isinstance(e, SSHErro):
                raise
            raise SSHErro(f"sem conexão com {self.cred.host}:{self.cred.porta}: {e}") from e
        transporte = c.get_transport()
        if transporte is not None:
            transporte.set_keepalive(20)
        self._cliente = c
        return self

    def fechar(self) -> None:
        if self._cliente is not None:
            self._cliente.close()
            self._cliente = None

    def __enter__(self) -> Sessao:
        return self

    def __exit__(self, *exc: object) -> None:
        self.fechar()

    @property
    def root(self) -> bool:
        return self.cred.usuario == "root"

    # --- comandos ------------------------------------------------------------------------------
    def rodar(self, comando: str, *, sudo: bool = False, entrada: str | None = None,
              log: Callable[[str], None] | None = None, timeout: float = 1800, checar: bool = True) -> tuple[int, str]:
        """Roda `comando` em `bash -lc`. Devolve (código, saída combinada já mascarada)."""
        if self._cliente is None:
            raise SSHErro("sessão fechada")
        cmd = f"bash -c {shlex.quote(comando)}"
        stdin_extra = ""
        if sudo and not self.root:
            if self.cred.senha_sudo:
                cmd = f"sudo -S -p '' {cmd}"
                stdin_extra = self.cred.senha_sudo + "\n"
            else:
                cmd = f"sudo -n {cmd}"
        canal = self._cliente.get_transport().open_session()  # type: ignore[union-attr]
        canal.set_combine_stderr(True)
        canal.settimeout(timeout)
        canal.exec_command(cmd)
        if stdin_extra or entrada:
            canal.sendall((stdin_extra + (entrada or "")).encode())
        canal.shutdown_write()
        partes: list[str] = []
        pendente = ""
        inicio = time.monotonic()
        while True:
            if canal.recv_ready():
                bloco = canal.recv(65536).decode(errors="replace")
                partes.append(bloco)
                pendente += bloco
                *linhas, pendente = pendente.split("\n")
                if log:
                    for linha in linhas:
                        log(self._mascara(linha))
            elif canal.exit_status_ready():
                break
            elif time.monotonic() - inicio > timeout:
                canal.close()
                raise SSHErro(f"comando passou de {int(timeout)} s")
            else:
                time.sleep(0.05)
        while canal.recv_ready():
            bloco = canal.recv(65536).decode(errors="replace")
            partes.append(bloco)
            pendente += bloco
        if log and pendente.strip():
            for linha in pendente.split("\n"):
                log(self._mascara(linha))
        codigo = canal.recv_exit_status()
        saida = self._mascara("".join(partes))
        if checar and codigo != 0:
            raise SSHErro(f"comando falhou (código {codigo}): {saida.strip()[-400:]}")
        return codigo, saida

    def enviar(self, conteudo: bytes, destino: str, modo: int = 0o644, dono: str = "root:root") -> None:
        """Grava `conteudo` em `destino` com dono e modo, via arquivo temporário + `install` (atômico)."""
        if self._cliente is None:
            raise SSHErro("sessão fechada")
        q = shlex.quote
        # Pasta temporária própria (mktemp -d, 0700): nome imprevisível, sem corrida de symlink em /tmp.
        _, pasta = self.rodar("umask 077; mktemp -d")
        pasta = pasta.strip().splitlines()[-1]
        if not pasta.startswith("/tmp/"):  # noqa: S108 — só confere o retorno do mktemp
            raise SSHErro("mktemp devolveu caminho inesperado")
        tmp = f"{pasta}/arquivo"
        sftp = self._cliente.open_sftp()
        try:
            with sftp.file(tmp, "wb") as f:
                f.set_pipelined(True)
                f.write(conteudo)
        finally:
            sftp.close()
        usuario, grupo = dono.split(":")
        self.rodar(
            f"install -D -m {modo:o} -o {q(usuario)} -g {q(grupo)} {q(tmp)} {q(destino)}; rc=$?; "
            f"rm -rf {q(pasta)}; exit $rc",
            sudo=True,
        )

    def ler(self, caminho: str) -> str | None:
        codigo, saida = self.rodar(f"cat {shlex.quote(caminho)} 2>/dev/null", sudo=True, checar=False)
        return saida if codigo == 0 else None
