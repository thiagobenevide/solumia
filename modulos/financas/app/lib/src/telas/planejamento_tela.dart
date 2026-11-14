import 'package:flutter/material.dart';

import '../api_financas.dart';
import '../formato.dart';
import 'comuns.dart';
import 'graficos.dart';
import 'painel_tela.dart';

/// Planejamento: orçamento por categoria (e o cadastro das categorias), metas e programações
/// (lançamentos recorrentes) com a projeção do saldo.
class PlanejamentoTela extends StatelessWidget {
  const PlanejamentoTela({super.key, required this.api, required this.cadastros});

  final ApiFinancas api;
  final Cadastros cadastros;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Column(
      children: [
        const TabBar(tabs: [Tab(text: 'Orçamento'), Tab(text: 'Metas'), Tab(text: 'Programações')]),
        Expanded(
          child: TabBarView(
            children: [
              _Orcamento(api: api, cadastros: cadastros),
              _Metas(api: api, cadastros: cadastros),
              _Programacoes(api: api, cadastros: cadastros),
            ],
          ),
        ),
      ],
    ),
  );
}

List<Campo> camposCategoria = const [
  Campo('nome', 'Nome', obrigatorio: true),
  Campo('tipo', 'Tipo', tipo: TipoCampo.opcao, opcoes: {
    'despesa': 'Despesa', 'receita': 'Receita', 'investimento': 'Investimento', 'transferencia': 'Transferência (fora dos totais)',
  }),
  Campo('grupo', 'Grupo da regra 50/30/20', tipo: TipoCampo.opcao, opcoes: {
    '': '—', 'essencial': 'Essencial (50%)', 'estilo': 'Estilo de vida (30%)', 'futuro': 'Futuro / investir (20%)',
  }),
  Campo('orcamento_mensal', 'Orçamento mensal (R\$)', tipo: TipoCampo.numero, ajuda: '0 = sem limite'),
  Campo('cor', 'Cor', ajuda: '#rrggbb'),
];

class _Orcamento extends StatefulWidget {
  const _Orcamento({required this.api, required this.cadastros});

  final ApiFinancas api;
  final Cadastros cadastros;

  @override
  State<_Orcamento> createState() => _OrcamentoState();
}

class _OrcamentoState extends State<_Orcamento> {
  late Future<Doc> _resumo = widget.api.resumo(mesIso(DateTime.now()));

  Future<void> _salvar(Doc? c) async {
    final d = await formulario(context, c == null ? 'Nova categoria' : 'Categoria', camposCategoria, c ?? {});
    if (d == null || !mounted) return;
    final ok = await tentar(
      context,
      () => c == null ? widget.api.criar('categorias', d) : widget.api.editar('categorias', c['id'] as String, d),
    );
    if (ok) {
      await widget.cadastros.carregar();
      setState(() => _resumo = widget.api.resumo(mesIso(DateTime.now())));
    }
  }

  @override
  Widget build(BuildContext context) => Esperar(
    futuro: _resumo,
    construir: (r) {
      final gasto = {for (final c in r['categorias'] as List) c['id']: n(c['valor'])};
      final cats = widget.cadastros.categorias;
      final totalOrc = cats.where((c) => c['tipo'] == 'despesa').fold<double>(0, (s, c) => s + n(c['orcamento_mensal']));
      return ListView(
        padding: const EdgeInsets.all(8),
        children: [
          GradeIndicadores(
            children: [
              Indicador('Orçado (despesas)', moeda(totalOrc)),
              Indicador('Gasto no mês', moeda(nn(r['despesas'])), detalhe: pct(totalOrc == 0 ? null : 100 * n(r['despesas']) / totalOrc)),
              Indicador('Receitas do mês', moeda(nn(r['receitas'])),
                  detalhe: 'orçado = ${pct(n(r['receitas']) == 0 ? null : 100 * totalOrc / n(r['receitas']))} da receita'),
            ],
          ),
          Secao(
            titulo: 'Categorias e limites',
            subtitulo: mesBr(r['mes'] as String),
            acoes: [IconButton(tooltip: 'Nova categoria', onPressed: () => _salvar(null), icon: const Icon(Icons.add))],
            child: Column(
              children: [
                for (final (i, c) in cats.indexed)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(radius: 8, backgroundColor: corDe(c['cor'] as String?, i)),
                    title: Text(c['nome'] as String),
                    subtitle: n(c['orcamento_mensal']) > 0
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            spacing: 4,
                            children: [
                              Text('${moeda(gasto[c['id']] ?? 0)} de ${moeda(nn(c['orcamento_mensal']))}'),
                              BarraProgresso(100 * (gasto[c['id']] ?? 0) / n(c['orcamento_mensal'])),
                            ],
                          )
                        : Text('${rotuloTipo[c['tipo']]} · ${moeda(gasto[c['id']] ?? 0)} no mês'),
                    trailing: MenuItem(
                      aoEditar: () => _salvar(c),
                      aoExcluir: () async {
                        if (!await confirmar(context, 'Excluir "${c['nome']}"? As transações ficam sem categoria.')) return;
                        if (!context.mounted) return;
                        if (await tentar(context, () => widget.api.excluir('categorias', c['id'] as String))) {
                          await widget.cadastros.carregar();
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

class _Metas extends StatefulWidget {
  const _Metas({required this.api, required this.cadastros});

  final ApiFinancas api;
  final Cadastros cadastros;

  @override
  State<_Metas> createState() => _MetasState();
}

class _MetasState extends State<_Metas> {
  late Future<List<Doc>> _metas = widget.api.metas();

  void _recarregar() => setState(() => _metas = widget.api.metas());

  Future<void> _salvar(Doc? m) async {
    final d = await formulario(context, m == null ? 'Nova meta' : 'Meta', [
      const Campo('nome', 'Nome', obrigatorio: true),
      const Campo('valor_alvo', 'Valor alvo (R\$)', tipo: TipoCampo.numero),
      const Campo('valor_inicial', 'Já tenho (R\$)', tipo: TipoCampo.numero),
      const Campo('prazo', 'Prazo', tipo: TipoCampo.data),
      Campo('categoria_id', 'Somar aportes da categoria', tipo: TipoCampo.opcao, opcoes: widget.cadastros.opcoesCategorias,
          ajuda: 'saídas nessa categoria contam como aporte'),
      const Campo('descricao', 'Descrição', tipo: TipoCampo.longo),
      const Campo('concluida', 'Concluída', tipo: TipoCampo.booleano),
    ], m ?? {'concluida': false});
    if (d == null || !mounted) return;
    final ok = await tentar(context, () => m == null ? widget.api.criar('metas', d) : widget.api.editar('metas', m['id'] as String, d));
    if (ok) _recarregar();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => _salvar(null), icon: const Icon(Icons.flag_outlined), label: const Text('Meta')),
    body: Esperar(
      futuro: _metas,
      recarregar: _recarregar,
      construir: (metas) => metas.isEmpty
          ? const Center(child: Text('Sem metas: reserva de emergência, viagem, entrada do imóvel…'))
          : ListView(
              padding: const EdgeInsets.all(8),
              children: [
                for (final m in metas)
                  Secao(
                    titulo: m['nome'] as String,
                    subtitulo: (m['descricao'] as String).isEmpty ? null : m['descricao'] as String,
                    acoes: [
                      if (m['concluida'] == true) const Etiqueta('concluída', cor: Colors.green),
                      MenuItem(
                        aoEditar: () => _salvar(m),
                        aoExcluir: () async {
                          if (await tentar(context, () => widget.api.excluir('metas', m['id'] as String))) _recarregar();
                        },
                      ),
                    ],
                    child: CartaoMeta(m),
                  ),
              ],
            ),
    ),
  );
}

class _Programacoes extends StatefulWidget {
  const _Programacoes({required this.api, required this.cadastros});

  final ApiFinancas api;
  final Cadastros cadastros;

  @override
  State<_Programacoes> createState() => _ProgramacoesState();
}

class _ProgramacoesState extends State<_Programacoes> {
  late Future<(List<Doc>, Doc)> _dados = _carregar();

  Future<(List<Doc>, Doc)> _carregar() => (widget.api.listar('programacoes'), widget.api.projecao(dias: 90)).wait;

  void _recarregar() => setState(() => _dados = _carregar());

  Future<void> _salvar(Doc? p) async {
    final d = await formulario(context, p == null ? 'Nova programação' : 'Programação', [
      const Campo('descricao', 'Descrição', obrigatorio: true),
      const Campo('valor', 'Valor', tipo: TipoCampo.numero, ajuda: 'negativo = despesa (aluguel), positivo = receita (salário)'),
      const Campo('frequencia', 'Frequência', tipo: TipoCampo.opcao,
          opcoes: {'mensal': 'Mensal', 'semanal': 'Semanal', 'anual': 'Anual', 'unica': 'Uma vez'}),
      const Campo('inicio', 'Primeira data', tipo: TipoCampo.data, obrigatorio: true),
      const Campo('fim', 'Última data (opcional)', tipo: TipoCampo.data),
      Campo('conta_id', 'Conta', tipo: TipoCampo.opcao, opcoes: widget.cadastros.opcoesContas),
      Campo('categoria_id', 'Categoria', tipo: TipoCampo.opcao, opcoes: widget.cadastros.opcoesCategorias),
      const Campo('contraparte', 'Contraparte'),
      const Campo('ativa', 'Ativa', tipo: TipoCampo.booleano),
    ], p ?? {'inicio': iso(DateTime.now()), 'ativa': true});
    if (d == null || !mounted) return;
    final ok = await tentar(
      context,
      () => p == null ? widget.api.criar('programacoes', d) : widget.api.editar('programacoes', p['id'] as String, d),
    );
    if (ok) _recarregar();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => _salvar(null), icon: const Icon(Icons.event_repeat), label: const Text('Programação')),
    body: Esperar(
      futuro: _dados,
      recarregar: _recarregar,
      construir: (d) {
        final (progs, proj) = d;
        final cs = Theme.of(context).colorScheme;
        final saldo = [for (final p in proj['saldo'] as List) (rotulo: dataBr(p['data'] as String).substring(0, 5), valor: n(p['saldo']))];
        return ListView(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 80),
          children: [
            Colunas(
              esquerda: [
                Secao(
                  titulo: 'Recorrentes',
                  subtitulo: 'salário, aluguel, assinaturas, parcelas…',
                  child: progs.isEmpty
                      ? const Text('Nenhuma programação.')
                      : Column(
                          children: [
                            for (final p in progs)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(p['ativa'] == true ? Icons.event_repeat : Icons.pause_circle_outline),
                                title: Text(p['descricao'] as String),
                                subtitle: Text('${p['frequencia']} desde ${dataBr(p['inicio'] as String?)}'
                                    '${p['fim'] != null ? ' até ${dataBr(p['fim'] as String)}' : ''}'),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(moeda(nn(p['valor'])), style: TextStyle(color: corValor(nn(p['valor']), cs))),
                                    MenuItem(
                                      aoEditar: () => _salvar(p),
                                      aoExcluir: () async {
                                        if (await tentar(context, () => widget.api.excluir('programacoes', p['id'] as String))) {
                                          _recarregar();
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
              direita: [
                Secao(titulo: 'Saldo projetado', subtitulo: 'contas líquidas nos próximos 90 dias', child: GraficoLinha(saldo)),
                Secao(
                  titulo: 'Próximos lançamentos',
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
                              Text(moeda(nn(i['valor'])), style: TextStyle(color: corValor(nn(i['valor']), cs))),
                              IconButton(
                                tooltip: 'Lançar agora no extrato',
                                icon: const Icon(Icons.playlist_add_check),
                                onPressed: () async {
                                  final ok = await tentar(context,
                                      () => widget.api.lancar(i['programacao_id'] as String, i['data'] as String), ok: 'Lançado');
                                  if (ok) _recarregar();
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
