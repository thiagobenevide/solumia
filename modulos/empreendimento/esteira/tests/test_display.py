import subprocess
import sys

import pytest
from esteira.core import display


def _no_screen(monkeypatch, output):
    monkeypatch.delenv("DISPLAY", raising=False)
    monkeypatch.delenv("WAYLAND_DISPLAY", raising=False)
    monkeypatch.setattr(display.subprocess, "run", lambda *a, **k: subprocess.CompletedProcess(a, 0, stdout=output))


def test_service_without_display_uses_systemd_session(monkeypatch):
    _no_screen(monkeypatch, "PATH=/bin\nDISPLAY=:0\nXAUTHORITY=/home/x/.Xauthority\n")
    env = display._environment()
    assert env["DISPLAY"] == ":0" and env["XAUTHORITY"] == "/home/x/.Xauthority"
    assert env["PATH"] != "/bin"


def test_without_graphical_session_warns(monkeypatch):
    _no_screen(monkeypatch, "PATH=/bin\n")
    with pytest.raises(display.NoDisplay, match="graphical session"):
        display.open_program("filmcraft", "x.fcproj")


def test_program_crashing_on_open_warns(monkeypatch):
    monkeypatch.setenv("DISPLAY", ":0")
    with pytest.raises(display.NoDisplay, match="code 3"):
        display.open_program(sys.executable, "-c", "raise SystemExit(3)")


def test_clean_exit_is_not_error(monkeypatch):
    monkeypatch.setenv("DISPLAY", ":0")
    display.open_program(sys.executable, "-c", "pass")
