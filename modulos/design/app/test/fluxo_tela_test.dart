import 'package:agent_design/src/api_design.dart';
import 'package:agent_design/src/cache.dart';
import 'package:agent_design/src/modelos.dart';
import 'package:agent_design/src/quadro/editor.dart';
import 'package:agent_design/src/quadro/quadro_tela.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _cor = Color(0xFF1565C0);
final _a = NoFluxo('a', tipo: TipoNo.processo, texto: 'A', a: const Offset(0, 0), b: const Offset(190, 80), cor: _cor);
final _b = NoFluxo('b', tipo: TipoNo.processo, texto: 'B', a: const Offset(0, 300), b: const Offset(190, 380), cor: _cor);
final _l = Ligacao('l', de: 'a', para: 'b', a: Offset.zero, b: Offset.zero, cor: _cor);

Future<EditorQuadro> _abrir(WidgetTester t) async {
  SharedPreferences.setMockInitialValues({});
  final cache = await CacheQuadros.abrir();
  final editor = EditorQuadro(
    ApiDesign('http://localhost:1'),
    cache,
    ResumoQuadro.fromJson({'id': 'q', 'titulo': 'Fluxo', 'fundo': 'liso'}),
    religar([_a, _b, _l]),
    offline: true,
  );
  t.view.physicalSize = const Size(1200, 900);
  t.view.devicePixelRatio = 1;
  await t.pumpWidget(MaterialApp(home: QuadroTela(editor: editor)));
  await t.pump();
  await t.sendKeyEvent(LogicalKeyboardKey.keyV); // ferramenta Seleção
  await t.pump();
  return editor;
}

Future<void> _fechar(WidgetTester t, EditorQuadro editor) async {
  await t.pumpWidget(const SizedBox()); // a tela descarta o editor
  await t.pump(const Duration(minutes: 1)); // deixa terminar a gravação (offline) e os tooltips
  t.view.reset();
}

Offset _naTela(WidgetTester t, Offset mundo, EditorQuadro e) {
  // A câmera enquadra os limites do quadro na tela: converte pelo próprio retângulo dos blocos.
  final lim = e.limites!;
  final area = t.getRect(find.byType(QuadroTela));
  final escala = (area.height * 0.8 / lim.height).clamp(0.0, area.width * 0.8 / lim.width);
  return area.center + (mundo - lim.center) * escala;
}

void main() {
  testWidgets('arrastar um bloco direto o move e a seta acompanha', (t) async {
    final editor = await _abrir(t);
    final antes = editor.elementos.whereType<Ligacao>().single.b;
    final g = await t.startGesture(_naTela(t, _b.retangulo.center, editor), kind: PointerDeviceKind.mouse);
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(30, 0));
      await t.pump();
    }
    await g.up();
    await t.pump();
    final b = editor.elementos.whereType<NoFluxo>().firstWhere((n) => n.id == 'b');
    expect(b.retangulo.left, greaterThan(_b.retangulo.left + 50));
    final seta = editor.elementos.whereType<Ligacao>().single;
    expect(seta.b, isNot(antes));
    expect(b.retangulo.inflate(0.5).contains(seta.b), isTrue);
    await _fechar(t, editor);
  });

  testWidgets('puxar a alça para o vazio cria um bloco novo ligado', (t) async {
    final editor = await _abrir(t);
    // seleciona o bloco A com um toque
    await t.tapAt(_naTela(t, _a.retangulo.center, editor), kind: PointerDeviceKind.mouse);
    await t.pump();
    final alcas = find.byTooltip('Arraste até outro bloco (ou para o vazio, criando um novo)');
    expect(alcas, findsNWidgets(4));
    // alça da direita → arrasta para longe
    await t.drag(alcas.at(1), const Offset(300, 0));
    await t.pumpAndSettle();
    // o bloco novo já abre a digitação no próprio quadro; Esc conclui
    expect(find.byType(AlertDialog), findsNothing);
    await t.enterText(find.byType(TextField).last, 'Validar pedido');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    final nos = editor.elementos.whereType<NoFluxo>().toList();
    expect(nos.length, 3);
    expect(nos.last.texto, 'Validar pedido');
    final setas = editor.elementos.whereType<Ligacao>().where((l) => l.de == 'a');
    expect(setas.map((l) => l.para), contains(nos.last.id));
    await _fechar(t, editor);
  });
}
