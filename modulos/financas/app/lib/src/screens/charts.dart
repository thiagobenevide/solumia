import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../format.dart';

/// Palette for categories without a defined color.
const palette = [
  Color(0xFF5C6BC0), Color(0xFF26A69A), Color(0xFFFFA726), Color(0xFFEF5350), Color(0xFFAB47BC),
  Color(0xFF29B6F6), Color(0xFF8D6E63), Color(0xFFFFCA28), Color(0xFF66BB6A), Color(0xFFEC407A),
];

Color colorOf(String? hex, int i) => hexColor(hex) ?? palette[i % palette.length];

/// Every chart draws itself in (bars grow, lines trace, slices sweep) when it appears or its data
/// changes, and answers touch/hover with the exact numbers of the point under the finger.
const _drawIn = Duration(milliseconds: 1100);

/// Runs the draw-in animation from 0 to 1 again whenever [data] changes.
class _DrawIn extends StatelessWidget {
  const _DrawIn({required this.data, required this.builder});

  final Object data;
  final Widget Function(BuildContext context, double t) builder;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) return builder(context, 1);
    return TweenAnimationBuilder<double>(
      key: ValueKey(identityHashCode(data)),
      tween: Tween(begin: 0, end: 1),
      duration: _drawIn,
      curve: Curves.easeOutCubic,
      builder: (context, t, _) => builder(context, t),
    );
  }
}

/// Index of the column under [x] in a chart [width] wide with [count] columns.
int _columnAt(double x, double width, int count) {
  if (count == 0 || width <= 0) return -1;
  return (x / (width / count)).floor().clamp(0, count - 1);
}

/// Floating label with the numbers of the selected point.
class _Tip extends StatelessWidget {
  const _Tip({required this.title, required this.lines});

  final String title;
  final List<(Color, String)> lines;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Material(
      elevation: 6,
      color: cs.inverseSurface,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 2,
          children: [
            Text(title, style: text.labelLarge?.copyWith(color: cs.onInverseSurface)),
            for (final (color, line) in lines)
              Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 6,
                children: [
                  Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                  Text(line, style: text.bodySmall?.copyWith(color: cs.onInverseSurface)),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Places [tip] above the point [x] of a chart [width] wide, without leaving its sides.
Widget _tipAt(double x, double width, Widget tip) {
  const tipWidth = 190.0;
  final double left = (x - tipWidth / 2).clamp(0.0, math.max(width - tipWidth, 0.0));
  return Positioned(
    left: left,
    top: 0,
    width: tipWidth,
    child: IgnorePointer(child: Align(alignment: Alignment.topCenter, child: tip)),
  );
}

/// Monthly cash flow: income and expense bars (+ investments) side by side and the balance line.
/// Touch or hover a month to read its numbers.
class FlowChart extends StatefulWidget {
  const FlowChart(this.months, {super.key, this.height = 220});

  final List<Doc> months;
  final double height;

  @override
  State<FlowChart> createState() => _FlowChartState();
}

class _FlowChartState extends State<FlowChart> {
  int _selected = -1;

  void _select(double x, double width) {
    final i = _columnAt(x, width, widget.months.length);
    if (i != _selected) setState(() => _selected = i);
  }

  void _clear() => setState(() => _selected = -1);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      spacing: 8,
      children: [
        SizedBox(
          height: widget.height,
          width: double.infinity,
          child: LayoutBuilder(builder: (context, box) => _chart(context, cs, box.maxWidth)),
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

  Widget _chart(BuildContext context, ColorScheme cs, double width) {
    final style = Theme.of(context).textTheme.bodySmall!;
    final months = widget.months;
    return MouseRegion(
      onHover: (e) => _select(e.localPosition.dx, width),
      onExit: (_) => _clear(),
      child: GestureDetector(
        onTapDown: (e) => _select(e.localPosition.dx, width),
        onHorizontalDragUpdate: (e) => _select(e.localPosition.dx, width),
        child: _DrawIn(
          data: months,
          builder: (context, t) => Stack(
            children: [
              Positioned.fill(child: CustomPaint(painter: _FlowPainter(months, cs, style, t, _selected))),
              if (_selected >= 0 && _selected < months.length)
                _tipAt(width / months.length * (_selected + 0.5), width, _flowTip(cs, months[_selected])),
            ],
          ),
        ),
      ),
    );
  }

  Widget _flowTip(ColorScheme cs, Doc m) {
    final lines = <(Color, String)>[
      (Colors.green.shade400, 'Receitas ${currency(n(m['receitas']))}'),
      (cs.error, 'Despesas ${currency(n(m['despesas']))}'),
    ];
    if (n(m['investimentos']) > 0) lines.add((Colors.teal.shade300, 'Investido ${currency(n(m['investimentos']))}'));
    lines.add((cs.primary, 'Saldo ${currency(n(m['saldo']))}'));
    return _Tip(title: shortMonth(m['mes'] as String), lines: lines);
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
  _FlowPainter(this.months, this.cs, this.estilo, this.t, this.selected);

  final List<Doc> months;
  final ColorScheme cs;
  final TextStyle estilo;

  /// Draw-in progress (0 → 1): each month's bars grow a little after the previous one.
  final double t;
  final int selected;

  double _grow(int i) {
    final start = 0.5 * i / math.max(months.length, 1);
    return Curves.easeOutBack.transform(((t - start) / 0.5).clamp(0.0, 1.0));
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (months.isEmpty) return;
    const baseLabel = 18.0;
    final h = size.height - baseLabel;
    var maximum = 1.0;
    var minBalance = 0.0;
    for (final x in months) {
      maximum = math.max(maximum, math.max(n(x['receitas']), n(x['despesas']) + n(x['investimentos'])));
      minBalance = math.min(minBalance, n(x['saldo']));
    }
    // headroom for the floating label
    final scale = h * 0.82 / (maximum - minBalance);
    final zero = h + minBalance * scale;
    final width = size.width / months.length;
    final bar = math.min(18.0, width * 0.3);
    final grade = Paint()..color = cs.outlineVariant.withValues(alpha: 0.4);
    canvas.drawLine(Offset(0, zero), Offset(size.width, zero), grade);
    if (selected >= 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(width * selected + 2, 0, width - 4, h), const Radius.circular(8)),
        Paint()..color = cs.primary.withValues(alpha: 0.08),
      );
    }
    final points = <Offset>[];
    for (var i = 0; i < months.length; i++) {
      final m = months[i];
      final g = _grow(i);
      final dim = selected >= 0 && selected != i ? 0.45 : 1.0;
      final cx = width * i + width / 2;
      final rec = n(m['receitas']) * scale * g;
      final des = n(m['despesas']) * scale * g;
      final inv = n(m['investimentos']) * scale * g;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(cx - bar - 1, zero - rec, bar, rec), const Radius.circular(3)),
        Paint()..color = Colors.green.shade400.withValues(alpha: dim),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(cx + 1, zero - des, bar, des), const Radius.circular(3)),
        Paint()..color = cs.error.withValues(alpha: dim),
      );
      if (inv > 0) {
        canvas.drawRect(Rect.fromLTWH(cx + 1, zero - des - inv, bar, inv), Paint()..color = Colors.teal.shade300.withValues(alpha: dim));
      }
      points.add(Offset(cx, zero - n(m['saldo']) * scale));
      final tp = TextPainter(text: TextSpan(text: shortMonth(m['mes'] as String), style: estilo), textDirection: TextDirection.ltr)
        ..layout();
      tp.paint(canvas, Offset(cx - tp.width / 2, size.height - tp.height));
    }
    _balanceLine(canvas, points);
  }

  void _balanceLine(Canvas canvas, List<Offset> points) {
    final line = Paint()
      ..color = cs.primary
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    final path = Path()..addPolygon(points, false);
    final p = ((t - 0.35) / 0.65).clamp(0.0, 1.0);
    drawPartial(canvas, path, p, line);
    final visible = (points.length * p).floor();
    for (var i = 0; i < visible && i < points.length; i++) {
      canvas.drawCircle(points[i], i == selected ? 5 : 3, Paint()..color = cs.primary);
    }
  }

  @override
  bool shouldRepaint(_FlowPainter old) => old.months != months || old.t != t || old.selected != selected;
}

/// Draws only the fraction [p] of the length of [path] (a line that traces itself).
void drawPartial(Canvas canvas, Path path, double p, Paint paint) {
  if (p <= 0) return;
  for (final part in path.computeMetrics()) {
    canvas.drawPath(part.extractPath(0, part.length * p), paint);
  }
}

/// Slice of a [Donut].
typedef Slice = ({String name, double value, Color color});

/// Donut with legend (percentage of each slice). Slices sweep in; touching a slice or its legend
/// line lifts it and shows its name and share in the middle.
class Donut extends StatefulWidget {
  const Donut(this.slices, {super.key, this.center, this.size = 150});

  final List<Slice> slices;
  final String? center;
  final double size;

  @override
  State<Donut> createState() => _DonutState();
}

class _DonutState extends State<Donut> {
  int _selected = -1;

  void _toggle(int i) => setState(() => _selected = _selected == i ? -1 : i);

  void _hover(int i) {
    if (i != _selected) setState(() => _selected = i);
  }

  double get _total {
    var total = 0.0;
    for (final f in widget.slices) {
      total += f.value;
    }
    return total;
  }

  /// Slice under [local] (point inside the donut box), or -1.
  int _sliceAt(Offset local) {
    final c = Offset(widget.size / 2, widget.size / 2);
    final d = local - c;
    final r = d.distance;
    if (r < widget.size * 0.28 || r > widget.size / 2 + 6) return -1;
    var angle = math.atan2(d.dy, d.dx) + math.pi / 2;
    if (angle < 0) angle += 2 * math.pi;
    final total = _total;
    if (total <= 0) return -1;
    var start = 0.0;
    for (var i = 0; i < widget.slices.length; i++) {
      final sweep = 2 * math.pi * widget.slices[i].value / total;
      if (angle >= start && angle < start + sweep) return i;
      start += sweep;
    }
    return -1;
  }

  @override
  Widget build(BuildContext context) {
    final total = _total;
    final text = Theme.of(context).textTheme;
    final legend = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 2,
      children: [
        for (var i = 0; i < widget.slices.length && i < 10; i++) _legendLine(context, i, total),
      ],
    );
    final chosen = _selected >= 0 && _selected < widget.slices.length ? widget.slices[_selected] : null;
    final middle = chosen == null
        ? Text(widget.center ?? '', textAlign: TextAlign.center, style: text.labelLarge)
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(chosen.name, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: text.labelMedium),
              Text(pct(total == 0 ? 0 : 100 * chosen.value / total), style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              Text(currency(chosen.value), style: text.labelSmall),
            ],
          );
    final chart = SizedBox(
      width: widget.size,
      height: widget.size,
      child: MouseRegion(
        onHover: (e) => _hover(_sliceAt(e.localPosition)),
        onExit: (_) => _hover(-1),
        child: GestureDetector(
          onTapDown: (e) => _toggle(_sliceAt(e.localPosition)),
          child: _DrawIn(
            data: widget.slices,
            builder: (context, t) => CustomPaint(
              painter: _DonutPainter(widget.slices, total, Theme.of(context).colorScheme.surfaceContainerHighest, t, _selected),
              child: Center(
                child: Padding(padding: EdgeInsets.all(widget.size * 0.2), child: middle),
              ),
            ),
          ),
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < 380) return Column(spacing: 12, children: [chart, legend]);
        return Row(spacing: 16, children: [chart, Expanded(child: legend)]);
      },
    );
  }

  Widget _legendLine(BuildContext context, int i, double total) {
    final f = widget.slices[i];
    final on = _selected == i;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => _toggle(i),
      onHover: (over) => _hover(over ? i : -1),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: on ? f.color.withValues(alpha: 0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          spacing: 6,
          children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: f.color, shape: BoxShape.circle)),
            Expanded(child: Text(f.name, overflow: TextOverflow.ellipsis)),
            Text(pct(total == 0 ? 0 : 100 * f.value / total), style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter(this.slices, this.total, this.background, this.t, this.selected);

  final List<Slice> slices;
  final double total;
  final Color background;
  final double t;
  final int selected;

  @override
  void paint(Canvas canvas, Size size) {
    final thickness = size.width * 0.14;
    final r = Rect.fromLTWH(thickness / 2 + 4, thickness / 2 + 4, size.width - thickness - 8, size.height - thickness - 8);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness;
    canvas.drawArc(r, 0, 2 * math.pi, false, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..color = background.withValues(alpha: 0.5));
    if (total <= 0) return;
    // the whole ring sweeps in clockwise; each slice keeps its share of the swept angle
    var start = -math.pi / 2;
    final reach = 2 * math.pi * t;
    for (var i = 0; i < slices.length; i++) {
      final f = slices[i];
      final ang = 2 * math.pi * f.value / total;
      final drawn = math.min(ang, reach - (start + math.pi / 2));
      if (drawn <= 0) break;
      final on = i == selected;
      final dim = selected >= 0 && !on ? 0.45 : 1.0;
      p
        ..color = f.color.withValues(alpha: dim)
        ..strokeWidth = on ? thickness * 1.35 : thickness;
      canvas.drawArc(r, start, math.max(drawn - 0.02, 0.001), false, p);
      start += ang;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) => old.slices != slices || old.t != t || old.selected != selected;
}

/// Simple line (balance projection, quote…) with a soft area under it and the minimum marked.
/// The line traces itself in; touch or hover reads the value of each point.
class LineChart extends StatefulWidget {
  const LineChart(this.points, {super.key, this.height = 160});

  final List<({String label, double value})> points;
  final double height;

  @override
  State<LineChart> createState() => _LineChartState();
}

class _LineChartState extends State<LineChart> {
  int _selected = -1;

  void _select(double x, double width) {
    final count = widget.points.length;
    if (count == 0) return;
    final step = count > 1 ? width / (count - 1) : width;
    final i = (x / step).round().clamp(0, count - 1);
    if (i != _selected) setState(() => _selected = i);
  }

  void _clear() => setState(() => _selected = -1);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall!;
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, box) => MouseRegion(
          onHover: (e) => _select(e.localPosition.dx, box.maxWidth),
          onExit: (_) => _clear(),
          child: GestureDetector(
            onTapDown: (e) => _select(e.localPosition.dx, box.maxWidth),
            onHorizontalDragUpdate: (e) => _select(e.localPosition.dx, box.maxWidth),
            child: _DrawIn(
              data: widget.points,
              builder: (context, t) => Stack(
                children: [
                  Positioned.fill(child: CustomPaint(painter: _LinePainter(widget.points, cs, style, t, _selected))),
                  if (_selected >= 0 && _selected < widget.points.length) _lineTip(cs, box.maxWidth),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _lineTip(ColorScheme cs, double width) {
    final point = widget.points[_selected];
    final count = widget.points.length;
    final x = count > 1 ? width / (count - 1) * _selected : width / 2;
    return _tipAt(x, width, _Tip(title: point.label, lines: [(cs.primary, currency(point.value))]));
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter(this.points, this.cs, this.estilo, this.t, this.selected);

  final List<({String label, double value})> points;
  final ColorScheme cs;
  final TextStyle estilo;
  final double t;
  final int selected;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    const margin = 16.0;
    final h = size.height - margin * 2;
    var lo = 0.0;
    var hi = 1.0;
    var iMin = 0;
    for (var i = 0; i < points.length; i++) {
      final v = points[i].value;
      lo = math.min(lo, v);
      hi = math.max(hi, v);
      if (v < points[iMin].value) iMin = i;
    }
    hi = math.max(hi, lo + 1);
    final step = points.length > 1 ? size.width / (points.length - 1) : 0.0;
    final grade = Paint()..color = cs.outlineVariant.withValues(alpha: 0.5);
    final zeroY = _y(0, lo, hi, h, margin);
    canvas.drawLine(Offset(0, zeroY), Offset(size.width, zeroY), grade);
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final o = Offset(step * i, _y(points[i].value, lo, hi, h, margin));
      if (i == 0) {
        path.moveTo(o.dx, o.dy);
      } else {
        path.lineTo(o.dx, o.dy);
      }
    }
    _area(canvas, size, path, step * (points.length - 1), margin);
    drawPartial(
      canvas,
      path,
      t,
      Paint()
        ..color = cs.primary
        ..strokeWidth = 2.2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );
    _label(canvas, size, points.first.label, Offset(0, size.height - margin + 2));
    if (points.length > 1) _label(canvas, size, points.last.label, Offset(size.width, size.height - margin + 2));
    if (t >= 1) {
      _label(canvas, size, currency(points[iMin].value), Offset(step * iMin, _y(points[iMin].value, lo, hi, h, margin) + 4));
    }
    if (selected >= 0 && selected < points.length) {
      final o = Offset(step * selected, _y(points[selected].value, lo, hi, h, margin));
      canvas.drawLine(Offset(o.dx, margin), Offset(o.dx, size.height - margin), grade);
      canvas.drawCircle(o, 6, Paint()..color = cs.primary.withValues(alpha: 0.25));
      canvas.drawCircle(o, 3.5, Paint()..color = cs.primary);
    }
  }

  double _y(double v, double lo, double hi, double h, double margin) => margin + h - (v - lo) / (hi - lo) * h;

  /// Soft gradient under the line, revealed left to right with the trace.
  void _area(Canvas canvas, Size size, Path line, double lastX, double margin) {
    final area = Path.from(line)
      ..lineTo(lastX, size.height - margin)
      ..lineTo(0, size.height - margin)
      ..close();
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width * t, size.height));
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [cs.primary.withValues(alpha: 0.22), cs.primary.withValues(alpha: 0)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
    );
    canvas.restore();
  }

  void _label(Canvas canvas, Size size, String text, Offset o) {
    final tp = TextPainter(text: TextSpan(text: text, style: estilo), textDirection: TextDirection.ltr)..layout();
    tp.paint(canvas, Offset((o.dx - tp.width / 2).clamp(0, math.max(size.width - tp.width, 0)), o.dy));
  }

  @override
  bool shouldRepaint(_LinePainter old) => old.points != points || old.t != t || old.selected != selected;
}
