"""Claude Code in headless mode (`claude -p`) with schema-validated JSON output, using the
subscription logged in on the PC, not the paid API.

- [claude_json] is the generic call (worker task `claude_json`, used e.g. by the Concursos study
  plan).
- [rewrite] rewrites academic text excerpts.

Runs on the worker (PC) or on the backend when it is on the same PC; no tools, no saved session and
no project CLAUDE.md/settings are loaded."""

import asyncio
import json
import tempfile
from typing import Any

# Rewrite goal -> instruction. The keys are part of the API contract with the app.
# `feedback` applies the advisor's comments.
REWRITE_GOALS = {
    "orientador": (
        "Revise the excerpt so it can be handed to the advisor: clarity, cohesion between "
        "sentences and paragraphs, rigor and precision of terms, impersonal academic register, "
        "without changing the author's meaning or argument."
    ),
    "formal": "Rewrite in a formal, impersonal academic register, keeping the content.",
    "traduzir": (
        "Translate the excerpt into Brazilian Portuguese, faithful to the original (no summarizing "
        "or commenting), in academic register; keep established technical terms."
    ),
    "conciso": "Remove redundancy, wordiness and repetition, keeping every idea and data point.",
    "expandir": (
        "Develop the excerpt's argument (explanations, logical flow, transitions) without adding "
        "new facts: where an idea needs a source, mark it with [CITAÇÃO NECESSÁRIA]."
    ),
    "gramatica": (
        "Fix only grammar, spelling, agreement, verb government and punctuation (standard norm); "
        "do not change style or structure."
    ),
    "feedback": "Apply the advisor's comments below to the excerpt, one by one.",
}

REWRITE_SYSTEM_PROMPT = """You are a reviewer of academic texts written in Brazilian Portuguese \
(undergraduate thesis, monograph, article), following the standard norm and the conventions of \
Brazilian scientific writing (ABNT for citations). Always answer in Brazilian Portuguese.

Fixed rules:
- Preserve the meaning, data, numbers, technical terminology and every citation \
(AUTHOR, year) and reference exactly as they are.
- Never invent references, authors, data or results. If a statement needs a source, \
mark it with [CITAÇÃO NECESSÁRIA]; if something looks wrong or ambiguous, mark it with \
[VERIFICAR: reason].
- Keep the author's voice; do not add conclusions the author did not make.
- Return plain text (no Markdown), keeping the paragraph breaks of the original.
- In `mudancas`, list the relevant changes (text before, after and the reason, short). In \
`observacoes`, point out what the author must solve on their own (missing sources, \
inconsistencies with the rest of the document, likely questions from the advisor)."""

# The JSON keys are part of the API contract with the app, so they stay as they are.
REWRITE_SCHEMA = {
    "type": "object",
    "properties": {
        "texto": {"type": "string"},
        "mudancas": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "antes": {"type": "string"},
                    "depois": {"type": "string"},
                    "motivo": {"type": "string"},
                },
                "required": ["antes", "depois", "motivo"],
                "additionalProperties": False,
            },
        },
        "observacoes": {"type": "string"},
    },
    "required": ["texto", "mudancas", "observacoes"],
    "additionalProperties": False,
}


class InvalidRewriteRequest(ValueError):
    """Request without an excerpt, with an unknown goal, or `feedback` without the comments."""


def _read_text_field(request: dict[str, Any], key: str) -> str:
    value = request.get(key)
    if not value:
        return ""
    return str(value).strip()


def build_rewrite_prompt(request: dict[str, Any]) -> str:
    """Whole document first (context, to keep coherence); then the goal and the excerpt."""
    excerpt = _read_text_field(request, "trecho")
    goal = _read_text_field(request, "objetivo")
    if not goal:
        goal = "orientador"
    feedback = _read_text_field(request, "feedback")
    extra_instruction = _read_text_field(request, "instrucao")
    context = _read_text_field(request, "contexto")

    if not excerpt:
        raise InvalidRewriteRequest("Select the excerpt to rewrite.")
    if goal not in REWRITE_GOALS:
        raise InvalidRewriteRequest(f"Unknown goal: {goal}")
    if goal == "feedback" and not feedback:
        raise InvalidRewriteRequest("Paste the advisor's comments to apply them.")

    parts = []
    if context:
        parts.append(
            "<documento>\n" + context + "\n</documento>\n"
            "(Full document, only as context: rewrite only the requested excerpt.)"
        )
    parts.append("Goal: " + REWRITE_GOALS[goal])
    if feedback:
        parts.append("<comentarios_do_orientador>\n" + feedback + "\n</comentarios_do_orientador>")
    if extra_instruction:
        parts.append("Additional request from the author: " + extra_instruction)
    parts.append("<trecho>\n" + excerpt + "\n</trecho>")
    return "\n\n".join(parts)


async def rewrite(
    request: dict[str, Any], binary: str = "claude", timeout_s: float = 280
) -> dict[str, Any]:
    """Returns `{texto, mudancas, observacoes}`. On failure raises a readable RuntimeError."""
    model = _read_text_field(request, "modelo")
    if not model:
        model = None
    return await claude_json(
        build_rewrite_prompt(request),
        REWRITE_SYSTEM_PROMPT,
        REWRITE_SCHEMA,
        binary=binary,
        timeout_s=timeout_s,
        model=model,
    )


def _build_command(
    system_prompt: str,
    schema: dict[str, Any],
    binary: str,
    model: str | None,
    effort: str,
    tools: str,
) -> list[str]:
    command = [
        binary, "-p",
        "--output-format", "json",
        "--json-schema", json.dumps(schema),
        "--system-prompt", system_prompt,
        "--tools", tools,
        "--no-session-persistence",
        "--setting-sources", "",
        "--strict-mcp-config",
        "--effort", effort,
    ]
    if tools:
        command.extend(["--allowedTools", tools])
    if model:
        command.extend(["--model", model])
    return command


async def claude_json(
    prompt: str,
    system_prompt: str,
    schema: dict[str, Any],
    *,
    binary: str = "claude",
    timeout_s: float = 280,
    model: str | None = None,
    effort: str = "high",
    tools: str = "",
) -> dict[str, Any]:
    """Runs `claude -p` with the prompt on stdin (long documents do not fit on the command line)
    and returns the JSON in the shape of [schema]. On failure raises a readable RuntimeError.
    [tools] (e.g. "WebSearch,WebFetch") enables and pre-approves those tools."""
    command = _build_command(system_prompt, schema, binary, model, effort, tools)

    # Empty folder: Claude Code does not load CLAUDE.md or any repository file.
    with tempfile.TemporaryDirectory() as empty_folder:
        try:
            process = await asyncio.create_subprocess_exec(
                *command,
                cwd=empty_folder,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
        except FileNotFoundError as error:
            raise RuntimeError(
                "Claude Code (`claude`) is not installed on this computer."
            ) from error
        try:
            stdout, stderr = await asyncio.wait_for(
                process.communicate(prompt.encode()), timeout_s
            )
        except TimeoutError as error:
            process.kill()
            raise RuntimeError(
                f"Claude Code took more than {timeout_s:.0f} s without answering."
            ) from error

    try:
        result = json.loads(stdout)
    except json.JSONDecodeError as error:
        raw_output = stderr if stderr else stdout
        detail = raw_output.decode(errors="replace").strip()[-400:]
        if not detail:
            detail = "no output"
        raise RuntimeError(f"Claude Code failed: {detail}") from error

    structured_output = result.get("structured_output")
    if result.get("is_error") or not isinstance(structured_output, dict):
        # e.g. not logged in ("Invalid API key · Please run /login") or subscription limit reached
        reason = result.get("result")
        if not reason:
            reason = result.get("subtype")
        raise RuntimeError(f"Claude Code failed: {reason}")
    return structured_output
