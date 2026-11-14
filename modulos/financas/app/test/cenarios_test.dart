import 'dart:convert';

import 'package:agent_financas/src/api_financas.dart';
import 'package:agent_financas/src/telas/cenarios_tela.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

List<Map<String, dynamic>> _serie(double inicio, double passo) => [
  for (var i = 0; i < 48; i++) {'mes': '20${27 + i ~/ 12}-${(i % 12 + 1).toString().padLeft(2, '0')}', 'saldo': inicio + passo * i},
];

final _resultado = {
  'pedido': {
    'descricao': 'EcoSport 2015', 'tipo': 'carro', 'valor': 45000, 'entrada': 0, 'prazo_meses': 48,
    'taxa_anual': 0.24, 'sistema': 'price', 'custo_mensal_extra': 262.5,
  },
  'realidade': {
    'renda_media': 6000, 'sobra_media': 1500, 'tendencia_mensal': 0, 'reserva': 19000,
    'parcelas_em_aberto': 350, 'meses_de_historico': 6, 'historico': [],
  },
  'juntar': {'meses': 16, 'data': '2028-02', 'aporte_mensal': 1500},
  'financiar': {
    'valor_financiado': 45000, 'primeira': 1410.58, 'ultima': 1410.58, 'total': 67707.78,
    'juros': 22707.78, 'comprometimento': 0.2788, 'cabe': false, 'taxa_mensal': 0.018,
  },
  'financiar_com_reserva': {
    'entrada': 5500, 'emergencia_guardada': 13500, 'valor_financiado': 39500, 'primeira': 1238.17,
    'juros': 19932.39, 'cabe': false,
  },
  'mcmv': null,
  'veredito': 'Financiar não cabe no seu orçamento hoje; o caminho é juntar.',
  'alertas': ['Parcela + custos do bem (R\$ 1.673,08/mês) passam da sua sobra mensal (R\$ 1.500,00).'],
  'projecao': {'sem_compra': _serie(19000, 1500), 'juntar': _serie(19000, 900), 'financiar': _serie(19000, -170)},
  'parcelamentos': [],
};

http.Response _json(Object corpo, [int status = 200]) =>
    http.Response(jsonEncode(corpo), status, headers: {'content-type': 'application/json; charset=utf-8'});

final _cliente = MockClient((r) async {
  final c = r.url.path;
  if (c.endsWith('/parcelamentos')) {
    return _json([
      {'descricao': 'Notebook Loja', 'conta_id': 'c', 'valor_parcela': 350, 'parcelas': 10, 'pagas': 3, 'restantes': 7,
       'valor_total': 3500, 'valor_restante': 2450, 'ultima': '2026-10-12', 'termina': '2027-05', 'ativo': true},
    ]);
  }
  if (c.endsWith('/cenarios/perguntar')) return _json({'tarefa': 't1', 'estado': 'rodando'}, 202);
  if (c.endsWith('/tarefas/t1')) {
    return _json({'estado': 'pronto', 'resultado': {'parametros': {'valor': 45000}, 'resultado': _resultado, 'analise': '**Juntar** leva 16 meses.'}});
  }
  throw StateError('rota inesperada $c');
});

void main() {
  for (final largura in const [360.0, 800.0, 1366.0, 1920.0]) {
    testWidgets('cenário do EcoSport em ${largura.toInt()} px', (tester) async {
      tester.view.physicalSize = Size(largura, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: CenariosTela(api: ApiFinancas('http://teste', cliente: _cliente)))));
      await tester.pumpAndSettle();
      expect(find.textContaining('7 compras').evaluate().isEmpty, isTrue);
      expect(find.textContaining('1 compras'), findsOneWidget); // parcelamentos
      await tester.enterText(find.byType(TextField), 'Quero um EcoSport 2015 de 45 mil');
      await tester.tap(find.text('Analisar minha realidade'));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('16 meses'), findsOneWidget);
      // o campo de texto também rola: rola a lista da tela
      final lista = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first;
      await tester.scrollUntilVisible(find.text('Análise da IA'), 300, scrollable: lista);
      expect(find.text('Análise da IA'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('passam da sua sobra'), findsOneWidget);
    });
  }
}
