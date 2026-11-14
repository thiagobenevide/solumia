import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models.dart';
import '../screens/chart.dart' show signalColors;
import 'editor.dart';

/// Sheet camera: screen = world (µm) × [scale] + [offset]. 0.02 px/µm ≈ 25 px per grid.
class Camera {
  Offset offset = const Offset(400, 300);
  double scale = 0.02;

  static const minimum = 0.002, maximum = 1.0;

  Offset toWorld(Offset screen) => (screen - offset) / scale;

  Offset toScreen(Offset world) => world * scale + offset;

  void zoom(double factor, Offset focus) {
    final world = toWorld(focus);
    scale = (scale * factor).clamp(minimum, maximum);
    offset = focus - world * scale;
  }

  void frame(Rect? area, Size screen) {
    if (area == null || area.isEmpty || screen.isEmpty) {
      scale = 0.02;
      offset = screen.center(Offset.zero);
      return;
    }
    scale = min(screen.width / area.width, screen.height / area.height).clamp(minimum, 0.08) * 0.85;
    offset = screen.center(Offset.zero) - area.center * scale;
  }
}

/// Schematic colors: dark on screen, light (paper) on export.
class Palette {
  const Palette({
    required this.background,
    required this.grade,
    required this.body,
    required this.fill,
    required this.pin,
    required this.wire,
    required this.junction,
    required this.label,
    required this.text,
    required this.field,
    required this.selection,
    required this.preview,
  });

  final Color background, grade, body, fill, pin, wire, junction, label, text, field, selection, preview;

  static const dark = Palette(
    background: Color(0xFF14161A),
    grade: Color(0xFF3A3F47),
    body: Color(0xFFE0A050),
    fill: Color(0x33E0A050),
    pin: Color(0xFFD06060),
    wire: Color(0xFF4CC38A),
    junction: Color(0xFF4CC38A),
    label: Color(0xFF6FA8FF),
    text: Color(0xFFDADDE2),
    field: Color(0xFFB0B6BF),
    selection: Color(0xFFFFE066),
    preview: Color(0x99FFFFFF),
  );

  static const role = Palette(
    background: Color(0xFFFFFFFF),
    grade: Color(0xFFDDDDDD),
    body: Color(0xFF8A1C1C),
    fill: Color(0x22F2D7A0),
    pin: Color(0xFF8A1C1C),
    wire: Color(0xFF1B6E3A),
    junction: Color(0xFF1B6E3A),
    label: Color(0xFF1B3F8A),
    text: Color(0xFF222222),
    field: Color(0xFF444444),
    selection: Color(0xFFE08A00),
    preview: Color(0x88000000),
  );
}

const _trace = 160.0; // line thickness in µm (~0.15 mm)

void _text(Canvas canvas, String s, Offset pos, double size, Color color, {TextAlign align = TextAlign.center}) {
  if (s.isEmpty) return;
  final tp = TextPainter(
    text: TextSpan(text: s, style: TextStyle(fontSize: size, color: color, fontFamily: 'monospace', height: 1)),
    textDirection: TextDirection.ltr,
  )..layout();
  final dx = switch (align) {
    TextAlign.left => 0.0,
    TextAlign.right => -tp.width,
    _ => -tp.width / 2,
  };
  tp.paint(canvas, pos + Offset(dx, -tp.height / 2));
}

/// Draws [s] at [pos] with rotation and mirror; texts always stay upright. [highlight] swaps the colors.
void paintSymbol(
  Canvas canvas,
  Symbol s, {
  required P pos,
  int rot = 0,
  bool mirrored = false,
  String ref = '',
  String value = '',
  required Palette palette,
  Color? highlight,
  bool fields = true,
}) {
  P world(P local) => pos + transform(local, rot, mirrored);
  final body = Paint()
    ..color = highlight ?? palette.body
    ..strokeWidth = _trace
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final full = Paint()..color = highlight ?? palette.body;

  canvas
    ..save()
    ..translate(pos.x.toDouble(), pos.y.toDouble())
    ..rotate(rot * pi / 180)
    ..scale(mirrored ? -1 : 1, 1);
  for (final d in s.drawing) {
    switch (d['t']) {
      case 'linha':
        final pts = [for (final q in d['p'] as List) P.json(q as List).offset];
        final path = Path()..addPolygon(pts, d['fechada'] == true);
        canvas.drawPath(path, d['cheia'] == true ? full : body);
      case 'ret':
        final r = Rect.fromPoints(P.json(d['a'] as List).offset, P.json(d['b'] as List).offset);
        canvas.drawRect(r, d['cheio'] == true ? full : (Paint()..color = highlight?.withValues(alpha: 0.15) ?? palette.fill));
        canvas.drawRect(r, body);
      case 'circ':
        canvas.drawCircle(P.json(d['c'] as List).offset, (d['r'] as num).toDouble(), d['cheio'] == true ? full : body);
      case 'arco':
        final c = P.json(d['c'] as List).offset, r = (d['r'] as num).toDouble();
        canvas.drawArc(
          Rect.fromCircle(center: c, radius: r),
          (d['ini'] as num) * pi / 180,
          (d['var'] as num) * pi / 180,
          false,
          body,
        );
    }
  }
  final leg = Paint()
    ..color = highlight ?? palette.pin
    ..strokeWidth = _trace
    ..strokeCap = StrokeCap.round;
  for (final p in s.pins) {
    if (p.comp > 0 && !p.hidden) canvas.drawLine(p.pos.offset, p.end.offset, leg);
  }
  canvas.restore();

  // Upright texts, at the already transformed positions.
  for (final d in s.drawing) {
    if (d['t'] == 'texto') _text(canvas, d['s'] as String, world(P.json(d['p'] as List)).offset, 1100, highlight ?? palette.body);
  }
  if (s.pinNames || s.pinNumbers) {
    for (final p in s.pins) {
      if (p.hidden) continue;
      final dir = transform(p.dir.vector, rot, mirrored);
      final end = world(p.end).offset;
      if (s.pinNames) {
        final align = dir.x > 0 ? TextAlign.left : (dir.x < 0 ? TextAlign.right : TextAlign.center);
        final inside = end + Offset(dir.x * 400.0, dir.y * 900.0);
        _text(canvas, p.name, inside, 900, highlight ?? palette.field, align: align);
      }
      if (s.pinNumbers) {
        final middle = (world(p.pos).offset + end) / 2;
        final fora = dir.x != 0 ? const Offset(0, -500) : const Offset(-500, 0);
        _text(canvas, p.n, middle + fora, 700, highlight ?? palette.pin);
      }
    }
  }
  if (fields) {
    if (!s.supply) _text(canvas, ref, world(s.refField).offset, 1100, highlight ?? palette.field);
    _text(canvas, value, world(s.valueField).offset, 1100, highlight ?? palette.field);
  }
}

/// Draws the [editor]'s open sheet in world coordinates (the canvas already comes with the camera applied).
void paintSheet(Canvas canvas, Editor editor, Palette palette, {bool withSelection = true}) {
  final hidden = editor.hidden;
  final sel = withSelection ? editor.selection : const <String>{};
  if (!hidden.contains(Layer.wires)) {
    for (final f in editor.wires) {
      final color = sel.contains(f.id) ? palette.selection : palette.wire;
      canvas.drawPath(
        Path()..addPolygon([for (final p in f.points) p.offset], false),
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = _trace * 1.2
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
    }
    final dot = Paint()..color = palette.junction;
    for (final j in juncoes(editor.wires, editor.sheetPins())) {
      canvas.drawCircle(j.offset, 420, dot);
    }
  }
  if (!hidden.contains(Layer.components)) {
    for (final c in editor.components) {
      paintSymbol(
        canvas,
        editor.symbolOf(c),
        pos: c.pos,
        rot: c.rot,
        mirrored: c.mirrored,
        ref: c.ref,
        value: c.value,
        palette: palette,
        highlight: sel.contains(c.id) ? palette.selection : null,
        fields: !hidden.contains(Layer.fields),
      );
    }
  }
  if (!hidden.contains(Layer.labels)) {
    for (final r in editor.labels) {
      final color = sel.contains(r.id) ? palette.selection : palette.label;
      final o = r.pos.offset;
      canvas.drawPath(
        Path()..addPolygon([o, o + const Offset(400, -700), o + Offset(r.name.length * 800.0 + 600, -700)], false),
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = _trace,
      );
      _text(canvas, r.name, o + const Offset(500, -1250), 1100, color, align: TextAlign.left);
    }
  }
  if (!hidden.contains(Layer.probes)) {
    for (final s in editor.probes) {
      final i = editor.probeIndex(s);
      final color = signalColors[i.clamp(0, signalColors.length - 1)];
      final tip = s.pos.offset, cable = tip + const Offset(1500, -1500);
      canvas
        ..drawLine(tip, cable, Paint()
          ..color = sel.contains(s.id) ? palette.selection : color
          ..strokeWidth = 380
          ..strokeCap = StrokeCap.round)
        ..drawCircle(cable, 650, Paint()..color = sel.contains(s.id) ? palette.selection : color)
        ..drawCircle(tip, 220, Paint()..color = palette.background);
      final name = s.type == 'v' ? 'V${i + 1}' : 'I ${s.ref}';
      final reading = editor.readings[s.id];
      _text(canvas, reading == null ? name : '$name = $reading', cable + const Offset(950, 0), 1100, palette.text,
          align: TextAlign.left);
    }
  }
  if (!hidden.contains(Layer.texts)) {
    for (final t in editor.texts) {
      _text(canvas, t.text, t.pos.offset + Offset(0, -t.size / 2), t.size.toDouble(),
          sel.contains(t.id) ? palette.selection : palette.text, align: TextAlign.left);
    }
  }
}

/// Dotted grid; coarsens the step while it is too tight on screen.
void paintGrid(Canvas canvas, Size screen, Camera camera, int step, Palette palette) {
  var p = step.toDouble();
  while (p * camera.scale < 10) {
    p *= 5;
  }
  final a = camera.toWorld(Offset.zero), b = camera.toWorld(Offset(screen.width, screen.height));
  final pts = <Offset>[];
  for (var x = (a.dx / p).floor() * p; x <= b.dx; x += p) {
    for (var y = (a.dy / p).floor() * p; y <= b.dy; y += p) {
      pts.add(camera.toScreen(Offset(x, y)));
    }
  }
  canvas.drawPoints(
    ui.PointMode.points,
    pts,
    Paint()
      ..color = palette.grade
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round,
  );
  // Axes at the origin, for orientation.
  final o = camera.toScreen(Offset.zero);
  final axis = Paint()
    ..color = palette.grade
    ..strokeWidth = 1;
  canvas
    ..drawLine(o - const Offset(12, 0), o + const Offset(12, 0), axis)
    ..drawLine(o - const Offset(0, 12), o + const Offset(0, 12), axis);
}

/// Bounds of everything on the sheet (to frame and export).
Rect? sheetBounds(Editor editor) {
  Rect? r;
  void sum(Rect x) => r = r == null ? x : r!.expandToInclude(x);
  for (final c in editor.components) {
    sum(c.bounds(editor.symbolOf(c)).inflate(1500));
  }
  for (final f in editor.wires) {
    for (final p in f.points) {
      sum(Rect.fromCircle(center: p.offset, radius: 500));
    }
  }
  for (final x in editor.labels) {
    sum(Rect.fromLTWH(x.pos.x.toDouble(), x.pos.y - 1500.0, x.name.length * 800.0 + 800, 1600));
  }
  for (final s in editor.probes) {
    sum(Rect.fromPoints(s.pos.offset, s.pos.offset + const Offset(9000, -2500)));
  }
  for (final t in editor.texts) {
    sum(Rect.fromLTWH(t.pos.x.toDouble(), t.pos.y - t.size.toDouble(), t.text.length * t.size * 0.62, t.size * 1.4));
  }
  return r;
}

/// Paints the sheet on screen: grid, items, tool preview, wire in progress, cursor and selection window.
class CadPainter extends CustomPainter {
  CadPainter(this.editor, this.camera, {this.window, required this.palette}) : super(repaint: editor);

  final Editor editor;
  final Camera camera;
  final Rect? window;
  final Palette palette;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = palette.background);
    if (!editor.hidden.contains(Layer.grade)) paintGrid(canvas, size, camera, editor.step, palette);
    canvas
      ..save()
      ..translate(camera.offset.dx, camera.offset.dy)
      ..scale(camera.scale);
    paintSheet(canvas, editor, palette);

    final cursor = editor.cursor;
    final s = editor.symbol;
    if (cursor != null && editor.tool == Tool.component && s != null) {
      paintSymbol(
        canvas,
        s,
        pos: cursor,
        rot: editor.previewRotation,
        mirrored: editor.previewMirror,
        ref: '${s.prefix}?',
        value: s.value,
        palette: palette,
        highlight: palette.preview,
      );
    }
    final wire = editor.wire;
    if (wire != null) {
      final pts = [...wire, if (cursor != null) ...orthogonalRoute(wire.last, cursor, horizontalFirst: editor.horizontalFirst).skip(1)];
      canvas.drawPath(
        Path()..addPolygon([for (final p in pts) p.offset], false),
        Paint()
          ..color = palette.wire.withValues(alpha: 0.7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = _trace * 1.2,
      );
    }
    if (cursor != null && editor.tool != Tool.select) {
      final cruz = Paint()
        ..color = palette.preview
        ..strokeWidth = 1 / camera.scale;
      final t = 10 / camera.scale;
      final c = cursor.offset;
      canvas
        ..drawLine(c - Offset(t, 0), c + Offset(t, 0), cruz)
        ..drawLine(c - Offset(0, t), c + Offset(0, t), cruz);
      if (editor.isConnection(cursor)) {
        canvas.drawCircle(
          c,
          6 / camera.scale,
          Paint()
            ..color = palette.selection
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5 / camera.scale,
        );
      }
    }
    canvas.restore();

    final j = window;
    if (j != null) {
      final r = Rect.fromPoints(camera.toScreen(j.topLeft), camera.toScreen(j.bottomRight));
      canvas
        ..drawRect(r, Paint()..color = palette.selection.withValues(alpha: 0.08))
        ..drawRect(
          r,
          Paint()
            ..color = palette.selection
            ..style = PaintingStyle.stroke,
        );
    }
  }

  @override
  bool shouldRepaint(CadPainter old) => true;
}
