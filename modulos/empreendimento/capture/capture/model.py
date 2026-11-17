"""Capture studio model, without GStreamer: sources, scenes, config, framing and transitions.

Video sources enter scenes as items (position/size on the canvas, opacity, framing and mask);
audio sources are global, like in OBS (single mixer). Everything is stored as JSON in
`$AGENT_DATA/recordings/studio/studio.json`.
"""

from __future__ import annotations

import json
import os
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path

VIDEO_KINDS = {"screen", "phone", "webcam", "image", "text", "color"}
AUDIO_KINDS = {"microphone", "output"}
# sources that go through the GL shader (framing, zoom, mask)
FRAMED_KINDS = {"screen", "phone", "webcam", "image"}
CAMERA_KINDS = {"phone", "webcam"}
ENCODERS = {"nvh264", "nvh265", "x264"}
TRANSITIONS = {"cut", "fade", "move", "slide", "zoom"}
FITS = {"cover", "contain", "stretch"}

API_PORT = 5620
# the env overrides let a second engine run beside the real one (test bench), never colliding
PREVIEW_PORT = int(os.environ.get("CAPTURE_PREVIEW_PORT", 5610))
# copy of the phone stream that the app receiver (ffmpeg) sends to the studio
PHONE_PORT = int(os.environ.get("CAPTURE_PHONE_PORT", 5602))


def studio_dir() -> Path:
    base = os.environ.get("AGENT_DATA") or str(Path.home() / "agent-data")
    return Path(base) / "recordings" / "studio"


def new_id() -> str:
    return uuid.uuid4().hex[:8]


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


@dataclass
class Source:
    kind: str
    name: str
    config: dict = field(default_factory=dict)
    id: str = field(default_factory=new_id)

    @property
    def video(self) -> bool:
        return self.kind in VIDEO_KINDS

    @property
    def framed(self) -> bool:
        return self.kind in FRAMED_KINDS


@dataclass
class Item:
    """Video source placed in a scene (canvas pixels) with its framing.

    zoom/cx/cy pick the part of the source shown (center normalized 0..1); radius rounds the
    corners in pixels (half of the smaller side = circle); fit decides how the source fills
    the item.
    """

    source: str
    x: int = 0
    y: int = 0
    w: int = 1920
    h: int = 1080
    alpha: float = 1.0
    visible: bool = True
    zoom: float = 1.0
    cx: float = 0.5
    cy: float = 0.5
    radius: float = 0.0
    border: float = 0.0
    border_color: str = "#FFFFFF"
    fit: str = "cover"


@dataclass
class Scene:
    name: str
    items: list[Item] = field(default_factory=list)
    id: str = field(default_factory=new_id)


@dataclass
class Config:
    width: int = 1920
    height: int = 1080
    fps: int = 60
    encoder: str = "nvh264"
    bitrate_kbps: int = 40000
    remux_mov: bool = True


@dataclass
class Studio:
    config: Config = field(default_factory=Config)
    sources: list[Source] = field(default_factory=list)
    scenes: list[Scene] = field(default_factory=list)
    current_scene: str | None = None

    # ------------------------------------------------------------------ lookup

    def source(self, source_id: str) -> Source:
        for s in self.sources:
            if s.id == source_id:
                return s
        raise KeyError(f"source {source_id} does not exist")

    def scene(self, scene_id: str) -> Scene:
        for s in self.scenes:
            if s.id == scene_id:
                return s
        raise KeyError(f"scene {scene_id} does not exist")

    def current(self) -> Scene | None:
        if self.current_scene is None:
            return None
        try:
            return self.scene(self.current_scene)
        except KeyError:
            return None

    def first_of(self, kinds: set[str]) -> Source | None:
        for s in self.sources:
            if s.kind in kinds:
                return s
        return None

    # ------------------------------------------------------------------ editing

    def add_source(self, kind: str, name: str, config: dict | None = None) -> Source:
        if kind not in VIDEO_KINDS | AUDIO_KINDS:
            raise ValueError(f"unknown source kind: {kind}")
        source = Source(kind=kind, name=name or kind, config=dict(config or {}))
        self.sources.append(source)
        # a new video source joins the current scene filling the canvas (like OBS)
        scene = self.current()
        if source.video and scene is not None:
            scene.items.append(Item(source=source.id, w=self.config.width, h=self.config.height))
        return source

    def remove_source(self, source_id: str) -> None:
        self.source(source_id)
        kept = []
        for s in self.sources:
            if s.id != source_id:
                kept.append(s)
        self.sources = kept
        for scene in self.scenes:
            items = []
            for item in scene.items:
                if item.source != source_id:
                    items.append(item)
            scene.items = items

    def add_scene(self, name: str) -> Scene:
        scene = Scene(name=name or f"Scene {len(self.scenes) + 1}")
        self.scenes.append(scene)
        if self.current_scene is None:
            self.current_scene = scene.id
        return scene

    def remove_scene(self, scene_id: str) -> None:
        self.scene(scene_id)
        kept = []
        for s in self.scenes:
            if s.id != scene_id:
                kept.append(s)
        self.scenes = kept
        if self.current_scene == scene_id:
            self.current_scene = self.scenes[0].id if self.scenes else None

    def set_items(self, scene_id: str, items: list[dict]) -> None:
        scene = self.scene(scene_id)
        new_items = []
        seen = set()
        for data in items:
            source = self.source(data["source"])
            if not source.video or source.id in seen:
                continue
            seen.add(source.id)
            new_items.append(self.item_from_dict(source.id, data))
        scene.items = new_items

    def item_from_dict(self, source_id: str, data: dict) -> Item:
        fit = data.get("fit", "cover")
        if fit not in FITS:
            fit = "cover"
        return Item(
            source=source_id,
            x=int(data.get("x", 0)),
            y=int(data.get("y", 0)),
            w=max(1, int(data.get("w", self.config.width))),
            h=max(1, int(data.get("h", self.config.height))),
            alpha=clamp(float(data.get("alpha", 1.0)), 0.0, 1.0),
            visible=bool(data.get("visible", True)),
            zoom=clamp(float(data.get("zoom", 1.0)), 1.0, 8.0),
            cx=clamp(float(data.get("cx", 0.5)), 0.0, 1.0),
            cy=clamp(float(data.get("cy", 0.5)), 0.0, 1.0),
            radius=max(0.0, float(data.get("radius", 0.0))),
            border=max(0.0, float(data.get("border", 0.0))),
            border_color=str(data.get("border_color", "#FFFFFF")),
            fit=fit,
        )

    def set_config(self, data: dict) -> None:
        config = self.config
        if "encoder" in data and data["encoder"] not in ENCODERS:
            raise ValueError(f"unknown encoder: {data['encoder']}")
        for key in ("width", "height", "fps", "bitrate_kbps"):
            if key in data:
                setattr(config, key, max(2, int(data[key])))
        if "encoder" in data:
            config.encoder = data["encoder"]
        if "remux_mov" in data:
            config.remux_mov = bool(data["remux_mov"])
        # NVENC/x264 need even dimensions
        config.width -= config.width % 2
        config.height -= config.height % 2

    # ------------------------------------------------------------------ JSON

    def to_json(self) -> dict:
        sources = []
        for s in self.sources:
            sources.append(asdict(s))
        scenes = []
        for s in self.scenes:
            scenes.append(asdict(s))
        return {
            "config": asdict(self.config),
            "sources": sources,
            "scenes": scenes,
            "current_scene": self.current_scene,
        }

    @classmethod
    def from_json(cls, data: dict) -> Studio:
        studio = cls(config=Config(**data.get("config", {})))
        for s in data.get("sources", []):
            studio.sources.append(Source(**s))
        for s in data.get("scenes", []):
            items = []
            for i in s.get("items", []):
                items.append(Item(**i))
            studio.scenes.append(Scene(id=s["id"], name=s["name"], items=items))
        studio.current_scene = data.get("current_scene")
        return studio

    @classmethod
    def default(cls) -> Studio:
        """First run: one scene with the whole screen following the mouse, mic and PC audio."""
        studio = cls()
        studio.add_scene("Screen")
        studio.add_source("screen", "Screen", {"monitor": 0, "follow_mouse": True})
        studio.add_source("microphone", "Microphone", {"device": "", "volume": 1.0})
        studio.add_source("output", "PC audio", {"device": "", "volume": 1.0})
        return studio

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.to_json(), ensure_ascii=False, indent=2))
        tmp.replace(path)

    @classmethod
    def load(cls, path: Path) -> Studio:
        if not path.exists():
            return cls.default()
        return cls.from_json(json.loads(path.read_text()))


# ---------------------------------------------------------------------- framing


def source_rect(
    source_aspect: float, item_aspect: float, zoom: float, cx: float, cy: float, fit: str
) -> tuple[float, float, float, float]:
    """Normalized source rectangle (x, y, w, h) shown inside an item.

    cover: fills the item cutting the source (no bars); contain: the whole source with bars
    (rectangle larger than 1, the shader makes the outside transparent); stretch: deforms.
    """
    zoom = max(1.0, zoom)
    if fit == "stretch":
        w = 1.0
        h = 1.0
    else:
        # region width/height in normalized units keeps the item aspect in source pixels
        relative = item_aspect / max(source_aspect, 1e-6)
        if (fit == "cover") == (relative <= 1):
            w = relative
            h = 1.0
        else:
            w = 1.0
            h = 1.0 / relative
    w /= zoom
    h /= zoom
    x = cx - w / 2
    y = cy - h / 2
    if w <= 1:
        x = clamp(x, 0.0, 1.0 - w)
    else:
        x = 0.5 - w / 2
    if h <= 1:
        y = clamp(y, 0.0, 1.0 - h)
    else:
        y = 0.5 - h / 2
    return x, y, w, h


def follow_target(center: float, pointer: float, window: float, dead_zone: float = 0.5) -> float:
    """Where the window center should go on one axis so the pointer stays in its inner area.

    `window` is the visible size (normalized); the pointer moves freely inside `dead_zone` of the
    window and pushes the window only when it leaves it. The result never shows outside the screen.
    """
    if window >= 1:
        return 0.5
    inner = window * dead_zone / 2
    target = center
    if pointer > center + inner:
        target = pointer - inner
    elif pointer < center - inner:
        target = pointer + inner
    return clamp(target, window / 2, 1 - window / 2)


def smooth(current: float, target: float, factor: float) -> float:
    return current + (target - current) * factor


# ---------------------------------------------------------------------- transitions


@dataclass
class Frame:
    """State of one compositor pad (and its shader) at an instant."""

    x: float
    y: float
    w: float
    h: float
    alpha: float
    z: int
    zoom: float = 1.0
    cx: float = 0.5
    cy: float = 0.5
    radius: float = 0.0
    border: float = 0.0
    border_color: str = "#FFFFFF"
    fit: str = "cover"


def frame_from_item(item: Item, z: int) -> Frame:
    alpha = item.alpha if item.visible else 0.0
    return Frame(
        item.x, item.y, item.w, item.h, alpha, z, item.zoom, item.cx, item.cy,
        item.radius, item.border, item.border_color, item.fit,
    )


def targets(studio: Studio, scene: Scene | None) -> dict[str, Frame]:
    """Final state of ALL video sources for a scene; outside it (or hidden) they get alpha 0."""
    result: dict[str, Frame] = {}
    if scene is not None:
        z = 1
        for item in scene.items:
            result[item.source] = frame_from_item(item, z)
            z += 1
    for source in studio.sources:
        if source.video and source.id not in result:
            result[source.id] = Frame(0, 0, studio.config.width, studio.config.height, 0.0, 0)
    return result


def ease(t: float) -> float:
    t = clamp(t, 0.0, 1.0)
    return t * t * (3 - 2 * t)


def mix(a: float, b: float, s: float) -> float:
    return a + (b - a) * s


def blend(a: Frame, b: Frame, s: float, alpha: float) -> Frame:
    """Geometry and framing from a to b; colors/fit jump to the target."""
    return Frame(
        mix(a.x, b.x, s), mix(a.y, b.y, s), mix(a.w, b.w, s), mix(a.h, b.h, s), alpha,
        b.z, mix(a.zoom, b.zoom, s), mix(a.cx, b.cx, s), mix(a.cy, b.cy, s),
        mix(a.radius, b.radius, s), mix(a.border, b.border, s), b.border_color, b.fit,
    )


def scaled(f: Frame, factor: float, alpha: float, dx: float = 0.0) -> Frame:
    """Same frame scaled around its center (and shifted), with another opacity."""
    w = f.w * factor
    h = f.h * factor
    return Frame(
        f.x + (f.w - w) / 2 + dx, f.y + (f.h - h) / 2, w, h, alpha, f.z, f.zoom, f.cx, f.cy,
        f.radius * factor, f.border, f.border_color, f.fit,
    )


def entering(b: Frame, s: float, kind: str, canvas_w: float) -> Frame:
    if kind == "slide":
        return scaled(b, 1.0, b.alpha, (1 - s) * canvas_w)
    if kind == "zoom":
        return scaled(b, mix(0.85, 1.0, s), b.alpha * s)
    return scaled(b, 1.0, b.alpha * s)


def leaving(a: Frame, s: float, kind: str, canvas_w: float) -> Frame:
    if kind == "slide":
        return scaled(a, 1.0, a.alpha, -s * canvas_w)
    if kind == "zoom":
        return scaled(a, mix(1.0, 1.12, s), a.alpha * (1 - s))
    return scaled(a, 1.0, a.alpha * (1 - s))


def interpolate(
    start: dict[str, Frame], end: dict[str, Frame], t: float, kind: str, canvas_w: float
) -> dict[str, Frame]:
    """Intermediate state of a transition at `t` in [0, 1].

    - cut: jumps to the target;
    - fade: crossfade in place;
    - move/slide/zoom: items present in both scenes morph (position, size, framing, mask);
      the others fade, slide sideways or zoom in/out.
    """
    if kind == "cut" or t >= 1:
        return dict(end)
    s = ease(t)
    result: dict[str, Frame] = {}
    for source_id, b in end.items():
        a = start.get(source_id)
        if a is None:
            a = Frame(b.x, b.y, b.w, b.h, 0.0, b.z)
        in_both = a.alpha > 0 and b.alpha > 0
        if in_both and kind != "fade":
            result[source_id] = blend(a, b, s, mix(a.alpha, b.alpha, s))
        elif in_both:
            result[source_id] = blend(a, b, 1.0, mix(a.alpha, b.alpha, s))
        elif b.alpha > 0:
            result[source_id] = entering(b, s, kind, canvas_w)
        elif a.alpha > 0:
            out = leaving(a, s, kind, canvas_w)
            out.z = a.z
            result[source_id] = out
        else:
            result[source_id] = b
    return result


# ---------------------------------------------------------------------- scene templates

TEMPLATES = {
    "screen_cam_circle": "Screen + face in a circle",
    "screen_cam_rounded": "Screen + horizontal camera",
    "screen_cam_vertical": "Screen + vertical camera",
    "side_by_side": "Screen and camera side by side",
    "cam_only": "Face only",
    "screen_only": "Screen only",
}


def screen_item(source_id: str, x: int, y: int, w: int, h: int) -> dict:
    return {"source": source_id, "x": x, "y": y, "w": w, "h": h, "fit": "cover"}


def camera_item(source_id: str, x: int, y: int, w: int, h: int, radius: float, zoom: float,
                border: float) -> dict:
    return {
        "source": source_id, "x": x, "y": y, "w": w, "h": h, "radius": radius, "zoom": zoom,
        "border": border, "fit": "cover",
    }


def template_items(name: str, width: int, height: int, screen: str | None,
                   camera: str | None) -> list[dict]:
    """Items of a ready-made layout for the canvas (landscape or vertical)."""
    if name not in TEMPLATES:
        raise ValueError(f"unknown template: {name}")
    portrait = height > width
    short = min(width, height)
    margin = round(short * 0.035)
    items: list[dict] = []
    if name == "cam_only":
        if camera:
            items.append(camera_item(camera, 0, 0, width, height, 0, 1.0, 0))
        return items
    if name == "side_by_side" and portrait:
        top = round(height * 0.55)
        if screen:
            items.append(screen_item(screen, 0, 0, width, top))
        if camera:
            items.append(camera_item(camera, 0, top, width, height - top, 0, 1.2, 0))
        return items
    if name == "side_by_side":
        left = round(width * 0.66)
        if screen:
            items.append(screen_item(screen, 0, 0, left, height))
        if camera:
            items.append(camera_item(camera, left, 0, width - left, height, 0, 1.2, 0))
        return items
    if screen:
        items.append(screen_item(screen, 0, 0, width, height))
    if not camera or name == "screen_only":
        return items
    if name == "screen_cam_circle":
        size = round(short * (0.34 if portrait else 0.28))
        x = (width - size) // 2 if portrait else width - size - margin
        items.append(camera_item(camera, x, height - size - margin, size, size, size / 2, 1.8, 6))
    elif name == "screen_cam_rounded":
        w = round(width * (0.6 if portrait else 0.26))
        h = round(w * 9 / 16)
        items.append(camera_item(camera, width - w - margin, height - h - margin, w, h, 24, 1.2, 4))
    elif name == "screen_cam_vertical":
        h = round(height * (0.45 if portrait else 0.72))
        w = round(h * 9 / 16)
        items.append(camera_item(camera, width - w - margin, height - h - margin, w, h, 24, 1.4, 4))
    return items
