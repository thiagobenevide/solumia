import 'dart:convert';

import 'package:agent_financas/src/finance_api.dart';
import 'package:agent_financas/src/screens/market_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, dynamic> _role(String t, double v) =>
    {'ticker': t, 'nome': 'Empresa com nome bem comprido $t S.A.', 'preco': 12.34, 'variacao_pct': v, 'volume': 1000};

final _act = {
  'tipo': 'acao', 'ticker': 'PETR4', 'nome': 'PETROLEO BRASILEIRO S.A. PETROBRAS', 'cnpj': '1', 'codigo_cvm': 9512,
  'setor': 'Petróleo e Gás', 'atividade': 'Exploração e produção', 'site': 'www.petrobras.com.br', 'tickers': ['PETR3', 'PETR4'],
  'cotacao': {'preco': 52.45, 'variacao_pct': -0.64, 'horario': '2026-10-28T11:36'},
  'proventos': {'dy_12m_pct': 9.5, 'total_12m': 4.98},
  'demonstrativos': [
    for (final a in [2021, 2022, 2023, 2024, 2025])
      {'ano': a, 'receita_liquida': 497512000.0, 'lucro_bruto': 240000000.0, 'ebit': 145600000.0, 'lucro_liquido': 110600000.0,
       'patrimonio_liquido': 417600000.0, 'divida_bruta': 384000000.0, 'caixa': 50000000.0, 'fco': 200300000.0,
       'capex': 108700000.0, 'dividendos': 45400000.0},
  ],
  'documentos': {
    'anuais_dfp': [{'referencia': '2025-12-31', 'entregue': '2026-03-05', 'link': 'http://www.rad.cvm.gov.br/a'}],
    'trimestrais_itr': [{'referencia': '2026-06-30', 'entregue': '2026-08-05', 'link': 'http://www.rad.cvm.gov.br/b'}],
    'releases_e_comunicados': [
      {'data': '2026-10-13', 'categoria': 'Comunicado ao Mercado', 'tipo': 'Outros',
       'assunto': 'Petrobras informa sobre resultado do 3º trimestre de 2026 com um assunto bem longo', 'link': 'https://www.rad.cvm.gov.br/c'},
    ],
    'paginas': {'cvm_rad': 'https://www.rad.cvm.gov.br/x', 'b3': 'https://b3', 'status_invest': 'https://si'},
  },
  'outros': [],
};

final _fii = {
  'tipo': 'fii', 'ticker': 'MXRF11', 'nome': 'FII MAXI RENDA RL', 'cnpj': '97.521.225/0001-25', 'segmento': 'Logística',
  'mandato': 'Renda', 'gestao': 'Ativa', 'administrador': 'BTG PACTUAL SERVICOS FINANCEIROS S.A. DISTRIBUIDOR', 'site': 'www.btgpactual.com',
  'meses': [
    for (var m = 1; m <= 12; m++)
      {'mes': '2026-${m.toString().padLeft(2, '0')}', 'patrimonio_liquido': 5304823085.0, 'valor_patrimonial_cota': 9.35,
       'dy_mes_pct': 1.0 + m / 100, 'cotistas': 1570595, 'taxa_adm_pct': 0.07},
  ],
  'composicao': [{'item': 'CRI/CRA', 'valor': 3.8e9, 'pct': 79.4}, {'item': 'cotas de outros FIIs', 'valor': 7e8, 'pct': 14.6}],
  'links': {'relatorios_fnet': 'https://fnet', 'status_invest': 'https://si'},
  'cotacao': {'preco': 8.96, 'variacao_pct': 0.2}, 'proventos': {'dy_12m_pct': 13.4, 'total_12m': 1.2}, 'p_vp': 0.96,
};

final _client = MockClient((r) async {
  final c = r.url.path;
  if (c.endsWith('/mercado/destaques')) {
    return _json({
      'altas': [for (var i = 0; i < 10; i++) _role('ALT${i}3', 5.0 - i)],
      'baixas': [for (var i = 0; i < 10; i++) _role('BAI${i}3', -5.0 + i)],
    });
  }
  if (c.endsWith('/mercado/ativo')) {
    final q = jsonDecode(r.body)['q'] as String;
    return _json({'tarefa': q, 'estado': 'rodando'}, 202);
  }
  if (c.endsWith('/tarefas/PETR4')) return _json({'estado': 'pronto', 'resultado': _act});
  if (c.endsWith('/tarefas/MXRF11')) return _json({'estado': 'pronto', 'resultado': _fii});
  throw StateError('rota inesperada $c');
});

Future<void> _screen(WidgetTester t, Size size, Widget w) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(home: Scaffold(body: w)));
  await t.pump(const Duration(seconds: 3));
  await t.pumpAndSettle();
}

void main() {
  final api = FinanceApi('http://teste', cliente: _client);
  for (final size in const [Size(360, 780), Size(800, 1280), Size(1366, 768), Size(1920, 1080)]) {
    final name = '${size.width.toInt()}×${size.height.toInt()}';

    testWidgets('destaques em $name', (t) async {
      await _screen(t, size, MarketScreen(api: api));
      expect(t.takeException(), isNull);
      expect(find.text('ALT03'), findsOneWidget);
      // on the phone the losers are behind the button; from tablet up, beside it
      expect(find.text('BAI03'), size.width >= 700 ? findsOneWidget : findsNothing);
    });

    testWidgets('ficha da ação em $name', (t) async {
      await _screen(t, size, AssetScreen(api: api, query: 'PETR4'));
      expect(t.takeException(), isNull);
      expect(find.textContaining('PETR4 ·'), findsOneWidget);
      expect(find.text('Resultado de 2025'), findsOneWidget);
    });

    testWidgets('ficha do FII em $name', (t) async {
      await _screen(t, size, AssetScreen(api: api, query: 'MXRF11'));
      expect(t.takeException(), isNull);
      expect(find.text('P/VP'), findsOneWidget);
    });
  }
}
