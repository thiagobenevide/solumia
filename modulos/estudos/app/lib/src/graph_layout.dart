import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

/// Force-directed simulation (Fruchterman–Reingold) that advances one step at a time, so the screen animates
/// the nodes settling: edges pull, nodes repel, the "temperature" drops on every step until it stops.
/// Fixed seed: the same graph always comes out with the same drawing. Positions in a square of side [side]
/// centered at the origin; [start] reuses already known positions (a filter change does not shuffle everything).
class GraphSimulation {
  GraphSimulation(this.ids, List<(String, String)> edges, {this.side = 1000, Map<String, Offset> start = const {}})
    : _x = Float64List(ids.length),
      _y = Float64List(ids.length),
      _k = ids.isEmpty ? 1 : sqrt(side * side / ids.length) * 0.8 {
    final score = {for (final (i, id) in ids.indexed) id: i};
    _links = [
      for (final (a, b) in edges)
        if (score[a] != null && score[b] != null && a != b) (score[a]!, score[b]!),
    ];
    // new nodes are born near the center and "explode" outwards: the animation stays readable
    final spread = start.isEmpty ? side * 0.25 : side * 0.05;
    for (var i = 0; i < ids.length; i++) {
      final p = start[ids[i]];
      _x[i] = p?.dx ?? (_random.nextDouble() - .5) * spread;
      _y[i] = p?.dy ?? (_random.nextDouble() - .5) * spread;
    }
    temperature = start.isEmpty ? side / 10 : side / 30;
  }

  final List<String> ids;
  final double side;
  final Float64List _x, _y;
  final double _k; // ideal distance between nodes
  late final List<(int, int)> _links;
  final _random = Random(42);
  late double temperature;

  static const _minima = 1.0;

  bool get active => temperature > _minima && ids.isNotEmpty;

  Offset position(int i) => Offset(_x[i], _y[i]);

  Map<String, Offset> get positions => {for (final (i, id) in ids.indexed) id: position(i)};

  void step() {
    final n = ids.length;
    final dx = Float64List(n), dy = Float64List(n);
    final k2 = _k * _k;
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        var ex = _x[i] - _x[j], ey = _y[i] - _y[j];
        var d2 = ex * ex + ey * ey;
        if (d2 < 1e-4) {
          ex = _random.nextDouble() - .5;
          ey = _random.nextDouble() - .5;
          d2 = 1e-4;
        }
        final f = k2 / d2; // (d/|d|) * k²/|d|
        dx[i] += ex * f;
        dy[i] += ey * f;
        dx[j] -= ex * f;
        dy[j] -= ey * f;
      }
    }
    for (final (a, b) in _links) {
      final ex = _x[a] - _x[b], ey = _y[a] - _y[b];
      final f = sqrt(ex * ex + ey * ey) / _k; // (d/|d|) * |d|²/k
      dx[a] -= ex * f;
      dy[a] -= ey * f;
      dx[b] += ex * f;
      dy[b] += ey * f;
    }
    final middle = side / 2;
    for (var i = 0; i < n; i++) {
      // light gravity towards the center: loose components do not escape the frame
      final gx = dx[i] - _x[i] * 0.02, gy = dy[i] - _y[i] * 0.02;
      final d = sqrt(gx * gx + gy * gy);
      if (d > 0) {
        final m = min(d, temperature) / d;
        _x[i] = (_x[i] + gx * m).clamp(-middle, middle);
        _y[i] = (_y[i] + gy * m).clamp(-middle, middle);
      }
    }
    temperature = max(temperature * 0.97, _minima);
  }
}

/// For `compute`: (ids, edges, side, initial positions) → final positions, simulating until it cools off
/// the UI thread (the screen only animates the result, without shaking).
Map<String, Offset> computeLayout((List<String>, List<(String, String)>, double, Map<String, Offset>) p) {
  final (ids, edges, side, start) = p;
  final sim = GraphSimulation(ids, edges, side: side, start: start);
  for (var i = 0; i < 600 && sim.active; i++) {
    sim.step();
  }
  return sim.positions;
}

/// Finished layout (no animation): runs the simulation [steps] times.
Map<String, Offset> graphLayout(
  List<String> nos,
  List<(String, String)> edges, {
  double side = 1000,
  int steps = 250,
}) {
  if (nos.isEmpty) return {};
  final sim = GraphSimulation(nos, edges, side: side);
  for (var i = 0; i < steps; i++) {
    sim.step();
  }
  return sim.positions;
}
