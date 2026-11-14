import 'package:flutter/material.dart';

import '../finance_api.dart';
import '../format.dart';
import 'common.dart';
import 'charts.dart';

/// Month dashboard: personal KPIs, cash flow, categories, budget, 50/30/20, counterparties,
/// scheduled entries, goals and balances.
class PanelScreen extends StatefulWidget {
  const PanelScreen({super.key, required this.api, required this.registry});

  final FinanceApi api;
  final Registry registry;

  @override
  State<PanelScreen> createState() => _PanelScreenState();
}

class _PanelScreenState extends State<PanelScreen> {
  var _mes = DateTime(DateTime.now().year, DateTime.now().month);
  late Future<(Doc, List<Doc>, Doc)> _dados = _load();

  Future<(Doc, List<Doc>, Doc)> _load() {
    final m = mesIso(_mes);
    final end = iso(DateTime(_mes.year, _mes.month + 1, 0));
    return (
      widget.api.summary(m),
      widget.api.flow(ate: m),
      widget.api.counterparties(de: iso(addMonths(_mes, -2)), ate: end),
    ).wait;
  }

  void _reload() => setState(() => _dados = _load());

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            MonthPicker(mes: _mes, aoMudar: (m) => setState(() {
              _mes = m;
              _dados = _load();
            })),
            const Spacer(),
            IconButton(tooltip: 'Atualizar', icon: const Icon(Icons.refresh), onPressed: _reload),
          ],
        ),
      ),
      Expanded(
        child: Waiting(
          future: _dados,
          reload: _reload,
          construir: (d) => _content(context, d.$1, d.$2, d.$3),
        ),
      ),
    ],
  );

  Widget _content(BuildContext context, Doc r, List<Doc> flow, Doc cp) {
    final cs = Theme.of(context).colorScheme;
    final ind = r['indicadores'] as Doc;
    final pat = r['patrimonio'] as Doc;
    final ant = r['anterior'] as Doc;
    final cats = [for (final c in r['categorias'] as List) c as Doc];
    final expenses = cats.where((c) => c['tipo'] != 'receita' && n(c['valor']) > 0).toList();
    final budgeted = cats.where((c) => n(c['orcamento']) > 0).toList();

    String change(dynamic v) => v == null ? 'mês anterior sem dados' : '${n(v) >= 0 ? '+' : ''}${pct(nn(v))} vs mês anterior';

    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        IndicatorGrid(
          children: [
            Indicator('Receitas', currency(nn(r['receitas'])), icone: Icons.south_west, color: Colors.green.shade400,
                detail: change(r['variacao_receitas'])),
            Indicator('Despesas', currency(nn(r['despesas'])), icone: Icons.north_east, color: cs.error,
                detail: change(r['variacao_despesas'])),
            Indicator('Investido no mês', currency(nn(r['investimentos'])), icone: Icons.savings_outlined,
                detail: 'taxa de investimento ${pct(nn(ind['taxa_investimento']))}'),
            Indicator('Saldo do mês', currency(nn(r['saldo'])), icone: Icons.account_balance_wallet_outlined,
                color: valueColor(nn(r['saldo']), cs), detail: 'mês anterior ${currency(nn(ant['saldo']))}'),
            Indicator('Taxa de poupança', pct(nn(ind['taxa_poupanca'])), icone: Icons.percent,
                color: n(ind['taxa_poupanca']) >= 20 ? Colors.green.shade400 : Colors.orange,
                detail: '(receitas − despesas) / receitas; meta ≥ 20%'),
            Indicator('Comprometimento', pct(nn(ind['comprometimento_despesas'])), icone: Icons.pie_chart_outline,
                detail: 'despesas / receitas'),
            Indicator('Reserva de emergência', ind['reserva_meses'] == null ? '—' : '${number(nn(ind['reserva_meses']), decimals: 1)} meses',
                icone: Icons.shield_outlined,
                color: n(ind['reserva_meses']) >= 6 ? Colors.green.shade400 : Colors.orange,
                detail: 'liquidez / despesa média de 3 meses (${currency(nn(ind['despesa_media_3m']))})'),
            Indicator('Patrimônio líquido', currency(nn(pat['liquido'])), icone: Icons.account_balance_outlined,
                detail: 'líquido ${currency(nn(pat['liquidez']))} · investido ${currency(nn(pat['investido']))} · dívidas ${currency(nn(pat['dividas']))}'),
            Indicator('Gasto médio diário', currency(nn(ind['gasto_medio_diario'])), icone: Icons.today_outlined,
                detail: 'projeção do mês ${currency(nn(ind['projecao_despesas_mes']))}'),
            Indicator('Despesas fixas', currency(nn(ind['despesas_fixas'])), icone: Icons.repeat,
                detail: '${pct(nn(ind['peso_fixas']))} da receita (programações mensais)'),
            Indicator('Cartão de crédito', currency(nn(ind['gasto_cartao'])), icone: Icons.credit_card,
                color: n(ind['peso_cartao']) > 30 ? cs.error : null,
                detail: '${pct(nn(ind['peso_cartao']))} da receita'),
            if (n(ind['sem_categoria']) > 0)
              Indicator('Sem categoria', '${ind['sem_categoria']}', icone: Icons.label_off_outlined, color: Colors.orange,
                  detail: 'categorize no Extrato para indicadores precisos'),
          ],
        ),
        Columns(
          left: [
            Section(title: 'Fluxo de caixa', subtitle: 'últimos 12 meses', child: FlowChart(flow)),
            Section(
              title: 'Despesas por categoria',
              child: expenses.isEmpty
                  ? const Text('Sem despesas no mês.')
                  : Donut(
                      [for (final (i, c) in expenses.indexed) (name: c['nome'] as String, value: n(c['valor']), color: colorOf(c['cor'] as String?, i))],
                      center: currency(nn(r['despesas'])),
                    ),
            ),
            Section(
              title: 'Orçamento do mês',
              subtitle: 'defina limites em Planejamento › Orçamento',
              child: budgeted.isEmpty
                  ? const Text('Nenhuma categoria com orçamento.')
                  : Column(
                      spacing: 10,
                      children: [for (final c in budgeted) _BudgetRow(c)],
                    ),
            ),
            Section(title: 'Regra 50/30/20', subtitle: 'em % da receita do mês', child: _Rule(r['regra_50_30_20'] as Doc)),
          ],
          right: [
            Section(
              title: 'Para quem mais envio dinheiro',
              subtitle: 'últimos 3 meses',
              child: _Ranking([for (final x in cp['enviado'] as List) x as Doc], cs.error),
            ),
            Section(
              title: 'De quem mais recebo',
              subtitle: 'últimos 3 meses',
              child: _Ranking([for (final x in cp['recebido'] as List) x as Doc], Colors.green.shade400),
            ),
            Section(title: 'A lançar no mês', subtitle: 'programações pendentes', child: _Upcoming(r, widget.api, _reload)),
            Section(title: 'Metas', child: _Goals([for (final m in r['metas'] as List) m as Doc])),
            Section(
              title: 'Maiores despesas',
              child: Column(
                children: [
                  for (final t in r['maiores_despesas'] as List)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(t['descricao'] as String, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${dataBr(t['data'] as String?)} · ${widget.registry.category(t['categoria_id'] as String?)?['nome'] ?? 'sem categoria'}'),
                      trailing: Text(currency(nn(t['valor'])), style: TextStyle(color: cs.error)),
                    ),
                ],
              ),
            ),
            Section(
              title: 'Contas',
              child: Column(
                children: [
                  for (final c in r['contas'] as List)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(accountIcon(c['tipo'] as String)),
                      title: Text(c['nome'] as String),
                      trailing: Text(currency(nn(c['saldo'])), style: TextStyle(color: valueColor(nn(c['saldo']), cs))),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

IconData accountIcon(String type) => switch (type) {
  'cartao' => Icons.credit_card,
  'poupanca' => Icons.savings_outlined,
  'investimento' => Icons.trending_up,
  'carteira' => Icons.payments_outlined,
  _ => Icons.account_balance_outlined,
};

class _BudgetRow extends StatelessWidget {
  const _BudgetRow(this.c);

  final Doc c;

  @override
  Widget build(BuildContext context) {
    final rest = n(c['orcamento']) - n(c['valor']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 4,
      children: [
        Row(
          children: [
            Expanded(child: Text(c['nome'] as String)),
            Flexible(
              child: Text('${currency(nn(c['valor']))} de ${currency(nn(c['orcamento']))}',
                  textAlign: TextAlign.end, style: Theme.of(context).textTheme.bodySmall),
            ),
          ],
        ),
        ProgressBar(nn(c['uso_orcamento']), color: hexColor(c['cor'] as String?)),
        Text(rest >= 0 ? 'restam ${currency(rest)}' : 'estourou ${currency(-rest)}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: rest < 0 ? Theme.of(context).colorScheme.error : null)),
      ],
    );
  }
}

class _Rule extends StatelessWidget {
  const _Rule(this.r);

  final Doc r;

  @override
  Widget build(BuildContext context) {
    const names = {'essencial': 'Essenciais', 'estilo': 'Estilo de vida', 'futuro': 'Futuro (investir)'};
    return Column(
      spacing: 10,
      children: [
        for (final e in names.entries)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 4,
            children: [
              Row(
                children: [
                  Expanded(child: Text(e.value)),
                  Flexible(
                    child: Text('${pct(nn(r[e.key]['pct']))} · ideal ${r[e.key]['ideal']}%  (${currency(nn(r[e.key]['valor']))})',
                        textAlign: TextAlign.end, style: Theme.of(context).textTheme.bodySmall),
                  ),
                ],
              ),
              ProgressBar(
                r[e.key]['pct'] == null ? 0 : 100 * n(r[e.key]['pct']) / n(r[e.key]['ideal']),
                color: e.key == 'futuro' ? Colors.teal : null,
              ),
            ],
          ),
      ],
    );
  }
}

class _Ranking extends StatelessWidget {
  const _Ranking(this.itens, this.color);

  final List<Doc> itens;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (itens.isEmpty) return const Text('Sem movimentações.');
    final maximum = n(itens.first['valor']);
    return Column(
      spacing: 6,
      children: [
        for (final x in itens.take(8))
          Row(
            spacing: 8,
            children: [
              Expanded(
                flex: 3,
                child: Text('${x['nome']}', overflow: TextOverflow.ellipsis),
              ),
              Expanded(
                flex: 3,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(value: maximum == 0 ? 0 : n(x['valor']) / maximum, minHeight: 6, color: color,
                      backgroundColor: Colors.transparent),
                ),
              ),
              SizedBox(width: 110, child: Text(currency(nn(x['valor'])), textAlign: TextAlign.end)),
              SizedBox(width: 36, child: Text('${x['vezes']}×', style: Theme.of(context).textTheme.bodySmall)),
            ],
          ),
      ],
    );
  }
}

class _Upcoming extends StatelessWidget {
  const _Upcoming(this.r, this.api, this.onPost);

  final Doc r;
  final FinanceApi api;
  final VoidCallback onPost;

  @override
  Widget build(BuildContext context) {
    final itens = r['a_lancar'] as List;
    if (itens.isEmpty) return const Text('Nada pendente.');
    return Column(
      children: [
        for (final i in itens)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(i['descricao'] as String),
            subtitle: Text(dataBr(i['data'] as String)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(currency(nn(i['valor'])), style: TextStyle(color: valueColor(nn(i['valor']), Theme.of(context).colorScheme))),
                IconButton(
                  tooltip: 'Lançar no extrato',
                  icon: const Icon(Icons.playlist_add_check),
                  onPressed: () async {
                    if (await tentar(context, () => api.post(i['programacao_id'] as String, i['data'] as String))) onPost();
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Goals extends StatelessWidget {
  const _Goals(this.goals);

  final List<Doc> goals;

  @override
  Widget build(BuildContext context) {
    if (goals.isEmpty) return const Text('Crie metas em Planejamento › Metas.');
    return Column(spacing: 12, children: [for (final m in goals) GoalCard(m)]);
  }
}

class GoalCard extends StatelessWidget {
  const GoalCard(this.m, {super.key});

  final Doc m;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 4,
    children: [
      Row(
        children: [
          Expanded(child: Text(m['nome'] as String, style: const TextStyle(fontWeight: FontWeight.w600))),
          Text(pct(nn(m['progresso']))),
        ],
      ),
      ProgressBar(nn(m['progresso']), color: Colors.teal),
      Text(
        [
          '${currency(nn(m['atual']))} de ${currency(nn(m['valor_alvo']))}',
          if (m['prazo'] != null) 'até ${dataBr(m['prazo'] as String)}',
          if (m['aporte_mensal_necessario'] != null) 'aportar ${currency(nn(m['aporte_mensal_necessario']))}/mês',
        ].join(' · '),
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ],
  );
}
