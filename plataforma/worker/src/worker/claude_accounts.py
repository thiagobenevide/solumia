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

TAREFAS = {"contas.listar", "contas.ativar", "contas.entrar", "contas.codigo", "contas.remover"}

PRINCIPAL = "principal"
_NOME = re.compile(r"^[a-z0-9][a-z0-9_-]{0,30}$")
_COMPARTILHADOS = ("projects", "settings.json", "skills", "plugins")
# Link do login: dentro do hyperlink do terminal (OSC 8) ou solto.
_URL_OSC = re.compile(rb"\x1b\]8;;(https://[^\x07\x1b]+/oauth/authorize\?[^\x07\x1b]+)")
_URL = re.compile(rb"(https://\S+/oauth/authorize\?[^\s\x07\x1b]+)")
_ESCAPE = re.compile(r"\x1b\][^\x07]*\x07|\x1b\[[0-9;?]*[A-Za-z]")
_ABANDONO_S = 600


@dataclass
class _Login:
    proc: asyncio.subprocess.Process
    fd: int


def _ler(fd: int, ate: re.Pattern[bytes] | None, limite_s: float) -> bytes:
    """Lê o terminal até achar [ate], o processo fechar o terminal ou passar [limite_s]."""
    saida = b""
    fim = time.monotonic() + limite_s
    while time.monotonic() < fim:
        pronto, _, _ = select.select([fd], [], [], 0.3)
        if not pronto:
            continue
        try:
            pedaco = os.read(fd, 4096)
        except OSError:  # processo saiu
            break
        if not pedaco:
            break
        saida += pedaco
        if ate is not None and ate.search(saida):
            break
    return saida


def _limpo(saida: bytes) -> str:
    return _ESCAPE.sub("", saida.decode(errors="replace")).strip()


class Contas:
    def __init__(self, pasta: str, binario: str = "claude", padrao: str = "~/.claude") -> None:
        self._pasta = Path(pasta).expanduser()
        self._bin = binario
        self._padrao = Path(padrao).expanduser()
        self._logins: dict[str, _Login] = {}
        self._aplicar(self.ativa())

    async def executar(self, tarefa: str, payload: dict[str, Any]) -> dict[str, Any]:
        nome = str(payload.get("nome") or "")
        if tarefa == "contas.ativar":
            return await self.ativar(nome)
        if tarefa == "contas.entrar":
            return await self.entrar(nome)
        if tarefa == "contas.codigo":
            return await self.codigo(nome, str(payload.get("codigo") or ""))
        if tarefa == "contas.remover":
            return await self.remover(nome)
        return await self.listar()

    def ativa(self) -> str:
        try:
            nome = (self._pasta / "ativa").read_text().strip()
        except OSError:
            return PRINCIPAL
        return nome if nome != PRINCIPAL and (self._pasta / nome).is_dir() else PRINCIPAL

    def _dir(self, nome: str) -> Path:
        return self._padrao if nome == PRINCIPAL else self._pasta / nome

    def _nomes(self) -> list[str]:
        if not self._pasta.is_dir():
            return [PRINCIPAL]
        return [PRINCIPAL, *sorted(p.name for p in self._pasta.iterdir() if p.is_dir())]

    def _ambiente(self, nome: str) -> dict[str, str]:
        env = dict(os.environ)
        env.pop("CLAUDE_CONFIG_DIR", None)
        if nome != PRINCIPAL:
            env["CLAUDE_CONFIG_DIR"] = str(self._dir(nome))
        return env

    def _aplicar(self, nome: str) -> None:
        if nome == PRINCIPAL:
            os.environ.pop("CLAUDE_CONFIG_DIR", None)
        else:
            os.environ["CLAUDE_CONFIG_DIR"] = str(self._dir(nome))

    def _validar(self, nome: str, existente: bool = True) -> None:
        if nome != PRINCIPAL and not _NOME.match(nome):
            raise RuntimeError("Nome de conta inválido: use letras minúsculas, números, - ou _.")
        if existente and nome not in self._nomes():
            raise RuntimeError(f"Conta {nome!r} não existe.")

    async def _status(self, nome: str) -> dict[str, Any]:
        dados: dict[str, Any] = {}
        try:
            proc = await asyncio.create_subprocess_exec(
                self._bin, "auth", "status", "--json",
                env=self._ambiente(nome),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
            saida, _ = await asyncio.wait_for(proc.communicate(), 20)
            dados = json.loads(saida)
        except (OSError, TimeoutError, json.JSONDecodeError):
            pass
        return {
            "nome": nome,
            "logado": bool(dados.get("loggedIn")),
            "email": str(dados.get("email") or ""),
            "plano": str(dados.get("subscriptionType") or ""),
        }

    async def listar(self) -> dict[str, Any]:
        contas = await asyncio.gather(*(self._status(n) for n in self._nomes()))
        return {"ativa": self.ativa(), "contas": list(contas)}

    async def ativar(self, nome: str) -> dict[str, Any]:
        self._validar(nome)
        if not (await self._status(nome))["logado"]:
            raise RuntimeError(f"A conta {nome!r} não está logada. Entre nela antes de ativar.")
        self._pasta.mkdir(parents=True, exist_ok=True)
        (self._pasta / "ativa").write_text(nome)
        self._aplicar(nome)
        return await self.listar()

    def _preparar(self, nome: str) -> None:
        pasta = self._dir(nome)
        pasta.mkdir(parents=True, exist_ok=True)
        for item in _COMPARTILHADOS:
            origem, destino = self._padrao / item, pasta / item
            if origem.exists() and not destino.exists() and not destino.is_symlink():
                destino.symlink_to(origem)

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
        if nome != PRINCIPAL:
            self._preparar(nome)
        self._cancelar(nome)
        mestre, escravo = os.openpty()
        try:
            proc = await asyncio.create_subprocess_exec(
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
        saida = await asyncio.to_thread(_ler, mestre, _URL_OSC, 30)
        achado = _URL_OSC.search(saida) or _URL.search(saida)
        if achado is None:
            with contextlib.suppress(ProcessLookupError):
                proc.kill()
            os.close(mestre)
            raise RuntimeError(f"O login não mostrou o link: {_limpo(saida)[-300:] or 'sem saída'}")
        login = self._logins[nome] = _Login(proc, mestre)

        def abandonar() -> None:  # só se ainda for este login (não um começado depois)
            if self._logins.get(nome) is login:
                self._cancelar(nome)

        asyncio.get_running_loop().call_later(_ABANDONO_S, abandonar)
        return {"nome": nome, "url": achado[1].decode()}

    async def codigo(self, nome: str, codigo: str) -> dict[str, Any]:
        """Cola o código mostrado depois da autorização e espera o login terminar."""
        login = self._logins.pop(nome, None)
        if login is None:
            raise RuntimeError("Nenhum login em andamento para esta conta. Comece de novo.")
        try:
            os.write(login.fd, codigo.strip().encode() + b"\r")
            saida = await asyncio.to_thread(_ler, login.fd, None, 40)
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(login.proc.wait(), 5)
        finally:
            with contextlib.suppress(ProcessLookupError):
                login.proc.kill()
            with contextlib.suppress(OSError):
                os.close(login.fd)
        status = await self._status(nome)
        if not status["logado"]:
            motivo = _limpo(saida)[-300:] or "sem resposta"
            raise RuntimeError(f"O login não foi concluído: {motivo}")
        return await self.listar()

    async def remover(self, nome: str) -> dict[str, Any]:
        self._validar(nome)
        if nome == PRINCIPAL:
            raise RuntimeError("A conta principal (a do terminal) não pode ser removida.")
        self._cancelar(nome)
        if self.ativa() == nome:
            (self._pasta / "ativa").write_text(PRINCIPAL)
            self._aplicar(PRINCIPAL)
        shutil.rmtree(self._dir(nome))  # os links compartilhados são apagados, não seguidos
        return await self.listar()
