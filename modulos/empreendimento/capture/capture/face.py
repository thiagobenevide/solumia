"""Face tracking for camera sources: a small gray copy of the frames goes to OpenCV (Haar cascade).

The tracker only reports where the face is (center and height, normalized to the source); the engine
moves the item framing smoothly toward it. Without OpenCV (`cv2`) the tracker stays inactive.
"""

from __future__ import annotations

import logging
import threading
import time

import gi

gi.require_version("Gst", "1.0")
from gi.repository import Gst  # noqa: E402

from .elements import caps, make  # noqa: E402

log = logging.getLogger("capture")

WIDTH = 320
HEIGHT = 180
INTERVAL = 0.2

try:
    import cv2
    import numpy as np
except ImportError:  # optional: the venv from infra/scripts/install_capture brings it
    cv2 = None
    np = None


def available() -> bool:
    return cv2 is not None


class FaceTracker:
    def __init__(self) -> None:
        self.sink: Gst.Element | None = None
        self.face: tuple[float, float, float] | None = None  # cx, cy, height
        self.seen_at = 0.0
        self.running = True
        self.cascade = None
        if cv2 is not None:
            path = cv2.data.haarcascades + "haarcascade_frontalface_default.xml"
            self.cascade = cv2.CascadeClassifier(path)
        self.thread = threading.Thread(target=self.loop, name="face-tracker", daemon=True)
        self.thread.start()

    def branch(self) -> list[Gst.Element]:
        """Elements to hang on a tee of the camera: queue -> scale -> GRAY8 -> appsink."""
        # no signal: the tracker thread pulls frames itself, so no Python runs on the video thread
        sink = make("appsink", emit_signals=False, max_buffers=1, drop=True, sync=False)
        self.sink = sink
        return [
            make("queue", leaky="downstream", max_size_buffers=1),
            # the thread reads 5 frames/s: scaling every camera frame was wasted CPU
            make("videorate", drop_only=True, max_rate=round(1 / INTERVAL)),
            make("videoscale", add_borders=False),
            make("videoconvert"),
            caps(f"video/x-raw,format=GRAY8,width={WIDTH},height={HEIGHT}"),
            sink,
        ]

    def pull(self) -> bytes | None:
        if self.sink is None:
            return None
        sample = self.sink.emit("try-pull-sample", 100 * Gst.MSECOND)
        if sample is None:
            return None
        buffer = sample.get_buffer()
        ok, info = buffer.map(Gst.MapFlags.READ)
        if not ok:
            return None
        frame = bytes(info.data)
        buffer.unmap(info)
        return frame

    def loop(self) -> None:
        while self.running:
            time.sleep(INTERVAL)
            if self.cascade is None:
                continue
            frame = self.pull()
            if frame is None or len(frame) < WIDTH * HEIGHT:
                continue
            self.detect(frame)

    def detect(self, frame: bytes) -> None:
        image = np.frombuffer(frame, dtype=np.uint8)[: WIDTH * HEIGHT].reshape(HEIGHT, WIDTH)
        image = cv2.equalizeHist(image)
        faces = self.cascade.detectMultiScale(image, scaleFactor=1.15, minNeighbors=5,
                                              minSize=(18, 18))
        if len(faces) == 0:
            return
        best = None
        for x, y, w, h in faces:
            if best is None or w * h > best[2] * best[3]:
                best = (x, y, w, h)
        x, y, w, h = best
        # a bit above the center: eyes on the upper third looks better than the nose in the middle
        self.face = ((x + w / 2) / WIDTH, (y + h * 0.45) / HEIGHT, h / HEIGHT)
        self.seen_at = time.monotonic()

    def current(self) -> tuple[float, float, float] | None:
        """Last face seen in the last 3 s (after that the framing stays where it is)."""
        if self.face is None or time.monotonic() - self.seen_at > 3:
            return None
        return self.face

    def stop(self) -> None:
        self.running = False
