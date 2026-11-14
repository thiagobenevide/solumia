"""On-screen drawing for the recording (pen tablet or mouse), like Epic Pen / Gromit.

A transparent always-on-top window covers the captured monitor; the screen capture records what is
drawn on it. Inactive, the window lets clicks through (empty input shape) and keeps the strokes
until they fade. Active, it takes the pen: pressure changes the width.

Keys while active: 1 pen, 2 highlighter, 3 arrow, 4 rectangle, 5 ellipse, 6 laser, X next color,
Z undo, Delete/C clear, Esc leave drawing mode.
"""

from __future__ import annotations

import logging
import math
import time

log = logging.getLogger("capture")

TOOLS = ("pen", "highlighter", "arrow", "rectangle", "ellipse", "laser")
COLORS = ("#FF3B30", "#FFCC00", "#34C759", "#0A84FF", "#FFFFFF", "#000000")
LASER_SECONDS = 0.9
SHAPE_TOOLS = ("arrow", "rectangle", "ellipse")
TOOL_KEYS = {"1": "pen", "2": "highlighter", "3": "arrow", "4": "rectangle", "5": "ellipse",
             "6": "laser"}


def hex_rgb(text: str) -> tuple[float, float, float]:
    value = str(text).lstrip("#")
    if len(value) != 6:
        return 1.0, 0.23, 0.19
    return int(value[0:2], 16) / 255, int(value[2:4], 16) / 255, int(value[4:6], 16) / 255


class Stroke:
    def __init__(self, tool: str, color: str, size: float):
        self.tool = tool
        self.color = color
        self.size = size
        self.points: list[tuple[float, float, float]] = []
        self.done_at: float | None = None

    def opacity(self, now: float, fade: float) -> float:
        if self.done_at is None:
            return 1.0
        life = fade
        if self.tool == "laser":
            life = LASER_SECONDS
        if life <= 0:
            return 1.0
        return max(0.0, 1.0 - (now - self.done_at) / life)


class DrawingOverlay:
    def __init__(self) -> None:
        self.window = None
        self.area = None
        self.ready = False
        self.active = False
        self.tool = "pen"
        self.color = COLORS[0]
        self.size = 6.0
        self.fade = 0.0  # seconds; 0 keeps the strokes until cleared
        self.strokes: list[Stroke] = []
        self.current: Stroke | None = None
        self.timer = None
        self.geometry: dict | None = None
        try:
            import gi

            gi.require_version("Gtk", "3.0")
            gi.require_version("Gdk", "3.0")
            from gi.repository import Gdk, GLib, Gtk

            self.Gdk = Gdk
            self.GLib = GLib
            self.Gtk = Gtk
            self.ready = Gtk.init_check(None)[0]
        except (ImportError, ValueError) as error:
            log.warning("drawing overlay unavailable: %s", error)

    # ------------------------------------------------------------------ public

    def state(self) -> dict:
        return {"available": self.ready, "active": self.active, "tool": self.tool,
                "color": self.color, "size": self.size, "fade": self.fade,
                "strokes": len(self.strokes)}

    def configure(self, data: dict, geometry: dict | None) -> None:
        if data.get("tool") in TOOLS:
            self.tool = data["tool"]
        if "color" in data:
            self.color = str(data["color"])
        if "size" in data:
            self.size = max(1.0, min(60.0, float(data["size"])))
        if "fade" in data:
            self.fade = max(0.0, min(30.0, float(data["fade"])))
        if "active" in data:
            self.set_active(bool(data["active"]), geometry)

    def set_active(self, active: bool, geometry: dict | None) -> None:
        if not self.ready:
            raise RuntimeError("drawing needs a graphical session (GTK)")
        self.ensure_window(geometry)
        self.active = active
        if active:
            self.window.input_shape_combine_region(None)
            self.window.show_all()
            self.window.present()
            self.set_cursor("crosshair")
        else:
            import cairo

            self.window.input_shape_combine_region(cairo.Region())
            self.set_cursor(None)
            self.hide_if_empty()
        self.redraw()

    def clear(self) -> None:
        self.strokes = []
        self.current = None
        self.redraw()
        self.hide_if_empty()

    def undo(self) -> None:
        if self.strokes:
            self.strokes.pop()
        self.redraw()
        self.hide_if_empty()

    # ------------------------------------------------------------------ window

    def ensure_window(self, geometry: dict | None) -> None:
        if self.window is not None and geometry == self.geometry:
            return
        if self.window is not None:
            self.window.destroy()
        Gtk = self.Gtk
        Gdk = self.Gdk
        window = Gtk.Window(type=Gtk.WindowType.TOPLEVEL)
        window.set_title("Solumia drawing")
        window.set_decorated(False)
        window.set_keep_above(True)
        window.set_skip_taskbar_hint(True)
        window.set_skip_pager_hint(True)
        window.set_app_paintable(True)
        visual = window.get_screen().get_rgba_visual()
        if visual is not None:
            window.set_visual(visual)
        if geometry:
            window.move(geometry["x"], geometry["y"])
            window.resize(geometry["w"], geometry["h"])
        else:
            window.fullscreen()
        area = Gtk.DrawingArea()
        area.set_events(
            Gdk.EventMask.BUTTON_PRESS_MASK | Gdk.EventMask.BUTTON_RELEASE_MASK
            | Gdk.EventMask.POINTER_MOTION_MASK | Gdk.EventMask.KEY_PRESS_MASK
        )
        area.connect("draw", self.on_draw)
        area.connect("button-press-event", self.on_press)
        area.connect("motion-notify-event", self.on_motion)
        area.connect("button-release-event", self.on_release)
        window.connect("key-press-event", self.on_key)
        window.add(area)
        self.window = window
        self.area = area
        self.geometry = geometry

    def set_cursor(self, name: str | None) -> None:
        gdk_window = self.window.get_window() if self.window is not None else None
        if gdk_window is None:
            return
        cursor = None
        if name:
            cursor = self.Gdk.Cursor.new_from_name(gdk_window.get_display(), name)
        gdk_window.set_cursor(cursor)

    def hide_if_empty(self) -> None:
        if self.window is not None and not self.active and not self.strokes:
            self.window.hide()

    def redraw(self) -> None:
        if self.area is not None:
            self.area.queue_draw()
        self.ensure_timer()

    def ensure_timer(self) -> None:
        if self.timer is None and self.needs_animation():
            self.timer = self.GLib.timeout_add(33, self.on_timer)

    def needs_animation(self) -> bool:
        for stroke in self.strokes:
            if stroke.done_at is not None and (self.fade > 0 or stroke.tool == "laser"):
                return True
        return False

    def on_timer(self) -> bool:
        now = time.monotonic()
        kept = []
        for stroke in self.strokes:
            if stroke.opacity(now, self.fade) > 0:
                kept.append(stroke)
        self.strokes = kept
        if self.area is not None:
            self.area.queue_draw()
        if not self.needs_animation():
            self.timer = None
            self.hide_if_empty()
            return False
        return True

    # ------------------------------------------------------------------ input

    def pressure(self, event) -> float:
        ok, value = event.get_axis(self.Gdk.AxisUse.PRESSURE)
        if ok and value > 0:
            return value
        return 0.6

    def on_press(self, _area, event) -> bool:
        if not self.active or event.button != 1:
            return False
        self.current = Stroke(self.tool, self.color, self.size)
        self.current.points.append((event.x, event.y, self.pressure(event)))
        self.strokes.append(self.current)
        return True

    def on_motion(self, _area, event) -> bool:
        if self.current is None:
            return False
        point = (event.x, event.y, self.pressure(event))
        if self.current.tool in SHAPE_TOOLS and len(self.current.points) > 1:
            self.current.points[-1] = point
        else:
            self.current.points.append(point)
        self.area.queue_draw()
        return True

    def on_release(self, _area, _event) -> bool:
        if self.current is None:
            return False
        self.current.done_at = time.monotonic()
        self.current = None
        self.redraw()
        return True

    def on_key(self, _window, event) -> bool:
        name = self.Gdk.keyval_name(event.keyval) or ""
        lower = name.lower()
        if name == "Escape":
            self.set_active(False, self.geometry)
        elif name in TOOL_KEYS:
            self.tool = TOOL_KEYS[name]
        elif lower == "x":
            index = COLORS.index(self.color) if self.color in COLORS else -1
            self.color = COLORS[(index + 1) % len(COLORS)]
        elif lower == "z":
            self.undo()
        elif name == "Delete" or lower == "c":
            self.clear()
        else:
            return False
        return True

    # ------------------------------------------------------------------ painting

    def on_draw(self, _area, context) -> bool:
        import cairo

        context.set_operator(cairo.OPERATOR_SOURCE)
        context.set_source_rgba(0, 0, 0, 0)
        context.paint()
        context.set_operator(cairo.OPERATOR_OVER)
        context.set_line_cap(cairo.LINE_CAP_ROUND)
        context.set_line_join(cairo.LINE_JOIN_ROUND)
        now = time.monotonic()
        for stroke in self.strokes:
            alpha = stroke.opacity(now, self.fade)
            if alpha > 0 and stroke.points:
                self.paint_stroke(context, stroke, alpha)
        return True

    def paint_stroke(self, context, stroke: Stroke, alpha: float) -> None:
        r, g, b = hex_rgb(stroke.color)
        if stroke.tool == "highlighter":
            context.set_source_rgba(r, g, b, 0.35 * alpha)
        else:
            context.set_source_rgba(r, g, b, alpha)
        if stroke.tool in SHAPE_TOOLS:
            self.paint_shape(context, stroke)
        elif stroke.tool == "highlighter":
            self.paint_polyline(context, stroke, stroke.size * 3)
        elif stroke.tool == "laser":
            self.paint_polyline(context, stroke, stroke.size * 1.4)
        else:
            self.paint_pen(context, stroke)

    def paint_polyline(self, context, stroke: Stroke, width: float) -> None:
        context.set_line_width(width)
        first = stroke.points[0]
        context.move_to(first[0], first[1])
        for x, y, _p in stroke.points[1:]:
            context.line_to(x, y)
        if len(stroke.points) == 1:
            context.line_to(first[0] + 0.1, first[1])
        context.stroke()

    def paint_pen(self, context, stroke: Stroke) -> None:
        # segment by segment: the pen pressure changes the width along the stroke
        points = stroke.points
        if len(points) == 1:
            self.paint_polyline(context, stroke, stroke.size * points[0][2] * 1.6)
            return
        for index in range(1, len(points)):
            x0, y0, p0 = points[index - 1]
            x1, y1, p1 = points[index]
            context.set_line_width(max(1.0, stroke.size * (p0 + p1) * 0.8))
            context.move_to(x0, y0)
            context.line_to(x1, y1)
            context.stroke()

    def paint_shape(self, context, stroke: Stroke) -> None:
        x0, y0, _ = stroke.points[0]
        x1, y1, _ = stroke.points[-1]
        context.set_line_width(stroke.size)
        if stroke.tool == "rectangle":
            context.rectangle(min(x0, x1), min(y0, y1), abs(x1 - x0), abs(y1 - y0))
            context.stroke()
        elif stroke.tool == "ellipse":
            self.paint_ellipse(context, x0, y0, x1, y1)
        else:
            self.paint_arrow(context, stroke, x0, y0, x1, y1)

    def paint_ellipse(self, context, x0: float, y0: float, x1: float, y1: float) -> None:
        w = max(abs(x1 - x0), 1.0)
        h = max(abs(y1 - y0), 1.0)
        context.save()
        context.translate((x0 + x1) / 2, (y0 + y1) / 2)
        context.scale(w / 2, h / 2)
        context.arc(0, 0, 1, 0, 2 * math.pi)
        context.restore()
        context.stroke()

    def paint_arrow(self, context, stroke: Stroke, x0: float, y0: float, x1: float,
                    y1: float) -> None:
        context.move_to(x0, y0)
        context.line_to(x1, y1)
        context.stroke()
        angle = math.atan2(y1 - y0, x1 - x0)
        head = max(stroke.size * 4, 18)
        context.move_to(x1, y1)
        context.line_to(x1 - head * math.cos(angle - 0.45), y1 - head * math.sin(angle - 0.45))
        context.line_to(x1 - head * math.cos(angle + 0.45), y1 - head * math.sin(angle + 0.45))
        context.close_path()
        context.fill()
