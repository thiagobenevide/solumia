import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'toolbox.dart';

/// Quick click of the pen side button while hovering (without touching): opens the radial menu,
/// as in Samsung Notes. Holding the button and touching is still the eraser (`classify`).
/// Android sends the button state in the hover events (`kPrimaryStylusButton`).
class ButtonClick {
  ButtonClick({DateTime Function()? clock}) : _now = clock ?? DateTime.now;

  final DateTime Function() _now;

  /// Up to how long pressed still counts as a click (longer than that is holding).
  static const limit = Duration(milliseconds: 450);

  DateTime? _pressed;

  /// Touched with the button pressed (eraser): on lifting while still holding, releasing the button is not a
  /// click. It only counts again after the button is released.
  var _locked = false;

  /// Returns the click position when the button is released in time; otherwise, null.
  Offset? hover(PointerHoverEvent e) {
    if (e.kind != PointerDeviceKind.stylus) return null;
    final pressed = e.buttons & kPrimaryStylusButton != 0;
    if (_locked) {
      if (!pressed) _locked = false;
      _pressed = null;
      return null;
    }
    if (pressed) {
      _pressed ??= _now();
      return null;
    }
    final inicio = _pressed;
    _pressed = null;
    if (inicio == null || _now().difference(inicio) > limit) return null;
    return e.localPosition;
  }

  /// The pen touched: the pressed button is now the eraser, not a click.
  void cancel() {
    _pressed = null;
    _locked = true;
  }
}

/// Radial menu around [center]: tools, undo/redo on the inner ring, colors on the
/// outer one and the thickness (− / +) in the middle. Tapping outside closes it.
class PenRadialMenu extends StatelessWidget {
  const PenRadialMenu({
    super.key,
    required this.center,
    required this.toolbox,
    required this.undo,
    required this.redo,
    required this.moreColors,
    required this.close,
  });

  final Offset center;
  final Estojo toolbox;
  final VoidCallback? undo, redo;
  final VoidCallback moreColors, close;

  static const radius = 150.0;
  static const _tools = [
    Tool.caneta,
    Tool.marcador,
    Tool.eraser,
    Tool.selection,
    Tool.text,
    Tool.reta,
    Tool.retangulo,
    Tool.laser,
  ];

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      // The whole menu fits on screen, even when clicking near the edge.
      final x = center.dx.clamp(radius, max(radius, c.maxWidth - radius));
      final y = center.dy.clamp(radius, max(radius, c.maxHeight - radius));
      return Stack(
        children: [
          Positioned.fill(
            child: Listener(behavior: HitTestBehavior.opaque, onPointerDown: (_) => close()),
          ),
          Positioned(
            left: x - radius,
            top: y - radius,
            width: radius * 2,
            height: radius * 2,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.6, end: 1),
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutBack,
              builder: (context, t, child) =>
                  Opacity(opacity: ((t - 0.6) / 0.4).clamp(0, 1), child: Transform.scale(scale: t, child: child)),
              child: ListenableBuilder(listenable: toolbox, builder: (context, _) => _wheel(context)),
            ),
          ),
        ],
      );
    },
  );

  Widget _wheel(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final itens = <Widget>[];
    // Outer ring: colors (the last one opens the full picker).
    final colors = [...quickColors, null];
    for (var i = 0; i < colors.length; i++) {
      final color = colors[i];
      final current = color != null && toolbox.color == color;
      itens.add(
        _onRing(
          i,
          colors.length,
          radius - 24,
          color == null
              ? _roundButton(scheme, Icons.palette_outlined, 'Mais cores', () {
                  close();
                  moreColors();
                })
              : Tooltip(
                  message: 'Cor',
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => toolbox.color = color,
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(color: current ? scheme.primary : Colors.black26, width: current ? 3 : 1),
                      ),
                    ),
                  ),
                ),
        ),
      );
    }
    // Inner ring: tools, undo and redo.
    final actions = <Widget>[
      for (final f in _tools)
        _roundButton(
          scheme,
          f.icone,
          f.label,
          () {
            toolbox.tool = f;
            close();
          },
          active: toolbox.tool == f,
        ),
      _roundButton(scheme, Icons.undo, 'Desfazer', undo),
      _roundButton(scheme, Icons.redo, 'Refazer', redo),
    ];
    for (var i = 0; i < actions.length; i++) {
      itens.add(_onRing(i, actions.length, radius - 76, actions[i]));
    }
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.surface.withValues(alpha: 0.96),
                boxShadow: const [BoxShadow(blurRadius: 18, color: Colors.black26)],
                border: Border.all(color: scheme.outlineVariant),
              ),
            ),
          ),
          Center(
            child: Container(
              width: 52 * 2 - 8,
              height: 52 * 2 - 8,
              decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.surfaceContainerHighest),
            ),
          ),
          ...itens,
          Center(child: _thickness(scheme)),
        ],
      ),
    );
  }

  /// Middle: sample of the stroke with the current color and thickness, − and + to thin/thicken.
  Widget _thickness(ColorScheme scheme) {
    final e = toolbox.thickness;
    final (minimum, maximum) = toolbox.tool == Tool.marcador ? (6.0, 48.0) : (1.0, 24.0);
    void change(double factor) => toolbox.thickness = (e * factor).clamp(minimum, maximum).roundToDouble().clamp(minimum, maximum);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _mini(Icons.add, 'Mais grosso', e < maximum ? () => change(1.3) : null),
        Container(
          width: min(30, e + 4),
          height: min(30, e + 4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: toolbox.tool.usesColor ? toolbox.color : scheme.onSurfaceVariant,
          ),
        ),
        Text('${e.round()}', style: const TextStyle(fontSize: 11)),
        _mini(Icons.remove, 'Mais fino', e > minimum ? () => change(1 / 1.3) : null),
      ],
    );
  }

  Widget _mini(IconData icone, String hint, VoidCallback? onItemTap) => IconButton(
    tooltip: hint,
    visualDensity: VisualDensity.compact,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(width: 26, height: 22),
    iconSize: 18,
    onPressed: onItemTap,
    icon: Icon(icone),
  );

  Widget _onRing(int i, int total, double r, Widget child) {
    final a = -pi / 2 + i * 2 * pi / total;
    return Positioned(
      left: radius + cos(a) * r - 20,
      top: radius + sin(a) * r - 20,
      width: 40,
      height: 40,
      child: Center(child: child),
    );
  }

  Widget _roundButton(ColorScheme scheme, IconData icone, String hint, VoidCallback? onItemTap, {bool active = false}) =>
      IconButton(
        tooltip: hint,
        isSelected: active,
        style: IconButton.styleFrom(
          backgroundColor: active ? scheme.primaryContainer : null,
          foregroundColor: active ? scheme.onPrimaryContainer : null,
        ),
        onPressed: onItemTap,
        icon: Icon(icone, size: 22),
      );
}
