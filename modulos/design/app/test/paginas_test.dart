import 'package:agent_design/src/api_design.dart';
import 'package:agent_design/src/cache.dart';
import 'package:agent_design/src/modelos.dart';
import 'package:agent_design/src/quadro/editor.dart';
import 'package:agent_design/src/quadro/quadro_tela.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _cor = Color(0xFF1565C0);
NoFluxo _no(String id, double y, {TipoNo tipo = TipoNo.processo}) =>
    NoFluxo(id, tipo: tipo, texto: id.toUpperCase(), a: Offset(0, y), b: Offset(190, y + 80), cor: _cor);

Future<EditorQuadro> _editor() async {
  SharedPreferences.setMockInitialValues({});
  return EditorQuadro(
    ApiDesign('http://localhost:1'),
    await CacheQuadros.abrir(),
    ResumoQuadro.fromJson({
      'id': 'q',
      'titulo': 'Verbas',
      'fundo': 'grade',
      'paginas': [
        {'id': 'p1', 'nome': '01 - Investimento'},
        {'id': 'p2', 'nome': '02 - Verba CVB'},
      ],
    }),
    [_no('a', 0), _no('b', 200), _no('c', 0, tipo: TipoNo.decisao)],
    paginaDe: const {'a': 'p1', 'b': 'p1', 'c': 'p2'},
    offline: true,
  );
}

Future<void> _abrir(WidgetTester t, EditorQuadro e, Size tamanho) async {
  t.view.physicalSize = tamanho;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(home: QuadroTela(editor: e)));
  await t.pumpAndSettle();
}

Future<void> _fechar(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(minutes: 1));
}

void main() {
  test('páginas: cada uma mostra o seu; o que se cria fica na página aberta', () async {
    final e = await _editor();
    expect(e.elementos.map((x) => x.id), ['a', 'b']);
    e.irPara('p2');
    expect(e.elementos.map((x) => x.id), ['c']);
    e.adicionar(_no('d', 300));
    e.remover({'c'});
    e.irPara('p1');
    expect(e.elementos.map((x) => x.id), ['a', 'b']); // a p1 não mudou
    e.irPara('p2');
    expect(e.elementos.map((x) => x.id), ['d']);
    e.desfazer();
    expect(e.elementos.map((x) => x.id), ['c', 'd']);
    e.dispose();
  });

  testWidgets('PC: formas e estilo fixos nos lados, abas embaixo trocam de página', (t) async {
    final e = await _editor();
    await _abrir(t, e, const Size(1600, 900));
    expect(t.takeException(), isNull);
    expect(find.text('Procurar formas'), findsOneWidget); // painel de formas
    expect(find.text('Diagrama'), findsOneWidget); // painel de estilo sem seleção
    expect(find.text('01 - Investimento'), findsOneWidget);
    await t.tap(find.text('02 - Verba CVB'));
    await t.pumpAndSettle();
    expect(e.paginaAtual, 'p2');
    // toca na forma "Banco de dados" do painel: entra na página aberta, selecionada
    await t.tap(find.byTooltip('Banco de dados'));
    await t.pumpAndSettle();
    final banco = e.elementos.whereType<NoFluxo>().singleWhere((n) => n.tipo == TipoNo.banco);
    // o estilo muda a forma e o preenchimento da seleção
    expect(find.text('Preenchimento'), findsOneWidget);
    await t.tap(find.byType(DropdownButtonFormField<TipoNo>));
    await t.pumpAndSettle();
    await t.tap(find.text('Hexágono').last);
    await t.pumpAndSettle();
    expect((e.elementos.singleWhere((x) => x.id == banco.id) as NoFluxo).tipo, TipoNo.hexagono);
    expect(t.takeException(), isNull);
    await _fechar(t);
  });

  testWidgets('celular: formas e estilo em gavetas', (t) async {
    final e = await _editor();
    await _abrir(t, e, const Size(400, 800));
    expect(t.takeException(), isNull);
    expect(find.text('Procurar formas'), findsNothing);
    await t.tap(find.byTooltip('Formas'));
    await t.pumpAndSettle();
    expect(find.text('Procurar formas'), findsOneWidget);
    await t.tap(find.byTooltip('Nota'));
    await t.pumpAndSettle();
    expect(e.elementos.whereType<NoFluxo>().where((n) => n.tipo == TipoNo.nota), hasLength(1));
    await t.tap(find.byTooltip('Estilo'));
    await t.pumpAndSettle();
    expect(find.text('Borda'), findsOneWidget);
    expect(t.takeException(), isNull);
    await _fechar(t);
  });

  test('a página de cada elemento vai junto no JSON e volta', () {
    final j = jsonComPagina(_no('a', 0), {'a': 'p2'});
    expect(j['pagina'], 'p2');
    final q = Quadro.fromJson({'id': 'q', 'elementos': [j], 'paginas': [{'id': 'p2', 'nome': 'X'}]});
    expect(q.paginaDe, {'a': 'p2'});
    expect(q.resumo.paginas.single.nome, 'X');
  });
}
