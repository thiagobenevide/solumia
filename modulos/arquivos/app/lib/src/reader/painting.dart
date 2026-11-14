import 'dart:math';

import 'package:flutter/material.dart';

import '../models.dart';

/// Draws the elements of a page. Everything is in PDF points; [scale] converts to the screen.
void paintStroke(Canvas canvas, InkStroke t, double scale) {
  if (t.points.isEmpty) return;
  final points = [for (final p in t.points) p.offset * scale];
  final base = t.thickness * scale;
  switch (t.brush) {
    case Brush.marcador:
      // Flat, translucent, multiplied stroke: the text underneath stays readable.
      canvas.drawPath(
        _smoothPath(points),
        Paint()
          ..color = t.color.withValues(alpha: 0.38)
          ..blendMode = BlendMode.multiply
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.square
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = base,
      );
    case Brush.caneta || Brush.lapis || Brush.caligrafia:
      final widths = _smooth([for (var i = 0; i < points.length; i++) _width(t, i, base)]);
      if (points.length == 1) {
        canvas.drawCircle(points.first, widths.first / 2, Paint()..color = t.color);
        return;
      }
      // Translucent pencil in a layer: overlapping joints do not darken into dots.
      final lapis = t.brush == Brush.lapis;
      if (lapis) {
        final media = t.points.fold(0.0, (s, p) => s + p.p) / t.points.length;
        canvas.saveLayer(null, Paint()..color = Colors.black.withValues(alpha: 0.35 + 0.55 * media));
      }
      final ink = Paint()
        ..color = lapis ? t.color.withValues(alpha: 1) : t.color
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      final (curve, ls) = _denseCurve(points, widths);
      for (var i = 1; i < curve.length; i++) {
        ink.strokeWidth = ls[i];
        canvas.drawLine(curve[i - 1], curve[i], ink);
      }
      if (lapis) canvas.restore();
  }
}

/// Moving average of the widths: removes the point-to-point jaggedness of pressure and direction.
List<double> _smooth(List<double> v, {int radius = 2}) => [
  for (var i = 0; i < v.length; i++)
    () {
      final de = max(0, i - radius), ate = min(v.length - 1, i + radius);
      var s = 0.0;
      for (var j = de; j <= ate; j++) {
        s += v[j];
      }
      return s / (ate - de + 1);
    }(),
];

/// Catmull-Rom through the points, with a step every ~1.5 px: the curve passes through all the points
/// without the corners of straight lines, and the width varies gradually between them.
(List<Offset>, List<double>) _denseCurve(List<Offset> p, List<double> l) {
  final curve = <Offset>[p.first], ls = <double>[l.first];
  for (var i = 0; i < p.length - 1; i++) {
    final p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.length - 1)];
    final steps = ((p2 - p1).distance / 1.5).ceil().clamp(1, 32);
    for (var s = 1; s <= steps; s++) {
      final u = s / steps, u2 = u * u, u3 = u2 * u;
      curve.add(
        (p1 * 2 + (p2 - p0) * u + (p0 * 2 - p1 * 5 + p2 * 4 - p3) * u2 + (p1 * 3 - p0 - p2 * 3 + p3) * u3) * 0.5,
      );
      ls.add(l[i] + (l[i + 1] - l[i]) * u);
    }
  }
  return (curve, ls);
}

/// Width of the segment ending at point [i]: pressure thickens it; on the calligraphy brush the
/// direction also counts (flat tip at 45°).
double _width(InkStroke t, int i, double base) {
  final p = t.points[i].p;
  switch (t.brush) {
    case Brush.caneta:
      return base * (0.35 + 0.95 * p);
    case Brush.lapis:
      return base * (0.6 + 0.5 * p);
    case Brush.caligrafia:
      if (i == 0) return base * 0.5;
      final d = t.points[i].offset - t.points[i - 1].offset;
      final angle = (d.direction - pi / 4).abs();
      return base * (0.2 + 0.8 * sin(angle).abs()) * (0.6 + 0.6 * p);
    case Brush.marcador:
      return base;
  }
}

Path _smoothPath(List<Offset> points) {
  final path = Path()..moveTo(points.first.dx, points.first.dy);
  if (points.length == 1) return path..lineTo(points.first.dx + 0.01, points.first.dy);
  for (var i = 1; i < points.length - 1; i++) {
    final middle = (points[i] + points[i + 1]) / 2;
    path.quadraticBezierTo(points[i].dx, points[i].dy, middle.dx, middle.dy);
  }
  return path..lineTo(points.last.dx, points.last.dy);
}

void paintHighlight(Canvas canvas, Highlight d, double scale, {bool selected = false}) {
  final ink = Paint()
    ..color = d.color.withValues(alpha: 0.4)
    ..blendMode = BlendMode.multiply;
  for (final r in d.rectangles) {
    final screen = Rect.fromLTRB(r.left * scale, r.top * scale, r.right * scale, r.bottom * scale);
    canvas.drawRRect(RRect.fromRectAndRadius(screen.inflate(1), const Radius.circular(2)), ink);
  }
  if (selected || d.comment.isNotEmpty) {
    final r = d.rectangles.firstOrNull;
    if (r == null) return;
    // Small mark in the corner: the highlight has a comment.
    canvas.drawCircle(Offset(r.left * scale - 4, r.top * scale), 3, Paint()..color = d.color.withValues(alpha: 1));
  }
}

TextPainter textPainter(AnnotatedText t, double scale) => TextPainter(
  text: TextSpan(
    text: t.text,
    style: TextStyle(color: t.color, fontSize: t.size * scale, height: 1.2),
  ),
  textDirection: TextDirection.ltr,
)..layout();

void paintText(Canvas canvas, AnnotatedText t, double scale) =>
    textPainter(t, scale).paint(canvas, t.position * scale);

/// Text rectangle in PDF points (to tap and edit/erase).
Rect textBounds(AnnotatedText t) {
  final tp = textPainter(t, 1);
  return t.position & tp.size;
}
