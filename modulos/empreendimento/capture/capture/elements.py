"""GStreamer helpers: element creation, links and the framing/mask shader."""

from __future__ import annotations

import gi

gi.require_version("Gst", "1.0")
from gi.repository import GObject, Gst  # noqa: E402

Gst.init(None)

# Framing + mask for one source. The output buffer has the canvas size and the compositor squeezes
# it into the item size, so the sampled rectangle keeps the ITEM aspect (no distortion) and the
# mask is computed in item units: `ia` = item width/height, `ih` = item height in pixels.
FRAMING_SHADER = """
#version 100
#ifdef GL_ES
precision highp float;
#endif
varying vec2 v_texcoord;
uniform sampler2D tex;
uniform float rx;
uniform float ry;
uniform float rw;
uniform float rh;
uniform float ia;
uniform float ih;
uniform float radius;
uniform float border;
uniform float br;
uniform float bg;
uniform float bb;

void main () {
  vec2 uv = v_texcoord;
  vec2 src = vec2(rx + uv.x * rw, ry + uv.y * rh);
  vec4 color = texture2D(tex, clamp(src, 0.0, 1.0));
  float inside = step(0.0, src.x) * step(src.x, 1.0) * step(0.0, src.y) * step(src.y, 1.0);
  vec2 p = (uv - 0.5) * vec2(ia, 1.0);
  float r = min(radius / ih, 0.5 * min(ia, 1.0));
  vec2 q = abs(p) - vec2(ia * 0.5, 0.5) + r;
  float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
  float px = 1.0 / ih;
  float shape = 1.0 - smoothstep(-px, px, d);
  float b = border / ih;
  if (b > 0.0) {
    float core = 1.0 - smoothstep(-px, px, d + b);
    color = mix(vec4(br, bg, bb, 1.0), vec4(color.rgb, color.a * inside), core);
    inside = 1.0;
  }
  gl_FragColor = vec4(color.rgb, color.a * inside * shape);
}
"""


def make(factory: str, name: str | None = None, **props) -> Gst.Element:
    element = Gst.ElementFactory.make(factory, name)
    if element is None:
        raise RuntimeError(f"missing GStreamer element: {factory}")
    for key, value in props.items():
        set_prop(element, key.rstrip("_").replace("_", "-"), value)
    return element


def make_live(factory: str, name: str, **props) -> Gst.Element:
    """Aggregator (compositor/audiomixer) that always runs in live mode and aggregates on timeout.

    Without force-live a failed latency query (a source still negotiating, e.g. the GL upload)
    makes it wait for data on every pad forever, which froze the studio.
    """
    value = GObject.Value(GObject.TYPE_BOOLEAN, True)
    element = Gst.ElementFactory.find(factory).create_with_properties(["force-live"], [value])
    if element is None:
        raise RuntimeError(f"missing GStreamer element: {factory}")
    element.set_property("name", name)
    for key, prop_value in props.items():
        set_prop(element, key.rstrip("_").replace("_", "-"), prop_value)
    return element


def set_prop(element: Gst.Element, prop: str, value) -> None:
    # strings go through the GStreamer parser (accepts enums by nick: "vbr", "zerolatency"...)
    if isinstance(value, str):
        Gst.util_set_object_arg(element, prop, value)
    else:
        element.set_property(prop, value)


def caps(text: str) -> Gst.Element:
    return make("capsfilter", caps=Gst.Caps.from_string(text))


def link_all(elements: list[Gst.Element]) -> None:
    for index in range(len(elements) - 1):
        a = elements[index]
        b = elements[index + 1]
        if not a.link(b):
            raise RuntimeError(f"could not link {a.get_name()} -> {b.get_name()}")


def color_argb(text, default: int = 0xFFFFFFFF) -> int:
    """'#RRGGBB' or '#AARRGGBB' -> ARGB integer."""
    if isinstance(text, int):
        return text
    hex_text = str(text or "").lstrip("#")
    try:
        if len(hex_text) == 6:
            return 0xFF000000 | int(hex_text, 16)
        if len(hex_text) == 8:
            return int(hex_text, 16)
    except ValueError:
        pass
    return default


def color_rgb(text) -> tuple[float, float, float]:
    value = color_argb(text)
    return ((value >> 16) & 0xFF) / 255, ((value >> 8) & 0xFF) / 255, (value & 0xFF) / 255


class DynamicLink:
    """Links the first pad of the wanted kind (decodebin & co.) when it shows up."""

    def __init__(self, origin: Gst.Element, target: Gst.Element, kind: str = "video/"):
        self.target = target
        self.kind = kind
        origin.connect("pad-added", self.on_pad)

    def on_pad(self, _element, pad: Gst.Pad) -> None:
        sink = self.target.get_static_pad("sink")
        current = pad.get_current_caps() or pad.query_caps(None)
        if sink.is_linked() or not current.to_string().startswith(self.kind):
            return
        pad.link(sink)


class AspectWatch:
    """Stores the source aspect (w/h with pixel aspect) when caps reach a pad."""

    def __init__(self, pad: Gst.Pad, store: dict, key: str):
        self.store = store
        self.key = key
        pad.add_probe(Gst.PadProbeType.EVENT_DOWNSTREAM, self.on_event)

    def on_event(self, _pad, info):
        event = info.get_event()
        if event.type != Gst.EventType.CAPS:
            return Gst.PadProbeReturn.OK
        structure = event.parse_caps().get_structure(0)
        ok_w, width = structure.get_int("width")
        ok_h, height = structure.get_int("height")
        if ok_w and ok_h and height > 0:
            aspect = width / height
            ok_par, num, den = structure.get_fraction("pixel-aspect-ratio")
            if ok_par and den > 0:
                aspect *= num / den
            self.store[self.key] = aspect
        return Gst.PadProbeReturn.OK
