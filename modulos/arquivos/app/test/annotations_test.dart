import 'dart:ui';

import 'package:agent_arquivos/src/reader/geometry.dart';
import 'package:agent_arquivos/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

InkStroke _trace(String id, [List<InkPoint>? points]) => InkStroke(
  id: id,
  page: 0,
  brush: Brush.caneta,
  color: const Color(0xFF000000),
  thickness: 2,
  points: points ?? const [InkPoint(0, 0, 0.5), InkPoint(10, 10, 0.5)],
);

void main() {
  test('projetos de leitura e tradução vão e voltam no json; ligar troca só o elemento', () {
    final d = Highlight(
      id: 'd1',
      page: 0,
      text: 'search strategy',
      color: const Color(0xFFFFEB3B),
      rectangles: const [],
      created: DateTime.utc(2026),
    ).copy(translation: 'estratégia de busca', projects: ['p1']);
    final a = Annotations(
      strokes: [
        _trace('t1').withProjects(['p1', 'p2']),
      ],
      highlights: [d],
    );
    final volta = Annotations.fromJson(a.toJson(baseVersion: 0));
    expect(volta.highlights.single.translation, 'estratégia de busca');
    expect(volta.highlights.single.projects, ['p1']);
    expect(volta.strokes.single.projects, ['p1', 'p2']);
    expect(_trace('t2').toJson().containsKey('projetos'), isFalse);
    final connected = volta.replace(volta.strokes.single.withProjects(const []));
    expect(connected.strokes.single.projects, isEmpty);
  });

  test('json ida e volta', () {
    final a = Annotations(
      version: 3,
      strokes: [_trace('t1')],
      highlights: [
        Highlight(
          id: 'd1',
          page: 2,
          text: 'trecho',
          color: const Color(0xFFFFEB3B),
          rectangles: const [Rect.fromLTRB(1, 2, 3, 4)],
          created: DateTime.utc(2026),
        ),
      ],
    );
    final j = a.toJson(baseVersion: 3);
    final b = Annotations.fromJson({...j, 'versao': 3});
    expect(b.strokes.single.points.last.x, 10);
    expect(b.highlights.single.rectangles.single, const Rect.fromLTRB(1, 2, 3, 4));
    expect(b.highlights.single.text, 'trecho');
  });

  test('mescla: adições e remoções locais sobre o que veio de outro aparelho', () {
    final t1 = _trace('t1');
    final t2 = _trace('t2');
    final base = Annotations(version: 1, strokes: [t1, t2]);
    final local = base.remover({'t1'}).adicionar(_trace('meu'));
    final server = Annotations(version: 2, strokes: [t1, t2, _trace('dele')]);
    final m = Annotations.merge(base, local, server);
    expect(m.strokes.map((t) => t.id), ['t2', 'dele', 'meu']);
    expect(m.version, 2);
  });

  test('retificar alinha a reta perto da horizontal e usa a pressão média', () {
    final r = straighten(const [InkPoint(0, 0, 0.2), InkPoint(50, 3, 0.6), InkPoint(100, 4, 1)]);
    expect(r, hasLength(2));
    expect(r.last.y, closeTo(0, 1e-9));
    expect(r.last.x, closeTo(100.08, 0.01));
    expect(r.first.p, closeTo(0.6, 1e-9));
  });

  test('borracha encosta no segmento', () {
    expect(touchesStroke(_trace('t'), const Offset(5, 6), 1), isTrue);
    expect(touchesStroke(_trace('t'), const Offset(5, 15), 1), isFalse);
  });

  test('trecho de texto vira um retângulo por linha', () {
    final chars = [
      for (var i = 0; i < 5; i++) Rect.fromLTWH(10.0 * i, 0, 9, 12),
      for (var i = 0; i < 5; i++) Rect.fromLTWH(10.0 * i, 20, 9, 12),
    ];
    expect(nearestChar(chars, const Offset(31, 25)), 8);
    final lines = excerptRects(chars, 2, 7);
    expect(lines, [const Rect.fromLTRB(20, 0, 49, 12), const Rect.fromLTRB(0, 20, 29, 32)]);
  });
}
