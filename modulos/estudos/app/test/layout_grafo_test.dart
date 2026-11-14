import 'package:agent_estudos/src/layout_grafo.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('nós ligados ficam mais perto que os soltos e o resultado é estável', () {
    final nos = ['a', 'b', 'c', 'd'];
    final arestas = [('a', 'b'), ('b', 'c')];
    final p = layoutGrafo(nos, arestas, lado: 600);
    expect(p.keys, nos);
    expect((p['a']! - p['b']!).distance, lessThan((p['a']! - p['d']!).distance));
    for (final o in p.values) {
      expect(o.dx.abs(), lessThanOrEqualTo(300));
      expect(o.dy.abs(), lessThanOrEqualTo(300));
    }
    expect(layoutGrafo(nos, arestas, lado: 600), p);
  });

  test('grafo vazio', () => expect(layoutGrafo([], []), isEmpty));
}
