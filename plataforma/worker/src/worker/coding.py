"""Codificação a distância: sessões do Claude Code (`claude -p`, assinatura logada neste PC)
rodando dentro do repositório, pedidas pelo app via VPS. Cada aba do app é uma sessão; o pedido
seguinte continua a conversa (`--resume`). As etapas (texto, ferramentas, resultado) voltam ao
Gateway como `evento` do canal `codigo` enquanto o Claude trabalha."""

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

# Navegador de código (só leitura): commit pedido pelo app e tamanho máximo do arquivo enviado.
_COMMIT = re.compile(r"^[0-9a-f]{4,40}$")
_LIMIT_FILE = 400_000
_LIMIT_SEARCH = 400
# Observações = comentários: o termo tem que aparecer depois de um marcador de comentário;
# sem termo, as marcações de pendência (TODO, FIXME...).
_COMMENT = re.compile(r"(//|#|/\*|^\s*\*|<!--|^\s*--\s)")
_MARKS = re.compile(r"\b(TODO|FIXME|XXX|HACK|NOTE|OBS)\b")
_HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def lines_new(diff: str) -> list[int]:
    """Números (lado novo) das linhas adicionadas num diff `-U0` (hunk `+início,n` = n linhas)."""
    new: list[int] = []
    for line in diff.splitlines():
        m = _HUNK.match(line)
        if m:
            start, n = int(m[1]), int(m[2] if m[2] is not None else 1)
            new.extend(range(start, start + n))
    return new


def changes(name_status: str) -> list[dict[str, str]]:
    """`git diff-tree --name-status` → `[{caminho, status}]` (A, M, D, R…; renomeado: nome novo)."""
    output = []
    for line in name_status.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2:
            output.append({"caminho": parts[-1], "status": parts[0][:1]})
    return output

# Vai junto do CLAUDE.md do repositório (carregado normalmente, pois roda na pasta do projeto).
SYSTEM = """Você está sendo acionado a distância pelo app (módulo Código), sem ninguém no terminal.
- Siga à risca o CLAUDE.md do repositório e os CLAUDE.md das pastas que tocar (economia de tokens, \
validação com infra/scripts/verificar, estilo em português).
- Não faça perguntas: decida pelo padrão do projeto e diga no fim o que assumiu.
- Outras sessões podem estar editando o mesmo repositório ao mesmo tempo: não reverta nem commite \
mudanças que não são suas.
- Só faça commit, push ou publicação quando o pedido mandar.
- Termine com um resumo curto: o que mudou (arquivo:linha), o que falhou e o próximo passo."""

_LIMIT_SUMMARY = 600

Issue = Callable[[dict[str, Any]], Awaitable[None]]


def _short(text: str, limite: int = _LIMIT_SUMMARY) -> str:
    text = text.strip()
    return text if len(text) <= limite else text[:limite] + "…"


def _summary_tool(nome: str, entry: dict[str, Any]) -> str:
    """O que a ferramenta vai fazer, numa linha: comando, arquivo ou padrão buscado."""
    for key in ("command", "file_path", "pattern", "path", "url", "description", "prompt"):
        if entry.get(key):
            return _short(str(entry[key]), 300)
    return _short(json.dumps(entry, ensure_ascii=False), 300)


def _text_result(content: Any) -> str:
    if isinstance(content, list):
        return "\n".join(str(c.get("text", "")) for c in content if isinstance(c, dict))
    return str(content or "")


def stages(msg: dict[str, Any]) -> list[dict[str, Any]]:
    """Uma linha do `--output-format stream-json` → etapas mostradas no app."""
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
    """Sessões em andamento (uma execução do `claude` por sessão por vez)."""

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
        """Grava as imagens, sobe o `claude` e volta na hora; as etapas seguem por `evento`."""
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
                limit=2**24,  # linhas do stream-json com resultados grandes de ferramentas
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
        terminou = False
        try:
            async for line in process.stdout:
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue
                for stage in stages(msg):
                    terminou = terminou or stage["tipo"] == "fim"
                    await self._avisar(session, stage)
            error = (await process.stderr.read()).decode(errors="replace").strip()
            code = await process.wait()
            if not terminou:
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
            # Sem conexão com o Gateway agora: a etapa se perde, o Claude segue trabalhando.
            logger.warning("Etapa da sessão %s não entregue ao Gateway", session)

    def stop(self, session: str) -> dict[str, Any]:
        process = self._processes.get(session)
        if process is None:
            return {"ok": False}
        process.terminate()
        return {"ok": True}

    async def git(self) -> dict[str, Any]:
        """Branch, arquivos alterados e últimos commits do repositório."""

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
        """Saída do `git` no repositório; código de saída ≠ 0 → RuntimeError com o stderr
        ([vazio_ok]: código 1 = nada encontrado, como no `git grep`)."""
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
        """Hash completo do [commit] (vazio = HEAD); só aceita hash, nunca ref ou opção."""
        if commit and not _COMMIT.match(commit):
            raise RuntimeError("Commit inválido")
        output = await self._git("rev-parse", "--verify", f"{commit or 'HEAD'}^{{commit}}")
        return output.decode().strip()

    async def tree(self, commit: str) -> dict[str, Any]:
        """Arquivos do repositório no [commit], o que ele mudou e os últimos commits."""
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
        """Conteúdo do arquivo no [commit] e as linhas que esse commit adicionou nele."""
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
        """Linhas com o [termo] (sem diferenciar maiúsculas) nos arquivos de texto do [commit];
        [observacoes]: só onde o termo está num comentário (sem termo: TODO/FIXME/...)."""
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
