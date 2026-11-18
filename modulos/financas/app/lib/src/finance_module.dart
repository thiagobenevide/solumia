import 'package:agent_arquivos/agent_arquivos.dart';
import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import 'finance_api.dart';
import 'screens/scenarios_screen.dart';
import 'screens/market_screen.dart';
import 'screens/news_screen.dart';
import 'screens/common.dart';
import 'screens/accounts_screen.dart';
import 'screens/finance_study_screen.dart';
import 'screens/statement_screen.dart';
import 'screens/investments_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/planning_screen.dart';

class FinanceModule extends Modulo {
  FinanceModule({required String url, String token = ''})
    : api = FinanceApi(url, token: token),
      files = FilesApi(url, token: token);

  final FinanceApi api;

  /// Company reports live in the Arquivos module (folder `Finanças/<ticker>`).
  final FilesApi files;

  late final registry = Registry(api);

  @override
  String get id => 'financas';

  @override
  TemaCena get cena => TemaCena.financas;

  @override
  String get nome => 'Finanças';

  @override
  String get descricao => 'Extrato, orçamento, metas, empresas, carteira e estudos';

  @override
  IconData get icone => Icons.account_balance_outlined;

  @override
  double? get larguraMaxima => 1600;

  @override
  Widget construir(BuildContext context) => _Finances(this);
}

class _Finances extends StatefulWidget {
  const _Finances(this.m);

  final FinanceModule m;

  @override
  State<_Finances> createState() => _FinancesState();
}

class _FinancesState extends State<_Finances> {
  late Future<void> _load = widget.m.registry.carregar();

  @override
  Widget build(BuildContext context) {
    final m = widget.m;
    return Waiting(
      future: _load,
      reload: () => setState(() => _load = m.registry.carregar()),
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
                  PanelScreen(api: m.api, registry: m.registry),
                  StatementScreen(api: m.api, registry: m.registry),
                  PlanningScreen(api: m.api, registry: m.registry),
                  AccountsScreen(api: m.api, registry: m.registry),
                  InvestmentsScreen(api: m.api, files: m.files, registry: m.registry),
                  ScenariosScreen(api: m.api),
                  MarketScreen(api: m.api, files: m.files),
                  NewsScreen(api: m.api),
                  FinanceStudyScreen(api: m.api, files: m.files),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
