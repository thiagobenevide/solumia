"""Trace for the Monitor graph: which node of the operation each process is in and what the LLM is processing now.

- `cache/live/<pid>.json`: live state of the process (flow, node, progress and the LLM call in progress, with
  the partial text generated token by token). Disappears when the process ends.
- `cache/trace.jsonl`: history of finished calls (prompt, answer, tokens, timings) and of node changes.
Only writes small files; never raises to the caller.
"""
import atexit
import itertools
import json
import os
import time

from esteira.projeto import CACHE

DIR = CACHE / "live"
LOG = CACHE / "trace.jsonl"
MAX_LOG = 20 * 2**20
_ids = itertools.count(1)
_live = {"pid": os.getpid(), "flow": None, "node": None, "detail": "", "since": time.time(), "progress": None,
         "call": None, "tasks": {}}
_last = 0.0


def _write_live(force=True):
    global _last
    _live["process"] = os.environ.get("ESTEIRA_PROCESS")
    now = time.time()
    if not force and now - _last < 0.4:
        return
    _last = now
    try:
        DIR.mkdir(parents=True, exist_ok=True)
        tmp = DIR / f".{os.getpid()}.tmp"
        tmp.write_text(json.dumps(_live, ensure_ascii=False, default=str))
        tmp.replace(DIR / f"{os.getpid()}.json")
    except OSError:
        pass


def _append(record):
    try:
        LOG.parent.mkdir(exist_ok=True)
        if LOG.exists() and LOG.stat().st_size > MAX_LOG:  # keeps the most recent half
            lines = LOG.read_text().splitlines()
            LOG.write_text("\n".join(lines[len(lines) // 2:]) + "\n")
        entry = dict(record, t=round(time.time(), 2), pid=os.getpid(), process=os.environ.get("ESTEIRA_PROCESS"),
                     flow=_live["flow"], node=_live["node"])
        with open(LOG, "a") as f:
            f.write(json.dumps(entry, ensure_ascii=False, default=str) + "\n")
    except OSError:
        pass


def node(flow, name, detail=""):
    """Enters node `name` of the flow (`roteiro:<canal>:<N>` or the episode id). name=None: left the flow."""
    _live.update(flow=flow, node=name, detail=detail, since=time.time(), progress=None)
    _append({"kind": "node", "detail": detail})
    _write_live()


def step(name, detail=""):
    """Changes node inside the current flow."""
    node(_live["flow"], name, detail)


def detail(text):
    _live["detail"] = text
    _write_live(False)


def progress(i, n, message="", remaining=None):
    _live["progress"] = {"i": i, "n": n, "message": message, "remaining": remaining}
    _write_live(i >= n)


def task(key, label, done, total=None, unit=""):
    """Bar of a subtask (download in bytes, rendered frames…); total=None = indeterminate."""
    current = _live["tasks"].get(key)
    if not current or current["label"] != label:
        current = _live["tasks"][key] = {"label": label, "start": time.time(), "unit": unit}
    current.update(done=done, total=total, t=time.time())
    _write_live(False)


def end_task(key):
    if _live["tasks"].pop(key, None) is not None:
        _write_live()


def external_file(name):
    """Path for a subprocess (e.g. `artigo baixar`) to write its own bar, tied to this process."""
    DIR.mkdir(parents=True, exist_ok=True)
    return DIR / f"{os.getpid()}.ext-{name}.json"


def call_start(engine, name, model, input_text, json_schema=None, **params):
    """engine: "local" | "claude". `json_schema`: the JSON Schema that constrains the answer. Returns the id."""
    call_id = f"{os.getpid()}-{next(_ids)}"
    schema = ""
    if json_schema:
        schema = json.dumps(json_schema, ensure_ascii=False)[:3000]
    _live["call"] = {"id": call_id, "engine": engine, "name": name, "model": model, "input": input_text[:12000],
                     "params": params, "start": time.time(), "partial": "", "tokens": 0, "schema": schema}
    _write_live()
    return call_id


def call_partial(text, tokens):
    call = _live["call"]
    if call:
        if not call.get("first"):
            call["first"] = time.time()  # end of prefill (+ queue/load): generation starts
        call["partial"], call["tokens"] = text[-6000:], tokens
        _write_live(False)


def call_end(output="", ok=True, error="", **metrics):
    call = _live["call"]
    if not call:
        return
    _append({"kind": "call", "id": call["id"], "engine": call["engine"], "name": call["name"], "model": call["model"],
             "input": call["input"][:8000], "output": output[:6000], "schema": call.get("schema", ""),
             "params": call["params"], "ok": ok, "error": error,
             "seconds": round(time.time() - call["start"], 2), **metrics})
    _live["call"] = None
    _write_live()


def cache(name, model):
    """Answer came from the pipeline cache (no tokens spent)."""
    _append({"kind": "cache", "name": name, "model": model})


@atexit.register
def _exit():
    try:
        (DIR / f"{os.getpid()}.json").unlink(missing_ok=True)
    except OSError:
        pass
