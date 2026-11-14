import 'package:agent_arquivos/agent_arquivos.dart';
import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import 'api_financas.dart';
import 'telas/cenarios_tela.dart';
import 'telas/mercado_tela.dart';
import 'telas/noticias_tela.dart';
import 'telas/comuns.dart';
import 'telas/contas_tela.dart';
import 'telas/estudo_tela.dart';
import 'telas/extrato_tela.dart';
import 'telas/investimentos_tela.dart';
import 'telas/painel_tela.dart';
import 'telas/planejamento_tela.dart';

class ModuloFinancas extends Modulo {
  ModuloFinancas({required String url, String token = ''})
    : api = ApiFinancas(url, token: token),
      arquivos = ApiArquivos(url, token: token);

  final ApiFinancas api;

  /// Relatórios das empresas ficam no módulo Arquivos (pasta `Finanças/<ticker>`).
  final ApiArquivos arquivos;

  late final cadastros = Cadastros(api);

  @override
  String get id => 'financas';

  @override
  String get nome => 'Finanças';

  @override
  String get descricao => 'Extrato, orçamento, metas, empresas, carteira e estudos';

  @override
  IconData get icone => Icons.account_balance_outlined;

  @override
  double? get larguraMaxima => 1600;

  @override
  Widget construir(BuildContext context) => _Financas(this);
}

class _Financas extends StatefulWidget {
  const _Financas(this.m);

  final ModuloFinancas m;

  @override
  State<_Financas> createState() => _FinancasState();
}

class _FinancasState extends State<_Financas> {
  late Future<void> _carga = widget.m.cadastros.carregar();

  @override
  Widget build(BuildContext context) {
    final m = widget.m;
    return Esperar(
      futuro: _carga,
      recarregar: () => setState(() => _carga = m.cadastros.carregar()),
      construir: (_) => DefaultTabController(
        length: 9,
        child: Column(
          children: [
            const TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(icon: Icon(Icons.dashboard_outlined), text: 'Painel'),
                Tab(icon: Icon(Icons.receipt_long_outlined), text: 'Extrato'),
                Tab(icon: Icon(Icons.flag_outlined), text: 'Planejamento'),
                Tab(icon: Icon(Icons.credit_card), text: 'Contas'),
                Tab(icon: Icon(Icons.query_stats), text: 'Investimentos'),
                Tab(icon: Icon(Icons.auto_graph), text: 'Cenários'),
                Tab(icon: Icon(Icons.candlestick_chart_outlined), text: 'Mercado'),
                Tab(icon: Icon(Icons.newspaper), text: 'Notícias'),
                Tab(icon: Icon(Icons.school_outlined), text: 'Estudos'),
              ],
            ),
            Expanded(
              child: TabBarView(
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  PainelTela(api: m.api, cadastros: m.cadastros),
                  ExtratoTela(api: m.api, cadastros: m.cadastros),
                  PlanejamentoTela(api: m.api, cadastros: m.cadastros),
                  ContasTela(api: m.api, cadastros: m.cadastros),
                  InvestimentosTela(api: m.api, arquivos: m.arquivos, cadastros: m.cadastros),
                  CenariosTela(api: m.api),
                  MercadoTela(api: m.api, arquivos: m.arquivos),
                  NoticiasTela(api: m.api),
                  EstudoTela(api: m.api, arquivos: m.arquivos),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
