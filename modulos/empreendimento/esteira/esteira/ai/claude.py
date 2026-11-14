"""Escalation to Claude (`claude -p`, no tools, no CLAUDE.md): only for what the code and the local LLM did not
settle with confidence. It receives a compact dossier built by the code and answers in validated JSON. It runs
on the Claude subscription (no API key): the "cost" is the API-price equivalent that `claude -p` reports, used
only as a measure of consumption. Every call goes to `cache/claude.jsonl` (cost, episode, reason). The brake is
the subscription quota: the `rate_limit_event` of each call saves the usage of the windows (5 h and weekly) in
`cache/claude_quota.json`; with any window at QUOTA_LIMIT or above, it returns None until the window resets, and
the caller keeps the local LLM's decision.
"""
import hashlib
import json
import os
import subprocess
import time
from datetime import date, datetime
from pathlib import Path

from pydantic import BaseModel, ValidationError

from esteira.core import events, trace
from esteira.project import CACHE

LEDGER = CACHE / "claude.jsonl"
QUOTA_FILE = CACHE / "claude_quota.json"
QUOTA_LIMIT = 0.90  # fraction of the subscription quota at which the system stops calling Claude
DEFAULT_MODEL = "claude-sonnet-5-5"
SYSTEM = ("You solve hard cases of an automatic video editing pipeline whose videos are in Brazilian Portuguese. "
          "Answer only in the requested JSON format, with objective decisions. Any text meant to appear in the "
          "video or to be read by the operator must be written in Brazilian Portuguese.")


def _subscription_env():
    """Environment without an API key: `claude -p` uses the subscription login (Pro/Max), which does not charge
    per call. With ANTHROPIC_API_KEY in the environment it would bill the API account, so the key is removed."""
    env = {}
    for key, value in os.environ.items():
        if key not in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"):
            env[key] = value
    return env


def _records():
    if not LEDGER.exists():
        return []
    records = []
    for line in LEDGER.read_text().splitlines():
        if line.strip():
            records.append(json.loads(line))
    return records


def spent(ep=None):
    """(spent on the episode, spent today) in US$."""
    today = date.today().isoformat()
    on_episode, on_today = 0, 0
    for record in _records():
        if ep and record.get("ep") == ep:
            on_episode += record.get("cost") or 0
        if record["t"].startswith(today):
            on_today += record.get("cost") or 0
    return on_episode, on_today


def _save_quota(info):
    windows = info.get("unifiedWindows") or {}
    if windows:
        QUOTA_FILE.parent.mkdir(exist_ok=True)
        QUOTA_FILE.write_text(json.dumps(windows))


def quota():
    """Highest usage (0–1) among the subscription windows that have not reset yet; 0 without a reading."""
    try:
        windows = json.loads(QUOTA_FILE.read_text())
    except (OSError, ValueError):
        return 0.0
    now = time.time()
    highest = 0.0
    for window in windows.values():
        if (window.get("resetsAt") or 0) > now:
            highest = max(highest, window.get("utilization") or 0.0)
    return highest


def quota_limit():
    from esteira.core import options
    value = options.read().get("quota_limit")
    if value is None:
        return QUOTA_LIMIT
    return float(value)


def quota_full():
    return quota() >= quota_limit()


def _cached(key, schema):
    for record in _records():
        if record.get("k") == key and record.get("answer") is not None:
            return schema.model_validate(record["answer"])
    return None


def query(dossier, schema: type[BaseModel], cfg, ep, reason, image=None):
    """`image`: path of ONE image (sheet) that Claude reads with the Read tool."""
    from esteira.core import options
    c = options.claude(cfg.get("claude", {}))
    if not c.get("ativo", True):
        return None
    signature = None
    if image:
        signature = hashlib.sha1(open(image, "rb").read()).hexdigest()
    model = c.get("modelo", DEFAULT_MODEL)
    key_parts = [dossier, schema.model_json_schema(), signature]
    if model != DEFAULT_MODEL:
        key_parts.append(model)
    key = hashlib.sha1(json.dumps(key_parts, ensure_ascii=False).encode()).hexdigest()
    cached = _cached(key, schema)
    if cached is not None:
        return cached
    if quota_full():
        events.warning(f"Claude not called ({reason}): subscription quota at {quota():.0%}")
        return None
    tools = ["--tools", ""]
    cwd = "/tmp"
    if image:
        dossier = f"Read the image {image} (only once) and then answer.\n\n" + dossier
        tools = ["--tools", "Read", "--allowedTools", "Read"]
        cwd = str(Path(image).parent)
    cmd = ["claude", "-p", dossier, "--model", model, "--output-format", "stream-json",
           "--verbose", *tools, "--no-session-persistence", "--setting-sources", "", "--strict-mcp-config",
           "--system-prompt", SYSTEM, "--json-schema", json.dumps(schema.model_json_schema()),
           "--max-budget-usd", f"{c.get('teto_chamada_usd', 0.30):.2f}"]
    start = time.monotonic()
    trace.call_start("claude", reason, model, dossier, schema_name=schema.__name__,
                     json_schema=schema.model_json_schema(), image=bool(image))
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=300, env=_subscription_env(), cwd=cwd)
        result = None
        for line in out.stdout.splitlines():
            event = json.loads(line) if line.startswith("{") else {}
            if event.get("type") == "rate_limit_event":
                _save_quota(event.get("rate_limit_info") or {})
            elif event.get("type") == "result":
                result = event
        if result is None:
            raise ValueError(f"no result: {out.stderr[-120:]}")
    except (subprocess.TimeoutExpired, ValueError) as e:
        trace.call_end(ok=False, error=str(e)[:200])
        events.warning(f"Claude failed ({reason}): {str(e)[:120]}")
        return None
    cost = result.get("total_cost_usd") or 0.0
    answer = None
    if not result.get("is_error"):
        try:
            answer = schema.model_validate(result.get("structured_output"))
        except ValidationError:
            answer = None
    dumped = None
    if answer:
        dumped = answer.model_dump()
    LEDGER.parent.mkdir(exist_ok=True)
    with open(LEDGER, "a") as f:
        f.write(json.dumps({"t": datetime.now().isoformat(timespec="seconds"), "ep": ep, "reason": reason,
                            "cost": cost, "k": key, "answer": dumped}, ensure_ascii=False) + "\n")
    usage = result.get("usage") or {}
    output = str(result.get("result", ""))[:2000]
    if answer:
        output = json.dumps(dumped, ensure_ascii=False)
    trace.call_end(output, ok=answer is not None, cost_usd=cost, input_tokens=usage.get("input_tokens"),
                   output_tokens=usage.get("output_tokens"), cache_read=usage.get("cache_read_input_tokens"),
                   total_s=round(time.monotonic() - start, 2))
    events.record_claude(reason, cost, round(time.monotonic() - start, 1), ok=answer is not None)
    return answer
