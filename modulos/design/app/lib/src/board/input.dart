import 'dart:math';
import 'dart:ui' show Rect, Size;

import 'package:flutter/gestures.dart';

import 'toolbox.dart';

/// What a pointer that touched is going to do.
enum Gesture { draw, erase, pan }

/// Input rules for every device:
/// - pen (S-Pen, Apple Pencil, Wacom/Huion tablet): draws with the tool; the eraser tip
///   or the side button erase;
/// - mouse: left button uses the tool; middle, right or space held move the board;
/// - finger: draws only while [Toolbox.fingerDraws]; otherwise moves (one finger) and zooms (pinch).
Gesture classify({
  required PointerDeviceKind type,
  required int buttons,
  required Tool tool,
  required bool fingerDraws,
  bool space = false,
}) {
  if (type == PointerDeviceKind.invertedStylus) return Gesture.erase;
  if (type == PointerDeviceKind.stylus && buttons & kPrimaryStylusButton != 0) return Gesture.erase;
  if (type == PointerDeviceKind.mouse && buttons & (kMiddleMouseButton | kSecondaryMouseButton) != 0) {
    return Gesture.pan;
  }
  if (space) return Gesture.pan;
  if (type == PointerDeviceKind.touch && !fingerDraws) return Gesture.pan;
  return switch (tool) {
    Tool.hand => Gesture.pan,
    Tool.eraser => Gesture.erase,
    _ => Gesture.draw,
  };
}

bool isPen(PointerDeviceKind type) => type == PointerDeviceKind.stylus || type == PointerDeviceKind.invertedStylus;

/// Normalized pressure 0–1. Mouse and finger have no useful pressure: 0.5 (medium thickness stroke).
double pressure(PointerEvent e) {
  if (!isPen(e.kind)) return 0.5;
  final band = e.pressureMax - e.pressureMin;
  if (band <= 0) return 0.5;
  return ((e.pressure - e.pressureMin) / band).clamp(0.05, 1.0);
}

/// Infinite board camera: screen = world × [scale] + [offset].
class Camera {
  Offset offset = Offset.zero;
  double scale = 1;

  static const minimum = 0.1, maximum = 8.0;

  Offset toWorld(Offset screen) => (screen - offset) / scale;

  Offset toScreen(Offset world) => world * scale + offset;

  /// Multiplies the zoom by [factor] keeping the screen point [focus] still.
  void zoom(double factor, Offset focus) {
    final nova = (scale * factor).clamp(minimum, maximum);
    final world = toWorld(focus);
    scale = nova;
    offset = focus - world * scale;
  }

  /// Frames [area] (world) in the [screen], with margin; an empty area goes back to the origin at 100%.
  void frame(Rect? area, Size screen) {
    if (area == null || area.isEmpty || screen.isEmpty) {
      scale = 1;
      offset = Offset.zero;
      return;
    }
    scale = min(screen.width / area.width, screen.height / area.height).clamp(minimum, 2.0) * 0.9;
    offset = screen.center(Offset.zero) - area.center * scale;
  }
}
