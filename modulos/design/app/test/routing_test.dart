import 'dart:ui';

import 'package:agent_design/src/models.dart';
import 'package:agent_design/src/routing.dart';
import 'package:flutter_test/flutter_test.dart';

const _color = Color(0xFF1565C0);
FlowNode _no(String id, Rect r, {NodeKind type = NodeKind.processo}) =>
    FlowNode(id, type: type, text: id, a: r.topLeft, b: r.bottomRight, color: _color);

/// Does some segment of the path go through [r]?
bool _crosses(List<Offset> c, Rect r) {
  final inside = r.deflate(1);
  for (var i = 0; i < c.length - 1; i++) {
    for (var t = 0.0; t <= 1; t += 0.02) {
      if (inside.contains(Offset.lerp(c[i], c[i + 1], t)!)) return true;
    }
  }
  return false;
}

void main() {
  test('a seta desvia do bloco que está no caminho e só faz curvas em ângulo reto', () {
    const a = Rect.fromLTWH(0, 0, 160, 60), b = Rect.fromLTWH(0, 400, 160, 60);
    const middle = Rect.fromLTWH(-20, 180, 200, 80);
    final route = orthogonalRoute(a, b, [middle])!;
    expect(_crosses(route, middle), isFalse);
    // starts at the border of A and ends at B's (the middle block is wider: goes around the side)
    bool onBorder(Offset p, Rect r) =>
        r.inflate(0.5).contains(p) && !r.deflate(0.5).contains(p);
    expect(onBorder(route.first, a), isTrue);
    expect(onBorder(route.last, b), isTrue);
    for (var i = 0; i < route.length - 1; i++) {
      expect(route[i].dx == route[i + 1].dx || route[i].dy == route[i + 1].dy, isTrue);
    }
  });

  test('blocos de frente ligam reto, sem degrau, mesmo com centros desalinhados', () {
    const a = Rect.fromLTWH(0, 0, 160, 60), b = Rect.fromLTWH(300, 10, 160, 60);
    expect(orthogonalRoute(a, b, const []), hasLength(2)); // a single line
    // diamond → rectangle: the rectangle aligns to the diamond tip
    final els = reconnect([
      _no('d', const Rect.fromLTWH(0, 0, 180, 90), type: NodeKind.decisao),
      _no('r', const Rect.fromLTWH(300, 30, 160, 48)),
      const Connector('l', de: 'd', to: 'r', a: Offset.zero, b: Offset.zero, color: _color, orthogonal: true),
    ]);
    final l = els.whereType<Connector>().single;
    expect(l.path, hasLength(2));
    expect(l.a, const Offset(180, 45)); // right tip of the diamond
  });

  test('em volta de uma fileira de blocos, nenhuma seta atravessa', () {
    final nos = [for (var i = 0; i < 6; i++) _no('n$i', Rect.fromLTWH(i * 220.0, (i % 2) * 160.0, 160, 70))];
    final arrows = [
      for (var i = 0; i < 5; i++)
        Connector('l$i', de: 'n$i', to: 'n${5 - i}', a: Offset.zero, b: Offset.zero, color: _color, orthogonal: true),
    ];
    final t = Stopwatch()..start();
    final els = reconnect([...nos, ...arrows]);
    expect(t.elapsedMilliseconds, lessThan(500));
    for (final l in els.whereType<Connector>()) {
      for (final n in nos) {
        if (n.id != l.de && n.id != l.to) expect(_crosses(l.path, n.retangulo), isFalse, reason: '${l.id} × ${n.id}');
      }
    }
  });
}
