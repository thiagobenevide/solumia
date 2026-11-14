"""Claude Code accounts on the PC, to switch from the app when one hits the window limit.

Each extra account is a config folder (`CLAUDE_CONFIG_DIR`) with its own login; the "principal"
one is the default (`~/.claude`, the terminal's). The active one applies to every `claude` the
worker starts: the variable lives in the process environment. `projects`, `settings.json`,
`skills` and `plugins` of the extra accounts are links to the principal's, so tabs keep going
(`--resume`) and memory stays the same after a switch.

Login: `claude auth login` in a pseudo-terminal; the app receives the link, the person authorizes
in the browser (any device) and pastes the code shown, which is written into the terminal."""

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
# Login link: inside the terminal hyperlink (OSC 8) or bare.
_URL_OSC = re.compile(rb"\x1b\]8;;(https://[^\x07\x1b]+/oauth/authorize\?[^\x07\x1b]+)")
_URL = re.compile(rb"(https://\S+/oauth/authorize\?[^\s\x07\x1b]+)")
_ESCAPE = re.compile(r"\x1b\][^\x07]*\x07|\x1b\[[0-9;?]*[A-Za-z]")
_ABANDONMENT_S = 600


@dataclass
class _Login:
    proc: asyncio.subprocess.Process
    fd: int


def _read(fd: int, ate: re.Pattern[bytes] | None, limit_s: float) -> bytes:
    """Reads the terminal until the pattern shows up, the process closes the terminal or the time
    limit passes."""
    output = b""
    end = time.monotonic() + limit_s
    while time.monotonic() < end:
        ready, _, _ = select.select([fd], [], [], 0.3)
        if not ready:
            continue
        try:
            chunk = os.read(fd, 4096)
        except OSError:  # the process exited
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
        self._folder = Path(pasta).expanduser()
        self._bin = binario
        self._default = Path(default).expanduser()
        self._logins: dict[str, _Login] = {}
        self._apply(self.ativa())

    async def executar(self, task: str, payload: dict[str, Any]) -> dict[str, Any]:
        name = str(payload.get("nome") or "")
        if task == "contas.ativar":
            return await self.activate(name)
        if task == "contas.entrar":
            return await self.enter(name)
        if task == "contas.codigo":
            return await self.codigo(name, str(payload.get("codigo") or ""))
        if task == "contas.remover":
            return await self.remover(name)
        return await self.list_all()

    def ativa(self) -> str:
        try:
            name = (self._folder / "ativa").read_text().strip()
        except OSError:
            return MAIN
        return name if name != MAIN and (self._folder / name).is_dir() else MAIN

    def _dir(self, nome: str) -> Path:
        return self._default if nome == MAIN else self._folder / nome

    def _names(self) -> list[str]:
        if not self._folder.is_dir():
            return [MAIN]
        return [MAIN, *sorted(p.name for p in self._folder.iterdir() if p.is_dir())]

    def _environment(self, nome: str) -> dict[str, str]:
        env = dict(os.environ)
        env.pop("CLAUDE_CONFIG_DIR", None)
        if nome != MAIN:
            env["CLAUDE_CONFIG_DIR"] = str(self._dir(nome))
        return env

    def _apply(self, nome: str) -> None:
        if nome == MAIN:
            os.environ.pop("CLAUDE_CONFIG_DIR", None)
        else:
            os.environ["CLAUDE_CONFIG_DIR"] = str(self._dir(nome))

    def _validate(self, nome: str, existente: bool = True) -> None:
        if nome != MAIN and not _NAME.match(nome):
            raise RuntimeError("Nome de conta inválido: use letras minúsculas, números, - ou _.")
        if existente and nome not in self._names():
            raise RuntimeError(f"Conta {nome!r} não existe.")

    async def _status(self, nome: str) -> dict[str, Any]:
        data: dict[str, Any] = {}
        try:
            process = await asyncio.create_subprocess_exec(
                self._bin, "auth", "status", "--json",
                env=self._environment(nome),
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

    async def list_all(self) -> dict[str, Any]:
        accounts = await asyncio.gather(*(self._status(n) for n in self._names()))
        return {"ativa": self.ativa(), "contas": list(accounts)}

    async def activate(self, nome: str) -> dict[str, Any]:
        self._validate(nome)
        if not (await self._status(nome))["logado"]:
            raise RuntimeError(f"A conta {nome!r} não está logada. Entre nela antes de ativar.")
        self._folder.mkdir(parents=True, exist_ok=True)
        (self._folder / "ativa").write_text(nome)
        self._apply(nome)
        return await self.list_all()

    def _prepare(self, nome: str) -> None:
        folder = self._dir(nome)
        folder.mkdir(parents=True, exist_ok=True)
        for item in _SHARED:
            origin, destination = self._default / item, folder / item
            if origin.exists() and not destination.exists() and not destination.is_symlink():
                destination.symlink_to(origin)

    def _cancel(self, nome: str) -> None:
        login = self._logins.pop(nome, None)
        if login is None:
            return
        with contextlib.suppress(ProcessLookupError):
            login.proc.kill()
        with contextlib.suppress(OSError):
            os.close(login.fd)

    async def enter(self, nome: str) -> dict[str, Any]:
        """Starts the account login (creates the folder if new) and returns the authorization
        link."""
        self._validate(nome, existente=False)
        if nome != MAIN:
            self._prepare(nome)
        self._cancel(nome)
        mestre, escravo = os.openpty()
        try:
            process = await asyncio.create_subprocess_exec(
                self._bin, "auth", "login",
                env={**self._environment(nome), "BROWSER": "/bin/true"},  # the browser is the app's
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
            shown = _clean(output)[-300:] or "sem saída"
            raise RuntimeError(f"O login não mostrou o link: {shown}")
        login = self._logins[nome] = _Login(process, mestre)

        def abandonar() -> None:  # only if it is still this login (not one started later)
            if self._logins.get(nome) is login:
                self._cancel(nome)

        asyncio.get_running_loop().call_later(_ABANDONMENT_S, abandonar)
        return {"nome": nome, "url": found[1].decode()}

    async def codigo(self, nome: str, code: str) -> dict[str, Any]:
        """Pastes the code shown after authorization and waits for the login to finish."""
        login = self._logins.pop(nome, None)
        if login is None:
            raise RuntimeError("Nenhum login em andamento para esta conta. Comece de novo.")
        try:
            os.write(login.fd, code.strip().encode() + b"\r")
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
        return await self.list_all()

    async def remover(self, nome: str) -> dict[str, Any]:
        self._validate(nome)
        if nome == MAIN:
            raise RuntimeError("A conta principal (a do terminal) não pode ser removida.")
        self._cancel(nome)
        if self.ativa() == nome:
            (self._folder / "ativa").write_text(MAIN)
            self._apply(MAIN)
        shutil.rmtree(self._dir(nome))  # shared links are deleted, not followed
        return await self.list_all()
