import 'package:agent_estudos/src/graph_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('nós ligados ficam mais perto que os soltos e o resultado é estável', () {
    final nos = ['a', 'b', 'c', 'd'];
    final edges = [('a', 'b'), ('b', 'c')];
    final p = graphLayout(nos, edges, side: 600);
    expect(p.keys, nos);
    expect((p['a']! - p['b']!).distance, lessThan((p['a']! - p['d']!).distance));
    for (final o in p.values) {
      expect(o.dx.abs(), lessThanOrEqualTo(300));
      expect(o.dy.abs(), lessThanOrEqualTo(300));
    }
    expect(graphLayout(nos, edges, side: 600), p);
  });

  test('grafo vazio', () => expect(graphLayout([], []), isEmpty));
}
