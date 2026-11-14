import 'package:flutter/material.dart';

/// Small time series (one measure, one axis): 2 px line, subtle grid, current value in the title and
/// crosshair with the value at the instant under the pointer (mouse or touch). Measures on different scales become
/// separate charts side by side, never two axes on the same one.
class TimeSeries extends StatefulWidget {
  const TimeSeries({
    super.key,
    required this.titulo,
    required this.unit,
    required this.points,
    this.maximum,
  });

  final String titulo;
  final String unit;

  /// (segundos Unix, valor); valores nulos interrompem a linha.
  final List<(num, num?)> points;

  /// Fixed axis cap (e.g. 100 for %); without it, the largest value of the series.
  final double? maximum;

  @override
  State<TimeSeries> createState() => _TimeSeriesState();
}

class _TimeSeriesState extends State<TimeSeries> {
  double? _x;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final values = widget.points.map((p) => p.$2).whereType<num>();
    final current = widget.points.isEmpty ? null : widget.points.last.$2;
    final top =
        widget.maximum ??
        (values.isEmpty ? 1.0 : (values.reduce((a, b) => a > b ? a : b) * 1.15).toDouble());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${widget.titulo}  ${current == null ? '—' : '${current.toStringAsFixed(current < 10 ? 1 : 0)} ${widget.unit}'}',
          style: t.textTheme.labelMedium,
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 90,
          child: MouseRegion(
            onHover: (e) => setState(() => _x = e.localPosition.dx),
            onExit: (_) => setState(() => _x = null),
            child: GestureDetector(
              onPanUpdate: (e) => setState(() => _x = e.localPosition.dx),
              onPanEnd: (_) => setState(() => _x = null),
              child: CustomPaint(
                size: Size.infinite,
                painter: _Painter(
                  points: widget.points,
                  top: top <= 0 ? 1 : top,
                  color: t.colorScheme.primary,
                  grade: t.colorScheme.outlineVariant.withValues(alpha: 0.4),
                  texto: t.textTheme.bodySmall!.copyWith(color: t.colorScheme.onSurfaceVariant),
                  backgroundLabel: t.colorScheme.surfaceContainerHighest,
                  unit: widget.unit,
                  ponteiro: _x,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Painter extends CustomPainter {
  _Painter({
    required this.points,
    required this.top,
    required this.color,
    required this.grade,
    required this.texto,
    required this.backgroundLabel,
    required this.unit,
    required this.ponteiro,
  });

  final List<(num, num?)> points;
  final double top;
  final Color color;
  final Color grade;
  final TextStyle texto;
  final Color backgroundLabel;
  final String unit;
  final double? ponteiro;

  @override
  void paint(Canvas canvas, Size size) {
    final gradeLine = Paint()
      ..color = grade
      ..strokeWidth = 1;
    for (final f in [0.0, 0.5, 1.0]) {
      canvas.drawLine(Offset(0, size.height * f), Offset(size.width, size.height * f), gradeLine);
    }
    _label(canvas, top.toStringAsFixed(0), const Offset(2, 0));
    if (points.length < 2) return;
    final t0 = points.first.$1.toDouble(), t1 = points.last.$1.toDouble();
    final span = (t1 - t0) <= 0 ? 1.0 : t1 - t0;
    Offset pos((num, num?) p) => Offset(
      (p.$1 - t0) / span * size.width,
      size.height - ((p.$2 ?? 0) / top).clamp(0.0, 1.0) * size.height,
    );
    final caminho = Path();
    var open = false;
    for (final p in points) {
      if (p.$2 == null) {
        open = false;
        continue;
      }
      final o = pos(p);
      open ? caminho.lineTo(o.dx, o.dy) : caminho.moveTo(o.dx, o.dy);
      open = true;
    }
    canvas.drawPath(
      caminho,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
    final x = ponteiro;
    if (x == null) return;
    final target = t0 + (x / size.width).clamp(0.0, 1.0) * span;
    final p = points.reduce((a, b) => (a.$1 - target).abs() < (b.$1 - target).abs() ? a : b);
    if (p.$2 == null) return;
    final o = pos(p);
    canvas.drawLine(
      Offset(o.dx, 0),
      Offset(o.dx, size.height),
      gradeLine..color = texto.color!.withValues(alpha: 0.5),
    );
    canvas.drawCircle(o, 4, Paint()..color = color);
    final moment = DateTime.fromMillisecondsSinceEpoch((p.$1 * 1000).round());
    final label =
        '${p.$2!.toStringAsFixed(1)} $unit · '
        '${moment.hour.toString().padLeft(2, '0')}:${moment.minute.toString().padLeft(2, '0')}:'
        '${moment.second.toString().padLeft(2, '0')}';
    _label(canvas, label, Offset((o.dx + 8).clamp(0, size.width - 150), 2), background: true);
  }

  void _label(Canvas canvas, String s, Offset o, {bool background = false}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: texto),
      textDirection: TextDirection.ltr,
    )..layout();
    if (background) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(o.dx - 4, o.dy - 2, tp.width + 8, tp.height + 4),
          const Radius.circular(4),
        ),
        Paint()..color = backgroundLabel,
      );
    }
    tp.paint(canvas, o);
  }

  @override
  bool shouldRepaint(_Painter old) =>
      old.points != points || old.ponteiro != ponteiro || old.top != top;
}
