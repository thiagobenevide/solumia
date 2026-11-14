import 'package:flutter/material.dart';

import '../api_financas.dart';
import '../formato.dart';
import 'comuns.dart';
import 'graficos.dart';

/// Dashboard do mês: KPIs pessoais, fluxo de caixa, categorias, orçamento, 50/30/20, contrapartes,
/// lançamentos programados, metas e saldos.
class PainelTela extends StatefulWidget {
  const PainelTela({super.key, required this.api, required this.cadastros});

  final ApiFinancas api;
  final Cadastros cadastros;

  @override
  State<PainelTela> createState() => _PainelTelaState();
}

class _PainelTelaState extends State<PainelTela> {
  var _mes = DateTime(DateTime.now().year, DateTime.now().month);
  late Future<(Doc, List<Doc>, Doc)> _dados = _carregar();

  Future<(Doc, List<Doc>, Doc)> _carregar() {
    final m = mesIso(_mes);
    final fim = iso(DateTime(_mes.year, _mes.month + 1, 0));
    return (
      widget.api.resumo(m),
      widget.api.fluxo(ate: m),
      widget.api.contrapartes(de: iso(somarMeses(_mes, -2)), ate: fim),
    ).wait;
  }

  void _recarregar() => setState(() => _dados = _carregar());

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            SeletorMes(mes: _mes, aoMudar: (m) => setState(() {
              _mes = m;
              _dados = _carregar();
            })),
            const Spacer(),
            IconButton(tooltip: 'Atualizar', icon: const Icon(Icons.refresh), onPressed: _recarregar),
          ],
        ),
      ),
      Expanded(
        child: Esperar(
          futuro: _dados,
          recarregar: _recarregar,
          construir: (d) => _conteudo(context, d.$1, d.$2, d.$3),
        ),
      ),
    ],
  );

  Widget _conteudo(BuildContext context, Doc r, List<Doc> fluxo, Doc cp) {
    final cs = Theme.of(context).colorScheme;
    final ind = r['indicadores'] as Doc;
    final pat = r['patrimonio'] as Doc;
    final ant = r['anterior'] as Doc;
    final cats = [for (final c in r['categorias'] as List) c as Doc];
    final despesas = cats.where((c) => c['tipo'] != 'receita' && n(c['valor']) > 0).toList();
    final orcadas = cats.where((c) => n(c['orcamento']) > 0).toList();

    String variacao(dynamic v) => v == null ? 'mês anterior sem dados' : '${n(v) >= 0 ? '+' : ''}${pct(nn(v))} vs mês anterior';

    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        GradeIndicadores(
          children: [
            Indicador('Receitas', moeda(nn(r['receitas'])), icone: Icons.south_west, cor: Colors.green.shade400,
                detalhe: variacao(r['variacao_receitas'])),
            Indicador('Despesas', moeda(nn(r['despesas'])), icone: Icons.north_east, cor: cs.error,
                detalhe: variacao(r['variacao_despesas'])),
            Indicador('Investido no mês', moeda(nn(r['investimentos'])), icone: Icons.savings_outlined,
                detalhe: 'taxa de investimento ${pct(nn(ind['taxa_investimento']))}'),
            Indicador('Saldo do mês', moeda(nn(r['saldo'])), icone: Icons.account_balance_wallet_outlined,
                cor: corValor(nn(r['saldo']), cs), detalhe: 'mês anterior ${moeda(nn(ant['saldo']))}'),
            Indicador('Taxa de poupança', pct(nn(ind['taxa_poupanca'])), icone: Icons.percent,
                cor: n(ind['taxa_poupanca']) >= 20 ? Colors.green.shade400 : Colors.orange,
                detalhe: '(receitas − despesas) / receitas; meta ≥ 20%'),
            Indicador('Comprometimento', pct(nn(ind['comprometimento_despesas'])), icone: Icons.pie_chart_outline,
                detalhe: 'despesas / receitas'),
            Indicador('Reserva de emergência', ind['reserva_meses'] == null ? '—' : '${numero(nn(ind['reserva_meses']), casas: 1)} meses',
                icone: Icons.shield_outlined,
                cor: n(ind['reserva_meses']) >= 6 ? Colors.green.shade400 : Colors.orange,
                detalhe: 'liquidez / despesa média de 3 meses (${moeda(nn(ind['despesa_media_3m']))})'),
            Indicador('Patrimônio líquido', moeda(nn(pat['liquido'])), icone: Icons.account_balance_outlined,
                detalhe: 'líquido ${moeda(nn(pat['liquidez']))} · investido ${moeda(nn(pat['investido']))} · dívidas ${moeda(nn(pat['dividas']))}'),
            Indicador('Gasto médio diário', moeda(nn(ind['gasto_medio_diario'])), icone: Icons.today_outlined,
                detalhe: 'projeção do mês ${moeda(nn(ind['projecao_despesas_mes']))}'),
            Indicador('Despesas fixas', moeda(nn(ind['despesas_fixas'])), icone: Icons.repeat,
                detalhe: '${pct(nn(ind['peso_fixas']))} da receita (programações mensais)'),
            Indicador('Cartão de crédito', moeda(nn(ind['gasto_cartao'])), icone: Icons.credit_card,
                cor: n(ind['peso_cartao']) > 30 ? cs.error : null,
                detalhe: '${pct(nn(ind['peso_cartao']))} da receita'),
            if (n(ind['sem_categoria']) > 0)
              Indicador('Sem categoria', '${ind['sem_categoria']}', icone: Icons.label_off_outlined, cor: Colors.orange,
                  detalhe: 'categorize no Extrato para indicadores precisos'),
          ],
        ),
        Colunas(
          esquerda: [
            Secao(titulo: 'Fluxo de caixa', subtitulo: 'últimos 12 meses', child: GraficoFluxo(fluxo)),
            Secao(
              titulo: 'Despesas por categoria',
              child: despesas.isEmpty
                  ? const Text('Sem despesas no mês.')
                  : Rosca(
                      [for (final (i, c) in despesas.indexed) (nome: c['nome'] as String, valor: n(c['valor']), cor: corDe(c['cor'] as String?, i))],
                      centro: moeda(nn(r['despesas'])),
                    ),
            ),
            Secao(
              titulo: 'Orçamento do mês',
              subtitulo: 'defina limites em Planejamento › Orçamento',
              child: orcadas.isEmpty
                  ? const Text('Nenhuma categoria com orçamento.')
                  : Column(
                      spacing: 10,
                      children: [for (final c in orcadas) _LinhaOrcamento(c)],
                    ),
            ),
            Secao(titulo: 'Regra 50/30/20', subtitulo: 'em % da receita do mês', child: _Regra(r['regra_50_30_20'] as Doc)),
          ],
          direita: [
            Secao(
              titulo: 'Para quem mais envio dinheiro',
              subtitulo: 'últimos 3 meses',
              child: _Ranking([for (final x in cp['enviado'] as List) x as Doc], cs.error),
            ),
            Secao(
              titulo: 'De quem mais recebo',
              subtitulo: 'últimos 3 meses',
              child: _Ranking([for (final x in cp['recebido'] as List) x as Doc], Colors.green.shade400),
            ),
            Secao(titulo: 'A lançar no mês', subtitulo: 'programações pendentes', child: _ALancar(r, widget.api, _recarregar)),
            Secao(titulo: 'Metas', child: _Metas([for (final m in r['metas'] as List) m as Doc])),
            Secao(
              titulo: 'Maiores despesas',
              child: Column(
                children: [
                  for (final t in r['maiores_despesas'] as List)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(t['descricao'] as String, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${dataBr(t['data'] as String?)} · ${widget.cadastros.categoria(t['categoria_id'] as String?)?['nome'] ?? 'sem categoria'}'),
                      trailing: Text(moeda(nn(t['valor'])), style: TextStyle(color: cs.error)),
                    ),
                ],
              ),
            ),
            Secao(
              titulo: 'Contas',
              child: Column(
                children: [
                  for (final c in r['contas'] as List)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(iconeConta(c['tipo'] as String)),
                      title: Text(c['nome'] as String),
                      trailing: Text(moeda(nn(c['saldo'])), style: TextStyle(color: corValor(nn(c['saldo']), cs))),
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

IconData iconeConta(String tipo) => switch (tipo) {
  'cartao' => Icons.credit_card,
  'poupanca' => Icons.savings_outlined,
  'investimento' => Icons.trending_up,
  'carteira' => Icons.payments_outlined,
  _ => Icons.account_balance_outlined,
};

class _LinhaOrcamento extends StatelessWidget {
  const _LinhaOrcamento(this.c);

  final Doc c;

  @override
  Widget build(BuildContext context) {
    final resto = n(c['orcamento']) - n(c['valor']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 4,
      children: [
        Row(
          children: [
            Expanded(child: Text(c['nome'] as String)),
            Flexible(
              child: Text('${moeda(nn(c['valor']))} de ${moeda(nn(c['orcamento']))}',
                  textAlign: TextAlign.end, style: Theme.of(context).textTheme.bodySmall),
            ),
          ],
        ),
        BarraProgresso(nn(c['uso_orcamento']), cor: corHex(c['cor'] as String?)),
        Text(resto >= 0 ? 'restam ${moeda(resto)}' : 'estourou ${moeda(-resto)}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: resto < 0 ? Theme.of(context).colorScheme.error : null)),
      ],
    );
  }
}

class _Regra extends StatelessWidget {
  const _Regra(this.r);

  final Doc r;

  @override
  Widget build(BuildContext context) {
    const nomes = {'essencial': 'Essenciais', 'estilo': 'Estilo de vida', 'futuro': 'Futuro (investir)'};
    return Column(
      spacing: 10,
      children: [
        for (final e in nomes.entries)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 4,
            children: [
              Row(
                children: [
                  Expanded(child: Text(e.value)),
                  Flexible(
                    child: Text('${pct(nn(r[e.key]['pct']))} · ideal ${r[e.key]['ideal']}%  (${moeda(nn(r[e.key]['valor']))})',
                        textAlign: TextAlign.end, style: Theme.of(context).textTheme.bodySmall),
                  ),
                ],
              ),
              BarraProgresso(
                r[e.key]['pct'] == null ? 0 : 100 * n(r[e.key]['pct']) / n(r[e.key]['ideal']),
                cor: e.key == 'futuro' ? Colors.teal : null,
              ),
            ],
          ),
      ],
    );
  }
}

class _Ranking extends StatelessWidget {
  const _Ranking(this.itens, this.cor);

  final List<Doc> itens;
  final Color cor;

  @override
  Widget build(BuildContext context) {
    if (itens.isEmpty) return const Text('Sem movimentações.');
    final maximo = n(itens.first['valor']);
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
                  child: LinearProgressIndicator(value: maximo == 0 ? 0 : n(x['valor']) / maximo, minHeight: 6, color: cor,
                      backgroundColor: Colors.transparent),
                ),
              ),
              SizedBox(width: 110, child: Text(moeda(nn(x['valor'])), textAlign: TextAlign.end)),
              SizedBox(width: 36, child: Text('${x['vezes']}×', style: Theme.of(context).textTheme.bodySmall)),
            ],
          ),
      ],
    );
  }
}

class _ALancar extends StatelessWidget {
  const _ALancar(this.r, this.api, this.aoLancar);

  final Doc r;
  final ApiFinancas api;
  final VoidCallback aoLancar;

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
                Text(moeda(nn(i['valor'])), style: TextStyle(color: corValor(nn(i['valor']), Theme.of(context).colorScheme))),
                IconButton(
                  tooltip: 'Lançar no extrato',
                  icon: const Icon(Icons.playlist_add_check),
                  onPressed: () async {
                    if (await tentar(context, () => api.lancar(i['programacao_id'] as String, i['data'] as String))) aoLancar();
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Metas extends StatelessWidget {
  const _Metas(this.metas);

  final List<Doc> metas;

  @override
  Widget build(BuildContext context) {
    if (metas.isEmpty) return const Text('Crie metas em Planejamento › Metas.');
    return Column(spacing: 12, children: [for (final m in metas) CartaoMeta(m)]);
  }
}

class CartaoMeta extends StatelessWidget {
  const CartaoMeta(this.m, {super.key});

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
      BarraProgresso(nn(m['progresso']), cor: Colors.teal),
      Text(
        [
          '${moeda(nn(m['atual']))} de ${moeda(nn(m['valor_alvo']))}',
          if (m['prazo'] != null) 'até ${dataBr(m['prazo'] as String)}',
          if (m['aporte_mensal_necessario'] != null) 'aportar ${moeda(nn(m['aporte_mensal_necessario']))}/mês',
        ].join(' · '),
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ],
  );
}
