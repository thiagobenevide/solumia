import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'model.dart';

// Palette and sizes of the reference generator (`docs/wireframes-nd/_gerador/lib.py`).
const _background = Color(0xFFF3F4F6);
const _ink = Color(0xFF111827);
const _suave = Color(0xFF6B7280);
const _line = Color(0xFF9CA3AF);
const _clara = Color(0xFFE5E7EB);
const _white = Colors.white;
const _dark = Color(0xFF1F2937);

/// (strong, soft) of each named color.
const colors = <String, (Color, Color)>{
  'azul': (Color(0xFF2563EB), Color(0xFFDBEAFE)),
  'ambar': (Color(0xFFD97706), Color(0xFFFEF3C7)),
  'vermelho': (Color(0xFFDC2626), Color(0xFFFEE2E2)),
  'verde': (Color(0xFF059669), Color(0xFFD1FAE5)),
  'roxo': (Color(0xFF7C3AED), Color(0xFFEDE9FE)),
  'ciano': (Color(0xFF0891B2), Color(0xFFCFFAFE)),
  'cinza': (_suave, _clara),
};

(Color, Color) corDoEstado(WfState e) => switch (e) {
  WfState.existe => colors['azul']!,
  WfState.proposto => colors['ambar']!,
  WfState.divergencia => colors['vermelho']!,
};

Color _textColor(Object? name) => switch (name) {
  'suave' => _suave,
  'branco' => _white,
  final String n when colors.containsKey(n) => colors[n]!.$1,
  _ => _ink,
};

/// Artboard sizes: header, screen window (usable area below the title bar) and notes panel.
class Artboard {
  Artboard(this.screen);

  final WfScreen screen;
  static const header = 72.0, margin = 24.0, bar = 30.0, panelWidth = 586.0;

  Rect get window => Rect.fromLTWH(margin, header + 16, screen.width, screen.height + bar);

  /// Origem das coordenadas dos componentes.
  Offset get origin => window.topLeft + const Offset(0, bar);
  Rect get panel => Rect.fromLTWH(window.right + 20, window.top, panelWidth, window.height);
  Size get size => Size(panel.right + margin, window.bottom + margin);
}

/// PNG of the whole [screen] (header, window and notes), with the same painter as the editor; goes in the AI package.
Future<Uint8List> renderScreen(WfScreen screen, List<WfComponent> components) async {
  final size = Artboard(screen).size;
  final recorder = ui.PictureRecorder();
  WireframePainter(screen, components).paint(Canvas(recorder), size);
  final image = await recorder.endRecording().toImage(size.width.ceil(), size.height.ceil());
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

class WireframePainter extends CustomPainter {
  WireframePainter(this.screen, this.components, {this.selectedItem, this.version = 0});

  final WfScreen screen;
  final List<WfComponent> components;
  final String? selectedItem;

  /// Goes up on every change: the editor mutates the components in place.
  final int version;

  @override
  void paint(Canvas c, Size size) {
    final p = Artboard(screen);
    c.drawRect(Offset.zero & size, Paint()..color = _background);
    _header(c, size.width);
    _window(c, p);
    c.save();
    c.clipRect(Rect.fromPoints(p.origin, p.window.bottomRight));
    c.translate(p.origin.dx, p.origin.dy);
    for (final comp in components) {
      _component(c, comp, Size(screen.width, screen.height));
    }
    for (final comp in components) {
      if (comp.nota != null) _highlighter(c, comp.box.topLeft, comp.nota!, comp.state);
    }
    final sel = components.where((e) => e.id == selectedItem).firstOrNull;
    if (sel != null) {
      final blue = colors['azul']!.$1;
      c.drawRect(sel.box.inflate(2), Paint()..color = blue..style = PaintingStyle.stroke..strokeWidth = 1.5);
      c.drawRect(Rect.fromCenter(center: sel.box.bottomRight, width: 10, height: 10), Paint()..color = blue);
    }
    c.restore();
    _panel(c, p);
  }

  @override
  bool shouldRepaint(WireframePainter old) =>
      old.version != version || old.selectedItem != selectedItem || old.screen != screen || old.components != components;

  // ---------- basics ----------

  /// [anchor]: `la` (left/top), `lm` (left/middle) or `mm` (center). Returns the width.
  double _text(Canvas c, Offset o, String s, {double tam = 13, bool bold = false, Color color = _ink, bool mono = false, String anchor = 'la', double? max, bool wrap = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(fontSize: tam, fontWeight: bold ? FontWeight.bold : FontWeight.normal, color: color, fontFamily: mono ? 'monospace' : null),
      ),
      textDirection: TextDirection.ltr,
      maxLines: wrap ? null : 1,
      ellipsis: wrap ? null : '…',
    )..layout(maxWidth: max ?? double.infinity);
    final d = switch (anchor) {
      'mm' => Offset(-tp.width / 2, -tp.height / 2),
      'lm' => Offset(0, -tp.height / 2),
      _ => Offset.zero,
    };
    tp.paint(c, o + d);
    return tp.width;
  }

  double _width(String s, double tam, {bool bold = true}) =>
      (TextPainter(
        text: TextSpan(text: s, style: TextStyle(fontSize: tam, fontWeight: bold ? FontWeight.bold : null)),
        textDirection: TextDirection.ltr,
      )..layout()).width;

  void _rect(Canvas c, Rect r, {Color background = _white, Color edge = _line, double esp = 1, double radius = 6}) {
    final rr = RRect.fromRectAndRadius(r, Radius.circular(radius));
    c.drawRRect(rr, Paint()..color = background);
    if (esp > 0) c.drawRRect(rr, Paint()..color = edge..style = PaintingStyle.stroke..strokeWidth = esp);
  }

  void _dashed(Canvas c, Rect r, Color color, {double esp = 2}) {
    final ink = Paint()..color = color..strokeWidth = esp;
    void side(Offset a, Offset b) {
      final total = (b - a).distance;
      for (var t = 0.0; t < total; t += 13) {
        c.drawLine(a + (b - a) * (t / total), a + (b - a) * (math.min(t + 8, total) / total), ink);
      }
    }

    side(r.topLeft, r.topRight);
    side(r.bottomLeft, r.bottomRight);
    side(r.topLeft, r.bottomLeft);
    side(r.topRight, r.bottomRight);
  }

  void _highlighter(Canvas c, Offset o, int n, WfState e) {
    c.drawCircle(o, 13, Paint()..color = corDoEstado(e).$1);
    c.drawCircle(o, 13, Paint()..color = _white..style = PaintingStyle.stroke..strokeWidth = 2);
    _text(c, o, '$n', bold: true, color: _white, anchor: 'mm');
  }

  // ---------- moldura ----------

  void _header(Canvas c, double w) {
    c.drawRect(Rect.fromLTWH(0, 0, w, Artboard.header), Paint()..color = _dark);
    final title = [screen.code, screen.name].where((s) => s.isNotEmpty).join('  ·  ');
    _text(c, const Offset(24, 12), title, tam: 22, bold: true, color: _white);
    _text(c, const Offset(24, 44), screen.subtitle, color: const Color(0xFFD1D5DB));
    var x = w - 24;
    for (final e in WfState.values.reversed) {
      final (color, suave) = corDoEstado(e);
      final label = e.label.toUpperCase();
      final lw = _width(label, 12) + 44;
      x -= lw;
      _rect(c, Rect.fromLTWH(x, 22, lw - 8, 26), background: suave, edge: color, radius: 12);
      c.drawCircle(Offset(x + 14, 35), 6, Paint()..color = color);
      _text(c, Offset(x + 25, 28), label, tam: 12, bold: true, color: color);
      x -= 6;
    }
  }

  void _window(Canvas c, Artboard p) {
    final j = p.window;
    _rect(c, j, radius: 10);
    c.drawRRect(
      RRect.fromRectAndCorners(Rect.fromLTWH(j.left, j.top, j.width, Artboard.bar), topLeft: const Radius.circular(10), topRight: const Radius.circular(10)),
      Paint()..color = _clara,
    );
    for (final (i, color) in const [Color(0xFFEF4444), Color(0xFFF59E0B), Color(0xFF10B981)].indexed) {
      c.drawCircle(Offset(j.left + 20 + i * 18, j.top + 15), 6, Paint()..color = color);
    }
    _text(c, Offset(j.left + 80, j.top + 8), screen.path.join('  ›  '), tam: 12, color: _suave);
  }

  void _panel(Canvas c, Artboard p) {
    final r = p.panel;
    _rect(c, r, radius: 10);
    _text(c, Offset(r.left + 18, r.top + 14), 'Componentes · cliques · endpoints', tam: 15, bold: true);
    c.drawLine(Offset(r.left, r.top + 44), Offset(r.right, r.top + 44), Paint()..color = _clara);
    var y = r.top + 58;
    final inner = r.width - 70;
    for (final n in screen.notas) {
      final color = corDoEstado(n.state).$1;
      _highlighter(c, Offset(r.left + 30, y + 10), n.n, n.state);
      y += _paragraph(c, Offset(r.left + 52, y), n.title, inner, tam: 13, bold: true, color: n.state == WfState.existe ? _ink : color) + 4;
      for (final (label, text) in n.linhas) {
        y += _paragraph(c, Offset(r.left + 52, y), text, inner, label: label, color: label.isEmpty ? _suave : _ink);
      }
      y += 12;
    }
  }

  double _paragraph(Canvas c, Offset o, String s, double max, {String label = '', double tam = 11, bool bold = false, Color color = _ink}) {
    final tp = TextPainter(
      text: TextSpan(
        children: [
          if (label.isNotEmpty) TextSpan(text: '$label ', style: const TextStyle(fontWeight: FontWeight.bold, color: _suave)),
          TextSpan(text: s),
        ],
        style: TextStyle(fontSize: tam, fontWeight: bold ? FontWeight.bold : null, color: color, height: 1.3),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: max);
    tp.paint(c, o);
    return tp.height;
  }

  // ---------- componentes ----------

  void _component(Canvas c, WfComponent comp, Size area) {
    final r = comp.box, p = comp.props;
    String s(String k) => '${p[k] ?? ''}';
    bool b(String k) => p[k] == true;
    List<Map> items(String k) => [for (final i in p[k] as List? ?? const []) if (i is Map) i];
    switch (comp.type) {
      case 'texto':
        _text(c, r.topLeft, s('texto'), tam: (p['tamanho'] as num? ?? 13).toDouble(), bold: b('negrito'), mono: b('mono'), color: _textColor(p['cor']), max: math.max(r.width, 1), wrap: true);
      case 'botao':
        final (background, text, edge) = switch (p['variante']) {
          'secundario' => (_white, _ink, _line),
          'perigo' => (colors['vermelho']!.$1, _white, colors['vermelho']!.$1),
          'sucesso' => (colors['verde']!.$1, _white, colors['verde']!.$1),
          'fantasma' => (_white, _suave, _clara),
          _ => (colors['azul']!.$1, _white, colors['azul']!.$1),
        };
        _rect(c, r, background: background, edge: edge);
        _text(c, r.center, '${s('icone')} ${s('texto')}'.trim(), bold: true, color: text, anchor: 'mm');
      case 'botao_icone':
        _rect(c, r);
        _text(c, r.center, s('icone'), tam: 15, bold: true, color: _suave, anchor: 'mm');
      case 'campo':
        _text(c, r.topLeft, s('rotulo') + (b('obrigatorio') ? ' *' : ''), tam: 11, bold: true, color: _suave);
        final box = Rect.fromLTRB(r.left, r.top + 16, r.right, math.max(r.bottom, r.top + 30));
        _rect(c, box, background: b('somente_leitura') ? _clara : _white, radius: 5);
        _text(c, box.topLeft + const Offset(8, 7), s('valor'), tam: 12, color: b('somente_leitura') ? _suave : _ink, max: math.max(box.width - 50, 1));
        if (b('busca')) {
          final blue = colors['azul']!;
          _text(c, Offset(box.right - 40, box.top + 7), '✕', tam: 12, color: _suave);
          _rect(c, Rect.fromLTWH(box.right - 24, box.top + 4, 20, box.height - 8), background: blue.$2, edge: blue.$2, radius: 4);
          _text(c, Offset(box.right - 14, box.center.dy), '⌕', tam: 14, bold: true, color: blue.$1, anchor: 'mm');
        }
        if (b('combo')) _text(c, Offset(box.right - 16, box.center.dy), '▾', bold: true, color: _suave, anchor: 'mm');
      case 'caixa':
        final blue = colors['azul']!.$1;
        final q = Rect.fromLTWH(r.left, r.center.dy - 7, 14, 14);
        _rect(c, q, background: b('marcado') ? blue : _white, edge: b('marcado') ? blue : _line, radius: 3);
        if (b('marcado')) _text(c, q.center, '✓', tam: 11, bold: true, color: _white, anchor: 'mm');
        _text(c, Offset(r.left + 22, r.center.dy), s('texto'), tam: 12, anchor: 'lm');
      case 'selo':
        final (color, suave) = colors[p['cor']] ?? colors['azul']!;
        _rect(c, r, background: suave, edge: color, radius: r.height / 2);
        _text(c, r.center, s('texto'), tam: 11, bold: true, color: color, anchor: 'mm');
      case 'abas':
        final blue = colors['azul']!;
        c.drawLine(Offset(r.left, r.top + 34), Offset(r.right, r.top + 34), Paint()..color = _clara..strokeWidth = 2);
        var x = r.left;
        for (final (i, item) in items('itens').indexed) {
          final label = '${item['texto'] ?? ''}';
          final w = _width(label, 13) + 36;
          final tab = Rect.fromLTWH(x, r.top, w, 34);
          if (i == p['ativa']) {
            _rect(c, tab, background: blue.$2, edge: blue.$2);
            c.drawLine(tab.bottomLeft, tab.bottomRight, Paint()..color = blue.$1..strokeWidth = 3);
          }
          _text(c, tab.center, label, bold: true, color: i == p['ativa'] ? blue.$1 : _suave, anchor: 'mm');
          final e = WfState.de(item['estado']);
          if (e != WfState.existe) _dashed(c, tab.inflate(3), corDoEstado(e).$1);
          x += w + 10;
        }
      case 'cartoes':
        final itens = items('itens');
        if (itens.isEmpty) break;
        final cw = (r.width - 10 * (itens.length - 1)) / itens.length;
        for (final (i, item) in itens.indexed) {
          final cx = r.left + i * (cw + 10);
          _rect(c, Rect.fromLTWH(cx, r.top, cw, r.height), edge: _clara, radius: 8);
          c.drawRect(Rect.fromLTWH(cx, r.top + 8, 4, r.height - 16), Paint()..color = colors['azul']!.$1);
          _text(c, Offset(cx + 14, r.top + 12), '${item['rotulo'] ?? ''}', tam: 11, color: _suave, max: math.max(cw - 20, 1));
          _text(c, Offset(cx + 14, r.top + 32), '${item['valor'] ?? ''}', tam: 17, bold: true, max: math.max(cw - 20, 1));
        }
      case 'tabela':
        _table(c, r, p, items('colunas'));
      case 'paginador':
        _text(c, Offset(r.left, r.top + 8), s('info'), tam: 11, color: _suave);
        for (final (i, g) in const ['«', '‹', '1', '›', '»'].indexed) {
          final bt = Rect.fromLTWH(r.left + 260 + i * 30, r.top, 26, 26);
          _rect(c, bt, background: g == '1' ? colors['azul']!.$1 : _white, radius: 4);
          _text(c, bt.center, g, tam: 12, bold: true, color: g == '1' ? _white : _suave, anchor: 'mm');
        }
      case 'menu':
        final itens = items('itens');
        _rect(c, r.shift(const Offset(4, 4)), background: const Color(0xFFD1D5DB), edge: const Color(0xFFD1D5DB));
        _rect(c, r);
        for (final (i, item) in itens.indexed) {
          final iy = r.top + 4 + i * 32;
          final e = '${item['estado'] ?? 'existe'}';
          if (e == 'proposto') _rect(c, Rect.fromLTRB(r.left + 4, iy + 2, r.right - 4, iy + 30), background: colors['ambar']!.$2, edge: colors['ambar']!.$2, radius: 4);
          final color = switch (e) { 'proposto' => colors['ambar']!.$1, 'divergencia' => colors['vermelho']!.$1, 'desabilitado' => _line, _ => _ink };
          _text(c, Offset(r.left + 14, iy + 16), '${item['texto'] ?? ''}', bold: e != 'desabilitado', color: color, anchor: 'lm');
        }
      case 'modal':
        c.drawRect(Offset.zero & area, Paint()..color = const Color(0x6E111827));
        _rect(c, r, radius: 10);
        _text(c, r.topLeft + const Offset(20, 18), s('titulo'), tam: 17, bold: true);
        _text(c, Offset(r.right - 26, r.top + 18), '✕', tam: 16, bold: true, color: _suave);
        c.drawLine(Offset(r.left, r.top + 52), Offset(r.right, r.top + 52), Paint()..color = _clara);
      case 'painel':
        final background = switch (p['fundo']) { 'cinza' => _background, final String n when colors.containsKey(n) => colors[n]!.$2, _ => _white };
        _rect(c, r, background: background, edge: _clara, radius: 8);
        if (s('titulo').isNotEmpty) _text(c, r.topLeft + const Offset(16, 14), s('titulo'), tam: 15, bold: true);
      case 'seta':
        final pts = [
          for (final q in p['pontos'] as List? ?? const [])
            if (q is List && q.length >= 2) r.topLeft + Offset((q[0] as num).toDouble(), (q[1] as num).toDouble()),
        ];
        if (pts.length < 2) break;
        final ink = Paint()..color = p['cor'] == null ? _suave : _textColor(p['cor'])..strokeWidth = 2;
        for (var i = 0; i < pts.length - 1; i++) {
          c.drawLine(pts[i], pts[i + 1], ink);
        }
        final (a, z) = (pts[pts.length - 2], pts.last);
        final ang = math.atan2(z.dy - a.dy, z.dx - a.dx);
        c.drawPath(
          Path()
            ..moveTo(z.dx, z.dy)
            ..lineTo(z.dx - 10 * math.cos(ang - .4), z.dy - 10 * math.sin(ang - .4))
            ..lineTo(z.dx - 10 * math.cos(ang + .4), z.dy - 10 * math.sin(ang + .4))
            ..close(),
          ink,
        );
    }
    if (comp.state != WfState.existe) {
      _dashed(c, r.inflate(comp.type == 'modal' ? 5 : 4), corDoEstado(comp.state).$1);
    }
  }

  void _table(Canvas c, Rect r, Map<String, dynamic> p, List<Map> columns) {
    final linhas = [for (final l in p['linhas'] as List? ?? const []) if (l is List) l];
    final h = (p['altura_linha'] as num? ?? 30).toDouble();
    final w = columns.fold<double>(0, (s, col) => s + (col['largura'] as num? ?? 0).toDouble());
    final total = Rect.fromLTWH(r.left, r.top, w, h * (linhas.length + 1));
    _rect(c, total, radius: 4);
    c.drawRect(Rect.fromLTWH(r.left + 1, r.top + 1, w - 2, h - 1), Paint()..color = const Color(0xFFF9FAFB));
    var x = r.left;
    for (final col in columns) {
      final cw = (col['largura'] as num? ?? 0).toDouble();
      _text(c, Offset(x + 8, r.top + h / 2), '${col['titulo'] ?? ''}', tam: 11, bold: true, color: _suave, anchor: 'lm');
      final e = WfState.de(col['estado']);
      if (e != WfState.existe) _dashed(c, Rect.fromLTWH(x + 2, r.top + 2, cw - 4, total.height - 4), corDoEstado(e).$1, esp: 1);
      x += cw;
    }
    for (final (ri, line) in linhas.indexed) {
      final y = r.top + h * (ri + 1);
      if (ri == p['destaque']) c.drawRect(Rect.fromLTWH(r.left + 1, y, w - 2, h), Paint()..color = colors['azul']!.$2);
      c.drawLine(Offset(r.left, y), Offset(r.left + w, y), Paint()..color = _clara);
      x = r.left;
      for (final (ci, col) in columns.indexed) {
        final cw = (col['largura'] as num? ?? 0).toDouble();
        final v = ci < line.length ? line[ci] : '';
        if (v is Map && v['selo'] != null) {
          final (color, suave) = colors[v['selo']] ?? colors['azul']!;
          final t = '${v['texto'] ?? ''}';
          final sw = _width(t, 11) + 14;
          final stamp = Rect.fromLTWH(x + 6, y + (h - 18) / 2, sw, 18);
          _rect(c, stamp, background: suave, edge: color, radius: 9);
          _text(c, stamp.center, t, tam: 11, bold: true, color: color, anchor: 'mm');
        } else {
          final t = v is Map ? '${v['texto'] ?? ''}' : '$v';
          _text(c, Offset(x + 8, y + h / 2), t, tam: 12, anchor: 'lm', max: math.max(cw - 12, 1));
        }
        x += cw;
      }
    }
  }
}
