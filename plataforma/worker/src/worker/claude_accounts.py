"""Contas do Claude Code no PC, para trocar pelo app quando uma bate o limite da janela.

Cada conta extra é uma pasta de configuração (`CLAUDE_CONFIG_DIR`) com o próprio login; a
"principal" é a padrão (`~/.claude`, a do terminal). A ativa vale para todo `claude` que o worker
sobe: a variável fica no ambiente do processo. `projects`, `settings.json`, `skills` e `plugins`
das contas extras são links para os da principal, para as abas continuarem (`--resume`) e a
memória ser a mesma depois da troca.

Login: `claude auth login` num pseudo-terminal; o app recebe o link, a pessoa autoriza no
navegador (qualquer aparelho) e cola o código mostrado, que é escrito no terminal."""

import asyncio
import contextlib
import json
import os
import re
import select
import shutil
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

TASKS = {"contas.listar", "contas.ativar", "contas.entrar", "contas.codigo", "contas.remover"}

MAIN = "principal"
_NAME = re.compile(r"^[a-z0-9][a-z0-9_-]{0,30}$")
_SHARED = ("projects", "settings.json", "skills", "plugins")
# Link do login: dentro do hyperlink do terminal (OSC 8) ou solto.
_URL_OSC = re.compile(rb"\x1b\]8;;(https://[^\x07\x1b]+/oauth/authorize\?[^\x07\x1b]+)")
_URL = re.compile(rb"(https://\S+/oauth/authorize\?[^\s\x07\x1b]+)")
_ESCAPE = re.compile(r"\x1b\][^\x07]*\x07|\x1b\[[0-9;?]*[A-Za-z]")
_ABANDONMENT_S = 600


@dataclass
class _Login:
    proc: asyncio.subprocess.Process
    fd: int


def _read(fd: int, ate: re.Pattern[bytes] | None, limit_s: float) -> bytes:
    """Lê o terminal até achar [ate], o processo fechar o terminal ou passar [limite_s]."""
    output = b""
    end = time.monotonic() + limit_s
    while time.monotonic() < end:
        ready, _, _ = select.select([fd], [], [], 0.3)
        if not ready:
            continue
        try:
            chunk = os.read(fd, 4096)
        except OSError:  # processo saiu
            break
        if not chunk:
            break
        output += chunk
        if ate is not None and ate.search(output):
            break
    return output


def _clean(output: bytes) -> str:
    return _ESCAPE.sub("", output.decode(errors="replace")).strip()


class Accounts:
    def __init__(self, pasta: str, binario: str = "claude", default: str = "~/.claude") -> None:
        self._pasta = Path(pasta).expanduser()
        self._bin = binario
        self._padrao = Path(default).expanduser()
        self._logins: dict[str, _Login] = {}
        self._aplicar(self.ativa())

    async def executar(self, task: str, payload: dict[str, Any]) -> dict[str, Any]:
        name = str(payload.get("nome") or "")
        if task == "contas.ativar":
            return await self.ativar(name)
        if task == "contas.entrar":
            return await self.entrar(name)
        if task == "contas.codigo":
            return await self.codigo(name, str(payload.get("codigo") or ""))
        if task == "contas.remover":
            return await self.remover(name)
        return await self.listar()

    def ativa(self) -> str:
        try:
            name = (self._pasta / "ativa").read_text().strip()
        except OSError:
            return MAIN
        return name if name != MAIN and (self._pasta / name).is_dir() else MAIN

    def _dir(self, nome: str) -> Path:
        return self._padrao if nome == MAIN else self._pasta / nome

    def _nomes(self) -> list[str]:
        if not self._pasta.is_dir():
            return [MAIN]
        return [MAIN, *sorted(p.name for p in self._pasta.iterdir() if p.is_dir())]

    def _ambiente(self, nome: str) -> dict[str, str]:
        env = dict(os.environ)
        env.pop("CLAUDE_CONFIG_DIR", None)
        if nome != MAIN:
            env["CLAUDE_CONFIG_DIR"] = str(self._dir(nome))
        return env

    def _aplicar(self, nome: str) -> None:
        if nome == MAIN:
            os.environ.pop("CLAUDE_CONFIG_DIR", None)
        else:
            os.environ["CLAUDE_CONFIG_DIR"] = str(self._dir(nome))

    def _validar(self, nome: str, existente: bool = True) -> None:
        if nome != MAIN and not _NAME.match(nome):
            raise RuntimeError("Nome de conta inválido: use letras minúsculas, números, - ou _.")
        if existente and nome not in self._nomes():
            raise RuntimeError(f"Conta {nome!r} não existe.")

    async def _status(self, nome: str) -> dict[str, Any]:
        data: dict[str, Any] = {}
        try:
            process = await asyncio.create_subprocess_exec(
                self._bin, "auth", "status", "--json",
                env=self._ambiente(nome),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
            output, _ = await asyncio.wait_for(process.communicate(), 20)
            data = json.loads(output)
        except (OSError, TimeoutError, json.JSONDecodeError):
            pass
        return {
            "nome": nome,
            "logado": bool(data.get("loggedIn")),
            "email": str(data.get("email") or ""),
            "plano": str(data.get("subscriptionType") or ""),
        }

    async def listar(self) -> dict[str, Any]:
        accounts = await asyncio.gather(*(self._status(n) for n in self._nomes()))
        return {"ativa": self.ativa(), "contas": list(accounts)}

    async def ativar(self, nome: str) -> dict[str, Any]:
        self._validar(nome)
        if not (await self._status(nome))["logado"]:
            raise RuntimeError(f"A conta {nome!r} não está logada. Entre nela antes de ativar.")
        self._pasta.mkdir(parents=True, exist_ok=True)
        (self._pasta / "ativa").write_text(nome)
        self._aplicar(nome)
        return await self.listar()

    def _preparar(self, nome: str) -> None:
        folder = self._dir(nome)
        folder.mkdir(parents=True, exist_ok=True)
        for item in _SHARED:
            origin, destination = self._padrao / item, folder / item
            if origin.exists() and not destination.exists() and not destination.is_symlink():
                destination.symlink_to(origin)

    def _cancelar(self, nome: str) -> None:
        login = self._logins.pop(nome, None)
        if login is None:
            return
        with contextlib.suppress(ProcessLookupError):
            login.proc.kill()
        with contextlib.suppress(OSError):
            os.close(login.fd)

    async def entrar(self, nome: str) -> dict[str, Any]:
        """Começa o login da conta (cria a pasta se for nova) e devolve o link de autorização."""
        self._validar(nome, existente=False)
        if nome != MAIN:
            self._preparar(nome)
        self._cancelar(nome)
        mestre, escravo = os.openpty()
        try:
            process = await asyncio.create_subprocess_exec(
                self._bin, "auth", "login",
                env={**self._ambiente(nome), "BROWSER": "/bin/true"},  # o navegador é o do app
                stdin=escravo, stdout=escravo, stderr=escravo,
                start_new_session=True,
            )
        except FileNotFoundError as e:
            os.close(mestre)
            raise RuntimeError("Claude Code (`claude`) não está instalado neste computador.") from e
        finally:
            os.close(escravo)
        output = await asyncio.to_thread(_read, mestre, _URL_OSC, 30)
        found = _URL_OSC.search(output) or _URL.search(output)
        if found is None:
            with contextlib.suppress(ProcessLookupError):
                process.kill()
            os.close(mestre)
            raise RuntimeError(f"O login não mostrou o link: {_clean(output)[-300:] or 'sem saída'}")
        login = self._logins[nome] = _Login(process, mestre)

        def abandonar() -> None:  # só se ainda for este login (não um começado depois)
            if self._logins.get(nome) is login:
                self._cancelar(nome)

        asyncio.get_running_loop().call_later(_ABANDONMENT_S, abandonar)
        return {"nome": nome, "url": found[1].decode()}

    async def codigo(self, nome: str, codigo: str) -> dict[str, Any]:
        """Cola o código mostrado depois da autorização e espera o login terminar."""
        login = self._logins.pop(nome, None)
        if login is None:
            raise RuntimeError("Nenhum login em andamento para esta conta. Comece de novo.")
        try:
            os.write(login.fd, codigo.strip().encode() + b"\r")
            output = await asyncio.to_thread(_read, login.fd, None, 40)
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(login.proc.wait(), 5)
        finally:
            with contextlib.suppress(ProcessLookupError):
                login.proc.kill()
            with contextlib.suppress(OSError):
                os.close(login.fd)
        status = await self._status(nome)
        if not status["logado"]:
            reason = _clean(output)[-300:] or "sem resposta"
            raise RuntimeError(f"O login não foi concluído: {reason}")
        return await self.listar()

    async def remover(self, nome: str) -> dict[str, Any]:
        self._validar(nome)
        if nome == MAIN:
            raise RuntimeError("A conta principal (a do terminal) não pode ser removida.")
        self._cancelar(nome)
        if self.ativa() == nome:
            (self._pasta / "ativa").write_text(MAIN)
            self._aplicar(MAIN)
        shutil.rmtree(self._dir(nome))  # os links compartilhados são apagados, não seguidos
        return await self.listar()
