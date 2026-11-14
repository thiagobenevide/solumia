import 'package:agent_design/src/design_api.dart';
import 'package:agent_design/src/cache.dart';
import 'package:agent_design/src/models.dart';
import 'package:agent_design/src/board/editor.dart';
import 'package:agent_design/src/notebook/notebook_screen.dart';
import 'package:agent_design/src/notebook/pen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final tam in [const Size(412, 915), const Size(800, 1280), const Size(1400, 900)]) {
  testWidgets('caderno cabe na tela em $tam', (t) async {
    SharedPreferences.setMockInitialValues({});
    final cache = await BoardCache.open();
    final editor = BoardEditor(ApiDesign('http://localhost:1'), cache,
        BoardSummary.fromJson({'id': 'q', 'titulo': 'Caderno', 'fundo': 'liso'}), [], offline: true)
      ..defaultPaper = const Paper();
    t.view.physicalSize = tam;
    t.view.devicePixelRatio = 1;
    await t.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: NotebookScreen(editor: editor, caneta: SmartPen())));
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.keyP);
    await t.pump();
    // The toolbar stays the size of the buttons (the Slider stretched it and it covered the notebook)
    // and the top bar does not overflow on any device.
    final bar = find.ancestor(of: find.byIcon(Icons.drag_indicator), matching: find.byType(SingleChildScrollView));
    expect(t.getRect(bar.first).height, lessThan(80));
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(minutes: 1));
    t.view.reset();
  });
  }
}
