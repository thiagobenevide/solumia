import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_financas.dart';
import '../formato.dart';
import 'comuns.dart';
import 'painel_tela.dart';

const tiposConta = {
  'corrente': 'Conta corrente',
  'poupanca': 'Poupança',
  'cartao': 'Cartão de crédito',
  'investimento': 'Investimentos (corretora)',
  'carteira': 'Dinheiro em espécie',
};

/// Contas e cartões com saldo; o cartão abre as faturas e o uso do limite.
class ContasTela extends StatelessWidget {
  const ContasTela({super.key, required this.api, required this.cadastros});

  final ApiFinancas api;
  final Cadastros cadastros;

  Future<void> _salvar(BuildContext context, Doc? c) async {
    final d = await formulario(context, c == null ? 'Nova conta ou cartão' : c['nome'] as String, const [
      Campo('nome', 'Nome', obrigatorio: true),
      Campo('tipo', 'Tipo', tipo: TipoCampo.opcao, opcoes: tiposConta),
      Campo('banco', 'Banco / emissor'),
      Campo('saldo_inicial', 'Saldo inicial (R\$)', tipo: TipoCampo.numero, ajuda: 'no cartão: dívida já existente em negativo'),
      Campo('limite', 'Limite do cartão (R\$)', tipo: TipoCampo.numero),
      Campo('dia_fechamento', 'Dia de fechamento da fatura', tipo: TipoCampo.inteiro),
      Campo('dia_vencimento', 'Dia de vencimento da fatura', tipo: TipoCampo.inteiro),
      Campo('cor', 'Cor', ajuda: '#rrggbb'),
      Campo('ativa', 'Ativa', tipo: TipoCampo.booleano),
    ], c ?? {'ativa': true});
    if (d == null || !context.mounted) return;
    final ok = await tentar(context, () => c == null ? api.criar('contas', d) : api.editar('contas', c['id'] as String, d));
    if (ok) await cadastros.carregar();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => _salvar(context, null), icon: const Icon(Icons.add), label: const Text('Conta')),
    body: ListenableBuilder(
      listenable: cadastros,
      builder: (context, _) => FutureBuilder<Doc>(
        // saldos vêm do resumo (saldo inicial + lançamentos)
        future: api.resumo(mesIso(DateTime.now())),
        builder: (context, s) {
          final saldos = {for (final c in (s.data?['contas'] as List?) ?? []) c['id']: nn(c['saldo'])};
          if (cadastros.contas.isEmpty) {
            return const Center(child: Text('Cadastre suas contas, cartões e corretoras para importar extratos.'));
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 80),
            children: [
              for (final c in cadastros.contas)
                Card(
                  child: ListTile(
                    leading: Icon(iconeConta(c['tipo'] as String), color: corHex(c['cor'] as String?)),
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
                        Text(moeda(saldos[c['id']]),
                            style: TextStyle(color: corValor(saldos[c['id']], Theme.of(context).colorScheme), fontWeight: FontWeight.w600)),
                        MenuItem(
                          aoEditar: () => _salvar(context, c),
                          aoExcluir: () async {
                            if (!await confirmar(context, 'Excluir "${c['nome']}"? As transações ficam sem conta.')) return;
                            if (!context.mounted) return;
                            if (await tentar(context, () => api.excluir('contas', c['id'] as String))) await cadastros.carregar();
                          },
                        ),
                      ],
                    ),
                    onTap: c['tipo'] == 'cartao'
                        ? () => abrirTela<void>(context, (_) => FaturasTela(api: api, conta: c))
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

class FaturasTela extends StatelessWidget {
  const FaturasTela({super.key, required this.api, required this.conta});

  final ApiFinancas api;
  final Doc conta;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Faturas · ${conta['nome']}')),
    body: Esperar(
      futuro: api.faturas(conta['id'] as String),
      construir: (f) {
        final faturas = f['faturas'] as List;
        final maior = faturas.fold<double>(1, (m, x) => n(x['total']) > m ? n(x['total']) : m);
        return ListView(
          padding: const EdgeInsets.all(8),
          children: [
            GradeIndicadores(
              children: [
                Indicador('Limite', moeda(nn(f['limite']))),
                Indicador('Usado', moeda(nn(f['usado'])), detalhe: pct(nn(f['uso_limite']))),
                Indicador('Disponível', moeda(nn(f['disponivel']))),
              ],
            ),
            if (f['uso_limite'] != null)
              Padding(padding: const EdgeInsets.all(8), child: BarraProgresso(nn(f['uso_limite']))),
            Secao(
              titulo: 'Faturas por mês',
              subtitulo: 'compras depois do fechamento caem na fatura seguinte',
              child: Column(
                children: [
                  for (final x in faturas)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Row(
                        spacing: 8,
                        children: [
                          Text(mesBr(x['mes'] as String)),
                          Etiqueta(x['situacao'] as String, cor: switch (x['situacao']) {
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
                              '${n(x['pagamentos']) > 0 ? ' · pago ${moeda(nn(x['pagamentos']))}' : ''}'),
                          LinearProgressIndicator(value: n(x['total']) / maior),
                        ],
                      ),
                      trailing: Text(moeda(nn(x['total'])), style: const TextStyle(fontWeight: FontWeight.w600)),
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
