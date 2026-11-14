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

logger = logging.getLogger("worker.codigo")

TAREFAS = {
    "codigo.enviar", "codigo.parar", "codigo.git",
    "codigo.arvore", "codigo.arquivo", "codigo.buscar",
}

# Navegador de código (só leitura): commit pedido pelo app e tamanho máximo do arquivo enviado.
_COMMIT = re.compile(r"^[0-9a-f]{4,40}$")
_LIMITE_ARQUIVO = 400_000
_LIMITE_BUSCA = 400
# Observações = comentários: o termo tem que aparecer depois de um marcador de comentário;
# sem termo, as marcações de pendência (TODO, FIXME...).
_COMENTARIO = re.compile(r"(//|#|/\*|^\s*\*|<!--|^\s*--\s)")
_MARCAS = re.compile(r"\b(TODO|FIXME|XXX|HACK|NOTE|OBS)\b")
_HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def linhas_novas(diff: str) -> list[int]:
    """Números (lado novo) das linhas adicionadas num diff `-U0` (hunk `+início,n` = n linhas)."""
    novas: list[int] = []
    for linha in diff.splitlines():
        m = _HUNK.match(linha)
        if m:
            inicio, n = int(m[1]), int(m[2] if m[2] is not None else 1)
            novas.extend(range(inicio, inicio + n))
    return novas


def mudancas(name_status: str) -> list[dict[str, str]]:
    """`git diff-tree --name-status` → `[{caminho, status}]` (A, M, D, R…; renomeado: nome novo)."""
    saida = []
    for linha in name_status.splitlines():
        partes = linha.split("\t")
        if len(partes) >= 2:
            saida.append({"caminho": partes[-1], "status": partes[0][:1]})
    return saida

# Vai junto do CLAUDE.md do repositório (carregado normalmente, pois roda na pasta do projeto).
SISTEMA = """Você está sendo acionado a distância pelo app (módulo Código), sem ninguém no terminal.
- Siga à risca o CLAUDE.md do repositório e os CLAUDE.md das pastas que tocar (economia de tokens, \
validação com infra/scripts/verificar, estilo em português).
- Não faça perguntas: decida pelo padrão do projeto e diga no fim o que assumiu.
- Outras sessões podem estar editando o mesmo repositório ao mesmo tempo: não reverta nem commite \
mudanças que não são suas.
- Só faça commit, push ou publicação quando o pedido mandar.
- Termine com um resumo curto: o que mudou (arquivo:linha), o que falhou e o próximo passo."""

_LIMITE_RESUMO = 600

Emitir = Callable[[dict[str, Any]], Awaitable[None]]


def _curto(texto: str, limite: int = _LIMITE_RESUMO) -> str:
    texto = texto.strip()
    return texto if len(texto) <= limite else texto[:limite] + "…"


def _resumo_ferramenta(nome: str, entrada: dict[str, Any]) -> str:
    """O que a ferramenta vai fazer, numa linha: comando, arquivo ou padrão buscado."""
    for chave in ("command", "file_path", "pattern", "path", "url", "description", "prompt"):
        if entrada.get(chave):
            return _curto(str(entrada[chave]), 300)
    return _curto(json.dumps(entrada, ensure_ascii=False), 300)


def _texto_resultado(conteudo: Any) -> str:
    if isinstance(conteudo, list):
        return "\n".join(str(c.get("text", "")) for c in conteudo if isinstance(c, dict))
    return str(conteudo or "")


def etapas(msg: dict[str, Any]) -> list[dict[str, Any]]:
    """Uma linha do `--output-format stream-json` → etapas mostradas no app."""
    tipo = msg.get("type")
    if tipo == "system" and msg.get("subtype") == "init":
        return [
            {"tipo": "inicio", "claude_sessao": msg.get("session_id"), "modelo": msg.get("model")}
        ]
    if tipo == "assistant":
        saida: list[dict[str, Any]] = []
        for bloco in (msg.get("message") or {}).get("content") or []:
            if bloco.get("type") == "text" and str(bloco.get("text", "")).strip():
                saida.append({"tipo": "texto", "texto": bloco["text"]})
            elif bloco.get("type") == "tool_use":
                nome = str(bloco.get("name", ""))
                saida.append(
                    {
                        "tipo": "ferramenta",
                        "nome": nome,
                        "resumo": _resumo_ferramenta(nome, bloco.get("input") or {}),
                    }
                )
        return saida
    if tipo == "user":
        conteudo = (msg.get("message") or {}).get("content")
        if not isinstance(conteudo, list):
            return []
        return [
            {
                "tipo": "resultado",
                "erro": bool(b.get("is_error")),
                "resumo": _curto(_texto_resultado(b.get("content"))),
            }
            for b in conteudo
            if isinstance(b, dict) and b.get("type") == "tool_result"
        ]
    if tipo == "result":
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


def _nome_seguro(nome: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]", "_", nome)[-80:] or "imagem.png"


class Codigo:
    """Sessões em andamento (uma execução do `claude` por sessão por vez)."""

    def __init__(self, settings: WorkerSettings, emitir: Emitir) -> None:
        self._settings = settings
        self._emitir = emitir
        self._processos: dict[str, asyncio.subprocess.Process] = {}
        self._tarefas: set[asyncio.Task[None]] = set()

    @property
    def _repo(self) -> Path:
        return Path(self._settings.codigo_dir).expanduser()

    @property
    def _imagens_dir(self) -> Path:
        return Path(self._settings.codigo_imagens_dir).expanduser()

    async def executar(self, tarefa: str, payload: dict[str, Any]) -> dict[str, Any]:
        if tarefa == "codigo.enviar":
            return await self.enviar(payload)
        if tarefa == "codigo.parar":
            return self.parar(str(payload["sessao_id"]))
        if tarefa == "codigo.arvore":
            return await self.arvore(str(payload.get("commit") or ""))
        if tarefa == "codigo.arquivo":
            return await self.arquivo(str(payload["caminho"]), str(payload.get("commit") or ""))
        if tarefa == "codigo.buscar":
            return await self.buscar(
                str(payload.get("termo") or ""),
                str(payload.get("commit") or ""),
                observacoes=bool(payload.get("observacoes")),
            )
        return await self.git()

    async def enviar(self, payload: dict[str, Any]) -> dict[str, Any]:
        """Grava as imagens, sobe o `claude` e volta na hora; as etapas seguem por `evento`."""
        sessao = str(payload["sessao_id"])
        if sessao in self._processos:
            raise RuntimeError("Esta aba ainda está trabalhando. Pare ou espere terminar.")
        texto = str(payload.get("texto") or "").strip()
        caminhos = self._gravar_imagens(sessao, payload.get("imagens") or [])
        if caminhos:
            texto += "\n\nImagens de referência (abra com a ferramenta Read):\n" + "\n".join(
                f"- {c}" for c in caminhos
            )
        comando = [
            self._settings.codigo_claude_bin, "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--permission-mode", self._settings.codigo_permissao,
            "--append-system-prompt", SISTEMA,
            "--add-dir", str(self._imagens_dir),
        ]
        if self._settings.codigo_ferramentas.strip():
            comando += ["--allowedTools", *self._settings.codigo_ferramentas.split(",")]
        if self._settings.codigo_ferramentas_proibidas.strip():
            comando += [
                "--disallowedTools", *self._settings.codigo_ferramentas_proibidas.split(",")
            ]
        if payload.get("claude_sessao"):
            comando += ["--resume", str(payload["claude_sessao"])]
        if payload.get("modelo"):
            comando += ["--model", str(payload["modelo"])]
        try:
            proc = await asyncio.create_subprocess_exec(
                *comando,
                cwd=self._repo,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                limit=2**24,  # linhas do stream-json com resultados grandes de ferramentas
            )
        except FileNotFoundError as e:
            raise RuntimeError("Claude Code (`claude`) não está instalado neste computador.") from e
        self._processos[sessao] = proc
        assert proc.stdin is not None
        proc.stdin.write(texto.encode())
        await proc.stdin.drain()
        proc.stdin.close()
        tarefa = asyncio.create_task(self._acompanhar(sessao, proc))
        self._tarefas.add(tarefa)
        tarefa.add_done_callback(self._tarefas.discard)
        return {"ok": True, "imagens": caminhos}

    def _gravar_imagens(self, sessao: str, imagens: list[dict[str, Any]]) -> list[str]:
        pasta = self._imagens_dir / _nome_seguro(sessao)
        caminhos = []
        for img in imagens:
            pasta.mkdir(parents=True, exist_ok=True)
            arq = pasta / f"{datetime.now(UTC):%Y%m%d%H%M%S%f}-{_nome_seguro(str(img['nome']))}"
            arq.write_bytes(base64.b64decode(str(img["b64"])))
            caminhos.append(str(arq))
        return caminhos

    async def _acompanhar(self, sessao: str, proc: asyncio.subprocess.Process) -> None:
        assert proc.stdout is not None and proc.stderr is not None
        terminou = False
        try:
            async for linha in proc.stdout:
                try:
                    msg = json.loads(linha)
                except json.JSONDecodeError:
                    continue
                for etapa in etapas(msg):
                    terminou = terminou or etapa["tipo"] == "fim"
                    await self._avisar(sessao, etapa)
            erro = (await proc.stderr.read()).decode(errors="replace").strip()
            codigo = await proc.wait()
            if not terminou:
                motivo = "Parado pelo app." if codigo < 0 else _curto(erro or f"saída {codigo}")
                await self._avisar(sessao, {"tipo": "fim", "erro": codigo != 0, "texto": motivo})
        except Exception as e:
            logger.exception("Falha acompanhando a sessão %s", sessao)
            await self._avisar(sessao, {"tipo": "fim", "erro": True, "texto": str(e)})
        finally:
            self._processos.pop(sessao, None)

    async def _avisar(self, sessao: str, etapa: dict[str, Any]) -> None:
        try:
            await self._emitir({**etapa, "sessao_id": sessao, "em": datetime.now(UTC).isoformat()})
        except Exception:
            # Sem conexão com o Gateway agora: a etapa se perde, o Claude segue trabalhando.
            logger.warning("Etapa da sessão %s não entregue ao Gateway", sessao)

    def parar(self, sessao: str) -> dict[str, Any]:
        proc = self._processos.get(sessao)
        if proc is None:
            return {"ok": False}
        proc.terminate()
        return {"ok": True}

    async def git(self) -> dict[str, Any]:
        """Branch, arquivos alterados e últimos commits do repositório."""

        async def rodar(*args: str) -> str:
            proc = await asyncio.create_subprocess_exec(
                "git", *args, cwd=self._repo,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
            )
            saida, _ = await proc.communicate()
            return saida.decode(errors="replace").rstrip()

        return {
            "status": await rodar("status", "--short", "--branch"),
            "log": await rodar("log", "--oneline", "-10"),
            "rodando": sorted(self._processos),
        }

    async def _git(self, *args: str, vazio_ok: bool = False) -> bytes:
        """Saída do `git` no repositório; código de saída ≠ 0 → RuntimeError com o stderr
        ([vazio_ok]: código 1 = nada encontrado, como no `git grep`)."""
        proc = await asyncio.create_subprocess_exec(
            "git", *args, cwd=self._repo,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
        saida, erro = await proc.communicate()
        if proc.returncode == 1 and vazio_ok:
            return b""
        if proc.returncode:
            raise RuntimeError(erro.decode(errors="replace").strip() or f"git {args[0]} falhou")
        return saida

    async def _commit(self, commit: str) -> str:
        """Hash completo do [commit] (vazio = HEAD); só aceita hash, nunca ref ou opção."""
        if commit and not _COMMIT.match(commit):
            raise RuntimeError("Commit inválido")
        saida = await self._git("rev-parse", "--verify", f"{commit or 'HEAD'}^{{commit}}")
        return saida.decode().strip()

    async def arvore(self, commit: str) -> dict[str, Any]:
        """Arquivos do repositório no [commit], o que ele mudou e os últimos commits."""
        alvo = await self._commit(commit)
        log = await self._git("log", "-40", "--format=%H%x1f%h%x1f%s%x1f%an%x1f%cI")
        campos = ("hash", "curto", "assunto", "autor", "data")
        commits = [
            dict(zip(campos, linha.split("\x1f"), strict=False))
            for linha in log.decode(errors="replace").splitlines()
        ]
        arquivos = await self._git("ls-tree", "-r", "--name-only", "-z", alvo)
        status = await self._git(
            "diff-tree", "--no-commit-id", "-r", "--root", "--name-status", "-M", alvo
        )
        return {
            "commit": alvo,
            "commits": commits,
            "arquivos": [a for a in arquivos.decode(errors="replace").split("\0") if a],
            "mudancas": mudancas(status.decode(errors="replace")),
        }

    async def arquivo(self, caminho: str, commit: str) -> dict[str, Any]:
        """Conteúdo do arquivo no [commit] e as linhas que esse commit adicionou nele."""
        if not caminho or caminho.startswith(("/", "-")) or ".." in caminho.split("/"):
            raise RuntimeError("Caminho inválido")
        alvo = await self._commit(commit)
        dados = await self._git("show", f"{alvo}:{caminho}")
        if b"\0" in dados[:8000]:
            return {"caminho": caminho, "binario": True, "tamanho": len(dados)}
        diff = await self._git(
            "show", "--format=", "-U0", "--no-color", "-M", alvo, "--", caminho
        )
        return {
            "caminho": caminho,
            "binario": False,
            "tamanho": len(dados),
            "cortado": len(dados) > _LIMITE_ARQUIVO,
            "texto": dados[:_LIMITE_ARQUIVO].decode(errors="replace"),
            "novas": linhas_novas(diff.decode(errors="replace")),
        }

    async def buscar(self, termo: str, commit: str, *, observacoes: bool = False) -> dict[str, Any]:
        """Linhas com o [termo] (sem diferenciar maiúsculas) nos arquivos de texto do [commit];
        [observacoes]: só onde o termo está num comentário (sem termo: TODO/FIXME/...)."""
        termo = termo.strip()
        if not termo and not observacoes:
            raise RuntimeError("Digite o que buscar")
        if len(termo) > 200:
            raise RuntimeError("Busca longa demais")
        alvo = await self._commit(commit)
        padrao = ["-F", "-i", "-e", termo] if termo else ["-w", "-E", "-e", _MARCAS.pattern[3:-3]]
        saida = await self._git(
            "grep", "-n", "-I", "-z", "--no-color", "--max-count=50", *padrao, alvo, "--",
            vazio_ok=True,
        )
        resultados: list[dict[str, Any]] = []
        cortado = False
        prefixo = f"{alvo}:"
        for linha in saida.decode(errors="replace").splitlines():
            partes = linha.split("\0", 2)
            if len(partes) < 3 or not partes[1].isdigit():
                continue
            caminho, numero, texto = partes
            if observacoes:
                inicio = _COMENTARIO.search(texto)
                resto = texto[inicio.start():] if inicio else ""
                if not (termo.lower() in resto.lower() if termo else _MARCAS.search(resto)):
                    continue
            if len(resultados) >= _LIMITE_BUSCA:
                cortado = True
                break
            resultados.append({
                "caminho": caminho.removeprefix(prefixo),
                "linha": int(numero),
                "texto": texto.strip()[:240],
            })
        return {"commit": alvo, "resultados": resultados, "cortado": cortado}
