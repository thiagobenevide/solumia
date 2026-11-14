import 'dart:convert';
import 'dart:io';

import 'package:agent_eletronica/src/api_eletronica.dart';
import 'package:agent_eletronica/src/cad/cad_tela.dart';
import 'package:agent_eletronica/src/cad/pintura.dart';
import 'package:agent_eletronica/src/modelos.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Símbolos reais do backend (`biblioteca.py`), gerados uma vez para o teste.
final _simbolos = jsonDecode(File('test/simbolos.json').readAsStringSync()) as List;

void main() {
  testWidgets('coloca um resistor, puxa um fio e gira pela tela', (t) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final biblioteca = Biblioteca([for (final s in _simbolos) Simbolo.fromJson(s as Map<String, dynamic>)]);
    final projeto = Projeto.fromJson({
      'id': 'p',
      'titulo': 'Teste',
      'versao': 1,
      'folhas': [{'id': 'f1', 'nome': 'Folha 1'}],
    });
    await t.pumpWidget(MaterialApp(home: CadTela(api: ApiEletronica('http://localhost:1'), projeto: projeto, biblioteca: biblioteca)));
    await t.pumpAndSettle();

    await t.tap(find.text('Resistor'));
    await t.pump();
    final tela = t.getCenter(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is PintorCad));
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tela);
    await mouse.moveTo(tela);
    await t.pump();
    await mouse.down(tela);
    await mouse.up();
    await t.pump();
    expect(projeto.componentes.single.ref, 'R1');

    await t.sendKeyEvent(LogicalKeyboardKey.keyW);
    for (final d in [const Offset(-200, 0), const Offset(-200, 120), const Offset(-200, 120)]) {
      await mouse.down(tela + d);
      await mouse.up();
      await t.pump();
    }
    expect(projeto.fios.single.pontos.length, 2);

    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await mouse.down(tela);
    await mouse.up();
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.keyR);
    await t.pump();
    expect(projeto.componentes.single.rot, 90);
    await t.sendKeyEvent(LogicalKeyboardKey.delete);
    await t.pump();
    expect(projeto.componentes, isEmpty);
    await t.sendKeyEvent(LogicalKeyboardKey.keyZ);
    // Ctrl+Z precisa do Ctrl apertado; a barra também desfaz.
    await t.tap(find.byTooltip('Desfazer (Ctrl+Z)'));
    await t.pump();
    expect(projeto.componentes.length, 1);
    await t.pump(const Duration(seconds: 1));
    await t.pumpWidget(const SizedBox());
  });
}
