import 'dart:convert';

import 'package:agent_concursos/src/exams_api.dart';
import 'package:agent_concursos/src/models.dart';
import 'package:agent_concursos/src/screens/exam_screen.dart';
import 'package:agent_concursos/src/screens/exams_screen.dart';
import 'package:agent_concursos/src/screens/radar_screen.dart';
import 'package:agent_concursos/src/screens/mock_exams_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _today = iso(DateTime.now());

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});

final _status = {
  'id': 'c1', 'nome': 'TJPB 2026', 'banca': 'FGV', 'cargo': 'TI – Desenvolvimento de Sistemas',
  'data_prova': '2027-01-24', 'dias_para_prova': 83, 'estado': 'pronto', 'tem_edital': true,
  'tarefas': 2, 'feitas': 1, 'atrasadas': 0,
  'proximo_prazo': {'titulo': 'Fim das inscrições', 'data': '2026-11-18', 'hora': '16:00', 'tipo': 'inscricao', 'detalhe': ''},
};

final _exam = {
  ..._status,
  'minutos_util': 120, 'minutos_fds': 240, 'observacoes': '', 'edital': {'nome': 'edital.pdf'},
  'geracao': {'estado': 'pronto', 'erro': ''},
  'resumo_plano': {'fator': 1.0, 'fim_estudo': '2027-01-17'},
  'estrutura': {
    'resumo': 'Analista TI', 'formato_prova': '60 objetivas', 'horario_prova': '13h',
    'disciplinas': [
      {'nome': 'Língua Portuguesa', 'modulo': 'gerais', 'questoes': 10, 'prioridade': 5, 'topicos': [
        {'titulo': 'Interpretação', 'conteudo': '1. Compreensão', 'horas': 6, 'prioridade': 'alta'},
      ]},
    ],
    'discursiva': {'descricao': '30 linhas', 'temas_provaveis': ['LGPD']},
    'estrategia': ['Questões da FGV'],
  },
  'prazos': [_status['proximo_prazo']],
  'tarefas': [
    {'id': 't1', 'data': _today, 'tipo': 'conteudo', 'disciplina': 'Língua Portuguesa',
     'titulo': 'Teoria + questões: Interpretação', 'minutos': 90, 'feito': false, 'chave': 'Língua Portuguesa|Interpretação|0'},
    {'id': 't2', 'data': _today, 'tipo': 'revisao', 'disciplina': '', 'titulo': 'Revisão da semana', 'minutos': 30, 'feito': true},
  ],
  'situacao': _status,
};

final _local = {'cidade': 'Campina Grande', 'uf': 'PB', 'lat': -7.23, 'lon': -35.88, 'km': 180, 'horas': 2.6};

final _radar = {
  'atualizado': '2026-11-02T12:00:00+00:00', 'erro': '', 'coletando': false, 'pendentes': 0,
  'origem': {'cidade': 'Custódia', 'uf': 'PE', 'lat': -8.08, 'lon': -37.64},
  'itens': [
    {'id': 'tre-pb', 'orgao': 'TRE - Tribunal Regional Eleitoral da Paraíba', 'uf': 'PB', 'url': 'https://pci/tre',
     'banca': 'Cebraspe', 'edital_url': 'https://x/edital.pdf', 'inscricoes_inicio': '2026-11-01',
     'inscricoes_fim': '2026-11-30', 'data_prova': '2027-02-14', 'horario_prova': '8h às 12h', 'taxa': 'R\$ 85',
     'resumo': 'Concurso do TRE-PB.', 'total_vagas_ti': 12, 'salario_max': 13994.78,
     'vagas_ti': [{'cargo': 'Analista Judiciário – TI', 'vagas': 12, 'cadastro_reserva': true, 'salario': 13994.78, 'requisitos': ''}],
     'sede': {'cidade': 'João Pessoa', 'uf': 'PB', 'lat': -7.11, 'lon': -34.86},
     'locais_prova': [_local], 'mais_proximo': _local},
  ],
};

final _mockExam = {
  'id': 's1', 'titulo': 'Simulado geral · 2 questões', 'estado': 'pronto', 'erro': '', 'minutos': 9,
  'criado': '2026-11-02', 'respostas': null, 'resultado': null,
  'questoes': [
    for (var n = 1; n <= 2; n++)
      {'n': n, 'disciplina': 'Língua Portuguesa', 'topico': 'Sintaxe', 'enunciado': 'Enunciado $n',
       'alternativas': ['a$n', 'b$n', 'c$n', 'd$n', 'e$n']},
  ],
};

ExamsApi _api() => ExamsApi('http://x', client: MockClient((r) async => _json(switch (r.url.path) {
  '/api/concursos' => [_status],
  '/api/concursos/radar' => _radar,
  '/api/concursos/radar/tre-pb/rota' => {'km': 180, 'horas': 2.6, 'estimada': false,
    'linha': [[-8.08, -37.64], [-7.6, -36.5], [-7.23, -35.88]]},
  '/api/concursos/c1/simulados/s1/respostas' => {
    ..._mockExam, 'respostas': [0, null],
    'questoes': [for (final q in _mockExam['questoes'] as List) {...q as Map, 'correta': 0, 'comentario': 'Porque sim'}],
    'resultado': {'acertos': 1, 'total': 2, 'pct': 50, 'em_branco': 1, 'segundos': 30, 'aprovado': false, 'por_disciplina': {}},
  },
  '/api/concursos/alertas' => [
    {'nivel': 'aviso', 'texto': 'TJPB 2026: Fim das inscrições em 7 dias', 'concurso_id': 'c1', 'concurso': 'TJPB 2026'},
  ],
  _ => _exam,
})));

void main() {
  testWidgets('listagem mostra concurso, contagem e alerta', (t) async {
    await t.pumpWidget(MaterialApp(home: Scaffold(body: ExamsScreen(api: _api()))));
    await t.pump();
    await t.pump();
    expect(find.text('TJPB 2026'), findsOneWidget);
    expect(find.text('83'), findsOneWidget);
    expect(find.textContaining('Fim das inscrições em 7 dias'), findsOneWidget);
  });

  testWidgets('detalhe mostra tarefas de hoje e o fluxo', (t) async {
    await t.pumpWidget(MaterialApp(home: ExamScreen(api: _api(), id: 'c1')));
    await t.pump();
    await t.pump();
    expect(find.text('Teoria + questões: Interpretação'), findsOneWidget);
    await t.tap(find.text('Fluxo'));
    await t.pumpAndSettle();
    expect(find.text('Língua Portuguesa'), findsOneWidget);
    expect(find.text('• Questões da FGV'), findsOneWidget);
  });

  testWidgets('radar mostra o concurso, abre o detalhe com distância e vagas', (t) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    String? followed;
    await t.pumpWidget(MaterialApp(home: Scaffold(body: RadarScreen(api: _api(), onFollow: (id) => followed = id, baseMap: false))));
    await t.pump();
    await t.pump();
    expect(find.text('Concursos de TI abertos · 1'), findsOneWidget);
    expect(find.text('180 km'), findsOneWidget);
    await t.tap(find.text('TRE - Tribunal Regional Eleitoral da Paraíba'));
    await t.pump();
    await t.pump();
    expect(find.text('Acompanhar e montar o fluxo de estudo'), findsOneWidget);
    expect(find.textContaining('R\$ 13.994,78'), findsWidgets);
    expect(find.text('180 km · 2h36'), findsOneWidget); // label in the middle of the route
    expect(followed, isNull);
  });

  testWidgets('simulado: marca, entrega e mostra o gabarito comentado', (t) async {
    await t.pumpWidget(MaterialApp(
      home: SolveMockExam(api: _api(), examId: 'c1', mockExam: MockExam.fromJson(_mockExam)),
    ));
    await t.tap(find.text('a1'));
    await t.pump();
    await t.tap(find.textContaining('Entregar ('));
    await t.pumpAndSettle();
    await t.tap(find.text('Entregar'));
    await t.pumpAndSettle();
    expect(find.text('1/2 acertos · 50%'), findsOneWidget);
    expect(find.text('Porque sim'), findsWidgets);
  });

  test('reais e duração', () {
    expect(real(13994.78), 'R\$ 13.994,78');
    expect(duration(2.6), '2h36');
  });
}
