import 'dart:math';
import 'dart:ui';

import '../models.dart';

/// Notebook smart pen (as in Samsung Notes): when the pen lifts, a stroke that is
/// clearly a line becomes an aligned line (horizontal, vertical, 45° or parallel to a recent line)
/// and a closed outline becomes a neat rectangle, square, triangle, ellipse or circle.
/// Writing does not change: only a stroke longer than ~2 ruling lines ([unit]) that fits the figure well
/// goes in; letters, words and scribbles stay as they were written.
class SmartPen {
  SmartPen({this.connected = true});

  bool connected;

  /// Angles (radians, 0–π) of the last lines, to align the next one in parallel.
  final List<double> _angles = [];

  Elemento? fit(Traco t, {double unit = 28}) {
    if (!connected) return null;
    final r = recognize(t, unit: unit, angles: _angles);
    if (r != null && r.reta) {
      _angles.add(r.angle);
      if (_angles.length > 12) _angles.removeAt(0);
    }
    return r?.stroke;
  }
}

/// What the pen recognized: the new stroke (same id, brush, color and thickness) and, if it is a line, the angle.
typedef Recognized = ({Traco stroke, bool reta, double angle, String figure});

const _degree = pi / 180;

Recognized? recognize(Traco t, {double unit = 28, List<double> angles = const []}) {
  final pts = [for (final p in t.pontos) p.offset];
  if (pts.length < 3) return null;
  var lengthOf = 0.0;
  for (var i = 1; i < pts.length; i++) {
    lengthOf += (pts[i] - pts[i - 1]).distance;
  }
  final box = _box(pts);
  final diagonal = box.size.longestSide;
  final minimum = max(44.0, unit * 1.8);
  final pressure = _median([for (final p in t.pontos) p.p]);
  Traco isNew(List<Offset> outline) => Traco(
    t.id,
    group: t.group,
    brush: t.brush,
    color: t.color,
    thickness: t.thickness,
    pontos: [for (final p in _densify(outline)) StrokePoint(p.dx, p.dy, pressure)],
  );

  // Line: the tips far apart and the whole stroke close to the chord.
  final a = pts.first, b = pts.last, chord = (b - a).distance;
  if (chord >= minimum && lengthOf <= chord * 1.12) {
    final deviation = pts.map((p) => _lineDistance(p, a, b)).reduce(max);
    if (deviation <= max(4.0, chord * 0.05)) {
      final angle = _align((b - a).direction, angles);
      final middle = (a + b) / 2, d = Offset.fromDirection(angle, chord / 2);
      return (stroke: isNew([middle - d, middle + d]), reta: true, angle: angle % pi, figure: 'reta');
    }
  }

  // Closed figures: the tips meet (or the stroke goes past the start) and the figure is large.
  if (diagonal < minimum || chord > max(18.0, lengthOf * 0.14) || t.brush == Pincel.marcador) return null;

  final c = box.center, rx = box.width / 2, ry = box.height / 2;
  if (rx > 4 && ry > 4) {
    final error = _media([for (final p in pts) (sqrt(pow((p.dx - c.dx) / rx, 2) + pow((p.dy - c.dy) / ry, 2)) - 1).abs()]);
    if (error < 0.09) {
      final circulo = (rx / ry - 1).abs() < 0.15;
      final radiusX = circulo ? (rx + ry) / 2 : rx, radiusY = circulo ? (rx + ry) / 2 : ry;
      final outline = [
        for (var i = 0; i <= 72; i++) c + Offset(cos(i * 5 * _degree) * radiusX, sin(i * 5 * _degree) * radiusY),
      ];
      return (stroke: isNew(outline), reta: false, angle: 0, figure: circulo ? 'circulo' : 'elipse');
    }
  }

  final vertices = _cantos(pts, diagonal * 0.08);
  if (vertices.length != 3 && vertices.length != 4) return null;
  // The stroke must stay near the polygon sides (otherwise it was a curve).
  final closed = [...vertices, vertices.first];
  final slack = _media([for (final p in pts) _outlineDistance(p, closed)]);
  if (slack > diagonal * 0.035) return null;

  if (vertices.length == 3) {
    return (stroke: isNew(closed), reta: false, angle: 0, figure: 'triangulo');
  }
  // Four corners with angles near 90°: rectangle; near the axis, it stays straight; otherwise, rotated.
  for (var i = 0; i < 4; i++) {
    final u = vertices[(i + 1) % 4] - vertices[i], v = vertices[(i + 3) % 4] - vertices[i];
    final ang = acos(((u.dx * v.dx + u.dy * v.dy) / (u.distance * v.distance)).clamp(-1.0, 1.0));
    if ((ang - pi / 2).abs() > 20 * _degree) return null;
  }
  final side = vertices[1] - vertices[0];
  var rotation = side.direction;
  final straight = ((rotation / (pi / 2)).round() * (pi / 2) - rotation).abs() < 10 * _degree;
  if (straight) rotation = 0;
  // Rectangle in the rotated coordinates (box of the corners), then back.
  Offset rotate(Offset p, double g) => Offset(p.dx * cos(g) - p.dy * sin(g), p.dx * sin(g) + p.dy * cos(g));
  final localItems = [for (final p in vertices) rotate(p - c, -rotation)];
  var localBox = _box(localItems);
  final quadrado = (localBox.width / localBox.height - 1).abs() < 0.12;
  if (quadrado) {
    final l = (localBox.width + localBox.height) / 2;
    localBox = Rect.fromCenter(center: localBox.center, width: l, height: l);
  }
  final cantos = [
    localBox.topLeft,
    localBox.topRight,
    localBox.bottomRight,
    localBox.bottomLeft,
    localBox.topLeft,
  ].map((p) => rotate(p, rotation) + c).toList();
  return (stroke: isNew(cantos), reta: false, angle: 0, figure: quadrado ? 'quadrado' : 'retangulo');
}

/// Snaps to 0°/90° (8°), 45° (5°) or parallel to a recent line (5°).
double _align(double angle, List<double> recent) {
  double near(double target) {
    final d = (angle - target) % pi;
    return min(d, pi - d);
  }

  for (final target in [0.0, pi / 2]) {
    if (near(target) < 8 * _degree) return _fit(angle, target);
  }
  for (final target in [pi / 4, 3 * pi / 4]) {
    if (near(target) < 5 * _degree) return _fit(angle, target);
  }
  for (final target in recent.reversed) {
    if (near(target) < 5 * _degree) return _fit(angle, target);
  }
  return angle;
}

/// The [target] angle (mod π) in the direction the line was drawn.
double _fit(double angle, double target) {
  final candidates = [target, target + pi, target - pi, target - 2 * pi, target + 2 * pi];
  return candidates.reduce((x, y) => (x - angle).abs() <= (y - angle).abs() ? x : y);
}

/// Corners of the closed outline: Ramer–Douglas–Peucker from the point farthest from the start,
/// juntando cantos quase alinhados.
List<Offset> _cantos(List<Offset> pts, double eps) {
  var far = 0;
  for (var i = 1; i < pts.length; i++) {
    if ((pts[i] - pts.first).distance > (pts[far] - pts.first).distance) far = i;
  }
  final ida = _rdp(pts.sublist(0, far + 1), eps), volta = _rdp([...pts.sublist(far), pts.first], eps);
  var v = [...ida, ...volta.sublist(1, volta.length - 1)];
  var changed = true;
  while (changed && v.length > 3) {
    changed = false;
    for (var i = 0; i < v.length; i++) {
      final ant = v[(i - 1 + v.length) % v.length], next = v[(i + 1) % v.length];
      if (_lineDistance(v[i], ant, next) < eps || (v[i] - ant).distance < eps) {
        v = [...v]..removeAt(i);
        changed = true;
        break;
      }
    }
  }
  return v;
}

List<Offset> _rdp(List<Offset> pts, double eps) {
  if (pts.length < 3) return pts;
  var larger = 0.0, score = 0;
  for (var i = 1; i < pts.length - 1; i++) {
    final d = _lineDistance(pts[i], pts.first, pts.last);
    if (d > larger) (larger, score) = (d, i);
  }
  if (larger <= eps) return [pts.first, pts.last];
  final esquerda = _rdp(pts.sublist(0, score + 1), eps);
  return [...esquerda.sublist(0, esquerda.length - 1), ..._rdp(pts.sublist(score), eps)];
}

double _lineDistance(Offset p, Offset a, Offset b) {
  final ab = b - a, l = ab.distance;
  if (l == 0) return (p - a).distance;
  return ((p.dx - a.dx) * ab.dy - (p.dy - a.dy) * ab.dx).abs() / l;
}

double _segmentDistance(Offset p, Offset a, Offset b) {
  final ab = b - a, l2 = ab.distanceSquared;
  if (l2 == 0) return (p - a).distance;
  final t = (((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / l2).clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

double _outlineDistance(Offset p, List<Offset> outline) {
  var d = double.infinity;
  for (var i = 1; i < outline.length; i++) {
    d = min(d, _segmentDistance(p, outline[i - 1], outline[i]));
  }
  return d;
}

/// Points every ~4 px along the sides: the eraser and the lasso keep finding the stroke through the middle.
List<Offset> _densify(List<Offset> outline) {
  final exit = <Offset>[outline.first];
  for (var i = 1; i < outline.length; i++) {
    final a = outline[i - 1], b = outline[i];
    final n = max(1, ((b - a).distance / 4).ceil());
    for (var k = 1; k <= n; k++) {
      exit.add(Offset.lerp(a, b, k / n)!);
    }
  }
  return exit;
}

Rect _box(List<Offset> pts) {
  var r = Rect.fromPoints(pts.first, pts.first);
  for (final p in pts) {
    r = r.expandToInclude(Rect.fromPoints(p, p));
  }
  return r;
}

double _media(List<double> v) => v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;

double _median(List<double> v) {
  final o = [...v]..sort();
  return o[o.length ~/ 2];
}
