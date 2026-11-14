"""Reading of the event log: state of each stage (`./dark status`) and filtered events (`./dark log`)."""
import json
import os
from datetime import datetime

from esteira.projeto import ep_id

ORDER = ["transcrever", "limpar", "cenas", "curar", "buscar", "avaliar", "graficos", "montar", "quadros", "thumb"]
_MARKS = {"ok": "✓", "error": "✗", "running": "▶", "aborted": "⚠", "?": "?"}
_BASE_KEYS = ("t", "ep", "stage", "kind", "message", "traceback")


def events(folder):
    file = folder / "log" / "events.jsonl"
    if not file.exists():
        return []
    result = []
    with open(file) as f:
        for line in f:
            if line.strip():
                result.append(json.loads(line))
    return result


def _alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except (OSError, TypeError):
        return False


def _position(item):
    name = item[0]
    if name in ORDER:
        return ORDER.index(name)
    return 99


def stages(folder):
    """{stage: {status, start, duration, message, i, n, remaining, warnings}} of the last run of each stage."""
    state = {}
    for event in events(folder):
        name, kind = event["stage"], event["kind"]
        if kind == "start":
            state[name] = {"status": "running", "start": event["t"], "pid": event.get("pid"), "message": "",
                           "warnings": 0}
            continue
        entry = state.setdefault(name, {"status": "?", "start": event["t"], "message": "", "warnings": 0})
        if kind == "progress":
            entry.update(i=event["i"], n=event["n"], remaining=event.get("remaining"),
                         message=event["message"] or entry["message"])
        elif kind in ("output", "warning"):
            entry["message"] = event["message"]
            entry["warnings"] += kind == "warning"
        elif kind == "end":
            entry.update(status="ok", duration=event.get("duration"))
        elif kind == "error":
            entry.update(status="error", duration=event.get("duration"), message=event["message"])
    for entry in state.values():  # process died without recording the end (kill -9, power loss)
        if entry["status"] == "running" and not _alive(entry.get("pid")):
            entry["status"] = "aborted"
    return dict(sorted(state.items(), key=_position))


def _time(s):
    if s is None:
        return "-"
    s = int(s)
    if s >= 3600:
        return f"{s // 3600}h{s % 3600 // 60:02d}m"
    return f"{s // 60}m{s % 60:02d}s"


def print_status(folder):
    state = stages(folder)
    if not state:
        print(f"{ep_id(folder)}: no stage recorded")
        return
    print(ep_id(folder))
    for name, entry in state.items():
        when = datetime.fromisoformat(entry["start"]).strftime("%d/%m %H:%M")
        if entry["status"] == "running":
            progress = "…"
            if entry.get("n"):
                progress = f"{entry.get('i', 0)}/{entry.get('n', '?')} {_time(entry.get('remaining'))} left"
            info = f"{progress} · {entry['message'][:70]}"
        else:
            info = f"{_time(entry.get('duration'))} · {entry['message'][:80]}"
        warnings = ""
        if entry["warnings"]:
            warnings = f" ({entry['warnings']} warnings)"
        print(f"  {_MARKS[entry['status']]} {name:12} {when}  {info}{warnings}")


def _selected(event, stage, errors, debug):
    if stage and event["stage"] != stage:
        return False
    if not debug and event["kind"] in ("debug", "progress"):
        return False
    return not errors or event["kind"] in ("error", "warning")


def print_log(folder, stage=None, n=20, errors=False, debug=False):
    selected = []
    for event in events(folder):
        if _selected(event, stage, errors, debug):
            selected.append(event)
    for event in selected[-n:]:
        extra = {}
        for key, value in event.items():
            if key not in _BASE_KEYS:
                extra[key] = value
        line = f"{event['t'][11:19]} {event['stage']:10} {event['kind']:8} {event['message'][:110]}"
        if extra:
            line += f" {extra}"
        print(line)
        if event.get("traceback") and errors:
            print("    " + event["traceback"].strip().splitlines()[-1][:160])
