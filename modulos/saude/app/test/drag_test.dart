import 'dart:convert';

import 'package:agent_saude/src/health_api.dart';
import 'package:agent_saude/src/dates.dart';
import 'package:agent_saude/src/screens/workouts_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Fake `/api/saude` backend with two exercises and the schedule in memory.
class _Server {
  final itens = <Map<String, dynamic>>[];
  final requests = <String>[];

  static Map<String, dynamic> _ex(String id, String name) => {
    'id': id,
    'nome': name,
    'area': 'Peito',
    'grupo': 'Peitoral',
    'equipamento': 'Peso do corpo',
    'ref': null,
    'series': 3,
    'repeticoes': '12',
    'carga_kg': null,
    'instrucoes': '',
    'personalizado': false,
    'imagem_propria': false,
  };

  late final cliente = MockClient((r) async {
    requests.add('${r.method} ${r.url.path}');
    final path = r.url.path;
    if (path == '/api/saude/exercicios') {
      return _json({
        'areas': ['Peito', 'Costas'],
        'exercicios': [_ex('flexao', 'Flexão de braço'), _ex('supino', 'Supino com halteres')],
      });
    }
    if (path == '/api/saude/agenda' && r.method == 'GET') {
      final de = r.url.queryParameters['de']!, ate = r.url.queryParameters['ate']!;
      return _json([
        for (final i in itens)
          if ((i['data'] as String).compareTo(de) >= 0 && (i['data'] as String).compareTo(ate) <= 0) i,
      ]);
    }
    if (path == '/api/saude/agenda' && r.method == 'POST') {
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      final item = {
        'id': 'i${itens.length}',
        'data': body['data'],
        'exercicio_id': body['exercicio_id'],
        'ordem': 0,
        'series': 3,
        'repeticoes': '12',
        'carga_kg': null,
        'observacao': '',
        'feito': false,
      };
      itens.add(item);
      return _json(item, 201);
    }
    if (path.startsWith('/api/saude/agenda/') && r.method == 'PATCH') {
      final item = itens.firstWhere((i) => i['id'] == path.split('/').last);
      item.addAll(jsonDecode(r.body) as Map<String, dynamic>);
      return _json(item);
    }
    return http.Response('{"detail": "não encontrado"}', 404);
  });

  static http.Response _json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});
}

Future<_Server> _open(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final server = _Server();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: WorkoutsScreen(api: HealthApi('http://teste', cliente: server.cliente))),
    ),
  );
  await tester.pumpAndSettle();
  return server;
}

/// Drags from [from] to [to]: with the mouse it starts right away; on touch it needs a long press.
Future<void> _drag(WidgetTester tester, Finder de, Offset to, {required bool tap}) async {
  final gesture = await tester.startGesture(
    tester.getCenter(de),
    kind: tap ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
  );
  if (tap) await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
  await gesture.moveBy(const Offset(-20, 0));
  await tester.pump();
  await gesture.moveTo(to);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

/// Point inside the day column (below the label) in the week view.
Offset _withinDay(WidgetTester tester, String label) => tester.getCenter(find.text(label)) + const Offset(0, 40);

void main() {
  final monday = weekStart(today());
  final wednesday = addDays(monday, 2);
  final friday = addDays(monday, 4);
  String column(DateTime d) => '${weekdays[d.weekday - 1]} ${d.day}';

  testWidgets('PC: biblioteca à direita, arrasta com o mouse e move entre dias', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final server = await _open(tester, const Size(1400, 900));

    expect(find.text('Exercícios'), findsOneWidget); // library already open on the wide screen
    await tester.tap(find.text('Peito'));
    await tester.pumpAndSettle();
    await _drag(tester, find.text('Flexão de braço'), _withinDay(tester, column(wednesday)), tap: false);

    expect(server.itens.single['data'], iso(wednesday));
    expect(find.text('Flexão de braço'), findsNWidgets(2)); // in the library and in the calendar
    expect(find.text('3 × 12'), findsOneWidget);

    // moves the placed item from Wednesday to Friday
    await _drag(tester, find.text('3 × 12'), _withinDay(tester, column(friday)), tap: false);
    expect(server.itens.single['data'], iso(friday));
    expect(server.requests.where((p) => p.startsWith('PATCH')), hasLength(1));
    debugDefaultTargetPlatformOverride = null;
  });

  for (final (name, size) in const [('celular', Size(400, 860)), ('tablet em pé', Size(800, 1280))]) {
    testWidgets('Android $name: abre a biblioteca embaixo e arrasta com toque longo', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final server = await _open(tester, size);

      expect(find.text('Exercícios'), findsNothing);
      await tester.tap(find.byTooltip('Exercícios'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Peito'));
      await tester.pumpAndSettle();

      // on the phone the week is a list of days with the long name; on the tablet, columns
      final target = size.width < 640 ? longDay(monday) : column(monday);
      await _drag(tester, find.text('Supino com halteres'), _withinDay(tester, target), tap: true);

      expect(server.itens.single['data'], iso(monday));
      expect(server.itens.single['exercicio_id'], 'supino');
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('botão + marca no dia em foco sem arrastar', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final server = await _open(tester, const Size(1400, 900));
    await tester.tap(find.text('Peito'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Marcar no dia em foco').first);
    await tester.pumpAndSettle();
    expect(server.itens.single['data'], iso(today()));
    debugDefaultTargetPlatformOverride = null;
  });
}
