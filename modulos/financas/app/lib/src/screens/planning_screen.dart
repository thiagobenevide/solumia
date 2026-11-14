import 'package:flutter/material.dart';

import '../finance_api.dart';
import '../format.dart';
import 'common.dart';
import 'charts.dart';
import 'dashboard_screen.dart';

/// Planning: budget per category (and the categories registry), goals and schedules
/// (recurring entries) with the balance projection.
class PlanningScreen extends StatelessWidget {
  const PlanningScreen({super.key, required this.api, required this.registry});

  final FinanceApi api;
  final Registry registry;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Column(
      children: [
        const TabBar(tabs: [Tab(text: 'Orçamento'), Tab(text: 'Metas'), Tab(text: 'Programações')]),
        Expanded(
          child: TabBarView(
            children: [
              _Budget(api: api, registry: registry),
              _Goals(api: api, registry: registry),
              _Schedules(api: api, registry: registry),
            ],
          ),
        ),
      ],
    ),
  );
}

List<FormFieldSpec> categoryFields = const [
  FormFieldSpec('nome', 'Nome', isRequired: true),
  FormFieldSpec('tipo', 'Tipo', type: FieldKind.option, options: {
    'despesa': 'Despesa', 'receita': 'Receita', 'investimento': 'Investimento', 'transferencia': 'Transferência (fora dos totais)',
  }),
  FormFieldSpec('grupo', 'Grupo da regra 50/30/20', type: FieldKind.option, options: {
    '': '—', 'essencial': 'Essencial (50%)', 'estilo': 'Estilo de vida (30%)', 'futuro': 'Futuro / investir (20%)',
  }),
  FormFieldSpec('orcamento_mensal', 'Orçamento mensal (R\$)', type: FieldKind.number, help: '0 = sem limite'),
  FormFieldSpec('cor', 'Cor', help: '#rrggbb'),
];

class _Budget extends StatefulWidget {
  const _Budget({required this.api, required this.registry});

  final FinanceApi api;
  final Registry registry;

  @override
  State<_Budget> createState() => _BudgetState();
}

class _BudgetState extends State<_Budget> {
  late Future<Doc> _summary = widget.api.summary(mesIso(DateTime.now()));

  Future<void> _save(Doc? c) async {
    final d = await form(context, c == null ? 'Nova categoria' : 'Categoria', categoryFields, c ?? {});
    if (d == null || !mounted) return;
    final ok = await tentar(
      context,
      () => c == null ? widget.api.create('categorias', d) : widget.api.edit('categorias', c['id'] as String, d),
    );
    if (ok) {
      await widget.registry.carregar();
      setState(() => _summary = widget.api.summary(mesIso(DateTime.now())));
    }
  }

  @override
  Widget build(BuildContext context) => Waiting(
    future: _summary,
    construir: (r) {
      final spent = {for (final c in r['categorias'] as List) c['id']: n(c['valor'])};
      final cats = widget.registry.categories;
      final totalOrc = cats.where((c) => c['tipo'] == 'despesa').fold<double>(0, (s, c) => s + n(c['orcamento_mensal']));
      return ListView(
        padding: const EdgeInsets.all(8),
        children: [
          IndicatorGrid(
            children: [
              Indicator('Orçado (despesas)', currency(totalOrc)),
              Indicator('Gasto no mês', currency(nn(r['despesas'])), detail: pct(totalOrc == 0 ? null : 100 * n(r['despesas']) / totalOrc)),
              Indicator('Receitas do mês', currency(nn(r['receitas'])),
                  detail: 'orçado = ${pct(n(r['receitas']) == 0 ? null : 100 * totalOrc / n(r['receitas']))} da receita'),
            ],
          ),
          Section(
            title: 'Categorias e limites',
            subtitle: mesBr(r['mes'] as String),
            stocks: [IconButton(tooltip: 'Nova categoria', onPressed: () => _save(null), icon: const Icon(Icons.add))],
            child: Column(
              children: [
                for (final (i, c) in cats.indexed)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(radius: 8, backgroundColor: colorOf(c['cor'] as String?, i)),
                    title: Text(c['nome'] as String),
                    subtitle: n(c['orcamento_mensal']) > 0
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            spacing: 4,
                            children: [
                              Text('${currency(spent[c['id']] ?? 0)} de ${currency(nn(c['orcamento_mensal']))}'),
                              ProgressBar(100 * (spent[c['id']] ?? 0) / n(c['orcamento_mensal'])),
                            ],
                          )
                        : Text('${typeLabel[c['tipo']]} · ${currency(spent[c['id']] ?? 0)} no mês'),
                    trailing: MenuItem(
                      onEdit: () => _save(c),
                      onDelete: () async {
                        if (!await confirm(context, 'Excluir "${c['nome']}"? As transações ficam sem categoria.')) return;
                        if (!context.mounted) return;
                        if (await tentar(context, () => widget.api.delete('categorias', c['id'] as String))) {
                          await widget.registry.carregar();
                          setState(() {});
                        }
                      },
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    },
  );
}

class _Goals extends StatefulWidget {
  const _Goals({required this.api, required this.registry});

  final FinanceApi api;
  final Registry registry;

  @override
  State<_Goals> createState() => _GoalsState();
}

class _GoalsState extends State<_Goals> {
  late Future<List<Doc>> _goals = widget.api.goals();

  void _reload() => setState(() => _goals = widget.api.goals());

  Future<void> _save(Doc? m) async {
    final d = await form(context, m == null ? 'Nova meta' : 'Meta', [
      const FormFieldSpec('nome', 'Nome', isRequired: true),
      const FormFieldSpec('valor_alvo', 'Valor alvo (R\$)', type: FieldKind.number),
      const FormFieldSpec('valor_inicial', 'Já tenho (R\$)', type: FieldKind.number),
      const FormFieldSpec('prazo', 'Prazo', type: FieldKind.data),
      FormFieldSpec('categoria_id', 'Somar aportes da categoria', type: FieldKind.option, options: widget.registry.categoryOptions,
          help: 'saídas nessa categoria contam como aporte'),
      const FormFieldSpec('descricao', 'Descrição', type: FieldKind.longText),
      const FormFieldSpec('concluida', 'Concluída', type: FieldKind.boolean),
    ], m ?? {'concluida': false});
    if (d == null || !mounted) return;
    final ok = await tentar(context, () => m == null ? widget.api.create('metas', d) : widget.api.edit('metas', m['id'] as String, d));
    if (ok) _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => _save(null), icon: const Icon(Icons.flag_outlined), label: const Text('Meta')),
    body: Waiting(
      future: _goals,
      reload: _reload,
      construir: (goals) => goals.isEmpty
          ? const Center(child: Text('Sem metas: reserva de emergência, viagem, entrada do imóvel…'))
          : ListView(
              padding: const EdgeInsets.all(8),
              children: [
                for (final m in goals)
                  Section(
                    title: m['nome'] as String,
                    subtitle: (m['descricao'] as String).isEmpty ? null : m['descricao'] as String,
                    stocks: [
                      if (m['concluida'] == true) const Tag('concluída', color: Colors.green),
                      MenuItem(
                        onEdit: () => _save(m),
                        onDelete: () async {
                          if (await tentar(context, () => widget.api.delete('metas', m['id'] as String))) _reload();
                        },
                      ),
                    ],
                    child: GoalCard(m),
                  ),
              ],
            ),
    ),
  );
}

class _Schedules extends StatefulWidget {
  const _Schedules({required this.api, required this.registry});

  final FinanceApi api;
  final Registry registry;

  @override
  State<_Schedules> createState() => _SchedulesState();
}

class _SchedulesState extends State<_Schedules> {
  late Future<(List<Doc>, Doc)> _dados = _load();

  Future<(List<Doc>, Doc)> _load() => (widget.api.list('programacoes'), widget.api.projection(days: 90)).wait;

  void _reload() => setState(() => _dados = _load());

  Future<void> _save(Doc? p) async {
    final d = await form(context, p == null ? 'Nova programação' : 'Programação', [
      const FormFieldSpec('descricao', 'Descrição', isRequired: true),
      const FormFieldSpec('valor', 'Valor', type: FieldKind.number, help: 'negativo = despesa (aluguel), positivo = receita (salário)'),
      const FormFieldSpec('frequencia', 'Frequência', type: FieldKind.option,
          options: {'mensal': 'Mensal', 'semanal': 'Semanal', 'anual': 'Anual', 'unica': 'Uma vez'}),
      const FormFieldSpec('inicio', 'Primeira data', type: FieldKind.data, isRequired: true),
      const FormFieldSpec('fim', 'Última data (opcional)', type: FieldKind.data),
      FormFieldSpec('conta_id', 'Conta', type: FieldKind.option, options: widget.registry.accountOptions),
      FormFieldSpec('categoria_id', 'Categoria', type: FieldKind.option, options: widget.registry.categoryOptions),
      const FormFieldSpec('contraparte', 'Contraparte'),
      const FormFieldSpec('ativa', 'Ativa', type: FieldKind.boolean),
    ], p ?? {'inicio': iso(DateTime.now()), 'ativa': true});
    if (d == null || !mounted) return;
    final ok = await tentar(
      context,
      () => p == null ? widget.api.create('programacoes', d) : widget.api.edit('programacoes', p['id'] as String, d),
    );
    if (ok) _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => _save(null), icon: const Icon(Icons.event_repeat), label: const Text('Programação')),
    body: Waiting(
      future: _dados,
      reload: _reload,
      construir: (d) {
        final (schedules, proj) = d;
        final cs = Theme.of(context).colorScheme;
        final balance = [for (final p in proj['saldo'] as List) (label: dataBr(p['data'] as String).substring(0, 5), value: n(p['saldo']))];
        return ListView(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 80),
          children: [
            Columns(
              left: [
                Section(
                  title: 'Recorrentes',
                  subtitle: 'salário, aluguel, assinaturas, parcelas…',
                  child: schedules.isEmpty
                      ? const Text('Nenhuma programação.')
                      : Column(
                          children: [
                            for (final p in schedules)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(p['ativa'] == true ? Icons.event_repeat : Icons.pause_circle_outline),
                                title: Text(p['descricao'] as String),
                                subtitle: Text('${p['frequencia']} desde ${dataBr(p['inicio'] as String?)}'
                                    '${p['fim'] != null ? ' até ${dataBr(p['fim'] as String)}' : ''}'),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(currency(nn(p['valor'])), style: TextStyle(color: valueColor(nn(p['valor']), cs))),
                                    MenuItem(
                                      onEdit: () => _save(p),
                                      onDelete: () async {
                                        if (await tentar(context, () => widget.api.delete('programacoes', p['id'] as String))) {
                                          _reload();
                                        }
                                      },
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                ),
              ],
              right: [
                Section(title: 'Saldo projetado', subtitle: 'contas líquidas nos próximos 90 dias', child: LineChart(balance)),
                Section(
                  title: 'Próximos lançamentos',
                  child: Column(
                    children: [
                      for (final i in (proj['itens'] as List).take(30))
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(i['descricao'] as String),
                          subtitle: Text(dataBr(i['data'] as String)),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(currency(nn(i['valor'])), style: TextStyle(color: valueColor(nn(i['valor']), cs))),
                              IconButton(
                                tooltip: 'Lançar agora no extrato',
                                icon: const Icon(Icons.playlist_add_check),
                                onPressed: () async {
                                  final ok = await tentar(context,
                                      () => widget.api.post(i['programacao_id'] as String, i['data'] as String), ok: 'Lançado');
                                  if (ok) _reload();
                                },
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        );
      },
    ),
  );
}
