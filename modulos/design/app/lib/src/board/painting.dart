import 'dart:math';
import 'dart:ui' show PointMode;

import 'package:flutter/material.dart';

import '../models.dart';
import 'input.dart';
import 'images.dart';

/// On the dark board (projection), almost-black ink turns white: the same drawing works for both.
Color ink(Color c, bool dark) => dark && c.computeLuminance() < 0.08 ? const Color(0xFFF5F5F5) : c;

Color bgColor(bool dark) => dark ? const Color(0xFF1B1F1D) : const Color(0xFFFDFDFB);

/// Draws [e] on the canvas already transformed to the world.
void paintElement(Canvas canvas, Elemento e, {bool dark = false}) {
  switch (e) {
    case Traco():
      _paintStroke(canvas, e, dark);
    case Forma():
      _paintShape(canvas, e, dark);
    case BoardText():
      textPainter(e, dark).paint(canvas, e.position);
    case FlowNode():
      _paintNode(canvas, e, dark);
    case Connector():
      _paintConnector(canvas, e, dark);
    case BoardTable():
      paintTable(canvas, e, dark);
    case BoardImage():
      _paintImage(canvas, e, dark);
  }
}

/// While the image has not arrived from the server, a gray box with an X marks the spot.
void _paintImage(Canvas canvas, BoardImage e, bool dark) {
  final r = e.retangulo;
  final img = BoardImageCache.instance.fetch(e.image);
  if (img != null) {
    final origin = Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
    canvas.drawImageRect(img, origin, r, Paint()..filterQuality = FilterQuality.medium);
    return;
  }
  final gray = Paint()
    ..color = dark ? const Color(0x33FFFFFF) : const Color(0x22000000)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5;
  canvas
    ..drawRect(r, gray)
    ..drawLine(r.topLeft, r.bottomRight, gray)
    ..drawLine(r.topRight, r.bottomLeft, gray);
}

/// Default background of the table header row.
const headerBackground = Color(0xFFECEFF1);

void paintTable(Canvas canvas, BoardTable t, bool dark) {
  final grade = Paint()
    ..color = ink(t.color, dark)
    ..style = PaintingStyle.stroke
    ..strokeWidth = max(1, t.size / 16);
  for (var l = 0; l < t.linhas; l++) {
    final header = t.header && l == 0;
    for (var c = 0; c < t.columns; c++) {
      final r = t.cell(l, c), cel = t.cells[l][c];
      final background = cel.background ?? (header ? headerBackground : null);
      if (background != null) {
        canvas.drawRect(r, Paint()..color = dark && cel.background == null ? const Color(0xFF2E3A40) : background);
      }
      if (cel.text.isEmpty) continue;
      final slack = t.size * 0.5;
      final text = TextPainter(
        text: formattedText(
          cel.text,
          TextStyle(
            color: ink(cel.textColor ?? const Color(0xFF111111), dark),
            fontSize: t.size,
            height: 1.25,
            fontWeight: cel.bold || header ? FontWeight.bold : null,
          ),
          dark,
        ),
        textAlign: const [TextAlign.left, TextAlign.center, TextAlign.right][cel.alignmentMode.clamp(0, 2)],
        textDirection: TextDirection.ltr,
        ellipsis: '…',
      )..layout(minWidth: max(0, r.width - slack * 2), maxWidth: max(0, r.width - slack * 2));
      canvas.save();
      canvas.clipRect(r);
      text.paint(canvas, Offset(r.left + slack, r.center.dy - text.height / 2));
      canvas.restore();
    }
  }
  for (var l = 0; l < t.linhas; l++) {
    for (var c = 0; c < t.columns; c++) {
      canvas.drawRect(t.cell(l, c), grade);
    }
  }
}

void _paintStroke(Canvas canvas, Traco t, bool dark) {
  if (t.pontos.isEmpty) return;
  final color = ink(t.color, dark);
  if (t.brush == Pincel.marcador) {
    canvas.drawPath(
      smoothPath([for (final p in t.pontos) p.offset]),
      Paint()
        ..color = color.withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = t.thickness,
    );
    return;
  }
  final brush = Paint()
    ..color = color
    ..strokeCap = StrokeCap.round;
  if (t.pontos.length == 1) {
    canvas.drawCircle(t.pontos.first.offset, _width(t, 0) / 2, brush);
    return;
  }
  brush.style = PaintingStyle.stroke;
  for (var i = 1; i < t.pontos.length; i++) {
    brush.strokeWidth = _width(t, i);
    canvas.drawLine(t.pontos[i - 1].offset, t.pontos[i].offset, brush);
  }
}

/// Pressure thickens the pen; averaging with the previous point avoids steps between segments.
double _width(Traco t, int i) {
  final p = i == 0 ? t.pontos[0].p : (t.pontos[i].p + t.pontos[i - 1].p) / 2;
  return t.thickness * (0.35 + 0.95 * p);
}

Path smoothPath(List<Offset> pontos) {
  final path = Path()..moveTo(pontos.first.dx, pontos.first.dy);
  if (pontos.length == 1) return path..lineTo(pontos.first.dx + 0.01, pontos.first.dy);
  for (var i = 1; i < pontos.length - 1; i++) {
    final middle = (pontos[i] + pontos[i + 1]) / 2;
    path.quadraticBezierTo(pontos[i].dx, pontos[i].dy, middle.dx, middle.dy);
  }
  return path..lineTo(pontos.last.dx, pontos.last.dy);
}

void _paintShape(Canvas canvas, Forma f, bool dark) {
  final brush = Paint()
    ..color = ink(f.color, dark)
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..strokeWidth = f.thickness;
  final r = Rect.fromPoints(f.a, f.b);
  switch (f.shape) {
    case ShapeKind.reta:
      canvas.drawLine(f.a, f.b, brush);
    case ShapeKind.seta:
      canvas.drawLine(f.a, f.b, brush);
      final d = f.b - f.a;
      if (d.distance < 1) return;
      final tip = max(10.0, f.thickness * 4);
      for (final side in [-1, 1]) {
        final angle = d.direction + pi + side * pi / 7;
        canvas.drawLine(f.b, f.b + Offset.fromDirection(angle, tip), brush);
      }
    case ShapeKind.retangulo:
      canvas.drawRect(r, brush);
    case ShapeKind.elipse:
      canvas.drawOval(r, brush);
  }
}

/// Block outline by type: rounded start/end, process with soft corners, straight
/// rectangle, circle, decision as a diamond, slanted input/output, document with a wavy base,
/// database as a cylinder, note with the folded corner, hexagon and container.
Path nodeOutline(FlowNode n) {
  final r = n.retangulo;
  switch (n.type) {
    case NodeKind.inicio || NodeKind.fim:
      return Path()..addRRect(RRect.fromRectAndRadius(r, Radius.circular(r.shortestSide / 2)));
    case NodeKind.decisao:
      return Path()
        ..moveTo(r.center.dx, r.top)
        ..lineTo(r.right, r.center.dy)
        ..lineTo(r.center.dx, r.bottom)
        ..lineTo(r.left, r.center.dy)
        ..close();
    case NodeKind.dado:
      final d = r.height * 0.3;
      return Path()
        ..moveTo(r.left + d, r.top)
        ..lineTo(r.right, r.top)
        ..lineTo(r.right - d, r.bottom)
        ..lineTo(r.left, r.bottom)
        ..close();
    case NodeKind.processo || NodeKind.subprocesso:
      return Path()..addRRect(RRect.fromRectAndRadius(r, const Radius.circular(6)));
    case NodeKind.quadrado || NodeKind.container:
      return Path()..addRect(r);
    case NodeKind.circulo:
      return Path()..addOval(r);
    case NodeKind.documento:
      final wave = r.height * 0.12;
      return Path()
        ..moveTo(r.left, r.top)
        ..lineTo(r.right, r.top)
        ..lineTo(r.right, r.bottom - wave)
        ..cubicTo(r.right - r.width * 0.25, r.bottom - wave * 2.6, r.left + r.width * 0.45, r.bottom + wave * 0.8, r.left, r.bottom - wave)
        ..close();
    case NodeKind.banco:
      final e = min(r.height * 0.15, 14.0);
      return Path()
        ..moveTo(r.left, r.top + e)
        ..arcToPoint(Offset(r.right, r.top + e), radius: Radius.elliptical(r.width / 2, e))
        ..lineTo(r.right, r.bottom - e)
        ..arcToPoint(Offset(r.left, r.bottom - e), radius: Radius.elliptical(r.width / 2, e))
        ..close();
    case NodeKind.nota:
      final c = min(16.0, r.shortestSide * 0.3);
      return Path()
        ..moveTo(r.left, r.top)
        ..lineTo(r.right - c, r.top)
        ..lineTo(r.right, r.top + c)
        ..lineTo(r.right, r.bottom)
        ..lineTo(r.left, r.bottom)
        ..close();
    case NodeKind.hexagono:
      final d = min(r.width * 0.2, r.height * 0.5);
      return Path()
        ..moveTo(r.left + d, r.top)
        ..lineTo(r.right - d, r.top)
        ..lineTo(r.right, r.center.dy)
        ..lineTo(r.right - d, r.bottom)
        ..lineTo(r.left + d, r.bottom)
        ..lineTo(r.left, r.center.dy)
        ..close();
  }
}

void _paintNode(Canvas canvas, FlowNode n, bool dark) {
  final color = ink(n.color, dark);
  final outline = nodeOutline(n);
  final r = n.retangulo;
  // The draw.io background when it came; otherwise, a very light border. A container stays almost transparent.
  final background = n.background == null
      ? color.withValues(alpha: n.type == NodeKind.container ? 0.04 : (dark ? 0.22 : 0.12))
      : (dark ? Color.lerp(n.background, const Color(0xFF1B1F1D), 0.55)! : n.background!);
  canvas.drawPath(outline, Paint()..color = background);
  final line = Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = n.type == NodeKind.container ? 1.2 : 2
    ..strokeJoin = StrokeJoin.round;
  canvas.drawPath(outline, line);
  switch (n.type) {
    case NodeKind.subprocesso:
      canvas.drawLine(Offset(r.left + 10, r.top), Offset(r.left + 10, r.bottom), line);
      canvas.drawLine(Offset(r.right - 10, r.top), Offset(r.right - 10, r.bottom), line);
    case NodeKind.banco:
      final e = min(r.height * 0.15, 14.0);
      canvas.drawArc(Rect.fromLTWH(r.left, r.top, r.width, e * 2), 0, pi, false, line);
    case NodeKind.nota:
      final c = min(16.0, r.shortestSide * 0.3);
      canvas.drawPath(
        Path()
          ..moveTo(r.right - c, r.top)
          ..lineTo(r.right - c, r.top + c)
          ..lineTo(r.right, r.top + c),
        line,
      );
    case NodeKind.container:
      canvas.drawLine(Offset(r.left, r.top + FlowNode.titleHeight), Offset(r.right, r.top + FlowNode.titleHeight), line);
    default:
  }
  final textColor = n.textColor != null ? ink(n.textColor!, dark) : ink(const Color(0xFF111111), dark);
  final estilo = TextStyle(
    color: textColor,
    fontSize: n.type == NodeKind.container ? 14 : 15,
    height: 1.2,
    fontWeight: n.type == NodeKind.container ? FontWeight.w600 : null,
  );
  if (n.type == NodeKind.container) {
    // Container/lane title at the top, on the left (like the draw.io swimlane).
    final t = TextPainter(
      text: formattedText(n.text, estilo, dark),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: max(20, r.width - 16));
    t.paint(canvas, Offset(r.left + 8, r.top + (FlowNode.titleHeight - t.height) / 2));
    return;
  }
  // Diamond, circle and hexagon have less usable area: the text is narrower.
  final narrow = n.type == NodeKind.decisao || n.type == NodeKind.circulo || n.type == NodeKind.hexagono;
  final width = n.esquerda ? r.width - 16 : r.width * (narrow ? 0.62 : 0.82);
  final text = TextPainter(
    text: formattedText(n.text, estilo, dark),
    textAlign: n.type == NodeKind.nota || n.esquerda ? TextAlign.left : TextAlign.center,
    textDirection: TextDirection.ltr,
    maxLines: max(1, (r.height * 0.9 / 18).floor()),
    ellipsis: '…',
  )..layout(maxWidth: max(20, width));
  final pos = switch (n) {
    _ when n.type == NodeKind.nota => Offset(r.left + 8, r.top + 8),
    _ when n.esquerda => Offset(r.left + 8, r.center.dy - text.height / 2),
    _ => r.center - Offset(text.width / 2, text.height / 2),
  };
  text.paint(canvas, pos);
}

/// Pieces of [stroke] with [gap] between them (near-zero stroke + round cap = dotted).
void _dashed(Canvas canvas, Offset a, Offset b, Paint brush, {double stroke = 8, double gap = 8}) {
  final d = b - a, total = d.distance;
  if (total == 0) return;
  final u = d / total;
  for (var t = 0.0; t < total; t += stroke + gap) {
    canvas.drawLine(a + u * t, a + u * min(t + stroke, total), brush);
  }
}

void _paintConnector(Canvas canvas, Connector l, bool dark) {
  final color = ink(l.color, dark);
  final brush = Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = l.thickness
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final c = l.path;
  if (l.line == LineKind.continua) {
    final stroke = Path()..moveTo(c.first.dx, c.first.dy);
    for (final p in c.skip(1)) {
      stroke.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(stroke, brush);
  } else {
    final pontilhada = l.line == LineKind.pontilhada;
    for (var i = 0; i < c.length - 1; i++) {
      _dashed(
        canvas,
        c[i],
        c[i + 1],
        brush,
        stroke: pontilhada ? 0.01 : 4 + l.thickness * 2,
        gap: pontilhada ? l.thickness * 2.5 + 2 : 4 + l.thickness * 2,
      );
    }
  }
  final fim = c.last - c[c.length - 2], inicio = c.first - c[1];
  if (fim.distance > 1) _paintTip(canvas, l.b, fim.direction, l.endTip, color, l.thickness, dark);
  if (inicio.distance > 1) _paintTip(canvas, l.a, inicio.direction, l.startTip, color, l.thickness, dark);
  if (l.label.isEmpty) return;
  final text = TextPainter(
    text: TextSpan(
      text: l.label,
      style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final box = Rect.fromCenter(center: l.middle, width: text.width + 10, height: text.height + 4);
  canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(4)), Paint()..color = bgColor(dark));
  text.paint(canvas, box.topLeft + const Offset(5, 2));
}

/// Figure at the arrow tip [p], pointing at angle [dir]; the hollow ones paint the background inside.
void _paintTip(Canvas canvas, Offset p, double dir, TipKind type, Color color, double thickness, bool dark) {
  if (type == TipKind.nenhuma) return;
  final t = 10 + thickness * 1.5;
  Offset em(double ang, double r) => p + Offset(cos(dir + ang) * r, sin(dir + ang) * r);
  final filled = Paint()..color = color;
  final outline = Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = max(1.5, thickness * 0.8)
    ..strokeJoin = StrokeJoin.round
    ..strokeCap = StrokeCap.round;
  final empty = Paint()..color = bgColor(dark);
  switch (type) {
    case TipKind.seta || TipKind.setaVazada:
      final f = Path()
        ..moveTo(p.dx, p.dy)
        ..lineTo(em(pi - pi / 8, t).dx, em(pi - pi / 8, t).dy)
        ..lineTo(em(pi + pi / 8, t).dx, em(pi + pi / 8, t).dy)
        ..close();
      if (type == TipKind.seta) {
        canvas.drawPath(f, filled);
      } else {
        canvas.drawPath(f, empty);
        canvas.drawPath(f, outline);
      }
    case TipKind.aberta:
      canvas.drawLine(p, em(pi - pi / 7, t), outline);
      canvas.drawLine(p, em(pi + pi / 7, t), outline);
    case TipKind.circulo || TipKind.circuloVazado:
      final r = t * 0.4, center = em(pi, r);
      if (type == TipKind.circulo) {
        canvas.drawCircle(center, r, filled);
      } else {
        canvas.drawCircle(center, r, empty);
        canvas.drawCircle(center, r, outline);
      }
    case TipKind.losango || TipKind.losangoVazado:
      final middle = em(pi, t * 0.6), side = t * 0.35;
      final f = Path()
        ..moveTo(p.dx, p.dy)
        ..lineTo(middle.dx + cos(dir + pi / 2) * side, middle.dy + sin(dir + pi / 2) * side)
        ..lineTo(em(pi, t * 1.2).dx, em(pi, t * 1.2).dy)
        ..lineTo(middle.dx + cos(dir - pi / 2) * side, middle.dy + sin(dir - pi / 2) * side)
        ..close();
      if (type == TipKind.losango) {
        canvas.drawPath(f, filled);
      } else {
        canvas.drawPath(f, empty);
        canvas.drawPath(f, outline);
      }
    case TipKind.nenhuma:
  }
}

TextPainter textPainter(BoardText t, bool dark) => TextPainter(
  text: formattedText(t.text, TextStyle(color: ink(t.color, dark), fontSize: t.size, height: 1.25), dark),
  textDirection: TextDirection.ltr,
)..layout();

final _marks = RegExp(r'(\*\*|__|==|\*)');

/// Light markup inside the text: `**bold**`, `*italic*`, `__underline__` and `==highlighter==`
/// (yellow background). A mark without a pair stays as text.
TextSpan formattedText(String text, TextStyle base, bool dark) {
  final openItems = <String>{};
  final pieces = <TextSpan>[];
  var rest = text;
  // Only a mark with a pair further ahead counts as a mark; otherwise it becomes plain text.
  while (rest.isNotEmpty) {
    final m = _marks.firstMatch(rest);
    if (m == null) {
      pieces.add(TextSpan(text: rest, style: _style(base, openItems, dark)));
      break;
    }
    final mark = m.group(0)!;
    final closes = openItems.contains(mark) || rest.indexOf(mark, m.end) >= 0;
    if (m.start > 0) pieces.add(TextSpan(text: rest.substring(0, m.start), style: _style(base, openItems, dark)));
    if (closes) {
      openItems.contains(mark) ? openItems.remove(mark) : openItems.add(mark);
    } else {
      pieces.add(TextSpan(text: mark, style: _style(base, openItems, dark)));
    }
    rest = rest.substring(m.end);
  }
  return TextSpan(style: base, children: pieces);
}

TextStyle _style(TextStyle base, Set<String> marks, bool dark) => base.copyWith(
  fontWeight: marks.contains('**') ? FontWeight.bold : null,
  fontStyle: marks.contains('*') ? FontStyle.italic : null,
  decoration: marks.contains('__') ? TextDecoration.underline : null,
  backgroundColor: marks.contains('==') ? const Color(0xFFFFE066).withValues(alpha: dark ? 0.45 : 0.9) : null,
  color: marks.contains('==') && !dark ? const Color(0xFF111111) : null,
);

/// Text without the marks (to measure and for the title).
String noMarks(String text) => text.replaceAll(_marks, '');

/// Background (dots, grid, lines) drawn on screen, following the camera.
void paintBackground(Canvas canvas, Size size, Background background, Camera camera, bool dark) {
  canvas.drawRect(Offset.zero & size, Paint()..color = bgColor(dark));
  if (background == Background.liso) return;
  var step = 32 * camera.scale;
  while (step < 12) {
    step *= 4; // too far: spaces out the grid so it does not become a blur
  }
  final color = (dark ? Colors.white : Colors.black).withValues(alpha: background == Background.pontos ? 0.22 : 0.08);
  final brush = Paint()
    ..color = color
    ..strokeWidth = background == Background.pontos ? max(1.5, camera.scale * 1.5) : 1
    ..strokeCap = StrokeCap.round;
  final x0 = camera.offset.dx % step, y0 = camera.offset.dy % step;
  switch (background) {
    case Background.pontos:
      final pontos = <Offset>[
        for (var x = x0; x < size.width; x += step)
          for (var y = y0; y < size.height; y += step) Offset(x, y),
      ];
      canvas.drawPoints(PointMode.points, pontos, brush);
    case Background.grade:
      for (var x = x0; x < size.width; x += step) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), brush);
      }
      for (var y = y0; y < size.height; y += step) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), brush);
      }
    case Background.linhas:
      for (var y = y0; y < size.height; y += step) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), brush);
      }
    case Background.liso:
      break;
  }
}

/// Notebook: the desk around and the sheet ([paper], from (0,0) to width × height in the world) with its
/// ruling, red margin and the header line, following the camera.
void paintPaper(Canvas canvas, Size size, Paper role, Camera camera, bool dark) {
  canvas.drawRect(Offset.zero & size, Paint()..color = dark ? const Color(0xFF101312) : const Color(0xFFE4E6E3));
  final sheet = Rect.fromPoints(camera.toScreen(Offset.zero), camera.toScreen(Offset(role.width, role.height)));
  canvas.drawRect(
    sheet.shift(const Offset(0, 2)),
    Paint()
      ..color = Colors.black.withValues(alpha: 0.18)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
  );
  final color = dark ? Color.lerp(role.color, const Color(0xFF1B1F1D), 0.88)! : role.color;
  canvas.drawRect(sheet, Paint()..color = color);
  final step = role.space * camera.scale;
  if (step < 4) return; // too far: the ruling becomes a blur
  final ink = dark ? Colors.white : const Color(0xFF3A5A8C);
  canvas
    ..save()
    ..clipRect(sheet);
  final top = sheet.top + (role.margin ? step * 3 : step);
  final esquerda = sheet.left + role.indent * camera.scale;
  final brush = Paint()
    ..color = ink.withValues(alpha: role.background == Background.pontos ? 0.35 : 0.22)
    ..strokeWidth = role.background == Background.pontos ? max(1.6, camera.scale * 1.6) : max(0.6, camera.scale * 0.8)
    ..strokeCap = StrokeCap.round;
  // Starts at the first visible step (a big zoom does not walk the whole sheet).
  double inicio(double base, double min) => base + max(0, ((min - base) / step).floor()) * step;
  final yMax = min(sheet.bottom, size.height), xMax = min(sheet.right, size.width);
  switch (role.background) {
    case Background.linhas:
      for (var y = inicio(top, 0); y < yMax; y += step) {
        canvas.drawLine(Offset(max(sheet.left, 0), y), Offset(xMax, y), brush);
      }
    case Background.grade:
      for (var y = inicio(sheet.top + step, 0); y < yMax; y += step) {
        canvas.drawLine(Offset(max(sheet.left, 0), y), Offset(xMax, y), brush);
      }
      for (var x = inicio(sheet.left + step, 0); x < xMax; x += step) {
        canvas.drawLine(Offset(x, max(sheet.top, 0)), Offset(x, yMax), brush);
      }
    case Background.pontos:
      canvas.drawPoints(PointMode.points, [
        for (var x = inicio(sheet.left + step, 0); x < xMax; x += step)
          for (var y = inicio(sheet.top + step, 0); y < yMax; y += step) Offset(x, y),
      ], brush);
    case Background.liso:
      break;
  }
  if (role.margin) {
    final red = Paint()
      ..color = const Color(0xFFE57373).withValues(alpha: 0.7)
      ..strokeWidth = max(0.8, camera.scale);
    canvas.drawLine(Offset(esquerda, sheet.top), Offset(esquerda, sheet.bottom), red);
    if (role.background != Background.linhas) {
      canvas.drawLine(Offset(sheet.left, top - step), Offset(sheet.right, top - step), red);
    }
  }
  canvas.restore();
}

/// Whole board: background and visible elements (what is off screen is not even drawn).
class BoardPainter extends CustomPainter {
  BoardPainter({
    required this.elements,
    required this.camera,
    required this.background,
    required this.dark,
    this.hiddenItems = const {},
    this.role,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final List<Elemento> elements;
  final Camera camera;
  final Background background;
  final bool dark;

  /// Notebook: sheet in place of the infinite background.
  final Paper? role;

  /// Elements being dragged: the [LivePainter] draws the moving version.
  final Set<String> hiddenItems;

  @override
  void paint(Canvas canvas, Size size) {
    role == null ? paintBackground(canvas, size, background, camera, dark) : paintPaper(canvas, size, role!, camera, dark);
    final visible = Rect.fromPoints(camera.toWorld(Offset.zero), camera.toWorld(size.bottomRight(Offset.zero)));
    canvas
      ..save()
      ..translate(camera.offset.dx, camera.offset.dy)
      ..scale(camera.scale);
    for (final e in elements) {
      if (!hiddenItems.contains(e.id) && e.bounds.overlaps(visible)) paintElement(canvas, e, dark: dark);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(BoardPainter old) =>
      old.elements != elements || old.background != background || old.role != role || old.dark != dark || old.hiddenItems != hiddenItems;
}

List<Offset> cantos(Rect r) => [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft];

/// What is being done right now: element under construction, laser trail and the eraser ring.
class LivePainter extends CustomPainter {
  LivePainter({
    required this.live,
    required this.laser,
    required this.camera,
    required this.dark,
    this.eraser,
    required this.dragged,
    required this.lasso,
    required this.box,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final Elemento? Function() live;
  final List<Elemento> Function() dragged;
  final List<Offset> Function() lasso;
  final Rect? Function() box;
  final List<(Offset, DateTime)> Function() laser;
  final Camera camera;
  final bool dark;
  final (Offset, double)? Function()? eraser;

  static const laserDuration = Duration(milliseconds: 700);

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..translate(camera.offset.dx, camera.offset.dy)
      ..scale(camera.scale);
    final e = live();
    if (e != null) paintElement(canvas, e, dark: dark);
    for (final a in dragged()) {
      paintElement(canvas, a, dark: dark);
    }
    canvas.restore();

    final highlight = Paint()
      ..color = const Color(0xFF2979FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final lassoPoints = lasso();
    if (lassoPoints.length > 1) {
      canvas.drawPath(
        Path()..addPolygon([for (final p in lassoPoints) camera.toScreen(p)], true),
        Paint()..color = const Color(0x222979FF),
      );
      canvas.drawPath(Path()..addPolygon([for (final p in lassoPoints) camera.toScreen(p)], false), highlight);
    }
    final r = box();
    if (r != null) {
      final screen = Rect.fromPoints(camera.toScreen(r.topLeft), camera.toScreen(r.bottomRight));
      canvas.drawRect(screen, highlight);
      for (final canto in cantos(screen)) {
        canvas
          ..drawRect(Rect.fromCenter(center: canto, width: 12, height: 12), Paint()..color = Colors.white)
          ..drawRect(Rect.fromCenter(center: canto, width: 12, height: 12), highlight);
      }
    }

    final trail = laser();
    final now = DateTime.now();
    for (var i = 1; i < trail.length; i++) {
      final age = now.difference(trail[i].$2).inMilliseconds / laserDuration.inMilliseconds;
      if (age >= 1) continue;
      canvas.drawLine(
        camera.toScreen(trail[i - 1].$1),
        camera.toScreen(trail[i].$1),
        Paint()
          ..color = const Color(0xFFFF1744).withValues(alpha: 1 - age)
          ..strokeWidth = 6 * (1 - age) + 2
          ..strokeCap = StrokeCap.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 3),
      );
    }

    final ring = eraser?.call();
    if (ring != null) {
      canvas.drawCircle(
        camera.toScreen(ring.$1),
        ring.$2 * camera.scale,
        Paint()
          ..color = (dark ? Colors.white : Colors.black).withValues(alpha: 0.4)
          ..style = PaintingStyle.stroke,
      );
    }
  }

  @override
  bool shouldRepaint(LivePainter old) => true;
}
