"""Command line for keyboard shortcuts and tablet buttons: `python3 -m capture.ctl <command>`.

Bind them in MATE (System > Preferences > Keyboard Shortcuts) or in the tablet driver, e.g.
`/usr/bin/python3 -m capture.ctl draw` with the working directory at modulos/empreendimento/capture
(or `infra/scripts/capture_ctl draw`).

    draw        toggle drawing mode         clear / undo   drawing
    zoom-in     zoom on the screen          zoom-out / zoom-reset
    record      start recording             stop
    scene NAME  switch scene (move transition)
"""

from __future__ import annotations

import json
import os
import sys
import urllib.request

from .model import API_PORT

COMMANDS = {
    "draw": ("POST", "/drawing", {"action": "toggle"}),
    "clear": ("POST", "/drawing", {"action": "clear"}),
    "undo": ("POST", "/drawing", {"action": "undo"}),
    "zoom-in": ("POST", "/zoom", {"action": "in"}),
    "zoom-out": ("POST", "/zoom", {"action": "out"}),
    "zoom-reset": ("POST", "/zoom", {"action": "reset"}),
    "record": ("POST", "/recording/start", {}),
    "stop": ("POST", "/recording/stop", {}),
}


def call(method: str, path: str, body: dict | None = None) -> dict:
    port = int(os.environ.get("CAPTURE_PORT", API_PORT))
    data = json.dumps(body or {}).encode() if method != "GET" else None
    request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, method=method,
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.loads(response.read() or b"{}")


def switch_scene(name: str) -> dict:
    state = call("GET", "/state")
    for scene in state["studio"]["scenes"]:
        if scene["name"].lower() == name.lower():
            body = {"transition": "move", "ms": 500}
            return call("POST", f"/scenes/{scene['id']}/activate", body)
    raise SystemExit(f"scene not found: {name}")


def main(arguments: list[str]) -> None:
    if not arguments or arguments[0] not in COMMANDS and arguments[0] != "scene":
        raise SystemExit(__doc__)
    if arguments[0] == "scene":
        print(json.dumps(switch_scene(" ".join(arguments[1:]))))
        return
    method, path, body = COMMANDS[arguments[0]]
    print(json.dumps(call(method, path, body)))


if __name__ == "__main__":
    main(sys.argv[1:])
