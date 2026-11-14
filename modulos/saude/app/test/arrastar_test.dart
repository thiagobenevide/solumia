import 'dart:convert';

import 'package:agent_saude/src/api_saude.dart';
import 'package:agent_saude/src/datas.dart';
import 'package:agent_saude/src/telas/treinos_tela.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Backend falso de `/api/saude` com dois exercícios e a agenda em memória.
class _Servidor {
  final itens = <Map<String, dynamic>>[];
  final pedidos = <String>[];

  static Map<String, dynamic> _ex(String id, String nome) => {
    'id': id,
    'nome': nome,
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
    pedidos.add('${r.method} ${r.url.path}');
    final caminho = r.url.path;
    if (caminho == '/api/saude/exercicios') {
      return _json({
        'areas': ['Peito', 'Costas'],
        'exercicios': [_ex('flexao', 'Flexão de braço'), _ex('supino', 'Supino com halteres')],
      });
    }
    if (caminho == '/api/saude/agenda' && r.method == 'GET') {
      final de = r.url.queryParameters['de']!, ate = r.url.queryParameters['ate']!;
      return _json([
        for (final i in itens)
          if ((i['data'] as String).compareTo(de) >= 0 && (i['data'] as String).compareTo(ate) <= 0) i,
      ]);
    }
    if (caminho == '/api/saude/agenda' && r.method == 'POST') {
      final corpo = jsonDecode(r.body) as Map<String, dynamic>;
      final item = {
        'id': 'i${itens.length}',
        'data': corpo['data'],
        'exercicio_id': corpo['exercicio_id'],
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
    if (caminho.startsWith('/api/saude/agenda/') && r.method == 'PATCH') {
      final item = itens.firstWhere((i) => i['id'] == caminho.split('/').last);
      item.addAll(jsonDecode(r.body) as Map<String, dynamic>);
      return _json(item);
    }
    return http.Response('{"detail": "não encontrado"}', 404);
  });

  static http.Response _json(Object corpo, [int status = 200]) =>
      http.Response(jsonEncode(corpo), status, headers: {'content-type': 'application/json; charset=utf-8'});
}

Future<_Servidor> _abrir(WidgetTester tester, Size tamanho) async {
  tester.view.physicalSize = tamanho;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final servidor = _Servidor();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: TreinosTela(api: ApiSaude('http://teste', cliente: servidor.cliente))),
    ),
  );
  await tester.pumpAndSettle();
  return servidor;
}

/// Arrasta de [de] até [para]: com o mouse começa na hora; no toque precisa do toque longo.
Future<void> _arrastar(WidgetTester tester, Finder de, Offset para, {required bool toque}) async {
  final gesto = await tester.startGesture(
    tester.getCenter(de),
    kind: toque ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
  );
  if (toque) await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
  await gesto.moveBy(const Offset(-20, 0));
  await tester.pump();
  await gesto.moveTo(para);
  await tester.pump();
  await gesto.up();
  await tester.pumpAndSettle();
}

/// Ponto dentro da coluna do dia (abaixo do rótulo) na vista da semana.
Offset _dentroDoDia(WidgetTester tester, String rotulo) => tester.getCenter(find.text(rotulo)) + const Offset(0, 40);

void main() {
  final segunda = inicioSemana(hoje());
  final quarta = somarDias(segunda, 2);
  final sexta = somarDias(segunda, 4);
  String coluna(DateTime d) => '${diasSemana[d.weekday - 1]} ${d.day}';

  testWidgets('PC: biblioteca à direita, arrasta com o mouse e move entre dias', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final servidor = await _abrir(tester, const Size(1400, 900));

    expect(find.text('Exercícios'), findsOneWidget); // biblioteca já aberta na tela larga
    await tester.tap(find.text('Peito'));
    await tester.pumpAndSettle();
    await _arrastar(tester, find.text('Flexão de braço'), _dentroDoDia(tester, coluna(quarta)), toque: false);

    expect(servidor.itens.single['data'], iso(quarta));
    expect(find.text('Flexão de braço'), findsNWidgets(2)); // na biblioteca e no calendário
    expect(find.text('3 × 12'), findsOneWidget);

    // move o item marcado da quarta para a sexta
    await _arrastar(tester, find.text('3 × 12'), _dentroDoDia(tester, coluna(sexta)), toque: false);
    expect(servidor.itens.single['data'], iso(sexta));
    expect(servidor.pedidos.where((p) => p.startsWith('PATCH')), hasLength(1));
    debugDefaultTargetPlatformOverride = null;
  });

  for (final (nome, tamanho) in const [('celular', Size(400, 860)), ('tablet em pé', Size(800, 1280))]) {
    testWidgets('Android $nome: abre a biblioteca embaixo e arrasta com toque longo', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final servidor = await _abrir(tester, tamanho);

      expect(find.text('Exercícios'), findsNothing);
      await tester.tap(find.byTooltip('Exercícios'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Peito'));
      await tester.pumpAndSettle();

      // no celular a semana é uma lista de dias com o nome longo; no tablet, colunas
      final alvo = tamanho.width < 640 ? diaLongo(segunda) : coluna(segunda);
      await _arrastar(tester, find.text('Supino com halteres'), _dentroDoDia(tester, alvo), toque: true);

      expect(servidor.itens.single['data'], iso(segunda));
      expect(servidor.itens.single['exercicio_id'], 'supino');
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('botão + marca no dia em foco sem arrastar', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final servidor = await _abrir(tester, const Size(1400, 900));
    await tester.tap(find.text('Peito'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Marcar no dia em foco').first);
    await tester.pumpAndSettle();
    expect(servidor.itens.single['data'], iso(hoje()));
    debugDefaultTargetPlatformOverride = null;
  });
}
