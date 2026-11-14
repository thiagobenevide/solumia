import 'dart:convert';

import 'package:agent_saude/src/api_saude.dart';
import 'package:agent_saude/src/aviso_treino.dart';
import 'package:agent_saude/src/health_connect.dart';
import 'package:agent_saude/src/sessao.dart';
import 'package:agent_saude/src/telas/guia_treino_tela.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _json({String fase = 'descanso', bool pausado = false}) => {
  'id': 'a', 'data': '2026-11-10', 'inicio': '2026-11-10T18:00:00Z', 'fim': null, 'estado': 'andamento',
  'descanso_s': 60, 'agora': '2026-11-10T18:10:00Z',
  'controle': {
    'fase': fase, 'indice': 0, 'inicio_serie': '2026-11-10T18:09:00Z', 'descanso_ate': '2026-11-10T18:10:45Z',
    'descanso_restante_s': 20, 'pausado': pausado, 'pausado_em': pausado ? '2026-11-10T18:08:00Z' : null,
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
  // relógio do aparelho 1 h adiantado: a conta usa o do servidor
  final local = DateTime.utc(2026, 11, 10, 19, 10);

  test('descanso usa o relógio do servidor', () {
    final s = SessaoTreino.fromJson(_json(), recebidaEm: local);
    expect(s.restanteDescanso(local), 45);
    expect(s.fase(local.add(const Duration(seconds: 46))), 'exercicio');
    expect(s.ativo(local), const Duration(minutes: 8));
    expect(s.atual!.repsIniciais, 11);
    expect(s.seriesFeitas, 1);
    expect(s.fcAtual(local), isNull);
    final comFc = SessaoTreino.fromJson({..._json(), 'fc_atual': {'bpm': 131, 'em': '2026-11-10T18:09:50Z'}}, recebidaEm: local);
    expect(comFc.fcAtual(local), 131);
    expect(comFc.fcAtual(local.add(const Duration(seconds: 25))), isNull);
  });

  test('pausado congela o descanso', () {
    final s = SessaoTreino.fromJson(_json(pausado: true), recebidaEm: local);
    expect(s.restanteDescanso(local.add(const Duration(minutes: 5))), 20);
    expect(s.fase(local), 'descanso');
  });

  test('relogio e frequência', () {
    expect(relogio(65), '1:05');
    expect(relogio(3723), '1:02:03');
    expect(resumirFrequencia([100, 140, 0, 120]), {'media': 120.0, 'maxima': 140.0, 'minima': 100.0, 'amostras': 3});
    expect(resumirFrequencia([]), isNull);
  });

  _guia();
}

final _comandos = <String>[];

Map<String, dynamic> _agora(Map<String, dynamic> j) => {...j, 'agora': DateTime.now().toUtc().toIso8601String()};

final _cliente = MockClient((r) async {
  final base = _json(fase: 'exercicio');
  if (r.url.path.endsWith('/comando')) {
    final acao = (jsonDecode(r.body) as Map)['acao'] as String;
    _comandos.add(acao);
    final ate = DateTime.now().toUtc().add(const Duration(seconds: 60)).toIso8601String();
    base['controle'] = {...base['controle'] as Map, 'fase': 'descanso', 'descanso_ate': ate};
  }
  return http.Response(jsonEncode(_agora(base)), 200, headers: {'content-type': 'application/json; charset=utf-8'});
});

void _guia() {
  setUp(() => AvisoTreino.ligado = false);
  for (final tamanho in const [Size(360, 740), Size(1366, 768)]) {
    testWidgets('guia em ${tamanho.width.toInt()} px: série feita vai ao descanso', (tester) async {
      tester.view.physicalSize = tamanho;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final api = ApiSaude('http://x', cliente: _cliente);
      final s = SessaoTreino.fromJson(_agora(_json(fase: 'exercicio')));
      await tester.pumpWidget(MaterialApp(home: GuiaTreinoTela(api: api, sessao: s, porId: const {})));
      expect(find.text('Série 2 de 3 · meta 8-12'), findsOneWidget);
      await tester.tap(find.text('Série feita'));
      await tester.pump();
      await tester.pump();
      expect(_comandos.last, 'concluir_serie');
      expect(find.text('Pular descanso'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
