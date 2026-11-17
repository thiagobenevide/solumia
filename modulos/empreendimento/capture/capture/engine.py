"""Studio engine: one always-on GStreamer pipeline, like OBS.

    black background ─┐
    screen/phone/     ├─ [GL shader: framing, zoom, mask] ─ glvideomixer ─ NV12 ─ tee ─┬─ preview
    webcam/image      │   (all on the GPU, one download)                             └─ [rec]
    text/color ───────┘
    mic/output ─ tee(raw) ─ volume ─ level ─ audiomixer ─ tee ─┬─ fakesink
                    └──────────── [rec: one track per source] └─ [rec: mix track]

Switching scenes, moving items, framing, text, volume and zoom happen live (element properties
and shader uniforms). Adding/removing a source or changing a device/canvas rebuilds the pipeline
(blocked while recording). The phone camera comes from the app receiver (UDP copy of the stream)
through a separate pipeline joined by intervideosink -> intervideosrc (no Python on the streaming
threads), so phone drops never stall the studio.
"""

from __future__ import annotations

import functools
import logging
import re
import subprocess
import threading
import time
from datetime import datetime
from pathlib import Path

import gi

gi.require_version("Gst", "1.0")
from gi.repository import GLib, Gst  # noqa: E402

from . import devices, face  # noqa: E402
from .elements import (  # noqa: E402
    FRAMING_SHADER,
    AspectWatch,
    DynamicLink,
    caps,
    color_argb,
    color_rgb,
    link_all,
    make,
    make_live,
    set_prop,
)
from .model import (  # noqa: E402
    CAMERA_KINDS,
    PHONE_PORT,
    PREVIEW_PORT,
    Frame,
    Studio,
    follow_target,
    interpolate,
    smooth,
    source_rect,
    studio_dir,
    targets,
)
from .overlay import DrawingOverlay  # noqa: E402

log = logging.getLogger("capture")

# NVENC through the CUDA implementation: the old one (nvh264enc) rejects presets on new drivers
FACTORIES = {"nvh264": "nvcudah264enc", "nvh265": "nvcudah265enc", "x264": "x264enc"}
# level sends a GValueArray that PyGObject cannot read, so it is parsed from the structure text
PEAK = re.compile(r"peak=\([A-Za-z]+\)[{<]([^}>]*)[}>]")
SOURCE_NAME = re.compile(r"s_([0-9a-f]{8})_")
AUDIO_CAPS = "audio/x-raw,format=S16LE,rate=48000,channels=2,layout=interleaved"
LIVE_KEYS = {"text", "font", "color", "shadow", "volume", "muted", "follow_mouse", "auto_zoom",
             "dead_zone"}
TICK_MS = 33
PREVIEW_FPS = 30


class Engine:
    def __init__(self, studio: Studio, path: Path):
        self.studio = studio
        self.path = path
        self.pipeline: Gst.Pipeline | None = None
        self.tee_video: Gst.Element | None = None
        self.tee_audio: Gst.Element | None = None
        self.pads: dict[str, Gst.Pad] = {}
        self.shaders: dict[str, Gst.Element] = {}
        self.aspects: dict[str, float] = {}
        self.volumes: dict[str, Gst.Element] = {}
        self.texts: dict[str, Gst.Element] = {}
        self.raw_tees: dict[str, Gst.Element] = {}
        self.bridges: dict[str, Gst.Pipeline] = {}
        self.trackers: dict[str, face.FaceTracker] = {}
        self.levels: dict[str, float] = {}
        self.frames: dict[str, Frame] = {}
        # live framing per source: [cx, cy, zoom multiplier, target multiplier]
        self.live: dict[str, list[float]] = {}
        self.failures: dict[str, str] = {}
        self.error: str | None = None
        self.encoder_used: str | None = None
        self.recording: dict | None = None
        self.recordings: list[dict] = []
        self.transition: dict | None = None
        self.counter: Gst.Element | None = None
        self.frames_rendered = 0
        self.fps = 0.0
        self.measured_at = time.monotonic()
        self.pointer = devices.Pointer()
        # geometry of each screen source, read once per build (xrandr is too slow for the tick)
        self.screens: dict[str, dict] = {}
        self.overlay = DrawingOverlay()
        GLib.timeout_add(TICK_MS, self.on_tick)

    # ================================================================== build

    def build(self) -> None:
        self.destroy()
        config = self.studio.config
        pipeline = Gst.Pipeline.new("studio")
        pipeline.use_clock(Gst.SystemClock.obtain())
        self.pipeline = pipeline
        compositor = self.build_video_output(pipeline)
        mixer = self.build_audio_output(pipeline)
        for source in self.studio.sources:
            if source.id in self.failures:
                continue
            try:
                if source.video:
                    self.add_video_source(source, compositor)
                else:
                    self.add_audio_source(source, mixer)
            except Exception as error:  # noqa: BLE001 - a bad source does not take the studio down
                self.failures[source.id] = str(error)
                log.warning("source %s (%s) failed: %s", source.name, source.kind, error)
        bus = pipeline.get_bus()
        bus.add_signal_watch()
        bus.connect("message", self.on_message)
        if pipeline.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
            self.error = "the pipeline did not start (see the source failures)"
        for bridge in self.bridges.values():
            bridge.set_state(Gst.State.PLAYING)
        self.apply(targets(self.studio, self.studio.current()))
        log.info("pipeline built: %dx%d@%d", config.width, config.height, config.fps)

    def build_video_output(self, pipeline: Gst.Pipeline) -> Gst.Element:
        config = self.studio.config
        video = f"width={config.width},height={config.height},framerate={config.fps}/1"
        # mixing on the GPU: the framed sources stay in GL memory (the CPU compositor blended every
        # full-canvas layer per frame and pinned the CPU) and only the final frame is downloaded
        compositor = make_live("glvideomixer", "comp", background="black",
                               latency=40 * Gst.MSECOND)
        mix_caps = caps(f"video/x-raw(memory:GLMemory),format=RGBA,{video},"
                        "pixel-aspect-ratio=1/1")
        to_nv12 = make("glcolorconvert")
        nv12_caps = caps("video/x-raw(memory:GLMemory),format=NV12")
        download = make("gldownload")
        out_caps = caps(f"video/x-raw,format=NV12,{video},pixel-aspect-ratio=1/1")
        self.tee_video = make("tee", "tee_video", allow_not_linked=True)
        elements = [compositor, mix_caps, to_nv12, nv12_caps, download, out_caps, self.tee_video]
        for element in elements:
            pipeline.add(element)
        link_all(elements)
        self.build_preview(pipeline)
        self.build_counter(pipeline)
        return compositor

    def build_preview(self, pipeline: Gst.Pipeline) -> None:
        """Light preview for the app (mpv reads the local UDP)."""
        config = self.studio.config
        width = 960
        height = round(width * config.height / config.width / 2) * 2
        if config.height > config.width:
            height = 960
            width = round(height * config.width / config.height / 2) * 2
        preview = [
            make("queue", "preview_queue", leaky="downstream", max_size_buffers=2),
            # the screen preview does not need the canvas rate: half the CPU of the x264 encode
            make("videorate", drop_only=True, max_rate=PREVIEW_FPS),
            make("videoscale"),
            make("videoconvert"),
            caps(f"video/x-raw,format=I420,width={width},height={height}"),
            make("x264enc", tune="zerolatency", speed_preset="ultrafast", bitrate=3000,
                 key_int_max=PREVIEW_FPS, threads=2),
            make("h264parse", config_interval=-1),
            make("mpegtsmux", alignment=7),
            make("udpsink", host="127.0.0.1", port=PREVIEW_PORT, sync=False, async_=False),
        ]
        for element in preview:
            pipeline.add(element)
        link_all(preview)
        self.tee_video.request_pad_simple("src_%u").link(preview[0].get_static_pad("sink"))

    def build_counter(self, pipeline: Gst.Pipeline) -> None:
        """Frame counter in C (fpsdisplaysink): no Python callback on the video thread."""
        queue = make("queue", leaky="downstream", max_size_buffers=2)
        self.counter = make("fpsdisplaysink", text_overlay=False, sync=False,
                            video_sink=make("fakesink", sync=False, async_=False))
        pipeline.add(queue)
        pipeline.add(self.counter)
        link_all([queue, self.counter])
        self.tee_video.request_pad_simple("src_%u").link(queue.get_static_pad("sink"))

    def build_audio_output(self, pipeline: Gst.Pipeline) -> Gst.Element:
        # silence keeps the mixer running even without a microphone
        mixer = make_live("audiomixer", "mixer", latency=40 * Gst.MSECOND,
                          ignore_inactive_pads=True)
        silence = make("audiotestsrc", "silence", is_live=True, wave="silence")
        silence_caps = caps(AUDIO_CAPS)
        mixer_caps = caps(AUDIO_CAPS)
        level = make("level", "master_level", interval=100 * Gst.MSECOND, post_messages=True)
        self.tee_audio = make("tee", "tee_audio", allow_not_linked=True)
        drain_queue = make("queue")
        drain = make("fakesink", sync=False, async_=False)
        elements = [mixer, silence, silence_caps, mixer_caps, level, self.tee_audio, drain_queue,
                    drain]
        for element in elements:
            pipeline.add(element)
        link_all([silence, silence_caps])
        silence_caps.get_static_pad("src").link(mixer.request_pad_simple("sink_%u"))
        link_all([mixer, mixer_caps, level, self.tee_audio])
        self.tee_audio.request_pad_simple("src_%u").link(drain_queue.get_static_pad("sink"))
        link_all([drain_queue, drain])
        return mixer

    def destroy(self) -> None:
        self.transition = None
        for bridge in self.bridges.values():
            bridge.set_state(Gst.State.NULL)
        for tracker in self.trackers.values():
            tracker.stop()
        if self.pipeline is not None:
            self.pipeline.get_bus().remove_signal_watch()
            self.pipeline.set_state(Gst.State.NULL)
        self.pipeline = None
        self.bridges.clear()
        self.trackers.clear()
        self.pads.clear()
        self.shaders.clear()
        self.volumes.clear()
        self.texts.clear()
        self.raw_tees.clear()
        self.levels.clear()
        self.counter = None
        self.frames_rendered = 0
        self.recording = None

    # ================================================================== sources

    def add_video_source(self, source, compositor: Gst.Element) -> None:
        prefix = f"s_{source.id}_"
        if source.kind == "screen":
            chain = self.screen_chain(source, prefix)
        elif source.kind == "color":
            chain = self.color_chain(source, prefix)
        elif source.kind == "text":
            chain = self.text_chain(source, prefix)
        elif source.kind == "image":
            chain = self.image_chain(source, prefix)
        elif source.kind == "webcam":
            chain = self.webcam_chain(source, prefix)
        elif source.kind == "phone":
            chain = self.phone_chain(source, prefix)
        else:
            raise RuntimeError(f"video kind without a chain: {source.kind}")
        if source.framed:
            chain += self.framing_chain(source, prefix)
        chain.append(make("queue", prefix + "queue", leaky="downstream", max_size_buffers=3))
        dynamic = None
        for element in chain:
            if isinstance(element, tuple):
                dynamic = element
                continue
            self.pipeline.add(element)
        elements = []
        for element in chain:
            if not isinstance(element, tuple):
                elements.append(element)
        self.link_chain(elements, dynamic)
        if source.kind in CAMERA_KINDS and source.config.get("track_face"):
            self.attach_tracker(source, prefix)
        pad = compositor.request_pad_simple("sink_%u")
        elements[-1].get_static_pad("src").link(pad)
        pad.set_property("alpha", 0.0)
        self.pads[source.id] = pad

    def link_chain(self, elements: list[Gst.Element], dynamic: tuple | None) -> None:
        if dynamic is None:
            link_all(elements)
            return
        origin, target = dynamic
        split = elements.index(origin)
        link_all(elements[: split + 1])
        DynamicLink(origin, target)
        link_all(elements[elements.index(target):])

    def screen_chain(self, source, prefix: str) -> list:
        fps = self.studio.config.fps
        monitor = devices.monitor(int(source.config.get("monitor", 0)))
        if monitor:
            self.screens[source.id] = monitor
        src = make("ximagesrc", prefix + "src", use_damage=False,
                   show_pointer=bool(source.config.get("cursor", True)))
        if monitor:
            src.set_property("startx", monitor["x"])
            src.set_property("starty", monitor["y"])
            src.set_property("endx", monitor["x"] + monitor["w"] - 1)
            src.set_property("endy", monitor["y"] + monitor["h"] - 1)
            self.aspects[source.id] = monitor["w"] / monitor["h"]
        return [src, caps(f"video/x-raw,framerate={fps}/1"), make("videoconvert")]

    def color_chain(self, source, prefix: str) -> list:
        config = self.studio.config
        return [
            make("videotestsrc", prefix + "src", is_live=True, pattern="solid-color",
                 foreground_color=color_argb(source.config.get("color", "#000000"))),
            caps(f"video/x-raw,format=BGRA,width={config.width},height={config.height},"
                 f"framerate={config.fps}/1"),
        ]

    def text_chain(self, source, prefix: str) -> list:
        config = source.config
        width = int(config.get("width", 1280))
        height = int(config.get("height", 200))
        overlay = make(
            "textoverlay", prefix + "text",
            text=str(config.get("text", "Text")),
            font_desc=str(config.get("font", "Sans Bold 48")),
            color=color_argb(config.get("color", "#FFFFFF")),
            halignment="center", valignment="center",
            draw_shadow=bool(config.get("shadow", True)),
        )
        self.texts[source.id] = overlay
        return [
            make("videotestsrc", prefix + "src", is_live=True, pattern="solid-color",
                 foreground_color=0),
            caps(f"video/x-raw,format=BGRA,width={width},height={height},"
                 f"framerate={self.studio.config.fps}/1"),
            overlay,
            # without this textoverlay negotiates caps the compositor pad refuses (NOFORMAT);
            # BGRA keeps the background transparent
            make("videoconvert"),
            caps("video/x-raw,format=BGRA"),
        ]

    def image_chain(self, source, prefix: str) -> list:
        path = str(source.config.get("file", ""))
        if not Path(path).is_file():
            raise RuntimeError(f"image not found: {path or '(empty)'}")
        decoder = make("decodebin", prefix + "decoder")
        convert = make("videoconvert")
        return [
            make("filesrc", prefix + "src", location=path), decoder, (decoder, convert), convert,
            make("imagefreeze", is_live=True),
            caps(f"video/x-raw,framerate={self.studio.config.fps}/1"),
        ]

    def webcam_chain(self, source, prefix: str) -> list:
        decoder = make("decodebin", prefix + "decoder")
        convert = make("videoconvert")
        device = str(source.config.get("device", "/dev/video0"))
        return [make("v4l2src", prefix + "src", device=device), decoder, (decoder, convert),
                convert]

    def phone_chain(self, source, prefix: str) -> list:
        width, height = self.bridge_size()
        channel = f"phone_{source.id}"
        # repeats the last phone frame at the canvas rate; black while the phone is away
        src = make("intervideosrc", prefix + "src", channel=channel)
        self.bridges[source.id] = self.phone_bridge(source, channel)
        self.aspects[source.id] = width / height
        return [src, caps(f"video/x-raw,format=I420,width={width},height={height},"
                          f"framerate={self.studio.config.fps}/1")]

    def bridge_size(self) -> tuple[int, int]:
        """The phone arrives landscape 16:9; it is scaled once to the canvas long side."""
        config = self.studio.config
        long_side = max(config.width, config.height)
        return long_side, round(long_side * 9 / 16 / 2) * 2

    def framing_chain(self, source, prefix: str) -> list:
        config = self.studio.config
        upload = make("glupload", prefix + "upload")
        AspectWatch(upload.get_static_pad("sink"), self.aspects, source.id)
        shader = make("glshader", prefix + "shader")
        shader.set_property("fragment", FRAMING_SHADER)
        self.shaders[source.id] = shader
        return [
            upload,
            make("glcolorconvert"),
            shader,
            caps(f"video/x-raw(memory:GLMemory),format=RGBA,width={config.width},"
                 f"height={config.height}"),
        ]

    def attach_tracker(self, source, prefix: str) -> None:
        """Hangs the face tracker on a tee right before the GL upload of the camera."""
        if not face.available():
            self.error = "face tracking needs OpenCV (run infra/scripts/install_capture)"
            return
        upload = self.pipeline.get_by_name(prefix + "upload")
        before = upload.get_static_pad("sink").get_peer()
        before.unlink(upload.get_static_pad("sink"))
        tee = make("tee", prefix + "face_tee")
        queue = make("queue", leaky="downstream", max_size_buffers=2)
        tracker = face.FaceTracker()
        branch = tracker.branch()
        self.pipeline.add(tee)
        self.pipeline.add(queue)
        for element in branch:
            self.pipeline.add(element)
        before.link(tee.get_static_pad("sink"))
        tee.request_pad_simple("src_%u").link(queue.get_static_pad("sink"))
        link_all([queue, upload])
        tee.request_pad_simple("src_%u").link(branch[0].get_static_pad("sink"))
        link_all(branch)
        self.trackers[source.id] = tracker

    def phone_bridge(self, source, channel: str) -> Gst.Pipeline:
        """Separate pipeline: UDP (MPEG-TS from the receiver) -> decode -> scale -> intervideo."""
        width, height = self.bridge_size()
        bridge = Gst.Pipeline.new(f"bridge_{source.id}")
        src = make("udpsrc", port=int(source.config.get("port", PHONE_PORT)),
                   buffer_size=32 * 1024 * 1024,
                   caps=Gst.Caps.from_string("video/mpegts,systemstream=true,packetsize=188"))
        decoder = make("decodebin")
        convert = make("videoconvert")
        scale = make("videoscale", add_borders=True)
        size = caps(f"video/x-raw,format=I420,width={width},height={height},"
                    "pixel-aspect-ratio=1/1")
        sink = make("intervideosink", channel=channel, sync=False)
        for element in (src, decoder, convert, scale, size, sink):
            bridge.add(element)
        link_all([src, decoder])
        DynamicLink(decoder, convert)
        link_all([convert, scale, size, sink])
        bus = bridge.get_bus()
        bus.add_signal_watch()
        bus.connect("message", self.on_bridge_message, bridge)
        return bridge

    def on_bridge_message(self, _bus, message: Gst.Message, bridge: Gst.Pipeline) -> None:
        if message.type != Gst.MessageType.ERROR:
            return
        error, _ = message.parse_error()
        log.warning("phone bridge: %s; restarting", error.message)
        bridge.set_state(Gst.State.NULL)
        GLib.timeout_add_seconds(2, self.restart_bridge, bridge)

    def restart_bridge(self, bridge: Gst.Pipeline) -> bool:
        bridge.set_state(Gst.State.PLAYING)
        return False

    def add_audio_source(self, source, mixer: Gst.Element) -> None:
        config = source.config
        prefix = f"s_{source.id}_"
        src = make("pulsesrc", prefix + "src", provide_clock=False)
        device = str(config.get("device") or "")
        if device:
            src.set_property("device", device)
        elif source.kind == "output":
            src.set_property("device", "@DEFAULT_MONITOR@")
        # raw tee before the volume: the separate track stays clean even if muted in the mix
        raw = make("tee", prefix + "raw", allow_not_linked=True)
        volume = make("volume", prefix + "volume", volume=float(config.get("volume", 1.0)),
                      mute=bool(config.get("muted", False)))
        self.volumes[source.id] = volume
        self.raw_tees[source.id] = raw
        chain = [
            src, make("audioconvert"), make("audioresample"), caps(AUDIO_CAPS), raw, volume,
            make("level", prefix + "level", interval=100 * Gst.MSECOND, post_messages=True),
            make("queue", prefix + "queue"),
        ]
        for element in chain:
            self.pipeline.add(element)
        link_all(chain)
        chain[-1].get_static_pad("src").link(mixer.request_pad_simple("sink_%u"))

    # ================================================================== messages

    def source_of(self, element: Gst.Object | None) -> str | None:
        while element is not None:
            match = SOURCE_NAME.match(element.get_name() or "")
            if match:
                return match.group(1)
            element = element.get_parent()
        return None

    def on_message(self, _bus, message: Gst.Message) -> None:
        if message.type == Gst.MessageType.ELEMENT:
            self.on_level(message)
        elif message.type == Gst.MessageType.ERROR:
            error, debug = message.parse_error()
            source_id = self.source_of(message.src)
            log.error("GStreamer: %s (%s)", error.message, debug)
            if source_id and not self.recording:
                # drop the broken source and keep going with the others
                self.failures[source_id] = error.message
                GLib.idle_add(self.rebuild)
            else:
                self.error = error.message
        elif message.type == Gst.MessageType.WARNING:
            warning, _ = message.parse_warning()
            log.warning("GStreamer: %s", warning.message)

    def on_level(self, message: Gst.Message) -> None:
        structure = message.get_structure()
        if structure is None or structure.get_name() != "level":
            return
        match = PEAK.search(structure.to_string())
        if not match:
            return
        peaks = []
        for value in match.group(1).split(","):
            if value.strip():
                peaks.append(float(value))
        key = self.source_of(message.src)
        if message.src.get_name() == "master_level":
            key = "master"
        if key:
            self.levels[key] = max(peaks) if peaks else -100.0

    def rebuild(self) -> bool:
        self.build()
        return False

    def measured_fps(self) -> float:
        now = time.monotonic()
        elapsed = now - self.measured_at
        if elapsed >= 0.5:
            rendered = self.counter.get_property("frames-rendered") if self.counter else 0
            self.fps = max(0, rendered - self.frames_rendered) / elapsed
            self.frames_rendered = rendered
            self.measured_at = now
        return self.fps

    # ================================================================== scenes and framing

    def apply(self, frames: dict[str, Frame]) -> None:
        self.frames = dict(frames)
        for source_id, frame in frames.items():
            pad = self.pads.get(source_id)
            if pad is None:
                continue
            pad.set_property("xpos", round(frame.x))
            pad.set_property("ypos", round(frame.y))
            pad.set_property("width", max(1, round(frame.w)))
            pad.set_property("height", max(1, round(frame.h)))
            pad.set_property("alpha", frame.alpha)
            pad.set_property("zorder", frame.z + 1)  # 0 is the background
            self.push_framing(source_id, frame)

    def live_state(self, source_id: str, frame: Frame) -> list[float]:
        state = self.live.get(source_id)
        if state is None:
            state = [frame.cx, frame.cy, 1.0, 1.0]
            self.live[source_id] = state
        return state

    def push_framing(self, source_id: str, frame: Frame) -> None:
        shader = self.shaders.get(source_id)
        if shader is None:
            return
        source = self.find_source(source_id)
        if source is None:
            return
        state = self.live_state(source_id, frame)
        dynamic = source.config.get("follow_mouse") or source_id in self.trackers
        cx = state[0] if dynamic else frame.cx
        cy = state[1] if dynamic else frame.cy
        zoom = frame.zoom * state[2]
        aspect = self.aspects.get(source_id, 16 / 9)
        item_aspect = max(frame.w, 1) / max(frame.h, 1)
        x, y, w, h = source_rect(aspect, item_aspect, zoom, cx, cy, frame.fit)
        r, g, b = color_rgb(frame.border_color)
        text = (
            f"uniforms, rx=(float){x}, ry=(float){y}, rw=(float){w}, rh=(float){h}, "
            f"ia=(float){item_aspect}, ih=(float){max(frame.h, 1)}, "
            f"radius=(float){frame.radius}, border=(float){frame.border}, "
            f"br=(float){r}, bg=(float){g}, bb=(float){b}"
        )
        structure = Gst.Structure.from_string(text)[0]
        shader.set_property("uniforms", structure)

    def find_source(self, source_id: str):
        for source in self.studio.sources:
            if source.id == source_id:
                return source
        return None

    def on_tick(self) -> bool:
        """30 Hz: transitions, mouse following, face tracking and the zoom animation."""
        if self.pipeline is None:
            return True
        if self.transition is not None:
            self.step_transition()
        for source_id, frame in self.frames.items():
            if frame.alpha <= 0 or source_id not in self.shaders:
                continue
            source = self.find_source(source_id)
            if source is None:
                continue
            state = self.live_state(source_id, frame)
            state[2] = smooth(state[2], state[3], 0.15)
            if source.kind == "screen" and source.config.get("follow_mouse"):
                self.follow_mouse(source, frame, state)
            elif source_id in self.trackers:
                self.follow_face(source, frame, state)
            self.push_framing(source_id, frame)
        return True

    def visible_window(self, source_id: str, frame: Frame, zoom: float) -> tuple[float, float]:
        aspect = self.aspects.get(source_id, 16 / 9)
        item_aspect = max(frame.w, 1) / max(frame.h, 1)
        _, _, w, h = source_rect(aspect, item_aspect, zoom, 0.5, 0.5, frame.fit)
        return w, h

    def follow_mouse(self, source, frame: Frame, state: list[float]) -> None:
        position = self.pointer.position()
        monitor = self.screens.get(source.id)
        if position is None or monitor is None:
            return
        px = (position[0] - monitor["x"]) / monitor["w"]
        py = (position[1] - monitor["y"]) / monitor["h"]
        w, h = self.visible_window(source.id, frame, frame.zoom * state[2])
        dead_zone = float(source.config.get("dead_zone", 0.5))
        state[0] = smooth(state[0], follow_target(state[0], px, w, dead_zone), 0.18)
        state[1] = smooth(state[1], follow_target(state[1], py, h, dead_zone), 0.18)

    def follow_face(self, source, frame: Frame, state: list[float]) -> None:
        found = self.trackers[source.id].current()
        if found is None:
            return
        fx, fy, height = found
        state[0] = smooth(state[0], fx, 0.08)
        state[1] = smooth(state[1], fy, 0.08)
        if source.config.get("auto_zoom"):
            # face around 45% of the visible height
            _, base_h = self.visible_window(source.id, frame, frame.zoom)
            state[3] = max(1.0, min(4.0, 0.45 * base_h / max(height, 0.05)))

    def zoom(self, source_id: str, action: str) -> None:
        source = self.studio.source(source_id)
        frame = self.frames.get(source_id)
        if frame is None:
            raise RuntimeError(f"{source.name} is not on the canvas")
        state = self.live_state(source_id, frame)
        if action == "in":
            state[3] = min(4.0, state[3] * 1.5)
        elif action == "out":
            state[3] = max(1.0, state[3] / 1.5)
        else:
            state[3] = 1.0

    def zoom_screens(self, action: str) -> None:
        for source in self.studio.sources:
            if source.kind == "screen" and source.id in self.frames:
                self.zoom(source.id, action)

    def activate_scene(self, scene_id: str, kind: str = "fade", ms: int = 400) -> None:
        scene = self.studio.scene(scene_id)
        self.studio.current_scene = scene_id
        self.save()
        end = targets(self.studio, scene)
        if kind == "cut" or ms <= 0:
            self.transition = None
            self.apply(end)
            return
        self.transition = {"start": dict(self.frames), "end": end, "kind": kind, "ms": ms,
                           "since": time.monotonic()}

    def step_transition(self) -> None:
        transition = self.transition
        t = (time.monotonic() - transition["since"]) * 1000 / transition["ms"]
        frames = interpolate(transition["start"], transition["end"], t, transition["kind"],
                             self.studio.config.width)
        self.apply(frames)
        if t >= 1:
            self.transition = None

    def reapply_scene(self) -> None:
        self.transition = None
        self.apply(targets(self.studio, self.studio.current()))

    # ================================================================== live editing

    def update_source(self, source_id: str, name: str | None, config: dict | None) -> None:
        source = self.studio.source(source_id)
        if name:
            source.name = name
        if config:
            needs_rebuild = source.kind == "color" and "color" in config
            for key in config:
                if key not in LIVE_KEYS:
                    needs_rebuild = True
            source.config.update(config)
            if needs_rebuild or source_id in self.failures:
                self.require_stopped("to change the source device/file")
                self.failures.pop(source_id, None)
                self.build()
            else:
                self.update_live(source, config)
        self.save()

    def update_live(self, source, config: dict) -> None:
        overlay = self.texts.get(source.id)
        if overlay is not None:
            if "text" in config:
                overlay.set_property("text", str(config["text"]))
            if "font" in config:
                overlay.set_property("font-desc", str(config["font"]))
            if "color" in config:
                overlay.set_property("color", color_argb(config["color"]))
            if "shadow" in config:
                overlay.set_property("draw-shadow", bool(config["shadow"]))
        volume = self.volumes.get(source.id)
        if volume is not None:
            if "volume" in config:
                volume.set_property("volume", max(0.0, min(4.0, float(config["volume"]))))
            if "muted" in config:
                volume.set_property("mute", bool(config["muted"]))
        if "auto_zoom" in config and not config["auto_zoom"] and source.id in self.live:
            self.live[source.id][3] = 1.0

    def require_stopped(self, reason: str = "to change sources or the canvas") -> None:
        if self.recording:
            raise RuntimeError(f"stop the recording {reason}")

    def drawing(self, data: dict) -> dict:
        geometry = None
        screen = self.studio.first_of({"screen"})
        if screen is not None:
            geometry = self.screens.get(screen.id)
        if data.get("action") == "clear":
            self.overlay.clear()
        elif data.get("action") == "undo":
            self.overlay.undo()
        elif data.get("action") == "toggle":
            self.overlay.set_active(not self.overlay.active, geometry)
        self.overlay.configure(data, geometry)
        return self.overlay.state()

    # ================================================================== recording

    def encoder(self) -> tuple[list[Gst.Element], str]:
        config = self.studio.config
        order = [config.encoder]
        for name in ("nvh264", "x264"):
            if name != config.encoder:
                order.append(name)
        for name in order:
            if Gst.ElementFactory.find(FACTORIES[name]) is None:
                continue
            element = make(FACTORIES[name])
            element.set_property("bitrate", config.bitrate_kbps)
            if name == "x264":
                set_prop(element, "speed-preset", "veryfast")
                element.set_property("key-int-max", config.fps)
                return [element, make("h264parse")], name
            # one keyframe per second: precise cuts and fast scrubbing in the editor
            settings = (("rate-control", "vbr"), ("preset", "p5"), ("tune", "high-quality"),
                        ("gop-size", config.fps))
            for prop, value in settings:
                try:
                    set_prop(element, prop, value)
                except (TypeError, ValueError):
                    log.info("%s without %s=%s", FACTORIES[name], prop, value)
            parser = make("h265parse" if name == "nvh265" else "h264parse")
            return [element, parser], name
        raise RuntimeError("no video encoder available")

    def audio_branch(self, muxer: Gst.Element) -> list[Gst.Element]:
        queue = make("queue", max_size_time=2 * Gst.SECOND, max_size_buffers=0, max_size_bytes=0)
        convert = make("audioconvert")
        # lossless PCM: DaVinci Resolve on Linux does not decode AAC
        audio_caps = caps("audio/x-raw,format=S16LE,rate=48000,channels=2")
        for element in (queue, convert, audio_caps):
            self.pipeline.add(element)
        link_all([queue, convert, audio_caps, muxer])
        return [queue, convert, audio_caps]

    def start_recording(self) -> str:
        if self.recording:
            return self.recording["file"]
        if self.pipeline is None:
            raise RuntimeError("studio is off")
        folder = studio_dir()
        folder.mkdir(parents=True, exist_ok=True)
        file = str(folder / f"{datetime.now():%Y-%m-%d_%H%M%S}.mkv")
        (encoder, parser), name = self.encoder()
        video_queue = make("queue", max_size_time=2 * Gst.SECOND, max_size_buffers=0,
                           max_size_bytes=0)
        convert = make("videoconvert")
        nv12 = caps("video/x-raw,format=NV12")
        muxer = make("matroskamux")
        sink = make("filesink", location=file)
        elements = [video_queue, convert, nv12, encoder, parser, muxer, sink]
        for element in elements:
            self.pipeline.add(element)
        link_all([video_queue, convert, nv12, encoder, parser, muxer])
        link_all([muxer, sink])
        # tracks: mix first, then each audio source raw (clean voice for editing and Whisper)
        taps = [(self.tee_audio, "Mix")]
        for source in self.studio.sources:
            if source.id in self.raw_tees:
                taps.append((self.raw_tees[source.id], source.name))
        links = [(self.tee_video, video_queue)]
        names = []
        for tee, track_name in taps:
            branch = self.audio_branch(muxer)
            elements += branch
            links.append((tee, branch[0]))
            names.append(track_name)
        for element in elements:
            element.sync_state_with_parent()
        pads = []
        for tee, queue in links:
            pad = tee.request_pad_simple("src_%u")
            pad.link(queue.get_static_pad("sink"))
            pads.append((tee, pad, queue))
        self.encoder_used = name
        self.recording = {"file": file, "since": time.monotonic(), "elements": elements,
                          "pads": pads, "sink": sink, "stopping": False, "tracks": names,
                          "encoder": name}
        return file

    def stop_recording(self) -> str | None:
        recording = self.recording
        if not recording:
            return None
        if recording["stopping"]:
            return recording["file"]
        recording["stopping"] = True
        sink_pad = recording["sink"].get_static_pad("sink")
        sink_pad.add_probe(Gst.PadProbeType.EVENT_DOWNSTREAM,
                           functools.partial(self.on_sink_event, recording))
        for tee, pad, queue in recording["pads"]:
            pad.add_probe(Gst.PadProbeType.IDLE, functools.partial(self.on_tee_idle, tee, queue))
        return recording["file"]

    def on_tee_idle(self, tee: Gst.Element, queue: Gst.Element, pad: Gst.Pad, _info):
        target = queue.get_static_pad("sink")
        pad.unlink(target)
        tee.release_request_pad(pad)
        target.send_event(Gst.Event.new_eos())
        return Gst.PadProbeReturn.REMOVE

    def on_sink_event(self, recording: dict, _pad, info):
        if info.get_event().type == Gst.EventType.EOS:
            GLib.idle_add(self.finish_recording, recording)
            return Gst.PadProbeReturn.DROP
        return Gst.PadProbeReturn.OK

    def finish_recording(self, recording: dict) -> bool:
        for element in recording["elements"]:
            element.set_state(Gst.State.NULL)
            if self.pipeline is not None:
                self.pipeline.remove(element)
        entry = {"file": recording["file"], "seconds": round(time.monotonic() - recording["since"]),
                 "tracks": recording["tracks"], "ready": False}
        self.recordings.insert(0, entry)
        if self.recording is recording:
            self.recording = None
        thread = threading.Thread(target=self.remux, args=(entry, recording["encoder"]),
                                  daemon=True)
        thread.start()
        return False

    def remux(self, entry: dict, encoder: str) -> None:
        """MKV (crash-safe) -> MOV for the editors, copying every track; the MKV goes away only if
        the MOV came out whole."""
        mkv = Path(entry["file"])
        if not self.studio.config.remux_mov:
            entry["ready"] = True
            return
        mov = mkv.with_suffix(".mov")
        command = ["ffmpeg", "-y", "-loglevel", "error", "-i", str(mkv), "-map", "0", "-c", "copy"]
        if encoder == "nvh265":
            command += ["-tag:v", "hvc1"]
        for index, title in enumerate(entry["tracks"]):
            # MOV shows the track name from handler_name; MKV/others read title
            command += [f"-metadata:s:a:{index}", f"title={title}",
                        f"-metadata:s:a:{index}", f"handler_name={title}"]
        command.append(str(mov))
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode == 0 and mov.exists() and mov.stat().st_size > 0:
            mkv.unlink(missing_ok=True)
            entry["file"] = str(mov)
        else:
            log.warning("remux failed, keeping the MKV: %s", result.stderr.strip()[-300:])
        entry["ready"] = True

    # ================================================================== state

    def save(self) -> None:
        self.studio.save(self.path)

    def state(self) -> dict:
        recording = self.recording
        levels = {}
        for key, value in self.levels.items():
            levels[key] = round(value, 1)
        has_phone = self.studio.first_of({"phone"}) is not None
        return {
            "running": self.pipeline is not None,
            "error": self.error,
            "failures": self.failures,
            "recording": recording is not None,
            "stopping": bool(recording and recording["stopping"]),
            "file": recording["file"] if recording else None,
            "seconds": round(time.monotonic() - recording["since"]) if recording else 0,
            "encoder": self.encoder_used,
            "fps": round(self.measured_fps(), 1),
            "levels": levels,
            "recordings": self.recordings[:20],
            "preview_port": PREVIEW_PORT,
            "studio": self.studio.to_json(),
            "drawing": self.overlay.state(),
            "face_tracking": face.available(),
            "udp_warning": has_phone and devices.rmem_max() < 8 * 1024 * 1024,
        }
