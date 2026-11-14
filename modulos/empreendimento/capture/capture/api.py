"""Local JSON API of the studio (127.0.0.1:5620), standard library only.

Every request runs on the GLib loop (where the pipeline lives) through `GLib.idle_add`.

    GET    /state                       full state (studio, levels, recording, drawing)
    GET    /devices                     monitors, audio (PulseAudio/PipeWire), webcams
    GET    /templates                   ready-made scene layouts
    PATCH  /config                      canvas/encoder (rebuilds)
    POST   /sources {kind,name,config}  PATCH/DELETE /sources/<id>
    POST   /sources/<id>/reload         tries a failed source again
    POST   /sources/<id>/zoom {action: in|out|reset}
    POST   /zoom {action}               zoom on every screen source (keyboard shortcuts)
    POST   /scenes {name}               PATCH /scenes/<id> {name?, items?}   DELETE /scenes/<id>
    POST   /scenes/template {template, name?}
    POST   /scenes/<id>/activate {transition: cut|fade|move|slide|zoom, ms}
    POST   /drawing {active?, action?: toggle|clear|undo, tool?, color?, size?, fade?}
    POST   /recording/start             POST /recording/stop
"""

from __future__ import annotations

import json
import logging
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from gi.repository import GLib

from . import devices
from .engine import Engine
from .model import CAMERA_KINDS, TEMPLATES, TRANSITIONS, template_items

log = logging.getLogger("capture")


class RequestError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


class LoopCall:
    """Runs a function on the GLib loop and hands the result back to the HTTP thread."""

    def __init__(self, function, args: tuple):
        self.function = function
        self.args = args
        self.done = threading.Event()
        self.result = None
        self.error: Exception | None = None

    def run(self) -> bool:
        try:
            self.result = self.function(*self.args)
        except Exception as error:  # noqa: BLE001 - goes back to the HTTP thread
            self.error = error
        self.done.set()
        return False

    def wait(self, timeout: float):
        # default priority: the 30 Hz tick must not starve the API
        GLib.idle_add(self.run, priority=GLib.PRIORITY_DEFAULT)
        if not self.done.wait(timeout):
            raise RequestError(504, "the engine did not answer")
        if self.error is not None:
            raise self.error
        return self.result


def on_loop(function, *args, timeout: float = 15):
    return LoopCall(function, args).wait(timeout)


class Router:
    def __init__(self, engine: Engine):
        self.engine = engine
        self.studio = engine.studio

    def handle(self, method: str, path: str, body: dict):
        parts = []
        for piece in path.split("/"):
            if piece:
                parts.append(piece)
        if method == "GET":
            return self.get(parts)
        if parts[:1] == ["sources"]:
            return self.sources(method, parts, body)
        if parts[:1] == ["scenes"]:
            return self.scenes(method, parts, body)
        if parts == ["config"] and method == "PATCH":
            return on_loop(self.set_config, body)
        if parts == ["zoom"] and method == "POST":
            return on_loop(self.engine.zoom_screens, str(body.get("action", "in")))
        if parts == ["drawing"] and method == "POST":
            return on_loop(self.engine.drawing, body)
        if parts == ["recording", "start"] and method == "POST":
            return {"file": on_loop(self.engine.start_recording)}
        if parts == ["recording", "stop"] and method == "POST":
            return {"file": on_loop(self.engine.stop_recording)}
        raise RequestError(404, f"unknown route: {method} {path}")

    def get(self, parts: list[str]):
        if parts == ["state"]:
            return on_loop(self.engine.state)
        if parts == ["devices"]:
            return {"monitors": devices.monitors(), "audio": devices.audio_devices(),
                    "webcams": devices.webcams()}
        if parts == ["templates"]:
            return TEMPLATES
        raise RequestError(404, "unknown route")

    # ------------------------------------------------------------------ sources

    def sources(self, method: str, parts: list[str], body: dict):
        if method == "POST" and len(parts) == 1:
            return on_loop(self.add_source, body)
        if len(parts) == 2 and method == "PATCH":
            return on_loop(self.engine.update_source, parts[1], body.get("name"),
                           body.get("config"))
        if len(parts) == 2 and method == "DELETE":
            return on_loop(self.remove_source, parts[1])
        if len(parts) == 3 and parts[2] == "reload" and method == "POST":
            return on_loop(self.reload_source, parts[1])
        if len(parts) == 3 and parts[2] == "zoom" and method == "POST":
            return on_loop(self.engine.zoom, parts[1], str(body.get("action", "in")))
        raise RequestError(404, "unknown route")

    def add_source(self, body: dict) -> dict:
        self.engine.require_stopped()
        source = self.studio.add_source(body.get("kind", ""), body.get("name", ""),
                                        body.get("config"))
        self.engine.save()
        self.engine.build()
        return {"id": source.id}

    def remove_source(self, source_id: str) -> None:
        self.engine.require_stopped()
        self.studio.remove_source(source_id)
        self.engine.failures.pop(source_id, None)
        self.engine.save()
        self.engine.build()

    def reload_source(self, source_id: str) -> None:
        self.engine.require_stopped()
        self.engine.failures.pop(source_id, None)
        self.engine.error = None
        self.engine.build()

    def set_config(self, body: dict) -> dict:
        self.engine.require_stopped()
        self.studio.set_config(body)
        self.engine.save()
        self.engine.build()
        return self.engine.state()

    # ------------------------------------------------------------------ scenes

    def scenes(self, method: str, parts: list[str], body: dict):
        if method == "POST" and parts == ["scenes"]:
            return on_loop(self.add_scene, str(body.get("name", "")))
        if method == "POST" and parts == ["scenes", "template"]:
            return on_loop(self.add_template, str(body.get("template", "")),
                           str(body.get("name", "")))
        if len(parts) == 2 and method == "PATCH":
            return on_loop(self.edit_scene, parts[1], body)
        if len(parts) == 2 and method == "DELETE":
            return on_loop(self.remove_scene, parts[1])
        if len(parts) == 3 and parts[2] == "activate" and method == "POST":
            transition = body.get("transition", "fade")
            if transition not in TRANSITIONS:
                raise RequestError(400, f"unknown transition: {transition}")
            return on_loop(self.engine.activate_scene, parts[1], transition,
                           int(body.get("ms", 400)))
        raise RequestError(404, "unknown route")

    def add_scene(self, name: str) -> dict:
        scene = self.studio.add_scene(name)
        self.engine.save()
        return {"id": scene.id}

    def add_template(self, template: str, name: str) -> dict:
        config = self.studio.config
        screen = self.studio.first_of({"screen"})
        camera = self.studio.first_of(CAMERA_KINDS)
        items = template_items(template, config.width, config.height,
                               screen.id if screen else None, camera.id if camera else None)
        scene = self.studio.add_scene(name or TEMPLATES[template])
        self.studio.set_items(scene.id, items)
        self.engine.save()
        return {"id": scene.id}

    def edit_scene(self, scene_id: str, body: dict) -> None:
        scene = self.studio.scene(scene_id)
        if body.get("name"):
            scene.name = str(body["name"])
        if "items" in body:
            self.studio.set_items(scene.id, body["items"])
            if self.studio.current_scene == scene.id:
                self.engine.reapply_scene()
        self.engine.save()

    def remove_scene(self, scene_id: str) -> None:
        self.studio.remove_scene(scene_id)
        self.engine.reapply_scene()
        self.engine.save()


class Handler(BaseHTTPRequestHandler):
    router: Router

    def reply(self, status: int, data) -> None:
        body = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def dispatch(self, method: str) -> None:
        try:
            size = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(size) or b"{}") if size else {}
            path = re.sub(r"\?.*$", "", self.path)
            result = self.router.handle(method, path, body)
            self.reply(200, result if result is not None else {"ok": True})
        except RequestError as error:
            self.reply(error.status, {"error": str(error)})
        except KeyError as error:
            self.reply(404, {"error": str(error).strip("'\"")})
        except (ValueError, RuntimeError) as error:
            self.reply(409, {"error": str(error)})
        except Exception as error:  # noqa: BLE001
            log.exception("API error")
            self.reply(500, {"error": str(error)})

    def do_GET(self):  # noqa: N802
        self.dispatch("GET")

    def do_POST(self):  # noqa: N802
        self.dispatch("POST")

    def do_PATCH(self):  # noqa: N802
        self.dispatch("PATCH")

    def do_DELETE(self):  # noqa: N802
        self.dispatch("DELETE")

    def log_message(self, *_):
        pass


def serve(engine: Engine, port: int) -> ThreadingHTTPServer:
    handler = type("BoundHandler", (Handler,), {"router": Router(engine)})
    server = ThreadingHTTPServer(("127.0.0.1", port), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server
