"""Opens windowed programs in the PC's graphical session, even with the panel running as a service."""
import os
import subprocess

_VARIABLES = ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "XDG_SESSION_TYPE")


class NoDisplay(RuntimeError):
    """The program could not open its window on the PC."""


def _environment():
    """The service starts at boot, before login, and inherits an environment without DISPLAY; the one that knows
    the session opened later is the user's systemd manager."""
    env = dict(os.environ)
    if env.get("DISPLAY") or env.get("WAYLAND_DISPLAY"):
        return env
    try:
        r = subprocess.run(["systemctl", "--user", "show-environment"], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return env
    for line in r.stdout.splitlines():
        name, _, value = line.partition("=")
        if name in _VARIABLES:
            env[name] = value
    return env


def open_program(*cmd):
    """Opens without blocking the caller. Raises NoDisplay if there is no session or the program dies on open."""
    env = _environment()
    if not (env.get("DISPLAY") or env.get("WAYLAND_DISPLAY")):
        raise NoDisplay(f"{cmd[0]}: no graphical session open on the PC")
    p = subprocess.Popen(cmd, env=env, start_new_session=True, stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        code = p.wait(timeout=2)
    except subprocess.TimeoutExpired:
        return
    # Exit code 0 here is normal: the program may have handed the file to an already open window.
    if code:
        raise NoDisplay(f"{cmd[0]} closed on open (code {code})")
