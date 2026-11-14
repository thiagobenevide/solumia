import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../format.dart';

/// Palette for categories without a defined color.
const palette = [
  Color(0xFF5C6BC0), Color(0xFF26A69A), Color(0xFFFFA726), Color(0xFFEF5350), Color(0xFFAB47BC),
  Color(0xFF29B6F6), Color(0xFF8D6E63), Color(0xFFFFCA28), Color(0xFF66BB6A), Color(0xFFEC407A),
];

Color colorOf(String? hex, int i) => hexColor(hex) ?? palette[i % palette.length];

/// Monthly cash flow: income and expense bars (+ investments) side by side and the balance line.
class FlowChart extends StatelessWidget {
  const FlowChart(this.months, {super.key, this.height = 220});

  final List<Doc> months;
  final double height;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      spacing: 8,
      children: [
        SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(painter: _FlowPainter(months, cs, Theme.of(context).textTheme.bodySmall!)),
        ),
        Wrap(
          spacing: 16,
          children: [
            _Legend(Colors.green.shade400, 'Receitas'),
            _Legend(cs.error, 'Despesas'),
            _Legend(Colors.teal.shade300, 'Investimentos'),
            _Legend(cs.primary, 'Saldo'),
          ],
        ),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend(this.color, this.text);

  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: 4,
    children: [
      Container(width: 10, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
      Text(text, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

class _FlowPainter extends CustomPainter {
  _FlowPainter(this.months, this.cs, this.estilo);

  final List<Doc> months;
  final ColorScheme cs;
  final TextStyle estilo;

  @override
  void paint(Canvas canvas, Size size) {
    if (months.isEmpty) return;
    const baseLabel = 18.0;
    final h = size.height - baseLabel;
    final maximum = months.fold<double>(1, (m, x) => math.max(m, math.max(n(x['receitas']), n(x['despesas']) + n(x['investimentos']))));
    final minBalance = months.fold<double>(0, (m, x) => math.min(m, n(x['saldo'])));
    final scale = h / (maximum - minBalance);
    final zero = h + minBalance * scale;
    final width = size.width / months.length;
    final bar = math.min(18.0, width * 0.3);
    final grade = Paint()..color = cs.outlineVariant.withValues(alpha: 0.4);
    canvas.drawLine(Offset(0, zero), Offset(size.width, zero), grade);

    final points = <Offset>[];
    for (var i = 0; i < months.length; i++) {
      final m = months[i];
      final cx = width * i + width / 2;
      final rec = n(m['receitas']) * scale;
      final des = n(m['despesas']) * scale;
      final inv = n(m['investimentos']) * scale;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(cx - bar - 1, zero - rec, bar, rec), const Radius.circular(3)),
        Paint()..color = Colors.green.shade400,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(cx + 1, zero - des, bar, des), const Radius.circular(3)),
        Paint()..color = cs.error,
      );
      if (inv > 0) {
        canvas.drawRect(Rect.fromLTWH(cx + 1, zero - des - inv, bar, inv), Paint()..color = Colors.teal.shade300);
      }
      points.add(Offset(cx, zero - n(m['saldo']) * scale));
      final tp = TextPainter(text: TextSpan(text: shortMonth(m['mes'] as String), style: estilo), textDirection: TextDirection.ltr)
        ..layout();
      tp.paint(canvas, Offset(cx - tp.width / 2, size.height - tp.height));
    }
    final line = Paint()
      ..color = cs.primary
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawPath(Path()..addPolygon(points, false), line);
    for (final p in points) {
      canvas.drawCircle(p, 3, Paint()..color = cs.primary);
    }
  }

  @override
  bool shouldRepaint(_FlowPainter old) => old.months != months;
}

/// Slice of a [Donut].
typedef Slice = ({String name, double value, Color color});

/// Donut with legend (percentage of each slice).
class Donut extends StatelessWidget {
  const Donut(this.slices, {super.key, this.center, this.size = 150});

  final List<Slice> slices;
  final String? center;
  final double size;

  @override
  Widget build(BuildContext context) {
    final total = slices.fold<double>(0, (s, f) => s + f.value);
    final legend = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        for (final f in slices.take(10))
          Row(
            spacing: 6,
            children: [
              Container(width: 10, height: 10, decoration: BoxDecoration(color: f.color, shape: BoxShape.circle)),
              Expanded(child: Text(f.name, overflow: TextOverflow.ellipsis)),
              Text(pct(total == 0 ? 0 : 100 * f.value / total), style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
      ],
    );
    return LayoutBuilder(
      builder: (context, c) {
        final chart = SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: _DonutPainter(slices, total, Theme.of(context).colorScheme.surfaceContainerHighest),
            child: Center(
              child: Text(center ?? '', textAlign: TextAlign.center, style: Theme.of(context).textTheme.labelLarge),
            ),
          ),
        );
        if (c.maxWidth < 380) return Column(spacing: 12, children: [chart, legend]);
        return Row(spacing: 16, children: [chart, Expanded(child: legend)]);
      },
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter(this.slices, this.total, this.background);

  final List<Slice> slices;
  final double total;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    final thickness = size.width * 0.16;
    final r = Rect.fromLTWH(thickness / 2, thickness / 2, size.width - thickness, size.height - thickness);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness;
    if (total <= 0) {
      canvas.drawArc(r, 0, 2 * math.pi, false, p..color = background);
      return;
    }
    var start = -math.pi / 2;
    for (final f in slices) {
      final ang = 2 * math.pi * f.value / total;
      canvas.drawArc(r, start, math.max(ang - 0.02, 0.001), false, p..color = f.color);
      start += ang;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) => old.slices != slices;
}

/// Simple line (balance projection, quote…) with the minimum and maximum marked.
class LineChart extends StatelessWidget {
  const LineChart(this.points, {super.key, this.height = 160});

  final List<({String label, double value})> points;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    width: double.infinity,
    child: CustomPaint(painter: _LinePainter(points, Theme.of(context).colorScheme, Theme.of(context).textTheme.bodySmall!)),
  );
}

class _LinePainter extends CustomPainter {
  _LinePainter(this.points, this.cs, this.estilo);

  final List<({String label, double value})> points;
  final ColorScheme cs;
  final TextStyle estilo;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    const margin = 16.0;
    final h = size.height - margin * 2;
    final vals = points.map((p) => p.value);
    final lo = math.min(vals.reduce(math.min), 0.0);
    final hi = math.max(vals.reduce(math.max), lo + 1);
    double y(double v) => margin + h - (v - lo) / (hi - lo) * h;
    final step = points.length > 1 ? size.width / (points.length - 1) : 0.0;
    final grade = Paint()..color = cs.outlineVariant.withValues(alpha: 0.5);
    canvas.drawLine(Offset(0, y(0)), Offset(size.width, y(0)), grade);
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final o = Offset(step * i, y(points[i].value));
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = cs.primary
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
    void label(String t, Offset o) {
      final tp = TextPainter(text: TextSpan(text: t, style: estilo), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, Offset((o.dx - tp.width / 2).clamp(0, size.width - tp.width), o.dy));
    }

    label(points.first.label, Offset(0, size.height - margin + 2));
    if (points.length > 1) label(points.last.label, Offset(size.width, size.height - margin + 2));
    final iMin = points.indexWhere((p) => p.value == vals.reduce(math.min));
    label(currency(points[iMin].value), Offset(step * iMin, y(points[iMin].value) + 4));
  }

  @override
  bool shouldRepaint(_LinePainter old) => old.points != points;
}
