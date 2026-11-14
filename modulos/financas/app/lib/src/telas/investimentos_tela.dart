import 'package:agent_arquivos/agent_arquivos.dart';
import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_financas.dart';
import '../formato.dart';
import 'comuns.dart';
import 'empresa_tela.dart';
import 'graficos.dart';

const statusEmpresa = {
  'estudo': 'Em estudo',
  'observar': 'Observar',
  'aprovada': 'Aprovada para aporte',
  'reprovada': 'Reprovada',
  'carteira': 'Na carteira',
};

/// Investimentos: ranking das empresas estudadas, setores, carteira (operações e proventos) e o
/// questionário de seleção.
class InvestimentosTela extends StatelessWidget {
  const InvestimentosTela({super.key, required this.api, required this.arquivos, required this.cadastros});

  final ApiFinancas api;
  final ApiArquivos arquivos;
  final Cadastros cadastros;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 4,
    child: Column(
      children: [
        const TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [Tab(text: 'Empresas'), Tab(text: 'Setores'), Tab(text: 'Carteira'), Tab(text: 'Questionário')],
        ),
        Expanded(
          child: TabBarView(
            children: [
              _Empresas(api: api, arquivos: arquivos),
              _Setores(api: api),
              _Carteira(api: api, cadastros: cadastros),
              _Questionario(api: api),
            ],
          ),
        ),
      ],
    ),
  );
}

class _Empresas extends StatefulWidget {
  const _Empresas({required this.api, required this.arquivos});

  final ApiFinancas api;
  final ApiArquivos arquivos;

  @override
  State<_Empresas> createState() => _EmpresasState();
}

class _EmpresasState extends State<_Empresas> {
  late Future<List<Doc>> _ranking = widget.api.ranking();
  String? _status;

  void _recarregar() => setState(() { _ranking = widget.api.ranking(); });

  Future<void> _nova() async {
    final d = await formulario(context, 'Nova empresa', camposEmpresa);
    if (d == null || !mounted) return;
    Doc? e;
    await tentar(context, () async => e = await widget.api.criar('empresas', d));
    if (e != null) await _abrir(e!['id'] as String);
  }

  Future<void> _abrir(String id) async {
    await abrirTela<void>(context, (_) => EmpresaTela(api: widget.api, arquivos: widget.arquivos, id: id));
    _recarregar();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton.extended(onPressed: _nova, icon: const Icon(Icons.add_business), label: const Text('Empresa')),
    body: Esperar(
      futuro: _ranking,
      recarregar: _recarregar,
      construir: (lista) {
        final filtradas = _status == null ? lista : lista.where((e) => e['status'] == _status).toList();
        return ListView(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 80),
          children: [
            Wrap(
              spacing: 6,
              children: [
                ChoiceChip(label: Text('Todas (${lista.length})'), selected: _status == null, onSelected: (_) => setState(() => _status = null)),
                for (final s in statusEmpresa.entries)
                  ChoiceChip(
                    label: Text('${s.value} (${lista.where((e) => e['status'] == s.key).length})'),
                    selected: _status == s.key,
                    onSelected: (_) => setState(() => _status = s.key),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (filtradas.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Cadastre uma empresa, preencha os demonstrativos (DRE, balanço), anexe os relatórios e '
                    'responda o questionário: a nota final diz se ela está apta para aporte.'),
              ),
            for (final e in filtradas)
              Card(
                child: ListTile(
                  onTap: () => _abrir(e['id'] as String),
                  leading: _Nota(nn(e['nota_final'])),
                  title: Text('${e['ticker']} · ${e['nome']}'),
                  subtitle: Wrap(
                    spacing: 10,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if ((e['setor'] as String).isNotEmpty) Text(e['setor'] as String),
                      Etiqueta(statusEmpresa[e['status']] ?? '${e['status']}'),
                      Etiqueta(e['veredito'] as String, cor: corVeredito(e['veredito'] as String)),
                      Text('ROE ${pct(nn(e['roe']))} · ML ${pct(nn(e['margem_liquida']))} · P/L ${numero(nn(e['pl']))} · '
                          'P/VP ${numero(nn(e['pvp']))} · DY ${pct(nn(e['dy']))}'),
                    ],
                  ),
                  trailing: Text(moeda(nn(e['cotacao']))),
                ),
              ),
          ],
        );
      },
    ),
  );
}

const camposEmpresa = [
  Campo('ticker', 'Ticker', obrigatorio: true, ajuda: 'ex.: TAEE11'),
  Campo('nome', 'Nome'),
  Campo('setor', 'Setor', ajuda: 'igual ao nome do setor cadastrado para somar a nota dele'),
  Campo('segmento', 'Segmento'),
  Campo('cnpj', 'CNPJ'),
  Campo('site', 'Site de RI'),
  Campo('status', 'Status', tipo: TipoCampo.opcao, opcoes: statusEmpresa),
  Campo('cotacao', 'Cotação atual (R\$)', tipo: TipoCampo.numero),
  Campo('acoes', 'Número de ações', tipo: TipoCampo.numero, ajuda: 'na mesma unidade dos demonstrativos (ex.: mil)'),
  Campo('preco_teto', 'Preço teto / valor justo (R\$)', tipo: TipoCampo.numero),
  Campo('descricao', 'O que a empresa faz', tipo: TipoCampo.longo),
];

class _Nota extends StatelessWidget {
  const _Nota(this.nota);

  final double? nota;

  @override
  Widget build(BuildContext context) {
    final cor = nota == null ? Colors.grey : (nota! >= 70 ? Colors.green : (nota! >= 50 ? Colors.orange : Colors.red));
    return CircleAvatar(
      backgroundColor: cor.withValues(alpha: 0.2),
      child: Text(nota == null ? '—' : nota!.round().toString(), style: TextStyle(color: cor, fontWeight: FontWeight.bold)),
    );
  }
}

// --- setores ---

class _Setores extends StatefulWidget {
  const _Setores({required this.api});

  final ApiFinancas api;

  @override
  State<_Setores> createState() => _SetoresState();
}

class _SetoresState extends State<_Setores> {
  late Future<List<Doc>> _setores = widget.api.listar('setores');

  void _recarregar() => setState(() { _setores = widget.api.listar('setores'); });

  Future<void> _novo() async {
    final d = await formulario(context, 'Novo setor', const [
      Campo('nome', 'Nome', obrigatorio: true, ajuda: 'ex.: Energia elétrica, Bancos, Saneamento'),
      Campo('descricao', 'Descrição e tese do setor', tipo: TipoCampo.longo),
    ]);
    if (d == null || !mounted) return;
    if (await tentar(context, () => widget.api.criar('setores', d))) _recarregar();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton.extended(onPressed: _novo, icon: const Icon(Icons.add), label: const Text('Setor')),
    body: Esperar(
      futuro: _setores,
      recarregar: _recarregar,
      construir: (setores) => setores.isEmpty
          ? const Center(child: Text('Avalie primeiro o setor: perenidade, barreiras, regulação, dividendos.'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 80),
              children: [
                for (final s in setores)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.category_outlined),
                      title: Text(s['nome'] as String),
                      subtitle: Text((s['descricao'] as String).isEmpty ? 'toque para responder o questionário do setor' : s['descricao'] as String,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      onTap: () async {
                        await abrirTela<void>(context, (_) => SetorTela(api: widget.api, id: s['id'] as String));
                        _recarregar();
                      },
                    ),
                  ),
              ],
            ),
    ),
  );
}

class SetorTela extends StatefulWidget {
  const SetorTela({super.key, required this.api, required this.id});

  final ApiFinancas api;
  final String id;

  @override
  State<SetorTela> createState() => _SetorTelaState();
}

class _SetorTelaState extends State<SetorTela> {
  late Future<(Doc, List<Doc>)> _dados = _carregar();

  Future<(Doc, List<Doc>)> _carregar() => (widget.api.analiseSetor(widget.id), widget.api.questionario()).wait;

  void _recarregar() => setState(() { _dados = _carregar(); });

  @override
  Widget build(BuildContext context) => Esperar(
    futuro: _dados,
    recarregar: _recarregar,
    construir: (d) {
      final (a, perguntas) = d;
      final setor = a['setor'] as Doc;
      final q = a['questionario'] as Doc;
      return Scaffold(
        appBar: AppBar(
          title: Text(setor['nome'] as String),
          actions: [
            IconButton(
              tooltip: 'Editar',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () async {
                final e = await formulario(context, 'Setor', const [
                  Campo('nome', 'Nome', obrigatorio: true),
                  Campo('descricao', 'Descrição e tese do setor', tipo: TipoCampo.longo),
                ], setor);
                if (e == null || !context.mounted) return;
                if (await tentar(context, () => widget.api.editar('setores', widget.id, e))) _recarregar();
              },
            ),
            IconButton(
              tooltip: 'Excluir',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                if (!await confirmar(context, 'Excluir o setor?') || !context.mounted) return;
                if (await tentar(context, () => widget.api.excluir('setores', widget.id)) && context.mounted) Navigator.pop(context);
              },
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(8),
          children: [
            GradeIndicadores(
              children: [
                Indicador('Nota do setor', q['nota'] == null ? '—' : numero(nn(q['nota']), casas: 0),
                    cor: corVeredito(a['veredito'] as String), detalhe: '${q['respondidas']}/${q['total']} respondidas'),
                Indicador('Veredito', a['veredito'] as String, cor: corVeredito(a['veredito'] as String)),
              ],
            ),
            if ((setor['descricao'] as String).isNotEmpty) Secao(titulo: 'Tese do setor', child: Text(setor['descricao'] as String)),
            Secao(
              titulo: 'Questionário do setor',
              child: Respostas(
                perguntas: perguntas.where((p) => p['alvo'] == 'setor').toList(),
                respostas: Map<String, dynamic>.from(setor['respostas'] as Map),
                aoSalvar: (r) async {
                  if (await tentar(context, () => widget.api.editar('setores', widget.id, {'respostas': r}), ok: 'Salvo')) _recarregar();
                },
              ),
            ),
            Secao(
              titulo: 'Empresas do setor',
              child: Column(
                children: [
                  for (final e in a['empresas'] as List)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: _Nota(nn(e['nota_final'])),
                      title: Text('${e['ticker']} · ${e['nome']}'),
                      subtitle: Text(e['veredito'] as String),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// Perguntas agrupadas por bloco com nota 0–5 cada; [aoSalvar] recebe o mapa id → nota.
class Respostas extends StatefulWidget {
  const Respostas({super.key, required this.perguntas, required this.respostas, required this.aoSalvar});

  final List<Doc> perguntas;
  final Map<String, dynamic> respostas;
  final ValueChanged<Map<String, dynamic>> aoSalvar;

  @override
  State<Respostas> createState() => _RespostasState();
}

class _RespostasState extends State<Respostas> {
  late final _r = Map<String, dynamic>.from(widget.respostas);
  var _mudou = false;

  static const _rotulos = ['0 · não', '1', '2', '3', '4', '5 · sim, muito'];

  @override
  Widget build(BuildContext context) {
    final blocos = <String, List<Doc>>{};
    for (final p in widget.perguntas) {
      blocos.putIfAbsent(p['bloco'] as String, () => []).add(p);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        for (final b in blocos.entries) ...[
          Text(b.key, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
          for (final p in b.value)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                Text('${p['texto']}  (peso ${p['peso']})'),
                if ((p['ajuda'] as String? ?? '').isNotEmpty) Text(p['ajuda'] as String, style: Theme.of(context).textTheme.bodySmall),
                Wrap(
                  spacing: 4,
                  children: [
                    for (var i = 0; i <= 5; i++)
                      ChoiceChip(
                        label: Text(i == 0 || i == 5 ? _rotulos[i] : '$i'),
                        selected: _r[p['id']] == i,
                        onSelected: (s) => setState(() {
                          _mudou = true;
                          s ? _r[p['id'] as String] = i : _r.remove(p['id']);
                        }),
                      ),
                  ],
                ),
              ],
            ),
        ],
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: _mudou ? () {
              setState(() => _mudou = false);
              widget.aoSalvar(_r);
            } : null,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Salvar respostas'),
          ),
        ),
      ],
    );
  }
}

// --- carteira ---

class _Carteira extends StatefulWidget {
  const _Carteira({required this.api, required this.cadastros});

  final ApiFinancas api;
  final Cadastros cadastros;

  @override
  State<_Carteira> createState() => _CarteiraState();
}

class _CarteiraState extends State<_Carteira> {
  late Future<(Doc, List<Doc>, List<Doc>)> _dados = _carregar();

  Future<(Doc, List<Doc>, List<Doc>)> _carregar() =>
      (widget.api.carteira(), widget.api.listar('operacoes'), widget.api.listar('proventos')).wait;

  void _recarregar() => setState(() { _dados = _carregar(); });

  Future<void> _operacao([Doc? o]) async {
    final d = await formulario(context, o == null ? 'Nova operação' : 'Operação', [
      const Campo('data', 'Data', tipo: TipoCampo.data, obrigatorio: true),
      const Campo('ticker', 'Ticker', obrigatorio: true),
      const Campo('tipo', 'Tipo', tipo: TipoCampo.opcao, opcoes: {'compra': 'Compra', 'venda': 'Venda'}),
      const Campo('quantidade', 'Quantidade', tipo: TipoCampo.numero),
      const Campo('preco', 'Preço unitário (R\$)', tipo: TipoCampo.numero),
      const Campo('taxas', 'Taxas e corretagem (R\$)', tipo: TipoCampo.numero),
      Campo('conta_id', 'Corretora', tipo: TipoCampo.opcao, opcoes: widget.cadastros.opcoesContas),
      const Campo('observacao', 'Observação / motivo', tipo: TipoCampo.longo),
    ], o ?? {'data': iso(DateTime.now())});
    if (d == null || !mounted) return;
    d['ticker'] = (d['ticker'] as String).toUpperCase();
    final ok = await tentar(context, () => o == null ? widget.api.criar('operacoes', d) : widget.api.editar('operacoes', o['id'] as String, d));
    if (ok) _recarregar();
  }

  Future<void> _provento([Doc? p]) async {
    final d = await formulario(context, p == null ? 'Novo provento' : 'Provento', const [
      Campo('data', 'Data do pagamento', tipo: TipoCampo.data, obrigatorio: true),
      Campo('ticker', 'Ticker', obrigatorio: true),
      Campo('tipo', 'Tipo', tipo: TipoCampo.opcao, opcoes: {'dividendo': 'Dividendo', 'jcp': 'JCP', 'rendimento': 'Rendimento (FII)', 'outro': 'Outro'}),
      Campo('valor', 'Valor recebido (R\$)', tipo: TipoCampo.numero),
    ], p ?? {'data': iso(DateTime.now())});
    if (d == null || !mounted) return;
    d['ticker'] = (d['ticker'] as String).toUpperCase();
    final ok = await tentar(context, () => p == null ? widget.api.criar('proventos', d) : widget.api.editar('proventos', p['id'] as String, d));
    if (ok) _recarregar();
  }

  @override
  Widget build(BuildContext context) => Esperar(
    futuro: _dados,
    recarregar: _recarregar,
    construir: (d) {
      final (c, ops, provs) = d;
      final cs = Theme.of(context).colorScheme;
      final t = c['totais'] as Doc;
      final abertas = [for (final p in c['posicoes'] as List) if (n(p['quantidade']) > 0) p as Doc];
      return ListView(
        padding: const EdgeInsets.all(8),
        children: [
          GradeIndicadores(
            children: [
              Indicador('Valor da carteira', moeda(nn(t['valor_atual'])), icone: Icons.pie_chart_outline),
              Indicador('Custo', moeda(nn(t['custo']))),
              Indicador('Resultado em aberto', moeda(nn(t['resultado_aberto'])), cor: corValor(nn(t['resultado_aberto']), cs),
                  detalhe: pct(nn(t['rentabilidade']))),
              Indicador('Lucro realizado', moeda(nn(t['realizado'])), cor: corValor(nn(t['realizado']), cs)),
              Indicador('Proventos recebidos', moeda(nn(t['proventos'])), cor: Colors.green.shade400),
            ],
          ),
          Colunas(
            esquerda: [
              Secao(
                titulo: 'Posições',
                subtitulo: 'cotação vem do cadastro da empresa',
                child: abertas.isEmpty
                    ? const Text('Sem posições abertas.')
                    : SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: DataTable(
                          columnSpacing: 18,
                          columns: const [
                            DataColumn(label: Text('Ativo')),
                            DataColumn(label: Text('Qtd'), numeric: true),
                            DataColumn(label: Text('PM'), numeric: true),
                            DataColumn(label: Text('Cotação'), numeric: true),
                            DataColumn(label: Text('Valor'), numeric: true),
                            DataColumn(label: Text('Result.'), numeric: true),
                            DataColumn(label: Text('Peso'), numeric: true),
                            DataColumn(label: Text('YoC'), numeric: true),
                          ],
                          rows: [
                            for (final p in abertas)
                              DataRow(cells: [
                                DataCell(Text(p['ticker'] as String)),
                                DataCell(Text(numero(nn(p['quantidade']), casas: 0))),
                                DataCell(Text(numero(nn(p['preco_medio'])))),
                                DataCell(Text(numero(nn(p['cotacao'])))),
                                DataCell(Text(moeda(nn(p['valor_atual'])))),
                                DataCell(Text(pct(nn(p['rentabilidade'])), style: TextStyle(color: corValor(nn(p['rentabilidade']), cs)))),
                                DataCell(Text(pct(nn(p['peso'])))),
                                DataCell(Text(pct(nn(p['yield_on_cost'])))),
                              ]),
                          ],
                        ),
                      ),
              ),
              Secao(
                titulo: 'Operações',
                acoes: [IconButton(tooltip: 'Nova operação', onPressed: _operacao, icon: const Icon(Icons.add))],
                child: Column(
                  children: [
                    for (final o in ops.reversed.take(50))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(o['tipo'] == 'compra' ? Icons.add_shopping_cart : Icons.sell_outlined,
                            color: o['tipo'] == 'compra' ? Colors.green.shade400 : cs.error),
                        title: Text('${o['tipo']} ${numero(nn(o['quantidade']), casas: 0)} ${o['ticker']} a ${moeda(nn(o['preco']))}'),
                        subtitle: Text(dataBr(o['data'] as String?)),
                        trailing: MenuItem(
                          aoEditar: () => _operacao(o),
                          aoExcluir: () async {
                            if (await tentar(context, () => widget.api.excluir('operacoes', o['id'] as String))) _recarregar();
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ],
            direita: [
              Secao(
                titulo: 'Alocação por setor',
                child: Rosca([
                  for (final (i, s) in (c['por_setor'] as List).indexed)
                    (nome: s['setor'] as String, valor: n(s['valor']), cor: paleta[i % paleta.length]),
                ], centro: moeda(nn(t['valor_atual']))),
              ),
              Secao(
                titulo: 'Proventos',
                acoes: [IconButton(tooltip: 'Novo provento', onPressed: _provento, icon: const Icon(Icons.add))],
                child: Column(
                  children: [
                    for (final m in (c['proventos_mes'] as List).reversed.take(12))
                      Row(children: [Expanded(child: Text(mesBr(m['mes'] as String))), Text(moeda(nn(m['valor'])))]),
                    const Divider(),
                    for (final p in provs.reversed.take(30))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('${p['ticker']} · ${p['tipo']}'),
                        subtitle: Text(dataBr(p['data'] as String?)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(moeda(nn(p['valor']))),
                            MenuItem(
                              aoEditar: () => _provento(p),
                              aoExcluir: () async {
                                if (await tentar(context, () => widget.api.excluir('proventos', p['id'] as String))) _recarregar();
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
  );
}

// --- questionário (modelo) ---

class _Questionario extends StatefulWidget {
  const _Questionario({required this.api});

  final ApiFinancas api;

  @override
  State<_Questionario> createState() => _QuestionarioState();
}

class _QuestionarioState extends State<_Questionario> {
  late Future<List<Doc>> _perguntas = widget.api.questionario();

  static const _campos = [
    Campo('texto', 'Pergunta', obrigatorio: true),
    Campo('alvo', 'Avalia', tipo: TipoCampo.opcao, opcoes: {'empresa': 'Empresa', 'setor': 'Setor'}),
    Campo('bloco', 'Bloco', ajuda: 'ex.: Negócio, Gestão, Valuation'),
    Campo('peso', 'Peso', tipo: TipoCampo.inteiro),
    Campo('ajuda', 'Como avaliar', tipo: TipoCampo.longo),
  ];

  Future<void> _salvarLista(List<Doc> lista) async {
    List<Doc>? nova;
    await tentar(context, () async => nova = await widget.api.salvarQuestionario(lista), ok: 'Questionário salvo');
    if (nova != null) setState(() { _perguntas = Future.value(nova); });
  }

  @override
  Widget build(BuildContext context) => Esperar(
    futuro: _perguntas,
    construir: (perguntas) => Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final d = await formulario(context, 'Nova pergunta', _campos, {'peso': 1, 'bloco': 'Geral'});
          if (d != null) await _salvarLista([...perguntas, d]);
        },
        icon: const Icon(Icons.add),
        label: const Text('Pergunta'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 80),
        children: [
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text('Cada pergunta recebe nota de 0 a 5 multiplicada pelo peso. Nota final da empresa = 50% '
                'questionário da empresa + 30% checagens automáticas dos indicadores + 20% nota do setor. '
                '≥ 70 apta para aporte · ≥ 50 observar · abaixo disso evitar.'),
          ),
          for (final (i, p) in perguntas.indexed)
            ListTile(
              leading: Etiqueta(p['alvo'] as String, cor: p['alvo'] == 'setor' ? Colors.purple : Colors.blue),
              title: Text(p['texto'] as String),
              subtitle: Text('${p['bloco']} · peso ${p['peso']}'),
              trailing: MenuItem(
                aoEditar: () async {
                  final d = await formulario(context, 'Pergunta', _campos, p);
                  if (d != null) await _salvarLista([...perguntas]..[i] = {...p, ...d});
                },
                aoExcluir: () => _salvarLista([...perguntas]..removeAt(i)),
              ),
            ),
        ],
      ),
    ),
  );
}
