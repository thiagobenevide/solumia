import 'package:agent_eletronica/src/modelos.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('transformar gira no sentido horário e espelha antes (igual ao backend)', () {
    const pino = P(-3 * grade, 0);
    expect(transformar(pino, 90, false), const P(0, -3 * grade));
    expect(transformar(pino, 180, false), const P(3 * grade, 0));
    expect(transformar(pino, 0, true), const P(3 * grade, 0));
    expect(transformar(pino, 90, true), const P(0, 3 * grade));
  });

  test('rota ortogonal em L e simplificação de cantos', () {
    expect(rotaOrtogonal(const P(0, 0), const P(10, 5)), [const P(0, 0), const P(10, 0), const P(10, 5)]);
    expect(rotaOrtogonal(const P(0, 0), const P(10, 5), horizontalPrimeiro: false), [const P(0, 0), const P(0, 5), const P(10, 5)]);
    expect(rotaOrtogonal(const P(0, 0), const P(10, 0)), [const P(0, 0), const P(10, 0)]);
    expect(simplificar([const P(0, 0), const P(5, 0), const P(5, 0), const P(10, 0), const P(10, 3)]), [
      const P(0, 0),
      const P(10, 0),
      const P(10, 3),
    ]);
  });

  test('próxima referência e junções', () {
    Componente r(String ref) => Componente(folha: 'f1', simbolo: 'resistor', ref: ref, valor: '', encapsulamento: '', pos: const P(0, 0));
    expect(proximaRef('R', [r('R1'), r('R7'), r('RV2')]), 'R8');
    expect(proximaRef('C', [r('R1')]), 'C1');

    final fios = [
      Fio(folha: 'f1', pontos: [const P(0, 0), const P(100, 0)]),
      Fio(folha: 'f1', pontos: [const P(50, 0), const P(50, 50)]), // T no meio do primeiro
      Fio(folha: 'f1', pontos: [const P(80, -20), const P(80, 20)]), // só cruza
    ];
    expect(juncoes(fios, [const P(100, 0)]), {const P(50, 0)});
  });

  test('projeto ida e volta em JSON', () {
    final p = Projeto.fromJson({
      'id': 'x',
      'titulo': 'Fonte',
      'versao': 3,
      'folhas': [{'id': 'f1', 'nome': 'Folha 1'}],
      'componentes': [
        {'id': 'a', 'folha': 'f1', 'simbolo': 'resistor', 'ref': 'R1', 'valor': '1k', 'encapsulamento': 'R_0603', 'x': 1270, 'y': 0, 'rot': 90, 'espelho': true},
      ],
      'fios': [
        {'id': 'w', 'folha': 'f1', 'pontos': [[0, 0], [1270, 0]]},
      ],
    });
    final j = p.esquematicoJson();
    expect((j['componentes'] as List).single['rot'], 90);
    expect((j['fios'] as List).single['pontos'], [[0, 0], [1270, 0]]);
    expect(p.itens('f1').length, 2);
  });

  test('símbolo importado: flags de pinos, unidade e símbolo que sumiu', () {
    final s = Simbolo.fromJson({
      'id': 'Device:R',
      'nome': 'R',
      'categoria': 'Device',
      'prefixo': 'R',
      'tipo': 'componente',
      'desenho': [],
      'pinos': [
        {'n': '1', 'x': 0, 'y': -3810, 'dir': 'b', 'comp': 1270, 'oculto': true},
      ],
      'campos': {'ref': [2032, 0], 'valor': [0, 0]},
      'nomes_pinos': false,
      'numeros_pinos': false,
      'descricao': 'Resistor',
    });
    expect([s.importado, s.numerosPinos, s.pinos.single.oculto, s.descricao], [true, false, true, 'Resistor']);
    final b = Biblioteca([])..adicionar([s]);
    expect(b.de('Device:R'), same(s));
    expect(b.de('Sumiu:X').pinos, isEmpty);
    expect(b.buscar('r'), isEmpty); // a busca local é só da base
  });
}
