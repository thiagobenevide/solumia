import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models.dart';

/// Reader bar tools, in the order they show up.
enum Tool {
  pan('Navegar', Icons.pan_tool_outlined),
  caneta('Caneta', Icons.edit_outlined),
  lapis('Lápis', Icons.create_outlined),
  caligrafia('Pincel', Icons.brush_outlined),
  marcador('Marca-texto livre', Icons.format_paint_outlined),
  textMark('Marca-texto (salva o texto)', Icons.border_color_outlined),
  eraser('Borracha', Icons.auto_fix_normal_outlined),
  text('Texto', Icons.title);

  const Tool(this.label, this.icone);

  final String label;
  final IconData icone;

  Brush? get brush => switch (this) {
    caneta => Brush.caneta,
    lapis => Brush.lapis,
    caligrafia => Brush.caligrafia,
    marcador => Brush.marcador,
    _ => null,
  };

  bool get usesColor => this != pan && this != eraser;
}

const quickColors = [
  Color(0xFF111111),
  Color(0xFF1E5EFF),
  Color(0xFFE53935),
  Color(0xFF2E7D32),
  Color(0xFF8E24AA),
  Color(0xFFFFEB3B),
  Color(0xFF7CF29C),
  Color(0xFFFF9EC8),
  Color(0xFF80D8FF),
  Color(0xFFFFB74D),
];

/// Chosen tool and the color/thickness of each one (switching tools does not lose the other's setting,
/// as in Samsung Notes).
class ReaderToolbox extends ChangeNotifier {
  Tool _tool = Tool.caneta;
  final Map<Tool, Color> _cores = {
    Tool.caneta: const Color(0xFF111111),
    Tool.lapis: const Color(0xFF424242),
    Tool.caligrafia: const Color(0xFF1E5EFF),
    Tool.marcador: const Color(0xFFFFEB3B),
    Tool.textMark: const Color(0xFFFFEB3B),
    Tool.text: const Color(0xFFE53935),
  };
  final Map<Tool, double> _thicknesses = {
    Tool.caneta: 2.0,
    Tool.lapis: 1.2,
    Tool.caligrafia: 5.0,
    Tool.marcador: 14.0,
    Tool.textMark: 14.0,
    Tool.eraser: 10.0,
    Tool.text: 14.0,
  };

  /// Forces every stroke to come out straight (ruler). Without it, holding the pen still at the end of the stroke for
  /// a moment also straightens it.
  bool straightLines = false;

  /// Only the pen draws; the finger scrolls and zooms (palm rejection). On by default on Android/iOS.
  bool penOnly = defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

  final List<Color> recent = [];

  Tool get tool => _tool;
  Color get color => colorOf(_tool);
  double get thickness => thicknessOf(_tool);

  Color colorOf(Tool f) => _cores[f] ?? const Color(0xFF111111);

  double thicknessOf(Tool f) => _thicknesses[f] ?? 2;

  /// Limits of the thickness control (in PDF points; font size for text).
  (double, double) get band => switch (_tool) {
    Tool.marcador || Tool.textMark => (4, 40),
    Tool.eraser => (2, 60),
    Tool.text => (6, 48),
    Tool.caligrafia => (1, 30),
    _ => (0.3, 20),
  };

  set tool(Tool f) {
    _tool = f;
    notifyListeners();
  }

  set color(Color c) {
    _cores[_tool] = c;
    recent
      ..remove(c)
      ..insert(0, c);
    if (recent.length > 6) recent.removeLast();
    notifyListeners();
  }

  set thickness(double v) {
    _thicknesses[_tool] = v;
    notifyListeners();
  }

  void toggleStraightLines() {
    straightLines = !straightLines;
    notifyListeners();
  }

  void togglePenOnly() {
    penOnly = !penOnly;
    notifyListeners();
  }
}
