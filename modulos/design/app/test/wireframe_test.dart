import 'dart:ui';

import 'package:agent_design/src/wireframe/modelo.dart';
import 'package:agent_design/src/wireframe/pintura.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('linhas da nota: "Rótulo: texto" vira rótulo, o resto é texto corrido', () {
    final n = Nota(1)..linhasTexto = 'Endpoint: POST /x\n\nsem rótulo aqui';
    expect(n.linhas, [('Endpoint', 'POST /x'), ('', 'sem rótulo aqui')]);
    expect(Nota.fromJson(n.toJson()).linhasTexto, 'Endpoint: POST /x\nsem rótulo aqui');
  });

  test('tabela se ajusta às colunas e linhas', () {
    final c = Componente(id: 't', tipo: 'tabela', pagina: 'p', caixa: const Rect.fromLTWH(10, 20, 1, 1), props: {
      'colunas': [
        {'titulo': 'A', 'largura': 100},
        {'titulo': 'B', 'largura': 50},
      ],
      'linhas': [
        ['1', '2'],
      ],
      'altura_linha': 30,
    });
    ajustarTamanho(c);
    expect(c.caixa, const Rect.fromLTWH(10, 20, 150, 60));
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
    final c = w.componentes.single;
    expect(c.pagina, 't1');
    final copia = c.copiar(id: 'm2', deslocar: const Offset(16, 16));
    (copia.props['itens'] as List).add({'texto': 'x'});
    expect(c.props['itens'], isEmpty);
    expect(copia.caixa.topLeft, const Offset(16, 16));
  });

  test('renderiza a tela inteira em PNG com todos os tipos do catálogo', () async {
    final tela = TelaWf.fromJson({'id': 't', 'nome': 'Tela', 'codigo': 'WF-01', 'largura': 800, 'altura': 600, 'notas': [Nota(1, titulo: 'x').toJson()]});
    final comps = [
      for (final MapEntry(key: tipo, value: (_, tam, props)) in catalogo.entries)
        Componente(id: tipo, tipo: tipo, pagina: 't', caixa: Offset.zero & tam, estado: EstadoWf.proposto, props: {...props, 'nota': 1}),
    ];
    final png = await renderizarTela(tela, comps);
    expect(png.sublist(1, 4), 'PNG'.codeUnits);
  });
}
