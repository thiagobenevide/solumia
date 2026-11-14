import 'dart:convert';

import 'package:agent_saude/src/health_api.dart';
import 'package:agent_saude/src/dates.dart';
import 'package:agent_saude/src/screens/spiritual_screen.dart';
import 'package:agent_saude/src/screens/analysis_screen.dart';
import 'package:agent_saude/src/screens/mental_screen.dart';
import 'package:agent_saude/src/screens/watch_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _today = iso(today());

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});

final _marked = <String>[];

final _client = MockClient((r) async {
  final c = r.url.path;
  if (r.method == 'POST' && c.endsWith('/marcar')) {
    _marked.add(c);
    return _json({});
  }
  return _json(switch (c) {
    '/api/saude/mental/habitos' => [
      {'id': 'h1', 'nome': 'Ler 20 páginas', 'tipo': 'construir', 'dias_semana': [1, 2, 3, 4, 5, 6, 7],
       'descricao': 'depois do café', 'arquivado': false, 'feitos': [_today], 'sequencia': 4, 'total': 10},
    ],
    '/api/saude/mental/foco' => {'sessoes': [], 'minutos_por_dia': {_today: 50}},
    '/api/saude/mental/diario' => [
      {'data': _today, 'humor': 4, 'ansiedade': 3, 'gratidao': 'família'},
    ],
    '/api/saude/espiritual/planos' => [
      {'id': 'p1', 'nome': 'Novo Testamento', 'nome_escopo': 'Novo Testamento', 'escopo': 'nt', 'dias': 90,
       'inicio': _today, 'lidos': 1, 'atrasados': ['2026-10-01'], 'capitulos': 260, 'fim': _today},
    ],
    '/api/saude/espiritual/planos/p1/leituras' => [
      {'data': _today, 'dia': 1, 'trechos': ['Mateus 1–3'], 'feito': false},
    ],
    '/api/notas' => [],
    '/api/saude/relogio/dias' => [
      {'data': _today, 'passos': 9100, 'sono_min': 400, 'sono_profundo_min': 80, 'sono_rem_min': 90, 'fc_repouso': 57,
       'peso_kg': 80.4, 'exercicios': [{'tipo': 'caminhada', 'inicio': '07:10', 'minutos': 35, 'calorias': 160}]},
    ],
    '/api/saude/relogio/resumo' => {
      'dias': 1,
      'medias': {'passos': 9100, 'sono_min': 400, 'fc_repouso': 57, 'peso_kg': 80.4},
      'metas': {'passos': {'meta': 8000, 'batidos': 1, 'dias': 1}, 'sono_min': {'meta': 420, 'batidos': 0, 'dias': 1}},
    },
    '/api/saude/relogio/estado' => {'health_connect': '2026-11-10T10:00:00+00:00'},
    '/api/saude/relogio/analises' => [
      {'criada_em': '2026-11-10T10:00:00+00:00', 'de': '2026-10-12', 'ate': '2026-11-10', 'pergunta': '',
       'texto': '## Resumo do período\nVocê dormiu 6h40 em média.'},
    ],
    _ => throw StateError('rota inesperada $c'),
  });
});

Future<void> _open(WidgetTester tester, Widget screen, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: screen)));
  await tester.pumpAndSettle();
}

void main() {
  final api = HealthApi('http://teste', cliente: _client);

  for (final size in const [Size(360, 780), Size(800, 1280), Size(1280, 800), Size(1366, 768), Size(1920, 1080), Size(3440, 1440)]) {
    testWidgets('Mental em ${size.width.toInt()} px: hábitos, foco e humor', (tester) async {
      await _open(tester, HabitsScreen(api: api), size);
      expect(find.text('Ler 20 páginas'), findsOneWidget);
      expect(find.text('🔥 4'), findsOneWidget);

      await _open(tester, FocusScreen(api: api), size);
      expect(find.text('25:00'), findsOneWidget);
      expect(find.textContaining('Hoje: 50 min'), findsOneWidget);

      await _open(tester, AnxietyScreen(api: api), size);
      expect(find.text('Ansiedade: 3 de 10'), findsOneWidget);
      await tester.tap(find.text('Começar'));
      await tester.pump(const Duration(seconds: 2));
      expect(find.textContaining('Inspire'), findsOneWidget);
      await tester.tap(find.text('Parar'));
      await tester.pumpAndSettle();
    });

    testWidgets('Sono e corpo em ${size.width.toInt()} px: indicadores, gráficos e exercícios', (tester) async {
      await _open(tester, WatchScreen(api: api), size);
      expect(find.text('6h40'), findsWidgets); // indicator and bar value
      expect(find.text('9100'), findsOneWidget);
      expect(find.text('1 de 1 dias na meta'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Sono por noite'), 300);
      expect(find.text('Sono por noite'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('caminhada · 35 min'), 300);
      expect(find.text('caminhada · 35 min'), findsOneWidget);
    });

    testWidgets('Análise em ${size.width.toInt()} px: última análise da LLM local', (tester) async {
      await _open(tester, AnalysisScreen(api: api), size);
      expect(find.text('Resumo do período'), findsOneWidget);
      expect(find.textContaining('6h40 em média'), findsOneWidget);
    });

    testWidgets('Espiritual em ${size.width.toInt()} px: leitura do dia e atrasados', (tester) async {
      _marked.clear();
      await _open(tester, SpiritualScreen(api: api), size);
      expect(find.text('Mateus 1–3'), findsOneWidget);
      expect(find.text('1 dias atrasados'), findsOneWidget);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(_marked, ['/api/saude/espiritual/planos/p1/marcar']);
    });
  }
}
