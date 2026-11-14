import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../finance_api.dart';
import '../format.dart';
import 'common.dart';
import 'dashboard_screen.dart';

const tiposConta = {
  'corrente': 'Conta corrente',
  'poupanca': 'Poupança',
  'cartao': 'Cartão de crédito',
  'investimento': 'Investimentos (corretora)',
  'carteira': 'Dinheiro em espécie',
};

/// Accounts and cards with balance; the card opens the invoices and the limit usage.
class AccountsScreen extends StatelessWidget {
  const AccountsScreen({super.key, required this.api, required this.registry});

  final FinanceApi api;
  final Registry registry;

  Future<void> _save(BuildContext context, Doc? c) async {
    final d = await form(context, c == null ? 'Nova conta ou cartão' : c['nome'] as String, const [
      FormFieldSpec('nome', 'Nome', isRequired: true),
      FormFieldSpec('tipo', 'Tipo', type: FieldKind.option, options: tiposConta),
      FormFieldSpec('banco', 'Banco / emissor'),
      FormFieldSpec('saldo_inicial', 'Saldo inicial (R\$)', type: FieldKind.number, help: 'no cartão: dívida já existente em negativo'),
      FormFieldSpec('limite', 'Limite do cartão (R\$)', type: FieldKind.number),
      FormFieldSpec('dia_fechamento', 'Dia de fechamento da fatura', type: FieldKind.integer),
      FormFieldSpec('dia_vencimento', 'Dia de vencimento da fatura', type: FieldKind.integer),
      FormFieldSpec('cor', 'Cor', help: '#rrggbb'),
      FormFieldSpec('ativa', 'Ativa', type: FieldKind.boolean),
    ], c ?? {'ativa': true});
    if (d == null || !context.mounted) return;
    final ok = await tentar(context, () => c == null ? api.create('contas', d) : api.edit('contas', c['id'] as String, d));
    if (ok) await registry.carregar();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => _save(context, null), icon: const Icon(Icons.add), label: const Text('Conta')),
    body: ListenableBuilder(
      listenable: registry,
      builder: (context, _) => FutureBuilder<Doc>(
        // balances come from the summary (initial balance + entries)
        future: api.summary(mesIso(DateTime.now())),
        builder: (context, s) {
          final balances = {for (final c in (s.data?['contas'] as List?) ?? []) c['id']: nn(c['saldo'])};
          if (registry.accounts.isEmpty) {
            return const Center(child: Text('Cadastre suas contas, cartões e corretoras para importar extratos.'));
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 80),
            children: [
              for (final c in registry.accounts)
                Card(
                  child: ListTile(
                    leading: Icon(accountIcon(c['tipo'] as String), color: hexColor(c['cor'] as String?)),
                    title: Text(c['nome'] as String),
                    subtitle: Text([
                      tiposConta[c['tipo']] ?? '',
                      if ((c['banco'] as String).isNotEmpty) c['banco'],
                      if (c['tipo'] == 'cartao') 'fecha dia ${c['dia_fechamento']}, vence dia ${c['dia_vencimento']}',
                      if (c['ativa'] != true) 'inativa',
                    ].join(' · ')),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(currency(balances[c['id']]),
                            style: TextStyle(color: valueColor(balances[c['id']], Theme.of(context).colorScheme), fontWeight: FontWeight.w600)),
                        MenuItem(
                          onEdit: () => _save(context, c),
                          onDelete: () async {
                            if (!await confirm(context, 'Excluir "${c['nome']}"? As transações ficam sem conta.')) return;
                            if (!context.mounted) return;
                            if (await tentar(context, () => api.delete('contas', c['id'] as String))) await registry.carregar();
                          },
                        ),
                      ],
                    ),
                    onTap: c['tipo'] == 'cartao'
                        ? () => abrirTela<void>(context, (_) => InvoicesScreen(api: api, account: c))
                        : null,
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
}

class InvoicesScreen extends StatelessWidget {
  const InvoicesScreen({super.key, required this.api, required this.account});

  final FinanceApi api;
  final Doc account;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Faturas · ${account['nome']}')),
    body: Waiting(
      future: api.invoices(account['id'] as String),
      construir: (f) {
        final invoices = f['faturas'] as List;
        final larger = invoices.fold<double>(1, (m, x) => n(x['total']) > m ? n(x['total']) : m);
        return ListView(
          padding: const EdgeInsets.all(8),
          children: [
            IndicatorGrid(
              children: [
                Indicator('Limite', currency(nn(f['limite']))),
                Indicator('Usado', currency(nn(f['usado'])), detail: pct(nn(f['uso_limite']))),
                Indicator('Disponível', currency(nn(f['disponivel']))),
              ],
            ),
            if (f['uso_limite'] != null)
              Padding(padding: const EdgeInsets.all(8), child: ProgressBar(nn(f['uso_limite']))),
            Section(
              title: 'Faturas por mês',
              subtitle: 'compras depois do fechamento caem na fatura seguinte',
              child: Column(
                children: [
                  for (final x in invoices)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Row(
                        spacing: 8,
                        children: [
                          Text(mesBr(x['mes'] as String)),
                          Tag(x['situacao'] as String, color: switch (x['situacao']) {
                            'aberta' => Colors.orange,
                            'futura' => Colors.blue,
                            _ => Colors.grey,
                          }),
                        ],
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        spacing: 4,
                        children: [
                          Text('${x['itens']} lançamentos · vence ${dataBr(x['vencimento'] as String?)}'
                              '${n(x['pagamentos']) > 0 ? ' · pago ${currency(nn(x['pagamentos']))}' : ''}'),
                          LinearProgressIndicator(value: n(x['total']) / larger),
                        ],
                      ),
                      trailing: Text(currency(nn(x['total'])), style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    ),
  );
}
