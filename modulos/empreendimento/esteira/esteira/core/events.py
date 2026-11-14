"""Pipeline events: each stage writes to `<project>/log/events.jsonl` what it did, how long it took and what failed.

It is the single source for `./dark status`, `./dark log` and the web panel. Inside `with stage(p, "montar")`:
- everything the stage prints becomes an `output` event (old modules do not need to change);
- `progress(i, n, message)` shows a bar with the estimated finish (on an interactive terminal) and records the event;
- `debug(message, **data)` only records (FilmCraft calls, timings), costing no terminal lines.
"""
import json
import os
import sys
import time
import traceback
from contextlib import contextmanager
from datetime import datetime

_current = None  # stage in progress in this process


class _Output:
    """Forwards stdout to the terminal and records each line as an event."""

    def __init__(self, stage, original):
        self.stage, self.original, self.buffer = stage, original, ""

    def write(self, s):
        self.original.write(s)
        self.buffer += s
        while "\n" in self.buffer:
            line, self.buffer = self.buffer.split("\n", 1)
            if line.strip():
                self.stage.record("output", line.strip())
        return len(s)

    def flush(self):
        self.original.flush()

    def isatty(self):
        return self.original.isatty()


class Stage:
    def __init__(self, project, name):
        folder = project.pasta / "log"
        folder.mkdir(exist_ok=True)
        self.file = folder / "events.jsonl"
        self.ep, self.name = project.ep, name
        self.t0 = time.monotonic()
        self.tty = sys.stdout.isatty()
        self._milestone = -1

    def record(self, kind, message="", **data):
        entry = {"t": datetime.now().isoformat(timespec="milliseconds"), "ep": self.ep, "stage": self.name,
                 "kind": kind, "message": message, **data}
        with open(self.file, "a") as f:
            f.write(json.dumps(entry, ensure_ascii=False, default=str) + "\n")

    def elapsed(self):
        return time.monotonic() - self.t0

    def progress(self, i, n, message=""):
        elapsed = self.elapsed()
        remaining = None
        if i:
            remaining = round(elapsed / i * (n - i), 1)
        self.record("progress", message, i=i, n=n, remaining=remaining)
        from esteira.core import trace
        trace.progress(i, n, message, remaining)
        pct = int(100 * i / n) if n else 100
        text = f"  [{self.name}] {i}/{n} {pct:3d}% · {_time(elapsed)}"
        if remaining:
            text += f" · {_time(remaining)} left"
        if self.tty:
            bar = "█" * (pct // 5) + "░" * (20 - pct // 5)
            sys.__stdout__.write(f"\r\033[K  {bar} {text.strip()} · {message[:50]}" + ("\n" if i >= n else ""))
            sys.__stdout__.flush()
        elif pct // 25 > self._milestone:  # outside the terminal (log read by Claude): only every 25%
            self._milestone = pct // 25
            sys.__stdout__.write(text + "\n")


def _time(s):
    s = int(s)
    if s >= 60:
        return f"{s // 60}m{s % 60:02d}s"
    return f"{s}s"


@contextmanager
def stage(project, name):
    global _current
    current, previous, stdout = Stage(project, name), _current, sys.stdout
    _current = current
    current.record("start", pid=os.getpid())
    from esteira.core import trace
    trace.node(project.ep, name)
    sys.stdout = _Output(current, stdout)
    try:
        yield current
    except KeyboardInterrupt:
        current.record("error", "interrupted", duration=round(current.elapsed(), 1))
        raise
    except BaseException as x:
        if isinstance(x, SystemExit) and not x.code:
            current.record("end", duration=round(current.elapsed(), 1))
        else:
            current.record("error", f"{type(x).__name__}: {x}", duration=round(current.elapsed(), 1),
                           traceback=traceback.format_exc(limit=6))
        raise
    else:
        current.record("end", duration=round(current.elapsed(), 1))
    finally:
        sys.stdout = stdout
        _current = previous
        trace.node(None, None)


# Shortcuts for modules that do not receive the stage: they become no-ops outside a stage.
def progress(i, n, message=""):
    if _current:
        _current.progress(i, n, message)


def debug(message, **data):
    if _current:
        _current.record("debug", message, **data)


def warning(message, **data):
    print(f"  ! {message}")
    if _current:
        _current.record("warning", message, **data)


def record_claude(reason, cost, seconds, ok=True):
    """Every Claude call shows up on the terminal and in the log (it is the part that costs money)."""
    print(f"  ☁ Claude: {reason} · US$ {cost:.4f} · {seconds}s" + ("" if ok else " · no valid answer"))
    if _current:
        _current.record("claude", reason, cost=cost, seconds=seconds, ok=ok)
