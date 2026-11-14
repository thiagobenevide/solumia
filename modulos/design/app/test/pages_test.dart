import 'package:agent_design/src/design_api.dart';
import 'package:agent_design/src/cache.dart';
import 'package:agent_design/src/models.dart';
import 'package:agent_design/src/board/editor.dart';
import 'package:agent_design/src/board/board_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _color = Color(0xFF1565C0);
FlowNode _no(String id, double y, {NodeKind type = NodeKind.processo}) =>
    FlowNode(id, type: type, text: id.toUpperCase(), a: Offset(0, y), b: Offset(190, y + 80), color: _color);

Future<BoardEditor> _editor() async {
  SharedPreferences.setMockInitialValues({});
  return BoardEditor(
    ApiDesign('http://localhost:1'),
    await BoardCache.open(),
    BoardSummary.fromJson({
      'id': 'q',
      'titulo': 'Verbas',
      'fundo': 'grade',
      'paginas': [
        {'id': 'p1', 'nome': '01 - Investimento'},
        {'id': 'p2', 'nome': '02 - Verba CVB'},
      ],
    }),
    [_no('a', 0), _no('b', 200), _no('c', 0, type: NodeKind.decisao)],
    pageOf: const {'a': 'p1', 'b': 'p1', 'c': 'p2'},
    offline: true,
  );
}

Future<void> _open(WidgetTester t, BoardEditor e, Size size) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(home: BoardScreen(editor: e)));
  await t.pumpAndSettle();
}

Future<void> _close(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(minutes: 1));
}

void main() {
  test('páginas: cada uma mostra o seu; o que se cria fica na página aberta', () async {
    final e = await _editor();
    expect(e.elements.map((x) => x.id), ['a', 'b']);
    e.goTo('p2');
    expect(e.elements.map((x) => x.id), ['c']);
    e.adicionar(_no('d', 300));
    e.remover({'c'});
    e.goTo('p1');
    expect(e.elements.map((x) => x.id), ['a', 'b']); // p1 did not change
    e.goTo('p2');
    expect(e.elements.map((x) => x.id), ['d']);
    e.undo();
    expect(e.elements.map((x) => x.id), ['c', 'd']);
    e.dispose();
  });

  testWidgets('PC: formas e estilo fixos nos lados, abas embaixo trocam de página', (t) async {
    final e = await _editor();
    await _open(t, e, const Size(1600, 900));
    expect(t.takeException(), isNull);
    expect(find.text('Procurar formas'), findsOneWidget); // shapes panel
    expect(find.text('Diagrama'), findsOneWidget); // style panel without selection
    expect(find.text('01 - Investimento'), findsOneWidget);
    await t.tap(find.text('02 - Verba CVB'));
    await t.pumpAndSettle();
    expect(e.currentPage, 'p2');
    // taps the "Banco de dados" shape of the panel: goes into the open page, selected
    await t.tap(find.byTooltip('Banco de dados'));
    await t.pumpAndSettle();
    final banco = e.elements.whereType<FlowNode>().singleWhere((n) => n.type == NodeKind.banco);
    // the style changes the shape and the fill of the selection
    expect(find.text('Preenchimento'), findsOneWidget);
    await t.tap(find.byType(DropdownButtonFormField<NodeKind>));
    await t.pumpAndSettle();
    await t.tap(find.text('Hexágono').last);
    await t.pumpAndSettle();
    expect((e.elements.singleWhere((x) => x.id == banco.id) as FlowNode).type, NodeKind.hexagono);
    expect(t.takeException(), isNull);
    await _close(t);
  });

  testWidgets('celular: formas e estilo em gavetas', (t) async {
    final e = await _editor();
    await _open(t, e, const Size(400, 800));
    expect(t.takeException(), isNull);
    expect(find.text('Procurar formas'), findsNothing);
    await t.tap(find.byTooltip('Formas'));
    await t.pumpAndSettle();
    expect(find.text('Procurar formas'), findsOneWidget);
    await t.tap(find.byTooltip('Nota'));
    await t.pumpAndSettle();
    expect(e.elements.whereType<FlowNode>().where((n) => n.type == NodeKind.nota), hasLength(1));
    await t.tap(find.byTooltip('Estilo'));
    await t.pumpAndSettle();
    expect(find.text('Borda'), findsOneWidget);
    expect(t.takeException(), isNull);
    await _close(t);
  });

  test('a página de cada elemento vai junto no JSON e volta', () {
    final j = jsonWithPage(_no('a', 0), {'a': 'p2'});
    expect(j['pagina'], 'p2');
    final q = Board.fromJson({'id': 'q', 'elementos': [j], 'paginas': [{'id': 'p2', 'nome': 'X'}]});
    expect(q.pageOf, {'a': 'p2'});
    expect(q.summary.pages.single.name, 'X');
  });
}
