import 'dart:convert';
import 'dart:io';

import 'package:agent_eletronica/src/electronics_api.dart';
import 'package:agent_eletronica/src/cad/cad_screen.dart';
import 'package:agent_eletronica/src/cad/painting.dart';
import 'package:agent_eletronica/src/models.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Real backend symbols (`biblioteca.py`), generated once for the test.
final _symbols = jsonDecode(File('test/simbolos.json').readAsStringSync()) as List;

void main() {
  testWidgets('coloca um resistor, puxa um fio e gira pela tela', (t) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final library = Library([for (final s in _symbols) Symbol.fromJson(s as Map<String, dynamic>)]);
    final project = Project.fromJson({
      'id': 'p',
      'titulo': 'Teste',
      'versao': 1,
      'folhas': [{'id': 'f1', 'nome': 'Folha 1'}],
    });
    await t.pumpWidget(MaterialApp(home: CadScreen(api: ElectronicsApi('http://localhost:1'), project: project, library: library)));
    await t.pumpAndSettle();

    await t.tap(find.text('Resistor'));
    await t.pump();
    final screen = t.getCenter(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is CadPainter));
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: screen);
    await mouse.moveTo(screen);
    await t.pump();
    await mouse.down(screen);
    await mouse.up();
    await t.pump();
    expect(project.components.single.ref, 'R1');

    await t.sendKeyEvent(LogicalKeyboardKey.keyW);
    for (final d in [const Offset(-200, 0), const Offset(-200, 120), const Offset(-200, 120)]) {
      await mouse.down(screen + d);
      await mouse.up();
      await t.pump();
    }
    expect(project.wires.single.points.length, 2);

    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await mouse.down(screen);
    await mouse.up();
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.keyR);
    await t.pump();
    expect(project.components.single.rot, 90);
    await t.sendKeyEvent(LogicalKeyboardKey.delete);
    await t.pump();
    expect(project.components, isEmpty);
    await t.sendKeyEvent(LogicalKeyboardKey.keyZ);
    // Ctrl+Z needs Ctrl pressed; the toolbar also undoes.
    await t.tap(find.byTooltip('Desfazer (Ctrl+Z)'));
    await t.pump();
    expect(project.components.length, 1);
    await t.pump(const Duration(seconds: 1));
    await t.pumpWidget(const SizedBox());
  });
}
