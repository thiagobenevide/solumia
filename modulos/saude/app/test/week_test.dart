import 'package:agent_saude/src/health_api.dart';
import 'package:agent_saude/src/dates.dart';
import 'package:agent_saude/src/models.dart';
import 'package:agent_saude/src/screens/calendar.dart';
import 'package:agent_saude/src/screens/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final day = today();
  final item = ItemAgenda.fromJson({
    'id': 'i1',
    'data': iso(day),
    'exercicio_id': 'elevacao',
    'ordem': 0,
    'series': 3,
    'repeticoes': '12-15',
    'feito': false,
  });
  final agenda = Agenda(
    api: HealthApi('http://teste'),
    dayItems: (d) => sameDay(d, day) ? [item, item] : const [],
    exercise: (_) => null,
    drop: (_, _) {},
    openItem: (_) {},
    toggleDone: (_) {},
    openDay: (_) {},
    imageVersion: (_) => 0,
  );

  // Window widths on the PC (with the catalog beside) and on the phone: nothing may overflow.
  for (final width in const [360.0, 640.0, 700.0, 900.0, 1200.0, 1920.0]) {
    testWidgets('semana em ${width.toInt()} px mostra o exercício inteiro', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: WeekView(agenda: agenda, focus: day)),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('3 × 12-15'), findsWidgets);
      // the summary stays on a single line (before, it wrapped letter by letter)
      final summary = tester.getSize(find.text('3 × 12-15').first);
      expect(summary.height, lessThan(24));
    });
  }
}
