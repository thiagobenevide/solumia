import 'package:agent_design/src/api_design.dart';
import 'package:agent_design/src/cache.dart';
import 'package:agent_design/src/modelos.dart';
import 'package:agent_design/src/quadro/editor.dart';
import 'package:agent_design/src/caderno/caderno_tela.dart';
import 'package:agent_design/src/caderno/caneta.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final tam in [const Size(412, 915), const Size(800, 1280), const Size(1400, 900)]) {
  testWidgets('caderno cabe na tela em $tam', (t) async {
    SharedPreferences.setMockInitialValues({});
    final cache = await CacheQuadros.abrir();
    final editor = EditorQuadro(ApiDesign('http://localhost:1'), cache,
        ResumoQuadro.fromJson({'id': 'q', 'titulo': 'Caderno', 'fundo': 'liso'}), [], offline: true)
      ..papelPadrao = const Papel();
    t.view.physicalSize = tam;
    t.view.devicePixelRatio = 1;
    await t.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: CadernoTela(editor: editor, caneta: CanetaInteligente())));
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.keyP);
    await t.pump();
    // A barra de ferramentas fica do tamanho dos botões (o Slider esticava e ela cobria o caderno)
    // e a barra superior não estoura em nenhum aparelho.
    final barra = find.ancestor(of: find.byIcon(Icons.drag_indicator), matching: find.byType(SingleChildScrollView));
    expect(t.getRect(barra.first).height, lessThan(80));
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(minutes: 1));
    t.view.reset();
  });
  }
}
