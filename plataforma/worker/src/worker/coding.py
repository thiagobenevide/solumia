"""Remote coding: Claude Code sessions (`claude -p`, subscription logged in on this PC) running
inside the repository, requested by the app through the VPS. Each app tab is a session; the next
request continues the conversation (`--resume`). The steps (text, tools, result) go back to the
Gateway as `evento` of the `codigo` channel while Claude works."""

import asyncio
import base64
import json
import logging
import re
from collections.abc import Awaitable, Callable
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from worker.core.config import WorkerSettings

logger = logging.getLogger("worker.coding")

TASKS = {
    "codigo.enviar", "codigo.parar", "codigo.git",
    "codigo.arvore", "codigo.arquivo", "codigo.buscar",
}

# Code browser (read only): commit requested by the app and max size of the file sent.
_COMMIT = re.compile(r"^[0-9a-f]{4,40}$")
_LIMIT_FILE = 400_000
_LIMIT_SEARCH = 400
# Observations = comments: the term must appear after a comment marker;
# without a term, the pending-work markers (TODO, FIXME...).
_COMMENT = re.compile(r"(//|#|/\*|^\s*\*|<!--|^\s*--\s)")
_MARKS = re.compile(r"\b(TODO|FIXME|XXX|HACK|NOTE|OBS)\b")
_HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def lines_new(diff: str) -> list[int]:
    """Numbers (new side) of the lines added in a `-U0` diff (hunk `+start,n` = n lines)."""
    new: list[int] = []
    for line in diff.splitlines():
        m = _HUNK.match(line)
        if m:
            start, n = int(m[1]), int(m[2] if m[2] is not None else 1)
            new.extend(range(start, start + n))
    return new


def changes(name_status: str) -> list[dict[str, str]]:
    """`git diff-tree --name-status` → `[{caminho, status}]` (A, M, D, R…; renamed: new name)."""
    output = []
    for line in name_status.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2:
            output.append({"caminho": parts[-1], "status": parts[0][:1]})
    return output

# Goes along with the repository CLAUDE.md (loaded as usual, since it runs in the project folder).
SYSTEM = """You are being triggered remotely by the app (Código module), with nobody at the
terminal.
- Follow to the letter the repository's CLAUDE.md and the CLAUDE.md of the folders you touch \
(token economy, validation with infra/scripts/verificar, the code style defined there).
- Do not ask questions: decide by the project's patterns and say at the end what you assumed.
- Other sessions may be editing the same repository at the same time: do not revert or commit \
changes that are not yours.
- Only commit, push or publish when the request says so.
- End with a short summary in Brazilian Portuguese: what changed (file:line), what failed and the \
next step."""

_LIMIT_SUMMARY = 600

Issue = Callable[[dict[str, Any]], Awaitable[None]]


def _short(text: str, limite: int = _LIMIT_SUMMARY) -> str:
    text = text.strip()
    return text if len(text) <= limite else text[:limite] + "…"


def _summary_tool(nome: str, entry: dict[str, Any]) -> str:
    """What the tool is about to do, in one line: command, file or searched pattern."""
    for key in ("command", "file_path", "pattern", "path", "url", "description", "prompt"):
        if entry.get(key):
            return _short(str(entry[key]), 300)
    return _short(json.dumps(entry, ensure_ascii=False), 300)


def _text_result(content: Any) -> str:
    if isinstance(content, list):
        return "\n".join(str(c.get("text", "")) for c in content if isinstance(c, dict))
    return str(content or "")


def stages(msg: dict[str, Any]) -> list[dict[str, Any]]:
    """One `--output-format stream-json` line → steps shown in the app."""
    kind = msg.get("type")
    if kind == "system" and msg.get("subtype") == "init":
        return [
            {"tipo": "inicio", "claude_sessao": msg.get("session_id"), "modelo": msg.get("model")}
        ]
    if kind == "assistant":
        output: list[dict[str, Any]] = []
        for block in (msg.get("message") or {}).get("content") or []:
            if block.get("type") == "text" and str(block.get("text", "")).strip():
                output.append({"tipo": "texto", "texto": block["text"]})
            elif block.get("type") == "tool_use":
                name = str(block.get("name", ""))
                output.append(
                    {
                        "tipo": "ferramenta",
                        "nome": name,
                        "resumo": _summary_tool(name, block.get("input") or {}),
                    }
                )
        return output
    if kind == "user":
        content = (msg.get("message") or {}).get("content")
        if not isinstance(content, list):
            return []
        return [
            {
                "tipo": "resultado",
                "erro": bool(b.get("is_error")),
                "resumo": _short(_text_result(b.get("content"))),
            }
            for b in content
            if isinstance(b, dict) and b.get("type") == "tool_result"
        ]
    if kind == "result":
        return [
            {
                "tipo": "fim",
                "erro": bool(msg.get("is_error")),
                "texto": str(msg.get("result") or msg.get("subtype") or ""),
                "claude_sessao": msg.get("session_id"),
                "custo_usd": msg.get("total_cost_usd"),
                "turnos": msg.get("num_turns"),
                "duracao_ms": msg.get("duration_ms"),
            }
        ]
    return []


def _name_safe(nome: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]", "_", nome)[-80:] or "imagem.png"


class Code:
    """Running sessions (one `claude` run per session at a time)."""

    def __init__(self, settings: WorkerSettings, issue: Issue) -> None:
        self._settings = settings
        self._issue = issue
        self._processes: dict[str, asyncio.subprocess.Process] = {}
        self._tasks: set[asyncio.Task[None]] = set()

    @property
    def _repo(self) -> Path:
        return Path(self._settings.codigo_dir).expanduser()

    @property
    def _images_dir(self) -> Path:
        return Path(self._settings.codigo_imagens_dir).expanduser()

    async def executar(self, task: str, payload: dict[str, Any]) -> dict[str, Any]:
        if task == "codigo.enviar":
            return await self.enviar(payload)
        if task == "codigo.parar":
            return self.stop(str(payload["sessao_id"]))
        if task == "codigo.arvore":
            return await self.tree(str(payload.get("commit") or ""))
        if task == "codigo.arquivo":
            return await self.arquivo(str(payload["caminho"]), str(payload.get("commit") or ""))
        if task == "codigo.buscar":
            return await self.fetch(
                str(payload.get("termo") or ""),
                str(payload.get("commit") or ""),
                observacoes=bool(payload.get("observacoes")),
            )
        return await self.git()

    async def enviar(self, payload: dict[str, Any]) -> dict[str, Any]:
        """Stores the images, starts `claude` and returns right away; the steps follow as
        `evento`."""
        session = str(payload["sessao_id"])
        if session in self._processes:
            raise RuntimeError("Esta aba ainda está trabalhando. Pare ou espere terminar.")
        text = str(payload.get("texto") or "").strip()
        paths = self._write_images(session, payload.get("imagens") or [])
        if paths:
            text += "\n\nImagens de referência (abra com a ferramenta Read):\n" + "\n".join(
                f"- {c}" for c in paths
            )
        command = [
            self._settings.codigo_claude_bin, "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--permission-mode", self._settings.codigo_permissao,
            "--append-system-prompt", SYSTEM,
            "--add-dir", str(self._images_dir),
        ]
        if self._settings.codigo_ferramentas.strip():
            command += ["--allowedTools", *self._settings.codigo_ferramentas.split(",")]
        if self._settings.codigo_ferramentas_proibidas.strip():
            command += [
                "--disallowedTools", *self._settings.codigo_ferramentas_proibidas.split(",")
            ]
        if payload.get("claude_sessao"):
            command += ["--resume", str(payload["claude_sessao"])]
        if payload.get("modelo"):
            command += ["--model", str(payload["modelo"])]
        try:
            process = await asyncio.create_subprocess_exec(
                *command,
                cwd=self._repo,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                limit=2**24,  # stream-json lines with large tool results
            )
        except FileNotFoundError as e:
            raise RuntimeError("Claude Code (`claude`) não está instalado neste computador.") from e
        self._processes[session] = process
        assert process.stdin is not None
        process.stdin.write(text.encode())
        await process.stdin.drain()
        process.stdin.close()
        task = asyncio.create_task(self._track(session, process))
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        return {"ok": True, "imagens": paths}

    def _write_images(self, session: str, images: list[dict[str, Any]]) -> list[str]:
        folder = self._images_dir / _name_safe(session)
        paths = []
        for img in images:
            folder.mkdir(parents=True, exist_ok=True)
            file = folder / f"{datetime.now(UTC):%Y%m%d%H%M%S%f}-{_name_safe(str(img['nome']))}"
            file.write_bytes(base64.b64decode(str(img["b64"])))
            paths.append(str(file))
        return paths

    async def _track(self, session: str, process: asyncio.subprocess.Process) -> None:
        assert process.stdout is not None and process.stderr is not None
        finished = False
        try:
            async for line in process.stdout:
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue
                for stage in stages(msg):
                    finished = finished or stage["tipo"] == "fim"
                    await self._avisar(session, stage)
            error = (await process.stderr.read()).decode(errors="replace").strip()
            code = await process.wait()
            if not finished:
                reason = "Parado pelo app." if code < 0 else _short(error or f"saída {code}")
                await self._avisar(session, {"tipo": "fim", "erro": code != 0, "texto": reason})
        except Exception as e:
            logger.exception("Falha acompanhando a sessão %s", session)
            await self._avisar(session, {"tipo": "fim", "erro": True, "texto": str(e)})
        finally:
            self._processes.pop(session, None)

    async def _avisar(self, session: str, etapa: dict[str, Any]) -> None:
        try:
            await self._issue({**etapa, "sessao_id": session, "em": datetime.now(UTC).isoformat()})
        except Exception:
            # No connection to the Gateway right now: the step is lost, Claude keeps working.
            logger.warning("Etapa da sessão %s não entregue ao Gateway", session)

    def stop(self, session: str) -> dict[str, Any]:
        process = self._processes.get(session)
        if process is None:
            return {"ok": False}
        process.terminate()
        return {"ok": True}

    async def git(self) -> dict[str, Any]:
        """Branch, changed files and latest commits of the repository."""

        async def rodar(*args: str) -> str:
            process = await asyncio.create_subprocess_exec(
                "git", *args, cwd=self._repo,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
            )
            output, _ = await process.communicate()
            return output.decode(errors="replace").rstrip()

        return {
            "status": await rodar("status", "--short", "--branch"),
            "log": await rodar("log", "--oneline", "-10"),
            "rodando": sorted(self._processes),
        }

    async def _git(self, *args: str, vazio_ok: bool = False) -> bytes:
        """`git` output in the repository; exit code ≠ 0 → RuntimeError with the stderr
        (with empty-ok: exit code 1 = nothing found, as in `git grep`)."""
        process = await asyncio.create_subprocess_exec(
            "git", *args, cwd=self._repo,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
        output, error = await process.communicate()
        if process.returncode == 1 and vazio_ok:
            return b""
        if process.returncode:
            raise RuntimeError(error.decode(errors="replace").strip() or f"git {args[0]} falhou")
        return output

    async def _commit(self, commit: str) -> str:
        """Full hash of the commit (empty = HEAD); accepts only a hash, never a ref or an option."""
        if commit and not _COMMIT.match(commit):
            raise RuntimeError("Commit inválido")
        output = await self._git("rev-parse", "--verify", f"{commit or 'HEAD'}^{{commit}}")
        return output.decode().strip()

    async def tree(self, commit: str) -> dict[str, Any]:
        """Repository files at the commit, what it changed and the latest commits."""
        target = await self._commit(commit)
        log = await self._git("log", "-40", "--format=%H%x1f%h%x1f%s%x1f%an%x1f%cI")
        fields = ("hash", "curto", "assunto", "autor", "data")
        commits = [
            dict(zip(fields, line.split("\x1f"), strict=False))
            for line in log.decode(errors="replace").splitlines()
        ]
        files = await self._git("ls-tree", "-r", "--name-only", "-z", target)
        status = await self._git(
            "diff-tree", "--no-commit-id", "-r", "--root", "--name-status", "-M", target
        )
        return {
            "commit": target,
            "commits": commits,
            "arquivos": [a for a in files.decode(errors="replace").split("\0") if a],
            "mudancas": changes(status.decode(errors="replace")),
        }

    async def arquivo(self, caminho: str, commit: str) -> dict[str, Any]:
        """File content at the commit and the lines that commit added to it."""
        if not caminho or caminho.startswith(("/", "-")) or ".." in caminho.split("/"):
            raise RuntimeError("Caminho inválido")
        target = await self._commit(commit)
        data = await self._git("show", f"{target}:{caminho}")
        if b"\0" in data[:8000]:
            return {"caminho": caminho, "binario": True, "tamanho": len(data)}
        diff = await self._git(
            "show", "--format=", "-U0", "--no-color", "-M", target, "--", caminho
        )
        return {
            "caminho": caminho,
            "binario": False,
            "tamanho": len(data),
            "cortado": len(data) > _LIMIT_FILE,
            "texto": data[:_LIMIT_FILE].decode(errors="replace"),
            "novas": lines_new(diff.decode(errors="replace")),
        }

    async def fetch(self, term: str, commit: str, *, observacoes: bool = False) -> dict[str, Any]:
        """Lines with the term (case-insensitive) in the text files of the commit;
        with observations: only where the term is in a comment (without a term: TODO/FIXME/...)."""
        term = term.strip()
        if not term and not observacoes:
            raise RuntimeError("Digite o que buscar")
        if len(term) > 200:
            raise RuntimeError("Busca longa demais")
        target = await self._commit(commit)
        default = ["-F", "-i", "-e", term] if term else ["-w", "-E", "-e", _MARKS.pattern[3:-3]]
        output = await self._git(
            "grep", "-n", "-I", "-z", "--no-color", "--max-count=50", *default, target, "--",
            vazio_ok=True,
        )
        results: list[dict[str, Any]] = []
        cortado = False
        prefix = f"{target}:"
        for line in output.decode(errors="replace").splitlines():
            parts = line.split("\0", 2)
            if len(parts) < 3 or not parts[1].isdigit():
                continue
            path, number, text = parts
            if observacoes:
                start = _COMMENT.search(text)
                rest = text[start.start():] if start else ""
                if not (term.lower() in rest.lower() if term else _MARKS.search(rest)):
                    continue
            if len(results) >= _LIMIT_SEARCH:
                cortado = True
                break
            results.append({
                "caminho": path.removeprefix(prefix),
                "linha": int(number),
                "texto": text.strip()[:240],
            })
        return {"commit": target, "resultados": results, "cortado": cortado}
