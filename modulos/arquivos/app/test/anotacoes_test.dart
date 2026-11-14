import 'dart:ui';

import 'package:agent_arquivos/src/leitor/geometria.dart';
import 'package:agent_arquivos/src/modelos.dart';
import 'package:flutter_test/flutter_test.dart';

Traco _traco(String id, [List<PontoTinta>? pontos]) => Traco(
  id: id,
  pagina: 0,
  pincel: Pincel.caneta,
  cor: const Color(0xFF000000),
  espessura: 2,
  pontos: pontos ?? const [PontoTinta(0, 0, 0.5), PontoTinta(10, 10, 0.5)],
);

void main() {
  test('projetos de leitura e tradução vão e voltam no json; ligar troca só o elemento', () {
    final d = Destaque(
      id: 'd1',
      pagina: 0,
      texto: 'search strategy',
      cor: const Color(0xFFFFEB3B),
      retangulos: const [],
      criado: DateTime.utc(2026),
    ).copiar(traducao: 'estratégia de busca', projetos: ['p1']);
    final a = Anotacoes(
      tracos: [
        _traco('t1').comProjetos(['p1', 'p2']),
      ],
      destaques: [d],
    );
    final volta = Anotacoes.fromJson(a.toJson(versaoBase: 0));
    expect(volta.destaques.single.traducao, 'estratégia de busca');
    expect(volta.destaques.single.projetos, ['p1']);
    expect(volta.tracos.single.projetos, ['p1', 'p2']);
    expect(_traco('t2').toJson().containsKey('projetos'), isFalse);
    final ligada = volta.substituir(volta.tracos.single.comProjetos(const []));
    expect(ligada.tracos.single.projetos, isEmpty);
  });

  test('json ida e volta', () {
    final a = Anotacoes(
      versao: 3,
      tracos: [_traco('t1')],
      destaques: [
        Destaque(
          id: 'd1',
          pagina: 2,
          texto: 'trecho',
          cor: const Color(0xFFFFEB3B),
          retangulos: const [Rect.fromLTRB(1, 2, 3, 4)],
          criado: DateTime.utc(2026),
        ),
      ],
    );
    final j = a.toJson(versaoBase: 3);
    final b = Anotacoes.fromJson({...j, 'versao': 3});
    expect(b.tracos.single.pontos.last.x, 10);
    expect(b.destaques.single.retangulos.single, const Rect.fromLTRB(1, 2, 3, 4));
    expect(b.destaques.single.texto, 'trecho');
  });

  test('mescla: adições e remoções locais sobre o que veio de outro aparelho', () {
    final t1 = _traco('t1');
    final t2 = _traco('t2');
    final base = Anotacoes(versao: 1, tracos: [t1, t2]);
    final local = base.remover({'t1'}).adicionar(_traco('meu'));
    final servidor = Anotacoes(versao: 2, tracos: [t1, t2, _traco('dele')]);
    final m = Anotacoes.mesclar(base, local, servidor);
    expect(m.tracos.map((t) => t.id), ['t2', 'dele', 'meu']);
    expect(m.versao, 2);
  });

  test('retificar alinha a reta perto da horizontal e usa a pressão média', () {
    final r = retificar(const [PontoTinta(0, 0, 0.2), PontoTinta(50, 3, 0.6), PontoTinta(100, 4, 1)]);
    expect(r, hasLength(2));
    expect(r.last.y, closeTo(0, 1e-9));
    expect(r.last.x, closeTo(100.08, 0.01));
    expect(r.first.p, closeTo(0.6, 1e-9));
  });

  test('borracha encosta no segmento', () {
    expect(tocaTraco(_traco('t'), const Offset(5, 6), 1), isTrue);
    expect(tocaTraco(_traco('t'), const Offset(5, 15), 1), isFalse);
  });

  test('trecho de texto vira um retângulo por linha', () {
    final chars = [
      for (var i = 0; i < 5; i++) Rect.fromLTWH(10.0 * i, 0, 9, 12),
      for (var i = 0; i < 5; i++) Rect.fromLTWH(10.0 * i, 20, 9, 12),
    ];
    expect(caractereMaisProximo(chars, const Offset(31, 25)), 8);
    final linhas = retangulosDoTrecho(chars, 2, 7);
    expect(linhas, [const Rect.fromLTRB(20, 0, 49, 12), const Rect.fromLTRB(0, 20, 29, 32)]);
  });
}
