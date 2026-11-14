"""System devices: monitors (xrandr), audio (PulseAudio/PipeWire), webcams and the X11 pointer."""

from __future__ import annotations

import ctypes
import ctypes.util
import json
import re
import subprocess
from pathlib import Path

MONITOR_LINE = re.compile(r"\s*(\d+): \S+ (\d+)/\d+x(\d+)/\d+\+(\d+)\+(\d+)\s+(\S+)")


def monitors() -> list[dict]:
    """X11 monitors (`xrandr --listmonitors`): index, name and geometry."""
    try:
        output = subprocess.run(
            ["xrandr", "--listmonitors"], capture_output=True, text=True, timeout=5
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    result = []
    for line in output.splitlines():
        match = MONITOR_LINE.match(line)
        if match is None:
            continue
        index, w, h, x, y, name = match.groups()
        result.append({"index": int(index), "name": name, "w": int(w), "h": int(h),
                       "x": int(x), "y": int(y)})
    return result


def monitor(index: int) -> dict | None:
    found = monitors()
    for m in found:
        if m["index"] == index:
            return m
    if found:
        return found[0]
    return None


def audio_devices() -> list[dict]:
    try:
        output = subprocess.run(
            ["pactl", "-f", "json", "list", "sources"], capture_output=True, text=True, timeout=5
        ).stdout
        sources = json.loads(output or "[]")
    except (OSError, subprocess.SubprocessError, ValueError):
        return []
    result = []
    for s in sources:
        name = str(s.get("name", ""))
        result.append({
            "name": name,
            "description": s.get("description") or name,
            "output": name.endswith(".monitor"),
        })
    return result


def webcams() -> list[str]:
    base = Path("/sys/class/video4linux")
    if not base.exists():
        return []
    result = []
    for d in base.iterdir():
        result.append(f"/dev/{d.name}")
    return sorted(result)


def rmem_max() -> int:
    try:
        return int(Path("/proc/sys/net/core/rmem_max").read_text())
    except (OSError, ValueError):
        return 0


class Pointer:
    """Mouse position on the X11 root window through libX11 (no extra dependency)."""

    def __init__(self) -> None:
        self.lib = None
        self.display = None
        self.root = None
        path = ctypes.util.find_library("X11")
        if path is None:
            return
        lib = ctypes.cdll.LoadLibrary(path)
        lib.XOpenDisplay.restype = ctypes.c_void_p
        lib.XOpenDisplay.argtypes = [ctypes.c_char_p]
        lib.XDefaultRootWindow.restype = ctypes.c_ulong
        lib.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        lib.XQueryPointer.argtypes = [
            ctypes.c_void_p, ctypes.c_ulong,
            ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong),
            ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int),
            ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int),
            ctypes.POINTER(ctypes.c_uint),
        ]
        display = lib.XOpenDisplay(None)
        if not display:
            return
        self.lib = lib
        self.display = display
        self.root = lib.XDefaultRootWindow(display)

    def position(self) -> tuple[int, int] | None:
        if self.lib is None:
            return None
        root = ctypes.c_ulong()
        child = ctypes.c_ulong()
        rx = ctypes.c_int()
        ry = ctypes.c_int()
        wx = ctypes.c_int()
        wy = ctypes.c_int()
        mask = ctypes.c_uint()
        ok = self.lib.XQueryPointer(
            self.display, self.root, ctypes.byref(root), ctypes.byref(child),
            ctypes.byref(rx), ctypes.byref(ry), ctypes.byref(wx), ctypes.byref(wy),
            ctypes.byref(mask),
        )
        if not ok:
            return None
        return rx.value, ry.value
