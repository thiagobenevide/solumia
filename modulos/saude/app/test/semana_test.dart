import 'package:agent_saude/src/api_saude.dart';
import 'package:agent_saude/src/datas.dart';
import 'package:agent_saude/src/modelos.dart';
import 'package:agent_saude/src/telas/calendario.dart';
import 'package:agent_saude/src/telas/comuns.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final dia = hoje();
  final item = ItemAgenda.fromJson({
    'id': 'i1',
    'data': iso(dia),
    'exercicio_id': 'elevacao',
    'ordem': 0,
    'series': 3,
    'repeticoes': '12-15',
    'feito': false,
  });
  final agenda = Agenda(
    api: ApiSaude('http://teste'),
    itensDoDia: (d) => mesmoDia(d, dia) ? [item, item] : const [],
    exercicio: (_) => null,
    soltar: (_, _) {},
    abrirItem: (_) {},
    alternarFeito: (_) {},
    abrirDia: (_) {},
    versaoImagem: (_) => 0,
  );

  // Larguras da janela no PC (com o catálogo ao lado) e no celular: nada pode estourar.
  for (final largura in const [360.0, 640.0, 700.0, 900.0, 1200.0, 1920.0]) {
    testWidgets('semana em ${largura.toInt()} px mostra o exercício inteiro', (tester) async {
      tester.view.physicalSize = Size(largura, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: VistaSemana(agenda: agenda, foco: dia)),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('3 × 12-15'), findsWidgets);
      // o resumo fica numa linha só (antes quebrava letra por letra)
      final resumo = tester.getSize(find.text('3 × 12-15').first);
      expect(resumo.height, lessThan(24));
    });
  }
}
