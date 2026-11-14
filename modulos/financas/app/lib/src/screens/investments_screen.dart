import 'package:agent_arquivos/agent_arquivos.dart';
import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../finance_api.dart';
import '../format.dart';
import 'common.dart';
import 'company_screen.dart';
import 'charts.dart';

const companyStatus = {
  'estudo': 'Em estudo',
  'observar': 'Observar',
  'aprovada': 'Aprovada para aporte',
  'reprovada': 'Reprovada',
  'carteira': 'Na carteira',
};

/// Investments: ranking of the studied companies, sectors, portfolio (operations and dividends) and the
/// selection questionnaire.
class InvestmentsScreen extends StatelessWidget {
  const InvestmentsScreen({super.key, required this.api, required this.files, required this.registry});

  final FinanceApi api;
  final FilesApi files;
  final Registry registry;

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
              _Companies(api: api, files: files),
              _Sectors(api: api),
              _Portfolio(api: api, registry: registry),
              _Questionnaire(api: api),
            ],
          ),
        ),
      ],
    ),
  );
}

class _Companies extends StatefulWidget {
  const _Companies({required this.api, required this.files});

  final FinanceApi api;
  final FilesApi files;

  @override
  State<_Companies> createState() => _CompaniesState();
}

class _CompaniesState extends State<_Companies> {
  late Future<List<Doc>> _ranking = widget.api.ranking();
  String? _status;

  void _reload() => setState(() { _ranking = widget.api.ranking(); });

  Future<void> _newTask() async {
    final d = await form(context, 'Nova empresa', companyFields);
    if (d == null || !mounted) return;
    Doc? e;
    await tentar(context, () async => e = await widget.api.create('empresas', d));
    if (e != null) await _open(e!['id'] as String);
  }

  Future<void> _open(String id) async {
    await abrirTela<void>(context, (_) => CompanyScreen(api: widget.api, files: widget.files, id: id));
    _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton.extended(onPressed: _newTask, icon: const Icon(Icons.add_business), label: const Text('Empresa')),
    body: Waiting(
      future: _ranking,
      reload: _reload,
      construir: (items) {
        final filtered = _status == null ? items : items.where((e) => e['status'] == _status).toList();
        return ListView(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 80),
          children: [
            Wrap(
              spacing: 6,
              children: [
                ChoiceChip(label: Text('Todas (${items.length})'), selected: _status == null, onSelected: (_) => setState(() => _status = null)),
                for (final s in companyStatus.entries)
                  ChoiceChip(
                    label: Text('${s.value} (${items.where((e) => e['status'] == s.key).length})'),
                    selected: _status == s.key,
                    onSelected: (_) => setState(() => _status = s.key),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (filtered.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Cadastre uma empresa, preencha os demonstrativos (DRE, balanço), anexe os relatórios e '
                    'responda o questionário: a nota final diz se ela está apta para aporte.'),
              ),
            for (final e in filtered)
              Card(
                child: ListTile(
                  onTap: () => _open(e['id'] as String),
                  leading: _Note(nn(e['nota_final'])),
                  title: Text('${e['ticker']} · ${e['nome']}'),
                  subtitle: Wrap(
                    spacing: 10,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if ((e['setor'] as String).isNotEmpty) Text(e['setor'] as String),
                      Tag(companyStatus[e['status']] ?? '${e['status']}'),
                      Tag(e['veredito'] as String, color: verdictColor(e['veredito'] as String)),
                      Text('ROE ${pct(nn(e['roe']))} · ML ${pct(nn(e['margem_liquida']))} · P/L ${number(nn(e['pl']))} · '
                          'P/VP ${number(nn(e['pvp']))} · DY ${pct(nn(e['dy']))}'),
                    ],
                  ),
                  trailing: Text(currency(nn(e['cotacao']))),
                ),
              ),
          ],
        );
      },
    ),
  );
}

const companyFields = [
  FormFieldSpec('ticker', 'Ticker', isRequired: true, help: 'ex.: TAEE11'),
  FormFieldSpec('nome', 'Nome'),
  FormFieldSpec('setor', 'Setor', help: 'igual ao nome do setor cadastrado para somar a nota dele'),
  FormFieldSpec('segmento', 'Segmento'),
  FormFieldSpec('cnpj', 'CNPJ'),
  FormFieldSpec('site', 'Site de RI'),
  FormFieldSpec('status', 'Status', type: FieldKind.option, options: companyStatus),
  FormFieldSpec('cotacao', 'Cotação atual (R\$)', type: FieldKind.number),
  FormFieldSpec('acoes', 'Número de ações', type: FieldKind.number, help: 'na mesma unidade dos demonstrativos (ex.: mil)'),
  FormFieldSpec('preco_teto', 'Preço teto / valor justo (R\$)', type: FieldKind.number),
  FormFieldSpec('descricao', 'O que a empresa faz', type: FieldKind.longText),
];

class _Note extends StatelessWidget {
  const _Note(this.note);

  final double? note;

  @override
  Widget build(BuildContext context) {
    final color = note == null ? Colors.grey : (note! >= 70 ? Colors.green : (note! >= 50 ? Colors.orange : Colors.red));
    return CircleAvatar(
      backgroundColor: color.withValues(alpha: 0.2),
      child: Text(note == null ? '—' : note!.round().toString(), style: TextStyle(color: color, fontWeight: FontWeight.bold)),
    );
  }
}

// --- setores ---

class _Sectors extends StatefulWidget {
  const _Sectors({required this.api});

  final FinanceApi api;

  @override
  State<_Sectors> createState() => _SectorsState();
}

class _SectorsState extends State<_Sectors> {
  late Future<List<Doc>> _sectors = widget.api.list('setores');

  void _reload() => setState(() { _sectors = widget.api.list('setores'); });

  Future<void> _new() async {
    final d = await form(context, 'Novo setor', const [
      FormFieldSpec('nome', 'Nome', isRequired: true, help: 'ex.: Energia elétrica, Bancos, Saneamento'),
      FormFieldSpec('descricao', 'Descrição e tese do setor', type: FieldKind.longText),
    ]);
    if (d == null || !mounted) return;
    if (await tentar(context, () => widget.api.create('setores', d))) _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton.extended(onPressed: _new, icon: const Icon(Icons.add), label: const Text('Setor')),
    body: Waiting(
      future: _sectors,
      reload: _reload,
      construir: (sectors) => sectors.isEmpty
          ? const Center(child: Text('Avalie primeiro o setor: perenidade, barreiras, regulação, dividendos.'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 80),
              children: [
                for (final s in sectors)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.category_outlined),
                      title: Text(s['nome'] as String),
                      subtitle: Text((s['descricao'] as String).isEmpty ? 'toque para responder o questionário do setor' : s['descricao'] as String,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      onTap: () async {
                        await abrirTela<void>(context, (_) => SectorScreen(api: widget.api, id: s['id'] as String));
                        _reload();
                      },
                    ),
                  ),
              ],
            ),
    ),
  );
}

class SectorScreen extends StatefulWidget {
  const SectorScreen({super.key, required this.api, required this.id});

  final FinanceApi api;
  final String id;

  @override
  State<SectorScreen> createState() => _SectorScreenState();
}

class _SectorScreenState extends State<SectorScreen> {
  late Future<(Doc, List<Doc>)> _dados = _load();

  Future<(Doc, List<Doc>)> _load() => (widget.api.sectorAnalysis(widget.id), widget.api.questionnaire()).wait;

  void _reload() => setState(() { _dados = _load(); });

  @override
  Widget build(BuildContext context) => Waiting(
    future: _dados,
    reload: _reload,
    construir: (d) {
      final (a, questions) = d;
      final sector = a['setor'] as Doc;
      final q = a['questionario'] as Doc;
      return Scaffold(
        appBar: AppBar(
          title: Text(sector['nome'] as String),
          actions: [
            IconButton(
              tooltip: 'Editar',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () async {
                final e = await form(context, 'Setor', const [
                  FormFieldSpec('nome', 'Nome', isRequired: true),
                  FormFieldSpec('descricao', 'Descrição e tese do setor', type: FieldKind.longText),
                ], sector);
                if (e == null || !context.mounted) return;
                if (await tentar(context, () => widget.api.edit('setores', widget.id, e))) _reload();
              },
            ),
            IconButton(
              tooltip: 'Excluir',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                if (!await confirm(context, 'Excluir o setor?') || !context.mounted) return;
                if (await tentar(context, () => widget.api.delete('setores', widget.id)) && context.mounted) Navigator.pop(context);
              },
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(8),
          children: [
            IndicatorGrid(
              children: [
                Indicator('Nota do setor', q['nota'] == null ? '—' : number(nn(q['nota']), decimals: 0),
                    color: verdictColor(a['veredito'] as String), detail: '${q['respondidas']}/${q['total']} respondidas'),
                Indicator('Veredito', a['veredito'] as String, color: verdictColor(a['veredito'] as String)),
              ],
            ),
            if ((sector['descricao'] as String).isNotEmpty) Section(title: 'Tese do setor', child: Text(sector['descricao'] as String)),
            Section(
              title: 'Questionário do setor',
              child: Answers(
                questions: questions.where((p) => p['alvo'] == 'setor').toList(),
                answers: Map<String, dynamic>.from(sector['respostas'] as Map),
                onSave: (r) async {
                  if (await tentar(context, () => widget.api.edit('setores', widget.id, {'respostas': r}), ok: 'Salvo')) _reload();
                },
              ),
            ),
            Section(
              title: 'Empresas do setor',
              child: Column(
                children: [
                  for (final e in a['empresas'] as List)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: _Note(nn(e['nota_final'])),
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

/// Questions grouped by block with a 0–5 score each; [onSave] gets the id → score map.
class Answers extends StatefulWidget {
  const Answers({super.key, required this.questions, required this.answers, required this.onSave});

  final List<Doc> questions;
  final Map<String, dynamic> answers;
  final ValueChanged<Map<String, dynamic>> onSave;

  @override
  State<Answers> createState() => _AnswersState();
}

class _AnswersState extends State<Answers> {
  late final _r = Map<String, dynamic>.from(widget.answers);
  var _changed = false;

  static const _labels = ['0 · não', '1', '2', '3', '4', '5 · sim, muito'];

  @override
  Widget build(BuildContext context) {
    final blocks = <String, List<Doc>>{};
    for (final p in widget.questions) {
      blocks.putIfAbsent(p['bloco'] as String, () => []).add(p);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        for (final b in blocks.entries) ...[
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
                        label: Text(i == 0 || i == 5 ? _labels[i] : '$i'),
                        selected: _r[p['id']] == i,
                        onSelected: (s) => setState(() {
                          _changed = true;
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
            onPressed: _changed ? () {
              setState(() => _changed = false);
              widget.onSave(_r);
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

class _Portfolio extends StatefulWidget {
  const _Portfolio({required this.api, required this.registry});

  final FinanceApi api;
  final Registry registry;

  @override
  State<_Portfolio> createState() => _PortfolioState();
}

class _PortfolioState extends State<_Portfolio> {
  late Future<(Doc, List<Doc>, List<Doc>)> _dados = _load();

  Future<(Doc, List<Doc>, List<Doc>)> _load() =>
      (widget.api.portfolio(), widget.api.list('operacoes'), widget.api.list('proventos')).wait;

  void _reload() => setState(() { _dados = _load(); });

  Future<void> _operation([Doc? o]) async {
    final d = await form(context, o == null ? 'Nova operação' : 'Operação', [
      const FormFieldSpec('data', 'Data', type: FieldKind.data, isRequired: true),
      const FormFieldSpec('ticker', 'Ticker', isRequired: true),
      const FormFieldSpec('tipo', 'Tipo', type: FieldKind.option, options: {'compra': 'Compra', 'venda': 'Venda'}),
      const FormFieldSpec('quantidade', 'Quantidade', type: FieldKind.number),
      const FormFieldSpec('preco', 'Preço unitário (R\$)', type: FieldKind.number),
      const FormFieldSpec('taxas', 'Taxas e corretagem (R\$)', type: FieldKind.number),
      FormFieldSpec('conta_id', 'Corretora', type: FieldKind.option, options: widget.registry.accountOptions),
      const FormFieldSpec('observacao', 'Observação / motivo', type: FieldKind.longText),
    ], o ?? {'data': iso(DateTime.now())});
    if (d == null || !mounted) return;
    d['ticker'] = (d['ticker'] as String).toUpperCase();
    final ok = await tentar(context, () => o == null ? widget.api.create('operacoes', d) : widget.api.edit('operacoes', o['id'] as String, d));
    if (ok) _reload();
  }

  Future<void> _dividend([Doc? p]) async {
    final d = await form(context, p == null ? 'Novo provento' : 'Provento', const [
      FormFieldSpec('data', 'Data do pagamento', type: FieldKind.data, isRequired: true),
      FormFieldSpec('ticker', 'Ticker', isRequired: true),
      FormFieldSpec('tipo', 'Tipo', type: FieldKind.option, options: {'dividendo': 'Dividendo', 'jcp': 'JCP', 'rendimento': 'Rendimento (FII)', 'outro': 'Outro'}),
      FormFieldSpec('valor', 'Valor recebido (R\$)', type: FieldKind.number),
    ], p ?? {'data': iso(DateTime.now())});
    if (d == null || !mounted) return;
    d['ticker'] = (d['ticker'] as String).toUpperCase();
    final ok = await tentar(context, () => p == null ? widget.api.create('proventos', d) : widget.api.edit('proventos', p['id'] as String, d));
    if (ok) _reload();
  }

  @override
  Widget build(BuildContext context) => Waiting(
    future: _dados,
    reload: _reload,
    construir: (d) {
      final (c, ops, dividends) = d;
      final cs = Theme.of(context).colorScheme;
      final t = c['totais'] as Doc;
      final openItems = [for (final p in c['posicoes'] as List) if (n(p['quantidade']) > 0) p as Doc];
      return ListView(
        padding: const EdgeInsets.all(8),
        children: [
          IndicatorGrid(
            children: [
              Indicator('Valor da carteira', currency(nn(t['valor_atual'])), icone: Icons.pie_chart_outline),
              Indicator('Custo', currency(nn(t['custo']))),
              Indicator('Resultado em aberto', currency(nn(t['resultado_aberto'])), color: valueColor(nn(t['resultado_aberto']), cs),
                  detail: pct(nn(t['rentabilidade']))),
              Indicator('Lucro realizado', currency(nn(t['realizado'])), color: valueColor(nn(t['realizado']), cs)),
              Indicator('Proventos recebidos', currency(nn(t['proventos'])), color: Colors.green.shade400),
            ],
          ),
          Columns(
            left: [
              Section(
                title: 'Posições',
                subtitle: 'cotação vem do cadastro da empresa',
                child: openItems.isEmpty
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
                            for (final p in openItems)
                              DataRow(cells: [
                                DataCell(Text(p['ticker'] as String)),
                                DataCell(Text(number(nn(p['quantidade']), decimals: 0))),
                                DataCell(Text(number(nn(p['preco_medio'])))),
                                DataCell(Text(number(nn(p['cotacao'])))),
                                DataCell(Text(currency(nn(p['valor_atual'])))),
                                DataCell(Text(pct(nn(p['rentabilidade'])), style: TextStyle(color: valueColor(nn(p['rentabilidade']), cs)))),
                                DataCell(Text(pct(nn(p['peso'])))),
                                DataCell(Text(pct(nn(p['yield_on_cost'])))),
                              ]),
                          ],
                        ),
                      ),
              ),
              Section(
                title: 'Operações',
                stocks: [IconButton(tooltip: 'Nova operação', onPressed: _operation, icon: const Icon(Icons.add))],
                child: Column(
                  children: [
                    for (final o in ops.reversed.take(50))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(o['tipo'] == 'compra' ? Icons.add_shopping_cart : Icons.sell_outlined,
                            color: o['tipo'] == 'compra' ? Colors.green.shade400 : cs.error),
                        title: Text('${o['tipo']} ${number(nn(o['quantidade']), decimals: 0)} ${o['ticker']} a ${currency(nn(o['preco']))}'),
                        subtitle: Text(dataBr(o['data'] as String?)),
                        trailing: MenuItem(
                          onEdit: () => _operation(o),
                          onDelete: () async {
                            if (await tentar(context, () => widget.api.delete('operacoes', o['id'] as String))) _reload();
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ],
            right: [
              Section(
                title: 'Alocação por setor',
                child: Donut([
                  for (final (i, s) in (c['por_setor'] as List).indexed)
                    (name: s['setor'] as String, value: n(s['valor']), color: palette[i % palette.length]),
                ], center: currency(nn(t['valor_atual']))),
              ),
              Section(
                title: 'Proventos',
                stocks: [IconButton(tooltip: 'Novo provento', onPressed: _dividend, icon: const Icon(Icons.add))],
                child: Column(
                  children: [
                    for (final m in (c['proventos_mes'] as List).reversed.take(12))
                      Row(children: [Expanded(child: Text(mesBr(m['mes'] as String))), Text(currency(nn(m['valor'])))]),
                    const Divider(),
                    for (final p in dividends.reversed.take(30))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('${p['ticker']} · ${p['tipo']}'),
                        subtitle: Text(dataBr(p['data'] as String?)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(currency(nn(p['valor']))),
                            MenuItem(
                              onEdit: () => _dividend(p),
                              onDelete: () async {
                                if (await tentar(context, () => widget.api.delete('proventos', p['id'] as String))) _reload();
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

// --- questionnaire (template) ---

class _Questionnaire extends StatefulWidget {
  const _Questionnaire({required this.api});

  final FinanceApi api;

  @override
  State<_Questionnaire> createState() => _QuestionnaireState();
}

class _QuestionnaireState extends State<_Questionnaire> {
  late Future<List<Doc>> _questions = widget.api.questionnaire();

  static const _campos = [
    FormFieldSpec('texto', 'Pergunta', isRequired: true),
    FormFieldSpec('alvo', 'Avalia', type: FieldKind.option, options: {'empresa': 'Empresa', 'setor': 'Setor'}),
    FormFieldSpec('bloco', 'Bloco', help: 'ex.: Negócio, Gestão, Valuation'),
    FormFieldSpec('peso', 'Peso', type: FieldKind.integer),
    FormFieldSpec('ajuda', 'Como avaliar', type: FieldKind.longText),
  ];

  Future<void> _saveList(List<Doc> items) async {
    List<Doc>? nova;
    await tentar(context, () async => nova = await widget.api.saveQuestionnaire(items), ok: 'Questionário salvo');
    if (nova != null) setState(() { _questions = Future.value(nova); });
  }

  @override
  Widget build(BuildContext context) => Waiting(
    future: _questions,
    construir: (questions) => Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final d = await form(context, 'Nova pergunta', _campos, {'peso': 1, 'bloco': 'Geral'});
          if (d != null) await _saveList([...questions, d]);
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
          for (final (i, p) in questions.indexed)
            ListTile(
              leading: Tag(p['alvo'] as String, color: p['alvo'] == 'setor' ? Colors.purple : Colors.blue),
              title: Text(p['texto'] as String),
              subtitle: Text('${p['bloco']} · peso ${p['peso']}'),
              trailing: MenuItem(
                onEdit: () async {
                  final d = await form(context, 'Pergunta', _campos, p);
                  if (d != null) await _saveList([...questions]..[i] = {...p, ...d});
                },
                onDelete: () => _saveList([...questions]..removeAt(i)),
              ),
            ),
        ],
      ),
    ),
  );
}
