import 'package:flutter/material.dart';

import '../models.dart';

/// Tools of the board bar, in the order they show up; [shortcut] is the keyboard key.
enum Tool {
  hand('Mover (H / espaço)', Icons.pan_tool_outlined, 'h'),
  selection('Selecionar com laço (V)', Icons.highlight_alt, 'v'),
  caneta('Caneta (P)', Icons.edit_outlined, 'p'),
  marcador('Marcador (M)', Icons.format_paint_outlined, 'm'),
  eraser('Borracha (E)', Icons.auto_fix_normal_outlined, 'e'),
  reta('Reta (L)', Icons.horizontal_rule, 'l'),
  seta('Seta (A)', Icons.arrow_right_alt, 'a'),
  retangulo('Retângulo (R)', Icons.crop_square, 'r'),
  elipse('Elipse (O)', Icons.circle_outlined, 'o'),
  text('Texto (T)', Icons.title, 't'),
  laser('Laser (K)', Icons.highlight, 'k');

  const Tool(this.label, this.icone, this.shortcut);

  final String label;
  final IconData icone;
  final String shortcut;

  ShapeKind? get shape => switch (this) {
    reta => ShapeKind.reta,
    seta => ShapeKind.seta,
    retangulo => ShapeKind.retangulo,
    elipse => ShapeKind.elipse,
    _ => null,
  };

  bool get usesColor => this != hand && this != eraser && this != laser && this != selection;

  bool get usesThickness => this != hand && this != laser && this != selection;
}

const quickColors = [
  Color(0xFF111111),
  Color(0xFF1E5EFF),
  Color(0xFFE53935),
  Color(0xFF2E7D32),
  Color(0xFF8E24AA),
  Color(0xFFFF9800),
  Color(0xFFFFEB3B),
  Color(0xFF80D8FF),
];

/// Chosen tool, color/thickness of each one and how the finger behaves.
class Estojo extends ChangeNotifier {
  Tool _tool = Tool.caneta;
  final Map<Tool, Color> _cores = {Tool.marcador: const Color(0xFFFFEB3B)};
  final Map<Tool, double> _thicknesses = {
    Tool.caneta: 3,
    Tool.marcador: 18,
    Tool.eraser: 12,
    Tool.text: 28,
  };
  Color _shapesColor = const Color(0xFF111111);
  bool? _fingerDraws;
  final List<Color> recent = [];
  bool _penSeen = false;

  Tool get tool => _tool;
  set tool(Tool f) {
    _tool = f;
    notifyListeners();
  }

  // Shapes and pen share the color: drawing a diagram does not require switching color on each tool.
  Color colorOf(Tool f) => _cores[f] ?? _shapesColor;
  Color get color => colorOf(_tool);
  set color(Color c) {
    rememberColor(c);
    if (_tool == Tool.marcador) {
      _cores[Tool.marcador] = c;
    } else {
      _shapesColor = c;
    }
    notifyListeners();
  }

  // Shapes use the pen thickness, for the same reason as the color.
  static Tool _key(Tool f) => f.shape != null ? Tool.caneta : f;
  double thicknessOf(Tool f) => _thicknesses[_key(f)] ?? 3;
  double get thickness => thicknessOf(_tool);
  set thickness(double v) {
    _thicknesses[_key(_tool)] = v;
    notifyListeners();
  }

  /// Does the finger draw? Automatic until the user chooses: draws until a pen shows up (S-Pen,
  /// drawing tablet); from then on the finger only moves and zooms (the palm does not scribble).
  bool get fingerDraws => _fingerDraws ?? !_penSeen;
  set fingerDraws(bool v) {
    _fingerDraws = v;
    notifyListeners();
  }

  /// Off-palette colors used last (up to 6), for the full picker.
  void rememberColor(Color c) {
    if (quickColors.contains(c)) return;
    recent
      ..remove(c)
      ..insert(0, c);
    if (recent.length > 6) recent.removeLast();
  }

  void penSeen() {
    if (_penSeen) return;
    _penSeen = true;
    notifyListeners();
  }
}
