import 'dart:math';
import 'dart:ui';

import '../models.dart';

/// Angles (degrees) a line "snaps" to when it passes near: horizontal, vertical and diagonals.
const _angleStep = 45.0;
const _angleTolerance = 5.0;

/// Turns the stroke into a line from the first to the last point, aligning to 0°/45°/90°… when the
/// angle is less than 5° from them. The pressure becomes the average, so the line has a uniform width.
List<InkPoint> straighten(List<InkPoint> points) {
  if (points.length < 2) return points;
  final a = points.first.offset;
  var b = points.last.offset;
  final d = b - a;
  final degrees = d.direction * 180 / pi;
  final target = (degrees / _angleStep).round() * _angleStep;
  if ((degrees - target).abs() < _angleTolerance) {
    final rad = target * pi / 180;
    b = a + Offset(cos(rad), sin(rad)) * d.distance;
  }
  final p = points.map((e) => e.p).reduce((x, y) => x + y) / points.length;
  return [InkPoint(a.dx, a.dy, p), InkPoint(b.dx, b.dy, p)];
}

/// Distance from point [p] to segment [a]–[b].
double distanceToSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final lengthSquared = ab.dx * ab.dx + ab.dy * ab.dy;
  if (lengthSquared == 0) return (p - a).distance;
  final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / lengthSquared).clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

/// Does point [p], with an eraser of radius [radius], touch the stroke?
bool touchesStroke(InkStroke t, Offset p, double radius) {
  if (!t.bounds.inflate(radius).contains(p)) return false;
  final reach = radius + t.thickness / 2;
  if (t.points.length == 1) return (t.points.first.offset - p).distance <= reach;
  for (var i = 1; i < t.points.length; i++) {
    if (distanceToSegment(p, t.points[i - 1].offset, t.points[i].offset) <= reach) return true;
  }
  return false;
}

/// Index of the character nearest to [p]: the one containing the point or, if none, the one with the smallest
/// distance (giving more weight to the vertical distance, so it does not jump lines).
int? nearestChar(List<Rect> chars, Offset p) {
  int? best;
  var smaller = double.infinity;
  for (var i = 0; i < chars.length; i++) {
    final r = chars[i];
    if (r.isEmpty && r.width == 0) continue;
    if (r.contains(p)) return i;
    final dx = p.dx < r.left ? r.left - p.dx : (p.dx > r.right ? p.dx - r.right : 0.0);
    final dy = p.dy < r.top ? r.top - p.dy : (p.dy > r.bottom ? p.dy - r.bottom : 0.0);
    final d = dx * dx + 9 * dy * dy;
    if (d < smaller) {
      smaller = d;
      best = i;
    }
  }
  return best;
}

/// Rectangles of the excerpt [start]..[end] (inclusive), one per line: consecutive characters with the vertical
/// center inside the previous one's height stay on the same line.
List<Rect> excerptRects(List<Rect> chars, int start, int end) {
  final lines = <Rect>[];
  Rect? current;
  for (var i = start; i <= end && i < chars.length; i++) {
    final r = chars[i];
    if (r.width <= 0 || r.height <= 0) continue;
    if (current != null && (r.center.dy - current.center.dy).abs() < current.height * 0.6 && r.left >= current.left - 2) {
      current = current.expandToInclude(r);
    } else {
      if (current != null) lines.add(current);
      current = r;
    }
  }
  if (current != null) lines.add(current);
  return lines;
}
