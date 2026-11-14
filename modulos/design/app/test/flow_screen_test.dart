import 'package:agent_design/src/design_api.dart';
import 'package:agent_design/src/cache.dart';
import 'package:agent_design/src/models.dart';
import 'package:agent_design/src/board/editor.dart';
import 'package:agent_design/src/board/board_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _color = Color(0xFF1565C0);
final _a = FlowNode('a', type: NodeKind.processo, text: 'A', a: const Offset(0, 0), b: const Offset(190, 80), color: _color);
final _b = FlowNode('b', type: NodeKind.processo, text: 'B', a: const Offset(0, 300), b: const Offset(190, 380), color: _color);
final _l = Connector('l', de: 'a', to: 'b', a: Offset.zero, b: Offset.zero, color: _color);

Future<BoardEditor> _open(WidgetTester t) async {
  SharedPreferences.setMockInitialValues({});
  final cache = await BoardCache.open();
  final editor = BoardEditor(
    ApiDesign('http://localhost:1'),
    cache,
    BoardSummary.fromJson({'id': 'q', 'titulo': 'Fluxo', 'fundo': 'liso'}),
    reconnect([_a, _b, _l]),
    offline: true,
  );
  t.view.physicalSize = const Size(1200, 900);
  t.view.devicePixelRatio = 1;
  await t.pumpWidget(MaterialApp(home: BoardScreen(editor: editor)));
  await t.pump();
  await t.sendKeyEvent(LogicalKeyboardKey.keyV); // Selection tool
  await t.pump();
  return editor;
}

Future<void> _close(WidgetTester t, BoardEditor editor) async {
  await t.pumpWidget(const SizedBox()); // the screen disposes the editor
  await t.pump(const Duration(minutes: 1)); // lets the save (offline) and the tooltips finish
  t.view.reset();
}

Offset _onScreen(WidgetTester t, Offset world, BoardEditor e) {
  // The camera frames the board bounds on screen: converts through the blocks' own rectangle.
  final lim = e.bounds!;
  final area = t.getRect(find.byType(BoardScreen));
  final scale = (area.height * 0.8 / lim.height).clamp(0.0, area.width * 0.8 / lim.width);
  return area.center + (world - lim.center) * scale;
}

void main() {
  testWidgets('arrastar um bloco direto o move e a seta acompanha', (t) async {
    final editor = await _open(t);
    final antes = editor.elements.whereType<Connector>().single.b;
    final g = await t.startGesture(_onScreen(t, _b.retangulo.center, editor), kind: PointerDeviceKind.mouse);
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(30, 0));
      await t.pump();
    }
    await g.up();
    await t.pump();
    final b = editor.elements.whereType<FlowNode>().firstWhere((n) => n.id == 'b');
    expect(b.retangulo.left, greaterThan(_b.retangulo.left + 50));
    final seta = editor.elements.whereType<Connector>().single;
    expect(seta.b, isNot(antes));
    expect(b.retangulo.inflate(0.5).contains(seta.b), isTrue);
    await _close(t, editor);
  });

  testWidgets('puxar a alça para o vazio cria um bloco novo ligado', (t) async {
    final editor = await _open(t);
    // selects block A with a tap
    await t.tapAt(_onScreen(t, _a.retangulo.center, editor), kind: PointerDeviceKind.mouse);
    await t.pump();
    final handles = find.byTooltip('Arraste até outro bloco (ou para o vazio, criando um novo)');
    expect(handles, findsNWidgets(4));
    // right handle → drag far away
    await t.drag(handles.at(1), const Offset(300, 0));
    await t.pumpAndSettle();
    // the new block opens typing right on the board; Esc finishes
    expect(find.byType(AlertDialog), findsNothing);
    await t.enterText(find.byType(TextField).last, 'Validar pedido');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    final nos = editor.elements.whereType<FlowNode>().toList();
    expect(nos.length, 3);
    expect(nos.last.text, 'Validar pedido');
    final arrows = editor.elements.whereType<Connector>().where((l) => l.de == 'a');
    expect(arrows.map((l) => l.to), contains(nos.last.id));
    await _close(t, editor);
  });
}
