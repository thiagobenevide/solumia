import 'dart:ui';

import 'package:agent_design/src/wireframe/model.dart';
import 'package:agent_design/src/wireframe/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('linhas da nota: "Rótulo: texto" vira rótulo, o resto é texto corrido', () {
    final n = StickyNote(1)..textLines = 'Endpoint: POST /x\n\nsem rótulo aqui';
    expect(n.linhas, [('Endpoint', 'POST /x'), ('', 'sem rótulo aqui')]);
    expect(StickyNote.fromJson(n.toJson()).textLines, 'Endpoint: POST /x\nsem rótulo aqui');
  });

  test('tabela se ajusta às colunas e linhas', () {
    final c = WfComponent(id: 't', type: 'tabela', page: 'p', box: const Rect.fromLTWH(10, 20, 1, 1), props: {
      'colunas': [
        {'titulo': 'A', 'largura': 100},
        {'titulo': 'B', 'largura': 50},
      ],
      'linhas': [
        ['1', '2'],
      ],
      'altura_linha': 30,
    });
    fitSize(c);
    expect(c.box, const Rect.fromLTWH(10, 20, 150, 60));
  });

  test('componente sem página vai para a primeira tela e a cópia não divide props', () {
    final w = Wireframe.fromJson({
      'id': 'w',
      'paginas': [
        {'id': 't1', 'nome': 'A'},
      ],
      'elementos': [
        {'id': 'm', 'tipo': 'menu', 'x': 0, 'y': 0, 'w': 240, 'h': 40, 'props': {'itens': <Object>[]}},
      ],
    });
    final c = w.components.single;
    expect(c.page, 't1');
    final copy = c.copyItems(id: 'm2', shift: const Offset(16, 16));
    (copy.props['itens'] as List).add({'texto': 'x'});
    expect(c.props['itens'], isEmpty);
    expect(copy.box.topLeft, const Offset(16, 16));
  });

  test('renderiza a tela inteira em PNG com todos os tipos do catálogo', () async {
    final screen = WfScreen.fromJson({'id': 't', 'nome': 'Tela', 'codigo': 'WF-01', 'largura': 800, 'altura': 600, 'notas': [StickyNote(1, title: 'x').toJson()]});
    final comps = [
      for (final MapEntry(key: type, value: (_, tam, props)) in catalog.entries)
        WfComponent(id: type, type: type, page: 't', box: Offset.zero & tam, state: WfState.proposto, props: {...props, 'nota': 1}),
    ];
    final png = await renderScreen(screen, comps);
    expect(png.sublist(1, 4), 'PNG'.codeUnits);
  });
}
