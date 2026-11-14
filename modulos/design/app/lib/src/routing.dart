import 'dart:collection';
import 'dart:math';
import 'dart:ui';

/// Right-angle route between two blocks avoiding the others (like the draw.io router).
///
/// Builds a sparse grid with the lines passing close to the block borders (with [margin]) and
/// through the exits of each side, and runs an A* that adds the length and a penalty per bend: out comes
/// the shortest path with the fewest bends that crosses no block. The arrow can leave and arrive through
/// any side; the A* chooses. Returns the points from start to end (on the block borders) or null if
/// there is no path (then the caller uses the simple route).
///
/// [straightFrom]/[straightTo]: the block has straight sides (rectangle, process…), so the arrow can leave from
/// any point of the side; that way, blocks facing each other connect with a straight line, without the
/// few-pixel step the exact middle of the side would give. Diamond and circle leave only from the middle.
/// [sideFrom]/[sideTo] pin the exit/arrival to a side (null = the A* chooses).
List<Offset>? orthogonalRoute(
  Rect de,
  Rect to,
  Iterable<Rect> obstacles, {
  double margin = 18,
  bool straightFrom = true,
  bool straightTo = true,
  int? sideOf,
  int? sideTo,
}) {
  // Only what is near both blocks matters: limits the grid (and the time) around them.
  final region = de.expandToInclude(to).inflate(margin * 12);
  final filledItems = [
    for (final o in [de, to, ...obstacles])
      if (o.overlaps(region)) o.inflate(margin),
  ];

  // Exits: the middle of each side, one [margin] step outwards.
  List<(Offset port, Offset fora, int side)> exits(Rect r) => [
    (r.topCenter, r.topCenter.translate(0, -margin), 0),
    (r.centerRight, r.centerRight.translate(margin, 0), 1),
    (r.bottomCenter, r.bottomCenter.translate(0, margin), 2),
    (r.centerLeft, r.centerLeft.translate(-margin, 0), 3),
  ];
  final sources = exits(de), targetsList = exits(to);
  // Blocks facing each other: one extra exit on each, at the same height (or column),
  // so the connector leaves straight. With two straight sides, in the middle of the shared band; with a diamond or
  // circle, at its tip (the straight block aligns to it).
  double? align(double start1, double end1, double c1, bool straight1, double start2, double end2, double c2, bool straight2) {
    final ini = max(start1, start2), fim = min(end1, end2);
    if (fim - ini <= 8) return null;
    if (straight1 && straight2) return (ini + fim) / 2;
    final target = straight1 ? c2 : (straight2 ? c1 : null);
    return target != null && target > ini + 4 && target < fim - 4 ? target : null;
  }

  final y = align(de.top, de.bottom, de.center.dy, straightFrom, to.top, to.bottom, to.center.dy, straightTo);
  if (y != null && (de.right < to.left || to.right < de.left)) {
    final fromLeft = de.center.dx <= to.center.dx;
    final (ld, lp) = fromLeft ? (de.right, to.left) : (de.left, to.right);
    final m = fromLeft ? margin : -margin;
    sources.add((Offset(ld, y), Offset(ld + m, y), fromLeft ? 1 : 3));
    targetsList.add((Offset(lp, y), Offset(lp - m, y), fromLeft ? 3 : 1));
  }
  final x = align(de.left, de.right, de.center.dx, straightFrom, to.left, to.right, to.center.dx, straightTo);
  if (x != null && (de.bottom < to.top || to.bottom < de.top)) {
    final fromTop = de.center.dy <= to.center.dy;
    final (ld, lp) = fromTop ? (de.bottom, to.top) : (de.top, to.bottom);
    final m = fromTop ? margin : -margin;
    sources.add((Offset(x, ld), Offset(x, ld + m), fromTop ? 2 : 0));
    targetsList.add((Offset(x, lp), Offset(x, lp - m), fromTop ? 0 : 2));
  }
  // Side chosen by the user (0 top, 1 right, 2 bottom, 3 left): only that one works.
  if (sideOf != null) sources.removeWhere((o) => o.$3 != sideOf);
  if (sideTo != null) targetsList.removeWhere((o) => o.$3 != sideTo);

  final xs = SplayTreeSet<double>(), ys = SplayTreeSet<double>();
  for (final r in filledItems) {
    xs.addAll([r.left, r.right]);
    ys.addAll([r.top, r.bottom]);
  }
  for (final (_, p, _) in [...sources, ...targetsList]) {
    xs.add(p.dx);
    ys.add(p.dy);
  }
  xs.addAll([region.left, region.right]);
  ys.addAll([region.top, region.bottom]);
  // Middle lines between the two blocks keep the path centered in the gap, like draw.io.
  xs.add((de.center.dx + to.center.dx) / 2);
  ys.add((de.center.dy + to.center.dy) / 2);
  final vx = xs.toList(), vy = ys.toList();

  bool inside(Offset p) => filledItems.any((r) => p.dx > r.left + 0.5 && p.dx < r.right - 0.5 && p.dy > r.top + 0.5 && p.dy < r.bottom - 0.5);
  bool crosses(Offset a, Offset b) {
    for (final r in filledItems) {
      if (a.dy == b.dy) {
        final y = a.dy;
        if (y > r.top + 0.5 && y < r.bottom - 0.5 && max(a.dx, b.dx) > r.left + 0.5 && min(a.dx, b.dx) < r.right - 0.5) return true;
      } else {
        final x = a.dx;
        if (x > r.left + 0.5 && x < r.right - 0.5 && max(a.dy, b.dy) > r.top + 0.5 && min(a.dy, b.dy) < r.bottom - 0.5) return true;
      }
    }
    return false;
  }

  final ix = {for (final (i, x) in vx.indexed) x: i}, iy = {for (final (i, y) in vy.indexed) y: i};
  // State: grid position and arrival direction (0 ↑, 1 →, 2 ↓, 3 ←); a bend is expensive.
  const curve = 60.0;
  const steps = [(0, -1), (1, 0), (0, 1), (-1, 0)];
  final targets = <(int, int), (Offset, int)>{
    for (final (port, p, side) in targetsList) (ix[p.dx]!, iy[p.dy]!): (port, side),
  };
  double h(int i, int j) {
    var best = double.infinity;
    for (final (_, p, _) in targetsList) {
      best = min(best, (vx[i] - p.dx).abs() + (vy[j] - p.dy).abs());
    }
    return best;
  }

  final cost = <(int, int, int), double>{};
  final cameFrom = <(int, int, int), (int, int, int)?>{};
  final queue = PriorityQueue<(double, (int, int, int))>((a, b) => a.$1.compareTo(b.$1));
  for (final (_, p, side) in sources) {
    final i = ix[p.dx]!, j = iy[p.dy]!;
    if (inside(p)) continue;
    // Leaving through the side that points to the target is cheaper (avoids loops right at the exit).
    final d = to.center - de.center;
    final against = switch (side) { 0 => d.dy > 0, 1 => d.dx < 0, 2 => d.dy < 0, _ => d.dx > 0 };
    final c = margin + (against ? curve * 2 : 0);
    final s = (i, j, side);
    cost[s] = c;
    cameFrom[s] = null;
    queue.add((c + h(i, j), s));
  }
  (int, int, int)? fim;
  var visits = 0;
  while (queue.isNotEmpty && visits++ < 20000) {
    final (_, s) = queue.removeFirst();
    final (i, j, dir) = s;
    final c = cost[s]!;
    final target = targets[(i, j)];
    // Arrives through the target exit entering in the direction of the side (coming from outside).
    if (target != null && (dir + 2) % 4 == target.$2) {
      fim = s;
      break;
    }
    for (final (nd, (di, dj)) in steps.indexed) {
      if (nd == (dir + 2) % 4) continue; // no U-turn
      final ni = i + di, nj = j + dj;
      if (ni < 0 || nj < 0 || ni >= vx.length || nj >= vy.length) continue;
      final a = Offset(vx[i], vy[j]), b = Offset(vx[ni], vy[nj]);
      if (inside(b) || crosses(a, b)) continue;
      final nc = c + (b - a).distance + (nd == dir ? 0 : curve);
      final ns = (ni, nj, nd);
      if (nc < (cost[ns] ?? double.infinity)) {
        cost[ns] = nc;
        cameFrom[ns] = s;
        queue.add((nc + h(ni, nj), ns));
      }
    }
  }
  if (fim == null) return null;

  final pontos = <Offset>[targets[(fim.$1, fim.$2)]!.$1];
  for ((int, int, int)? s = fim; s != null; s = cameFrom[s]) {
    pontos.add(Offset(vx[s.$1], vy[s.$2]));
  }
  // the origin port is the one of the exit side of the first state
  var firstItem = fim;
  while (cameFrom[firstItem] != null) {
    firstItem = cameFrom[firstItem]!;
  }
  pontos.add(
    sources.firstWhere((o) => o.$3 == firstItem.$3 && ix[o.$2.dx] == firstItem.$1 && iy[o.$2.dy] == firstItem.$2).$1,
  );
  return _trim(pontos.reversed.toList());
}

/// Removes the points in the middle of straight segments.
List<Offset> _trim(List<Offset> p) {
  final exit = <Offset>[];
  for (final q in p) {
    if (exit.isNotEmpty && (exit.last - q).distance < 0.5) continue;
    if (exit.length >= 2) {
      final a = exit[exit.length - 2], b = exit.last;
      if ((a.dx == b.dx && b.dx == q.dx) || (a.dy == b.dy && b.dy == q.dy)) {
        exit[exit.length - 1] = q;
        continue;
      }
    }
    exit.add(q);
  }
  return exit;
}

/// Min priority queue (binary heap) for the A*.
class PriorityQueue<T> {
  PriorityQueue(this._compare);

  final int Function(T, T) _compare;
  final _items = <T>[];

  bool get isNotEmpty => _items.isNotEmpty;

  void _swap(int a, int b) {
    final t = _items[a];
    _items[a] = _items[b];
    _items[b] = t;
  }

  void add(T item) {
    _items.add(item);
    var i = _items.length - 1;
    while (i > 0) {
      final parent = (i - 1) >> 1;
      if (_compare(_items[i], _items[parent]) >= 0) break;
      _swap(i, parent);
      i = parent;
    }
  }

  T removeFirst() {
    final firstItem = _items.first, last = _items.removeLast();
    if (_items.isNotEmpty) {
      _items[0] = last;
      var i = 0;
      while (true) {
        final e = 2 * i + 1, d = e + 1;
        var smaller = i;
        if (e < _items.length && _compare(_items[e], _items[smaller]) < 0) smaller = e;
        if (d < _items.length && _compare(_items[d], _items[smaller]) < 0) smaller = d;
        if (smaller == i) break;
        _swap(i, smaller);
        i = smaller;
      }
    }
    return firstItem;
  }
}
