import 'dart:convert';

import 'package:agent_saude/src/health_api.dart';
import 'package:agent_saude/src/workout_notice.dart';
import 'package:agent_saude/src/health_connect.dart';
import 'package:agent_saude/src/session.dart';
import 'package:agent_saude/src/screens/workout_guide_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _json({String phase = 'descanso', bool paused = false}) => {
  'id': 'a', 'data': '2026-11-10', 'inicio': '2026-11-10T18:00:00Z', 'fim': null, 'estado': 'andamento',
  'descanso_s': 60, 'agora': '2026-11-10T18:10:00Z',
  'controle': {
    'fase': phase, 'indice': 0, 'inicio_serie': '2026-11-10T18:09:00Z', 'descanso_ate': '2026-11-10T18:10:45Z',
    'descanso_restante_s': 20, 'pausado': paused, 'pausado_em': paused ? '2026-11-10T18:08:00Z' : null,
    'pausa_total_s': 120,
  },
  'exercicios': [
    {
      'item_id': 'i', 'exercicio_id': 'flexao', 'nome': 'Flexão', 'planejado': {'series': 3, 'repeticoes': '8-12', 'carga_kg': null},
      'meta': {'tempo_s': null, 'min': 8, 'max': 12}, 'sugestao': null, 'anterior': null, 'pulado': false,
      'series': [{'repeticoes': 11, 'carga_kg': null}],
    },
  ],
};

void main() {
  // device clock 1 h ahead: the math uses the server's
  final local = DateTime.utc(2026, 11, 10, 19, 10);

  test('descanso usa o relógio do servidor', () {
    final s = WorkoutSession.fromJson(_json(), receivedAt: local);
    expect(s.restRemaining(local), 45);
    expect(s.phase(local.add(const Duration(seconds: 46))), 'exercicio');
    expect(s.active(local), const Duration(minutes: 8));
    expect(s.current!.initialReps, 11);
    expect(s.setsDone, 1);
    expect(s.currentHr(local), isNull);
    final comFc = WorkoutSession.fromJson({..._json(), 'fc_atual': {'bpm': 131, 'em': '2026-11-10T18:09:50Z'}}, receivedAt: local);
    expect(comFc.currentHr(local), 131);
    expect(comFc.currentHr(local.add(const Duration(seconds: 25))), isNull);
  });

  test('pausado congela o descanso', () {
    final s = WorkoutSession.fromJson(_json(paused: true), receivedAt: local);
    expect(s.restRemaining(local.add(const Duration(minutes: 5))), 20);
    expect(s.phase(local), 'descanso');
  });

  test('relogio e frequência', () {
    expect(watch(65), '1:05');
    expect(watch(3723), '1:02:03');
    expect(summarizeHeartRate([100, 140, 0, 120]), {'media': 120.0, 'maxima': 140.0, 'minima': 100.0, 'amostras': 3});
    expect(summarizeHeartRate([]), isNull);
  });

  _guide();
}

final _commands = <String>[];

Map<String, dynamic> _now(Map<String, dynamic> j) => {...j, 'agora': DateTime.now().toUtc().toIso8601String()};

final _client = MockClient((r) async {
  final base = _json(phase: 'exercicio');
  if (r.url.path.endsWith('/comando')) {
    final action = (jsonDecode(r.body) as Map)['acao'] as String;
    _commands.add(action);
    final ate = DateTime.now().toUtc().add(const Duration(seconds: 60)).toIso8601String();
    base['controle'] = {...base['controle'] as Map, 'fase': 'descanso', 'descanso_ate': ate};
  }
  return http.Response(jsonEncode(_now(base)), 200, headers: {'content-type': 'application/json; charset=utf-8'});
});

void _guide() {
  setUp(() => WorkoutNotice.on = false);
  for (final size in const [Size(360, 740), Size(1366, 768)]) {
    testWidgets('guia em ${size.width.toInt()} px: série feita vai ao descanso', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final api = HealthApi('http://x', cliente: _client);
      final s = WorkoutSession.fromJson(_now(_json(phase: 'exercicio')));
      await tester.pumpWidget(MaterialApp(home: WorkoutGuideScreen(api: api, session: s, byId: const {})));
      expect(find.text('Série 2 de 3 · meta 8-12'), findsOneWidget);
      await tester.tap(find.text('Série feita'));
      await tester.pump();
      await tester.pump();
      expect(_commands.last, 'concluir_serie');
      expect(find.text('Pular descanso'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
