"""Record of each pipeline process (heavy `./dark <command>`, from the terminal or the queue): what it is, slot,
engine, when it started and how it ended. `cache/processes.jsonl` gets one line at the start and another at the
end (same id). The id goes to the environment (`ESTEIRA_PROCESS`) and the trace tags every record with it, for
the process page.
"""
import atexit
import json
import os
import time

import psutil

from esteira.projeto import CACHE

FILE = CACHE / "processes.jsonl"
_me = {}


def _append(record):
    FILE.parent.mkdir(exist_ok=True)
    with open(FILE, "a") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


def register(command, target, args, slot, engine):
    start = time.time()
    pid = os.getpid()
    process_id = f"{int(start * 1000)}-{pid}"
    try:
        output = os.readlink("/proc/self/fd/1")
    except OSError:
        output = None
    if not (output and output.startswith("/") and os.path.isfile(output)):
        output = None
    _me.update(id=process_id)
    os.environ["ESTEIRA_PROCESS"] = process_id
    _append({"id": process_id, "event": "start", "pid": pid, "command": command, "target": target, "args": args,
             "slot": slot, "engine": engine, "start": round(start, 2), "queue": os.environ.get("ESTEIRA_QUEUE"),
             "output": output})
    return process_id


def cancelled():
    _me["cancelled"] = True


def failed(error):
    _me["error"] = f"{type(error).__name__}: {error}"[:300]


@atexit.register
def _end():
    if _me:
        _append({"id": _me["id"], "event": "end", "end": round(time.time(), 2), "ok": "error" not in _me,
                 "error": _me.get("error", ""), "cancelled": _me.get("cancelled", False)})


def _state(record):
    if "end" in record:
        if record.get("cancelled"):
            return "cancelled"
        if record.get("ok"):
            return "ok"
        return "error"
    if psutil.pid_exists(record["pid"]) and abs(psutil.Process(record["pid"]).create_time() - record["start"]) < 5:
        return "running"
    return "interrupted"  # died without going through atexit (kill -9, power loss)


def _start_time(record):
    return record["start"]


def list_recent(limit=200):
    """Processes (most recent first) with state: running | ok | error | cancelled | interrupted."""
    if not FILE.exists():
        return []
    records = {}
    with open(FILE, "rb") as f:
        f.seek(max(0, FILE.stat().st_size - 2_000_000))
        for line in f.read().decode("utf-8", "replace").splitlines():
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if record.get("event") == "start":
                records[record["id"]] = record
            elif record.get("id") in records:
                records[record["id"]].update(record)
    result = []
    for record in records.values():
        record["state"] = _state(record)
        record["duration"] = round((record.get("end") or time.time()) - record["start"])
        result.append(record)
    result.sort(key=_start_time, reverse=True)
    return result[:limit]


def get(process_id):
    for record in list_recent(2000):
        if record["id"] == process_id:
            return record
    return None
