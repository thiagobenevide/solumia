"""Machine slots: only one heavy process at a time (16 GB GPU, CPU and disk are a single resource). Exception: a
process that only uses Claude (`--engine claude` on `curate` or `script`, no GPU or local LLM) takes the "claude"
slot and can run alongside the one holding the "machine" slot.

fcntl lock on `cache/locks/<slot>.lock` (the system releases it if the process dies, even with kill -9); the
current holder is written to `<slot>.json`, so whoever waits (CLI, queue, panel) knows who has it.
"""
import atexit
import fcntl
import json
import os
import time

import psutil

from esteira.project import CACHE

DIR = CACHE / "locks"
CLAUDE_OK = {"curate", "script", "studio-style", "studio-factory"}  # stages whose only heavy work is the LLM; the others use GPU/ffmpeg/render
SLOTS = ("machine", "claude")
_held = {}


def slot(command, engine="local"):
    if engine == "claude" and command in CLAUDE_OK:
        return "claude"
    return "machine"


def owner(name):
    """Who holds the slot now ({pid, command, since, process}) or None."""
    try:
        data = json.loads((DIR / f"{name}.json").read_text())
    except (OSError, ValueError):
        return None
    if psutil.pid_exists(data.get("pid", -1)) and data.get("pid") != os.getpid():
        return data
    return None


def is_free(name):
    return owner(name) is None


def acquire(name, command, wait=True, process=None):
    """Takes the slot `name` until the process ends. wait=False: returns False if it is taken."""
    from esteira.core import trace
    DIR.mkdir(parents=True, exist_ok=True)
    f = open(DIR / f"{name}.lock", "w")
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        if not wait:
            f.close()
            return False
        current = owner(name) or {}
        message = f"waiting for slot {name}: held by `{current.get('command', '?')}` (pid {current.get('pid', '?')})"
        print(f"⏳ {message}", flush=True)
        trace.detail(message)
        fcntl.flock(f, fcntl.LOCK_EX)
        print(f"▶ slot {name} released", flush=True)
    _held[name] = f
    holder = {"pid": os.getpid(), "command": command, "since": time.time(), "process": process}
    (DIR / f"{name}.json").write_text(json.dumps(holder, ensure_ascii=False))
    return True


@atexit.register
def _release():
    for name in list(_held):
        try:
            (DIR / f"{name}.json").unlink(missing_ok=True)
        except OSError:
            pass
