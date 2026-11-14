import 'dart:convert';

import 'package:agent_estudos/src/studies_api.dart';
import 'package:agent_estudos/src/models.dart';
import 'package:agent_estudos/src/screens/graph_screen.dart';
import 'package:agent_estudos/src/screens/foreign_languages_screen.dart';
import 'package:agent_estudos/src/screens/readings_screen.dart';
import 'package:agent_estudos/src/screens/projects_screen.dart';
import 'package:agent_estudos/src/screens/tracks_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _today = iso(DateUtils.dateOnly(DateTime.now()));

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});

final _options = StudyOptions.fromJson({
  'areas': ['Tecnologia', 'Finanças', 'Linguagens', 'Saúde'],
  'status': ['quero ler', 'lendo', 'lido'],
  'idiomas': {'en': 'Inglês', 'fr': 'Francês'},
  'niveis': ['A1', 'A2', 'B1', 'B2', 'C1', 'C2'],
  'tipos_citacao': ['Direta curta (até 3 linhas)', 'Indireta (paráfrase)'],
  'tipos_conteudo': ['Conceito ou definição', 'Método ou procedimento'],
  'status_uso': ['Não usado', 'Usado', 'Descartado'],
});

const _book = {
  'id': 'codigo-limpo',
  'titulo': 'Código Limpo',
  'original': 'Clean Code',
  'autor': 'Robert C. Martin',
  'edicao': '1ª ed. (2008)',
  'tipo': 'livro',
  'tenho': true,
  'leitura': null,
};

const _hint = {
  'livro': 'codigo-limpo',
  'capitulos': 'Caps. 1–5 — Nomes, Funções',
  'foco': 'Grife as regras que você quebra hoje.',
  'indice': 0,
  'feita': null,
};

final _track = {
  'id': 'arquiteto-software',
  'area': 'Tecnologia',
  'titulo': 'Arquiteto de Software',
  'descricao': 'Trilha principal da carreira.',
  'frentes': ['Código', 'Back-end'],
  'total_etapas': 1,
  'etapas_concluidas': 0,
  'progresso': 0.25,
  'proxima': {
    'tipo': 'leitura',
    'etapa_id': 'codigo-limpo',
    'etapa': 'Código limpo',
    'fase': '1. O ofício',
    'indicacao': {..._hint, 'livro': _book},
  },
  'etapas': [
    {
      'id': 'codigo-limpo',
      'fase': '1. O ofício',
      'titulo': 'Código limpo',
      'frentes': ['Código'],
      'objetivo': 'Escrever código legível.',
      'conceitos': ['DRY'],
      'leituras': [
        {..._hint, 'livro': _book},
      ],
      'pratica': 'Refatore uma função longa.',
      'entregavel': 'Antes e depois.',
      'pratica_feita': null,
      'nota_id': null,
      'progresso': 0.25,
      'concluida': false,
    },
  ],
};

const _project = {
  'id': 'p1',
  'nome': 'Pré-TCC',
  'descricao': 'Matriz do pré-projeto',
  'cor': 0xFF3F51B5,
  'secoes': ['1 Introdução', '4 Método'],
  'trechos': 1,
  'comentarios': 2,
  'manuscritos': 1,
  'trabalhos': 1,
  'atualizado': '2026-11-06T10:00:00+00:00',
};

final _client = MockClient(
  (r) async => _json(switch (r.url.path) {
    '/api/estudos/leituras' => [
      {
        'id': 'l1',
        'titulo': 'Clean Code',
        'autor': 'Robert Martin',
        'tipo': 'livro',
        'area': 'Tecnologia',
        'status': 'lendo',
        'paginas': 400,
        'pagina_atual': 100,
        'nota_id': null,
        'tags': [],
        'url': '',
      },
    ],
    '/api/estudos/conhecimento/trilhas' => [_track],
    '/api/estudos/conhecimento/trilhas/arquiteto-software' => _track,
    '/api/notas/grafo' => {
      'nos': [
        {'id': 'a', 'titulo': 'Tecnologia', 'tipo': 'nota', 'tags': [], 'grau': 2},
        {
          'id': 'b',
          'titulo': 'Clean Code',
          'tipo': 'nota',
          'tags': ['tecnologia'],
          'grau': 1,
        },
        {
          'id': 'c',
          'titulo': 'Ações',
          'tipo': 'nota',
          'tags': ['finanças'],
          'grau': 1,
        },
        {'id': 'd', 'titulo': 'Finanças', 'tipo': 'nota', 'tags': [], 'grau': 1},
      ],
      'arestas': [
        {'de': 'b', 'para': 'a', 'tipo': 'link'},
        {'de': 'c', 'para': 'd', 'tipo': 'link'},
      ],
    },
    '/api/estudos/idiomas' => [
      {
        'id': 't1',
        'idioma': 'en',
        'nome': 'Inglês',
        'nivel_inicial': 'A2',
        'nivel_alvo': 'B2',
        'nivel_atual': 'A2',
        'minutos_por_dia': 60,
        'dias_semana': [1, 2, 3, 4, 5, 6, 7],
        'inicio': _today,
        'horas': 100,
        'marcos': [
          {'nivel': 'A1', 'horas_total': 100, 'horas_faltando': 0, 'concluido': true, 'previsao': _today},
          {'nivel': 'A2', 'horas_total': 200, 'horas_faltando': 100, 'concluido': false, 'previsao': '2027-03-01'},
        ],
      },
    ],
    '/api/estudos/idiomas/t1/cronograma' => [
      {
        'data': _today,
        'nivel': 'A2',
        'tema': 'viagens e transporte',
        'minutos': 60,
        'feito_minutos': 0,
        'blocos': [
          {'habilidade': 'escuta', 'titulo': 'Escuta', 'minutos': 30, 'descricao': 'Podcast curto.'},
        ],
      },
    ],
    '/api/estudos/projetos' => [_project],
    '/api/estudos/projetos/p1/matriz' => {
      'projeto': _project,
      'trabalhos': [
        {
          'codigo': 'T001',
          'arquivo_id': 'a1',
          'leitura_id': null,
          'titulo': 'Recuperação da informação',
          'autor': 'Araújo, W. C. O.',
          'autor_citacao': 'Araújo',
          'ano': '2020',
          'referencia': 'Araújo, W. (2020).',
          'trechos': 3,
          'usados': 1,
        },
      ],
      'itens': [
        {
          'id': 'd1',
          'tipo': 'destaque',
          'codigo': 'T001-01',
          'trabalho': 'T001',
          'arquivo_id': 'a1',
          'arquivo_titulo': 'Artigo',
          'pagina': 10,
          'texto': 'Search strategy in five steps',
          'traducao': 'Estratégia de busca em cinco etapas',
          'comentario': 'Base do meu método',
          'cor': 0xFFFFEB3B,
          'citacao_parentetica': '[Araújo 2020]',
          'citacao_narrativa': 'Araújo (2020)',
          'classificacao': {'status_uso': 'Usado', 'secao': '4 Método'},
        },
        {
          'id': 'x1',
          'tipo': 'texto',
          'codigo': 'T001-02',
          'trabalho': 'T001',
          'arquivo_id': 'a1',
          'arquivo_titulo': 'Artigo',
          'pagina': 2,
          'texto': 'Ideia para a introdução',
          'citacao_parentetica': '[Araújo 2020]',
          'citacao_narrativa': 'Araújo (2020)',
          'classificacao': {'status_uso': 'Não usado'},
        },
        {
          'id': 'm-a1-2',
          'tipo': 'manuscrito',
          'codigo': 'T001-03',
          'trabalho': 'T001',
          'arquivo_id': 'a1',
          'arquivo_titulo': 'Artigo',
          'pagina': 2,
          'texto': '',
          'tracos': [
            {
              'pincel': 'caneta',
              'cor': 0xFF111111,
              'espessura': 2,
              'pontos': [0, 0, 1, 40, 20, 1, 80, 5, 1],
            },
          ],
          'citacao_parentetica': '[Araújo 2020]',
          'citacao_narrativa': 'Araújo (2020)',
          'classificacao': {'status_uso': 'Não usado'},
        },
      ],
    },
    _ => throw StateError('rota inesperada ${r.url.path}'),
  }),
);

Future<void> _open(WidgetTester tester, Widget screen, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: screen)));
  await tester.pumpAndSettle();
}

void main() {
  final api = StudiesApi('http://teste', cliente: _client);

  for (final size in const [
    Size(360, 780),
    Size(800, 1280),
    Size(1280, 800),
    Size(1366, 768),
    Size(1920, 1080),
    Size(3440, 1440),
  ]) {
    final px = size.width.toInt();

    testWidgets('Leituras em $px px', (tester) async {
      await _open(tester, ReadingsScreen(api: api, options: _options), size);
      expect(find.text('Clean Code'), findsOneWidget);
      expect(find.text('100 de 400 páginas'), findsOneWidget);
    });

    testWidgets('Projetos de leitura em $px px', (tester) async {
      await _open(tester, ReadingProjectsScreen(api: api, options: _options), size);
      expect(find.text('Pré-TCC'), findsOneWidget);
    });

    testWidgets('Matriz do projeto em $px px: trechos, filtros, trabalhos e cobertura', (tester) async {
      await _open(tester, ProjectScreen(api: api, options: _options, project: ReadingProject.fromJson(_project)), size);
      expect(find.text('Search strategy in five steps'), findsOneWidget);
      expect(find.text('Estratégia de busca em cinco etapas'), findsOneWidget);
      expect(find.text('Base do meu método'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'introdução');
      await tester.pumpAndSettle();
      expect(find.text('Search strategy in five steps'), findsNothing);
      expect(find.text('Ideia para a introdução'), findsOneWidget);
      await tester.tap(find.textContaining('Trabalhos ('));
      await tester.pumpAndSettle();
      expect(find.text('Recuperação da informação'), findsOneWidget);
      await tester.tap(find.text('Cobertura'));
      await tester.pumpAndSettle();
      expect(find.text('Matriz trabalho × seção'), findsOneWidget);
    });

    testWidgets('Trilhas em $px px: próxima leitura e etapas por fase', (tester) async {
      await _open(tester, TracksScreen(api: api), size);
      expect(find.text('Tecnologia · Arquiteto de Software'), findsOneWidget);
      expect(find.text('Leia agora · Código limpo'), findsOneWidget);
      expect(find.text('1. O ofício'), findsOneWidget);
      await tester.tap(find.text('Código limpo'));
      await tester.pumpAndSettle();
      expect(find.text('Código Limpo — Caps. 1–5 — Nomes, Funções'), findsOneWidget);
    });

    testWidgets('Grafo em $px px: o filtro de área esconde as outras', (tester) async {
      await _open(tester, GraphScreen(api: api, areas: _options.areas), size);
      expect(find.text('4 notas · 2 ligações'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Tecnologia'));
      await tester.pumpAndSettle();
      expect(find.text('2 notas · 2 ligações'), findsOneWidget); // only "Tecnologia" and "Clean Code"
    });

    testWidgets('Idiomas em $px px: marcos e cronograma do dia', (tester) async {
      await _open(tester, ForeignLanguagesScreen(api: api, options: _options), size);
      expect(find.textContaining('Inglês: A2 → B2'), findsOneWidget);
      expect(find.textContaining('A2 · 100 h · mar/2027'), findsOneWidget);
      expect(find.textContaining('viagens e transporte'), findsOneWidget);
    });
  }
}
