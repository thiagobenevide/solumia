import 'dart:math';

import 'package:flutter/material.dart';

import '../calculations.dart';

/// Fixed order of the signal colors (validated categorical palette, dark mode). The color stays with the signal
/// while it is visible; no more than 8 at the same time.
const signalColors = [
  Color(0xFF3987E5),
  Color(0xFFD95926),
  Color(0xFF199E70),
  Color(0xFFC98500),
  Color(0xFFD55181),
  Color(0xFF008300),
  Color(0xFF9085E9),
  Color(0xFFE66767),
];

const _grade = Color(0xFF2C2C2A);
const _margin = EdgeInsets.fromLTRB(68, 10, 14, 30);

/// "Round" step (1, 2 or 5 × 10ⁿ) for about [target] divisions in [band].
double roundStep(double band, [int target = 5]) {
  if (band <= 0 || !band.isFinite) return 1;
  final raw = band / target;
  final ten = pow(10, (log(raw) / ln10).floor()).toDouble();
  final m = raw / ten;
  return (m < 1.5 ? 1 : m < 3.5 ? 2 : m < 7.5 ? 5 : 10) * ten;
}

/// Oscilloscope: [series] (all with the same [unitY]) against [x]; [logX] for AC. Hovering the mouse or the
/// finger shows the crosshair and the values at the nearest point.
class CurvesChart extends StatefulWidget {
  const CurvesChart({
    super.key,
    required this.x,
    required this.series,
    required this.colors,
    required this.unitX,
    required this.unitY,
    this.logX = false,
  });

  final List<double> x;
  final Map<String, List<double>> series;
  final Map<String, Color> colors;
  final String unitX, unitY;
  final bool logX;

  @override
  State<CurvesChart> createState() => _CurvesChartState();
}

class _CurvesChartState extends State<CurvesChart> {
  int? _index;

  void _point(Offset local, Size size) {
    final x = widget.x;
    if (x.isEmpty) return;
    final area = _margin.deflateRect(Offset.zero & size);
    final f = ((local.dx - area.left) / area.width).clamp(0.0, 1.0);
    final scale = _XScale(x, widget.logX);
    final target = scale.inverse(f);
    var lo = 0, hi = x.length - 1;
    while (hi - lo > 1) {
      final middle = (lo + hi) ~/ 2;
      x[middle] < target ? lo = middle : hi = middle;
    }
    final i = (target - x[lo]).abs() <= (x[hi] - target).abs() ? lo : hi;
    if (i != _index) setState(() => _index = i);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final size = c.biggest;
        return MouseRegion(
          onHover: (e) => _point(e.localPosition, size),
          onExit: (_) => setState(() => _index = null),
          child: Listener(
            onPointerDown: (e) => _point(e.localPosition, size),
            onPointerMove: (e) => _point(e.localPosition, size),
            child: CustomPaint(
              size: size,
              painter: _ChartPainter(
                widget,
                _index,
                text: theme.colorScheme.onSurface,
                faintText: theme.colorScheme.onSurfaceVariant,
                box: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Linear x axis or in decades (log10), mapped to 0–1.
class _XScale {
  _XScale(List<double> x, this.logarithmic) {
    final valid = logarithmic ? x.where((v) => v > 0) : x;
    start = _t(valid.isEmpty ? 1 : valid.first);
    end = _t(valid.isEmpty ? 10 : valid.last);
    if (end == start) end = start + 1;
  }

  final bool logarithmic;
  late double start, end;

  double _t(double v) => logarithmic ? (v > 0 ? log(v) / ln10 : double.nan) : v;

  double fraction(double v) => (_t(v) - start) / (end - start);

  double inverse(double f) {
    final t = start + f * (end - start);
    return logarithmic ? pow(10, t).toDouble() : t;
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.g, this.score, {required this.text, required this.faintText, required this.box});

  final CurvesChart g;
  final int? score;
  final Color text, faintText, box;

  void _label(Canvas canvas, String s, Offset pos, {TextAlign align = TextAlign.center, Color? color, double size = 11}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: color ?? faintText, fontSize: size)),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = align == TextAlign.right ? -tp.width : (align == TextAlign.left ? 0.0 : -tp.width / 2);
    tp.paint(canvas, pos + Offset(dx, -tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final area = _margin.deflateRect(Offset.zero & size);
    if (area.isEmpty || g.x.isEmpty) return;
    var ymin = double.infinity, ymax = -double.infinity;
    for (final s in g.series.values) {
      for (final v in s) {
        if (v.isFinite) {
          ymin = min(ymin, v);
          ymax = max(ymax, v);
        }
      }
    }
    if (!ymin.isFinite) ymin = ymax = 0;
    if (ymax - ymin < 1e-15) {
      final slack = ymax.abs() * 0.1 + 1e-12;
      ymin -= slack;
      ymax += slack;
    }
    final stepY = roundStep(ymax - ymin);
    ymin = (ymin / stepY).floor() * stepY;
    ymax = (ymax / stepY).ceil() * stepY;
    final ex = _XScale(g.x, g.logX);
    double px(double v) => area.left + ex.fraction(v) * area.width;
    double py(double v) => area.bottom - (v - ymin) / (ymax - ymin) * area.height;

    final grade = Paint()
      ..color = _grade
      ..strokeWidth = 1;
    for (var v = ymin; v <= ymax + stepY / 2; v += stepY) {
      canvas.drawLine(Offset(area.left, py(v)), Offset(area.right, py(v)), grade);
      _label(canvas, format(v.abs() < stepY * 1e-6 ? 0 : v, g.unitY), Offset(area.left - 6, py(v)), align: TextAlign.right);
    }
    if (g.logX) {
      for (var d = ex.start.floor(); d <= ex.end.ceil(); d++) {
        final v = pow(10, d).toDouble();
        if (d < ex.start - 1e-9 || d > ex.end + 1e-9) continue;
        canvas.drawLine(Offset(px(v), area.top), Offset(px(v), area.bottom), grade);
        _label(canvas, format(v, g.unitX), Offset(px(v), area.bottom + 14));
      }
    } else {
      final stepX = roundStep(ex.end - ex.start, 6);
      for (var v = (ex.start / stepX).ceil() * stepX; v <= ex.end + stepX * 1e-6; v += stepX) {
        canvas.drawLine(Offset(px(v), area.top), Offset(px(v), area.bottom), grade);
        _label(canvas, format(v.abs() < stepX * 1e-6 ? 0 : v, g.unitX), Offset(px(v), area.bottom + 14));
      }
    }

    canvas
      ..save()
      ..clipRect(area.inflate(2));
    for (final e in g.series.entries) {
      final path = Path();
      var open = false;
      for (var i = 0; i < min(e.value.length, g.x.length); i++) {
        final x = px(g.x[i]), y = py(e.value[i]);
        if (!x.isFinite || !y.isFinite) {
          open = false;
          continue;
        }
        open ? path.lineTo(x, y) : path.moveTo(x, y);
        open = true;
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = g.colors[e.key] ?? text
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round,
      );
    }
    canvas.restore();

    final i = score;
    if (i == null || i >= g.x.length) return;
    final cx = px(g.x[i]);
    canvas.drawLine(Offset(cx, area.top), Offset(cx, area.bottom), Paint()..color = faintText.withValues(alpha: 0.6));
    final lines = <(String, Color?)>[
      (format(g.x[i], g.unitX), null),
      for (final e in g.series.entries)
        if (i < e.value.length) ('${e.key}  ${format(e.value[i], g.unitY)}', g.colors[e.key]),
    ];
    for (final e in g.series.entries) {
      if (i >= e.value.length || !py(e.value[i]).isFinite) continue;
      final p = Offset(cx, py(e.value[i]));
      canvas
        ..drawCircle(p, 5, Paint()..color = box)
        ..drawCircle(p, 4, Paint()..color = g.colors[e.key] ?? text);
    }
    const height = 16.0;
    final width = lines.map((l) => l.$1.length * 6.6 + 24).reduce(max);
    var left = cx + 12;
    if (left + width > size.width) left = cx - 12 - width;
    final boxR = Rect.fromLTWH(left, area.top + 4, width, lines.length * height + 8);
    canvas.drawRRect(RRect.fromRectAndRadius(boxR, const Radius.circular(6)), Paint()..color = box);
    for (var k = 0; k < lines.length; k++) {
      final y = boxR.top + 4 + height * k + height / 2;
      final color = lines[k].$2;
      if (color != null) canvas.drawCircle(Offset(boxR.left + 10, y), 4, Paint()..color = color);
      _label(canvas, lines[k].$1, Offset(boxR.left + 20, y), align: TextAlign.left, color: text);
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) => old.g != g || old.score != score;
}
