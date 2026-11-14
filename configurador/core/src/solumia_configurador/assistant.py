"""Claude assistant inside the configurator: guides the person through the screens.

Uses the Claude Code logged in on this PC (`claude -p`, subscription), never the paid API. What
Claude can and cannot do:
- no tools at all (`--tools ""`), no MCP, no settings, no saved session, run in an empty temporary
  folder: it cannot read files, run commands or touch the VPS; it only answers;
- it receives a sanitized snapshot of the configuration: states and booleans, never secret values,
  hosts, domains, user names or fingerprints (see [snapshot]); the person can see the exact text;
- every outgoing prompt and every answer goes through the vault mask and through a redaction of
  the manifest's identifying values and of key/token patterns;
- the conversation lives only in the core's memory and dies with the session;
- the transport to Anthropic is the one of Claude Code itself (TLS).
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from . import craft_apps, names, secret_store
from .engine import Mask, list_runs
from .manifest import Manifest
from .platform_setup import System
from .roles.worker import LEGACY_UNIT, unit_state

MAX_QUESTION = 4000
MAX_TURNS = 12
_TIMEOUT_S = 240

# Screen ids the answer may point to; the app maps them to its navigation.
SCREENS = ["", "inicio", "conta", "vps", "pastas", "craft_apps", "apps", "worker", "registro"]

_SCHEMA = {
    "type": "object",
    "properties": {
        "resposta": {"type": "string"},
        "tela": {"type": "string", "enum": SCREENS},
    },
    "required": ["resposta", "tela"],
    "additionalProperties": False,
}

_SYSTEM_PROMPT = f"""You are the assistant built into the {names.DISPLAY_NAME} configurator, a desktop \
program that installs and runs {names.DISPLAY_NAME} (gateway on a VPS, worker with GPU on the home PC, \
media folders, Craft Apps, phone/PC apps) without a terminal. You guide the person step by step.

What you know: only the sanitized snapshot of the configuration in <estado> (states, never values) \
and the conversation. You cannot see files, run commands, open screens or apply anything.

Rules:
- Everything is done through the configurator screens. Every change appears first as a plan and \
only runs after the person presses "Aplicar". Never send the person to a terminal or to download \
files by hand; if something has no screen yet, say so plainly.
- Never ask for passwords, private keys, tokens, TOTP codes or the vault passphrase. If the person \
pastes one, do not repeat it and tell them to keep it out of the chat.
- The person also runs an older installation called "agent" (units agent-*, ports 48080/2222/8765/\
9980/8081, /opt/agent). {names.DISPLAY_NAME} uses its own names and ports ({names.PREFIX}-*, gateway \
{names.GATEWAY_HOST_PORT}, tunnel {names.SSH_TUNNEL_PORT}, worker llama {names.LLAMA_LOCAL_PORT}, \
/opt/{names.PREFIX}) so both run in parallel. Never suggest stopping, editing or removing anything \
of "agent".
- Answer in the language of the person (Brazilian Portuguese by default), short and practical, in \
Markdown. When one screen is the next step, put its id in `tela` ({", ".join(s for s in SCREENS if s)}); \
otherwise leave it empty.
- Do not invent states: if the snapshot does not say it, say you cannot see it."""

_PATTERNS = [
    re.compile(r"-----BEGIN [A-Z ]+-----.*?-----END [A-Z ]+-----", re.S),
    re.compile(r"\b(sk-ant-|sk_live_|worker_|ghp_|github_pat_)[\w-]{8,}"),
    re.compile(r"\bssh-(ed25519|rsa) [A-Za-z0-9+/=]{20,}"),
    re.compile(r"\botpauth://\S+"),
]


class AssistantError(RuntimeError):
    pass


@dataclass
class Conversation:
    turns: list[dict[str, str]] = field(default_factory=list)
    lock: threading.Lock = field(default_factory=threading.Lock)

    def add(self, question: str, answer: str) -> None:
        with self.lock:
            self.turns.append({"pergunta": question, "resposta": answer})
            while len(self.turns) > MAX_TURNS:
                self.turns.pop(0)

    def clear(self) -> None:
        with self.lock:
            self.turns.clear()


def find_claude() -> str | None:
    """A program opened from the desktop menu may not have ~/.local/bin in its PATH."""
    found = shutil.which("claude")
    if found:
        return found
    home = Path.home()
    candidates = [home / ".local/bin/claude", home / ".claude/local/claude", Path("/usr/local/bin/claude")]
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def _identifying_values(m: Manifest) -> list[str]:
    """Values of the manifest that identify the person or the servers: never sent to Claude."""
    values = [m.conta.usuario, m.topologia.dominio]
    for node in m.nos.values():
        values.append(node.endereco)
        if node.ssh:
            values.extend([node.ssh.host, node.ssh.usuario, node.ssh.impressao_host])
    result = []
    for value in values:
        if value and len(str(value)) >= 3 and value not in ("local", "ssh"):
            result.append(str(value))
    return result


def redact(text: str, m: Manifest, mask: Mask) -> str:
    text = mask(text)
    for value in sorted(_identifying_values(m), key=len, reverse=True):
        text = text.replace(value, "[oculto]")
    for pattern in _PATTERNS:
        text = pattern.sub("[oculto]", text)
    return text


def _node_summary(name: str, node: Any) -> dict[str, Any]:
    ssh = node.ssh
    return {
        "no": name,
        "onde": "este computador" if node.endereco == "local" else "remoto",
        "papeis": list(node.papeis),
        "ssh_definido": ssh is not None,
        "impressao_confirmada": bool(ssh and ssh.impressao_host),
        "pastas_definidas": node.pastas is not None,
    }


def _recent_runs(runs_dir: Path) -> list[dict[str, Any]]:
    result = []
    for run in list_runs(runs_dir, limit=8):
        result.append({"titulo": run.get("titulo"), "estado": run.get("estado")})
    return result


def snapshot(m: Manifest, vault_names: list[str], system: System, runs_dir: Path) -> dict[str, Any]:
    """Sanitized state: what is configured, never with which values."""
    nodes = []
    for name, node in m.nos.items():
        nodes.append(_node_summary(name, node))
    installed = []
    for app_id, info in craft_apps.instalados().items():
        installed.append(f"{app_id} {info.get('versao', '')}".strip())
    return {
        "sistema": f"{system.so} {system.arquitetura}",
        "conta_criada": secret_store.PASSWORD_HASH in vault_names,
        "totp_ativo": secret_store.TOTP in vault_names,
        "topologia": m.topologia.tipo,
        "dominio_definido": bool(m.topologia.dominio),
        "nos": nodes,
        "segredos_no_cofre": len(vault_names),
        "craft_apps_instalados": installed,
        "servicos_neste_pc": {
            names.WORKER_UNIT: unit_state(names.WORKER_UNIT),
            f"{LEGACY_UNIT} (instalação antiga)": unit_state(LEGACY_UNIT),
        },
        "ultimas_aplicacoes": _recent_runs(runs_dir),
    }


def _build_prompt(state_text: str, history: list[dict[str, str]], question: str) -> str:
    parts = ["<estado>\n" + state_text + "\n</estado>"]
    for turn in history:
        parts.append("<pessoa>\n" + turn["pergunta"] + "\n</pessoa>")
        parts.append("<assistente>\n" + turn["resposta"] + "\n</assistente>")
    parts.append("<pessoa>\n" + question + "\n</pessoa>")
    return "\n\n".join(parts)


def _command(binary: str) -> list[str]:
    return [
        binary, "-p",
        "--output-format", "json",
        "--json-schema", json.dumps(_SCHEMA),
        "--system-prompt", _SYSTEM_PROMPT,
        "--tools", "",
        "--no-session-persistence",
        "--setting-sources", "",
        "--strict-mcp-config",
        "--effort", "medium",
    ]


def _environment() -> dict[str, str]:
    """Subscription only: an API key in the environment would make Claude Code bill the API."""
    env = dict(os.environ)
    env.pop("ANTHROPIC_API_KEY", None)
    env.pop("ANTHROPIC_AUTH_TOKEN", None)
    return env


def _parse(stdout: str, stderr: str) -> dict[str, Any]:
    try:
        result = json.loads(stdout)
    except json.JSONDecodeError as error:
        detail = (stderr or stdout).strip()[-300:] or "sem saída"
        raise AssistantError(f"o Claude Code falhou: {detail}") from error
    output = result.get("structured_output")
    if result.get("is_error") or not isinstance(output, dict):
        reason = result.get("result") or result.get("subtype")
        raise AssistantError(f"o Claude Code falhou: {reason}")
    return output


def ask(prompt: str, binary: str) -> dict[str, Any]:
    with tempfile.TemporaryDirectory() as empty_folder:
        try:
            r = subprocess.run(_command(binary), input=prompt, capture_output=True, text=True, cwd=empty_folder,
                               env=_environment(), timeout=_TIMEOUT_S)
        except subprocess.TimeoutExpired as error:
            raise AssistantError(f"o Claude não respondeu em {_TIMEOUT_S} s") from error
        except OSError as error:
            raise AssistantError(f"não consegui abrir o Claude Code: {error}") from error
    return _parse(r.stdout, r.stderr)


def state_text(m: Manifest, vault_names: list[str], system: System, runs_dir: Path, mask: Mask) -> str:
    raw = json.dumps(snapshot(m, vault_names, system, runs_dir), ensure_ascii=False, indent=1)
    return redact(raw, m, mask)


def answer(question: str, conversation: Conversation, context: str, m: Manifest, mask: Mask) -> dict[str, Any]:
    binary = find_claude()
    if binary is None:
        raise AssistantError("o Claude Code (`claude`) não está instalado neste computador")
    clean_question = redact(question.strip(), m, mask)
    with conversation.lock:
        history = list(conversation.turns)
    output = ask(_build_prompt(context, history, clean_question), binary)
    reply = redact(str(output.get("resposta", "")), m, mask)
    screen = output.get("tela", "")
    if screen not in SCREENS:
        screen = ""
    conversation.add(clean_question, reply)
    return {"pergunta": clean_question, "resposta": reply, "tela": screen}
