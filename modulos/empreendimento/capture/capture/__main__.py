"""`python3 -m capture`: starts the studio engine and the local API.

Runs with the system Python (PyGObject/GStreamer come from apt) or with the venv made by
`infra/scripts/install_capture` (system packages + OpenCV for face tracking).
"""

from __future__ import annotations

import faulthandler
import logging
import os
import signal
from pathlib import Path

# own GStreamer registry: the user cache may predate the NVIDIA driver and hide NVENC
# (nvcodec "0 features")
REGISTRY = Path.home() / ".cache" / "solumia-capture" / "registry.bin"
REGISTRY.parent.mkdir(parents=True, exist_ok=True)
os.environ.setdefault("GST_REGISTRY", str(REGISTRY))


class App:
    def __init__(self) -> None:
        from gi.repository import GLib

        from .api import serve
        from .engine import Engine
        from .model import API_PORT, Studio, studio_dir

        path = studio_dir() / "studio.json"
        self.engine = Engine(Studio.load(path), path)
        self.engine.save()
        self.port = int(os.environ.get("CAPTURE_PORT", API_PORT))
        self.server = serve(self.engine, self.port)
        self.loop = GLib.MainLoop()
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, self.quit)
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, self.quit)
        GLib.idle_add(self.start)

    def start(self) -> bool:
        self.engine.build()
        return False

    def quit(self) -> bool:
        from gi.repository import GLib

        if self.engine.recording:
            self.engine.stop_recording()
            GLib.timeout_add_seconds(3, self.loop.quit)
        else:
            self.loop.quit()
        return True

    def run(self) -> None:
        logging.getLogger("capture").info("studio at http://127.0.0.1:%d", self.port)
        try:
            self.loop.run()
        finally:
            self.server.shutdown()
            self.engine.destroy()


def main() -> None:
    # `kill -USR1 <pid>` dumps every Python thread: diagnoses a stuck pipeline
    faulthandler.register(signal.SIGUSR1, all_threads=True)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    App().run()


if __name__ == "__main__":
    main()
