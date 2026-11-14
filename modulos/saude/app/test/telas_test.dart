import 'dart:convert';

import 'package:agent_saude/src/api_saude.dart';
import 'package:agent_saude/src/datas.dart';
import 'package:agent_saude/src/telas/espiritual_tela.dart';
import 'package:agent_saude/src/telas/analise_tela.dart';
import 'package:agent_saude/src/telas/mental_tela.dart';
import 'package:agent_saude/src/telas/relogio_tela.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _hoje = iso(hoje());

http.Response _json(Object corpo) =>
    http.Response(jsonEncode(corpo), 200, headers: {'content-type': 'application/json; charset=utf-8'});

final _marcados = <String>[];

final _cliente = MockClient((r) async {
  final c = r.url.path;
  if (r.method == 'POST' && c.endsWith('/marcar')) {
    _marcados.add(c);
    return _json({});
  }
  return _json(switch (c) {
    '/api/saude/mental/habitos' => [
      {'id': 'h1', 'nome': 'Ler 20 páginas', 'tipo': 'construir', 'dias_semana': [1, 2, 3, 4, 5, 6, 7],
       'descricao': 'depois do café', 'arquivado': false, 'feitos': [_hoje], 'sequencia': 4, 'total': 10},
    ],
    '/api/saude/mental/foco' => {'sessoes': [], 'minutos_por_dia': {_hoje: 50}},
    '/api/saude/mental/diario' => [
      {'data': _hoje, 'humor': 4, 'ansiedade': 3, 'gratidao': 'família'},
    ],
    '/api/saude/espiritual/planos' => [
      {'id': 'p1', 'nome': 'Novo Testamento', 'nome_escopo': 'Novo Testamento', 'escopo': 'nt', 'dias': 90,
       'inicio': _hoje, 'lidos': 1, 'atrasados': ['2026-10-01'], 'capitulos': 260, 'fim': _hoje},
    ],
    '/api/saude/espiritual/planos/p1/leituras' => [
      {'data': _hoje, 'dia': 1, 'trechos': ['Mateus 1–3'], 'feito': false},
    ],
    '/api/notas' => [],
    '/api/saude/relogio/dias' => [
      {'data': _hoje, 'passos': 9100, 'sono_min': 400, 'sono_profundo_min': 80, 'sono_rem_min': 90, 'fc_repouso': 57,
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

Future<void> _abrir(WidgetTester tester, Widget tela, Size tamanho) async {
  tester.view.physicalSize = tamanho;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: tela)));
  await tester.pumpAndSettle();
}

void main() {
  final api = ApiSaude('http://teste', cliente: _cliente);

  for (final tamanho in const [Size(360, 780), Size(800, 1280), Size(1280, 800), Size(1366, 768), Size(1920, 1080), Size(3440, 1440)]) {
    testWidgets('Mental em ${tamanho.width.toInt()} px: hábitos, foco e humor', (tester) async {
      await _abrir(tester, HabitosTela(api: api), tamanho);
      expect(find.text('Ler 20 páginas'), findsOneWidget);
      expect(find.text('🔥 4'), findsOneWidget);

      await _abrir(tester, FocoTela(api: api), tamanho);
      expect(find.text('25:00'), findsOneWidget);
      expect(find.textContaining('Hoje: 50 min'), findsOneWidget);

      await _abrir(tester, AnsiedadeTela(api: api), tamanho);
      expect(find.text('Ansiedade: 3 de 10'), findsOneWidget);
      await tester.tap(find.text('Começar'));
      await tester.pump(const Duration(seconds: 2));
      expect(find.textContaining('Inspire'), findsOneWidget);
      await tester.tap(find.text('Parar'));
      await tester.pumpAndSettle();
    });

    testWidgets('Sono e corpo em ${tamanho.width.toInt()} px: indicadores, gráficos e exercícios', (tester) async {
      await _abrir(tester, RelogioTela(api: api), tamanho);
      expect(find.text('6h40'), findsWidgets); // indicador e valor da barra
      expect(find.text('9100'), findsOneWidget);
      expect(find.text('1 de 1 dias na meta'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Sono por noite'), 300);
      expect(find.text('Sono por noite'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('caminhada · 35 min'), 300);
      expect(find.text('caminhada · 35 min'), findsOneWidget);
    });

    testWidgets('Análise em ${tamanho.width.toInt()} px: última análise da LLM local', (tester) async {
      await _abrir(tester, AnaliseTela(api: api), tamanho);
      expect(find.text('Resumo do período'), findsOneWidget);
      expect(find.textContaining('6h40 em média'), findsOneWidget);
    });

    testWidgets('Espiritual em ${tamanho.width.toInt()} px: leitura do dia e atrasados', (tester) async {
      _marcados.clear();
      await _abrir(tester, EspiritualTela(api: api), tamanho);
      expect(find.text('Mateus 1–3'), findsOneWidget);
      expect(find.text('1 dias atrasados'), findsOneWidget);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(_marcados, ['/api/saude/espiritual/planos/p1/marcar']);
    });
  }
}
