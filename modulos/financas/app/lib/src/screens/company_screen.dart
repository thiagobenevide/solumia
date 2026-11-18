import 'package:agent_arquivos/agent_arquivos.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../finance_api.dart';
import '../format.dart';
import 'common.dart';
import 'investments_screen.dart';
import 'market_screen.dart';

const accountLabel = {
  'receita_liquida': 'Receita líquida',
  'custo': 'Custo (CPV)',
  'lucro_bruto': 'Lucro bruto',
  'despesas_operacionais': 'Despesas operacionais',
  'ebit': 'EBIT',
  'depreciacao': 'Depreciação e amortização',
  'resultado_financeiro': 'Resultado financeiro',
  'lucro_antes_ir': 'Lucro antes do IR',
  'ir_csll': 'IR e CSLL',
  'lucro_liquido': 'Lucro líquido',
  'ativo_total': 'Ativo total',
  'ativo_circulante': 'Ativo circulante',
  'caixa': 'Caixa e aplicações',
  'passivo_circulante': 'Passivo circulante',
  'divida_bruta': 'Dívida bruta',
  'patrimonio_liquido': 'Patrimônio líquido',
  'fco': 'Fluxo de caixa operacional',
  'capex': 'Capex',
  'dividendos': 'Dividendos + JCP pagos',
  'acoes': 'Número de ações (mil)',
};

/// Indicators by year: (key, label, is percentage).
const _indicators = [
  ('margem_bruta', 'Margem bruta', true),
  ('margem_ebit', 'Margem EBIT', true),
  ('margem_ebitda', 'Margem EBITDA', true),
  ('margem_liquida', 'Margem líquida', true),
  ('roe', 'ROE', true),
  ('roa', 'ROA', true),
  ('roic', 'ROIC', true),
  ('cresc_receita', 'Cresc. receita', true),
  ('cresc_lucro', 'Cresc. lucro', true),
  ('payout', 'Payout', true),
  ('conversao_caixa', 'FCO / lucro', true),
  ('ebitda', 'EBITDA', false),
  ('divida_liquida', 'Dívida líquida', false),
  ('divida_liquida_ebitda', 'Dív. líq. / EBITDA', false),
  ('divida_liquida_pl', 'Dív. líq. / PL', false),
  ('liquidez_corrente', 'Liquidez corrente', false),
  ('giro_ativo', 'Giro do ativo', false),
  ('fcl', 'Fluxo de caixa livre', false),
  ('lpa', 'LPA', false),
  ('vpa', 'VPA', false),
];

/// Values in R\$ (no decimals); the others are ratios.
const _absolute = {'ebitda', 'divida_liquida', 'fcl'};

class CompanyScreen extends StatefulWidget {
  const CompanyScreen({super.key, required this.api, required this.files, required this.id});

  final FinanceApi api;
  final FilesApi files;
  final String id;

  @override
  State<CompanyScreen> createState() => _CompanyScreenState();
}

class _CompanyScreenState extends State<CompanyScreen> {
  late Future<(Doc, List<Doc>)> _dados = _load();

  Future<(Doc, List<Doc>)> _load() => (widget.api.analysis(widget.id), widget.api.questionnaire()).wait;

  void _reload() => setState(() => _dados = _load());

  Future<void> _edit(Doc data) async {
    if (await tentar(context, () => widget.api.edit('empresas', widget.id, data))) _reload();
  }

  @override
  Widget build(BuildContext context) => Waiting(
    future: _dados,
    reload: _reload,
    construir: (d) {
      final (a, questions) = d;
      final e = a['empresa'] as Doc;
      return DefaultTabController(
        length: 7,
        child: Scaffold(
          appBar: AppBar(
            title: Text('${e['ticker']} · ${e['nome']}'),
            actions: [
              IconButton(
                tooltip: 'Atualizar pela CVM (DRE, ações e cotação)',
                icon: const Icon(Icons.sync),
                onPressed: () async {
                  if (await tentar(context, () => widget.api.importCvm(widget.id), ok: 'Atualizada pela CVM')) _reload();
                },
              ),
              IconButton(
                tooltip: 'Editar cadastro',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () async {
                  final data = await form(context, 'Empresa', companyFields, e);
                  if (data != null) await _edit(data);
                },
              ),
              IconButton(
                tooltip: 'Excluir',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  if (!await confirm(context, 'Excluir ${e['ticker']} e toda a análise?') || !context.mounted) return;
                  if (await tentar(context, () => widget.api.delete('empresas', widget.id)) && context.mounted) {
                    Navigator.pop(context);
                  }
                },
              ),
            ],
            bottom: const TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(text: 'Mercado'),
                Tab(text: 'Análise'),
                Tab(text: 'Demonstrativos'),
                Tab(text: 'Indicadores'),
                Tab(text: 'Questionário'),
                Tab(text: 'Relatórios'),
                Tab(text: 'Anotações'),
              ],
            ),
          ),
          body: TabBarView(
            children: [
              '${e['ticker']}'.isEmpty
                  ? const Center(child: Text('Cadastre o ticker para ver cotação, proventos e documentos.'))
                  : MarketSheet(api: widget.api, files: widget.files, query: '${e['ticker']}', canFollow: false),
              _Summary(a: a, onEdit: _edit),
              _Statements(a: a, onEdit: _edit),
              _Indicators(a: a),
              ListView(
                padding: const EdgeInsets.all(8),
                children: [
                  Section(
                    title: 'Questionário da empresa',
                    subtitle: 'edite as perguntas em Investimentos › Questionário',
                    child: Answers(
                      questions: questions.where((p) => p['alvo'] == 'empresa').toList(),
                      answers: Map<String, dynamic>.from(e['respostas'] as Map),
                      onSave: (r) => _edit({'respostas': r}),
                    ),
                  ),
                ],
              ),
              _Reports(company: e, files: widget.files, onEdit: _edit),
              _Annotations(company: e, onEdit: _edit),
            ],
          ),
        ),
      );
    },
  );
}

class _Summary extends StatelessWidget {
  const _Summary({required this.a, required this.onEdit});

  final Doc a;
  final Future<void> Function(Doc) onEdit;

  @override
  Widget build(BuildContext context) {
    final e = a['empresa'] as Doc;
    final v = a['valuation'] as Doc;
    final q = a['questionario'] as Doc;
    final sector = a['setor'] as Doc?;
    final verdict = a['veredito'] as String;
    String num2(dynamic x) => number(nn(x));
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        IndicatorGrid(
          children: [
            Indicator('Nota final', a['nota_final'] == null ? '—' : number(nn(a['nota_final']), decimals: 0),
                color: verdictColor(verdict), detail: verdict, icone: Icons.verified_outlined),
            Indicator('Questionário', q['nota'] == null ? '—' : number(nn(q['nota']), decimals: 0),
                detail: '${q['respondidas']}/${q['total']} respondidas · peso 50%'),
            Indicator('Indicadores', a['nota_indicadores'] == null ? '—' : number(nn(a['nota_indicadores']), decimals: 0),
                detail: 'checagens automáticas · peso 30%'),
            Indicator('Setor', sector?['nota'] == null ? '—' : number(nn(sector!['nota']), decimals: 0),
                detail: sector == null ? 'cadastre o setor "${e['setor']}"' : '${sector['nome']} · peso 20%'),
          ],
        ),
        IndicatorGrid(
          children: [
            Indicator('Cotação', currency(nn(v['cotacao']))),
            Indicator('Valor de mercado', currency(nn(v['valor_mercado']))),
            Indicator('P/L', num2(v['pl'])),
            Indicator('P/VP', num2(v['pvp'])),
            Indicator('EV/EBITDA', num2(v['ev_ebitda'])),
            Indicator('EV/EBIT', num2(v['ev_ebit'])),
            Indicator('PSR', num2(v['psr'])),
            Indicator('Dividend yield', pct(nn(v['dy']))),
            Indicator('FCL yield', pct(nn(v['fcl_yield']))),
            Indicator('CAGR receita', pct(nn(a['cagr_receita']))),
            Indicator('CAGR lucro', pct(nn(a['cagr_lucro']))),
            Indicator('Preço Graham', currency(nn(v['preco_graham'])), detail: '√(22,5 × LPA × VPA)'),
            Indicator('Preço Bazin', currency(nn(v['preco_bazin'])), detail: 'dividendo por ação / 6%'),
            Indicator('Preço teto', currency(nn(v['preco_teto'])), detail: 'margem de segurança ${pct(nn(v['margem_seguranca']))}',
                color: v['margem_seguranca'] == null ? null : valueColor(nn(v['margem_seguranca']), Theme.of(context).colorScheme)),
          ],
        ),
        Columns(
          left: [
            Section(
              title: 'Checagens automáticas',
              subtitle: 'último ano dos demonstrativos',
              child: Column(
                children: [
                  for (final c in a['checagens'] as List)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        c['ok'] == null ? Icons.help_outline : (c['ok'] == true ? Icons.check_circle : Icons.cancel),
                        color: c['ok'] == null ? Colors.grey : (c['ok'] == true ? Colors.green : Colors.red),
                      ),
                      title: Text(c['nome'] as String),
                      trailing: c['valor'] == null ? null : Text(number(nn(c['valor']))),
                    ),
                ],
              ),
            ),
            if ((q['blocos'] as Map).isNotEmpty)
              Section(
                title: 'Questionário por bloco',
                child: Column(
                  spacing: 8,
                  children: [
                    for (final b in (q['blocos'] as Map).entries)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        spacing: 4,
                        children: [Text('${b.key} · ${pct(nn(b.value))}'), ProgressBar(nn(b.value))],
                      ),
                  ],
                ),
              ),
          ],
          right: [
            _EditableText(title: 'Tese de investimento', value: e['tese'] as String, onSave: (t) => onEdit({'tese': t})),
            _EditableText(title: 'Riscos', value: e['riscos'] as String, onSave: (t) => onEdit({'riscos': t})),
            if ((e['descricao'] as String).isNotEmpty) Section(title: 'O que faz', child: Text(e['descricao'] as String)),
          ],
        ),
      ],
    );
  }
}

class _EditableText extends StatelessWidget {
  const _EditableText({required this.title, required this.value, required this.onSave});

  final String title;
  final String value;
  final ValueChanged<String> onSave;

  @override
  Widget build(BuildContext context) => Section(
    title: title,
    stocks: [
      IconButton(
        icon: const Icon(Icons.edit_outlined, size: 18),
        onPressed: () async {
          final d = await form(context, title, [FormFieldSpec('t', title, type: FieldKind.longText)], {'t': value});
          if (d != null) onSave(d['t'] as String);
        },
      ),
    ],
    child: Text(value.isEmpty ? 'Ainda não escrito.' : value),
  );
}

class _Statements extends StatefulWidget {
  const _Statements({required this.a, required this.onEdit});

  final Doc a;
  final Future<void> Function(Doc) onEdit;

  @override
  State<_Statements> createState() => _StatementsState();
}

class _StatementsState extends State<_Statements> {
  var _vertical = false;

  List<Doc> get _dem => [for (final d in widget.a['demonstrativos'] as List) d as Doc];

  Future<void> _year([Doc? current]) async {
    final d = await form(context, current == null ? 'Novo ano' : 'Ano ${current['ano']}', [
      const FormFieldSpec('ano', 'Ano', type: FieldKind.integer, isRequired: true),
      for (final c in accountLabel.entries) FormFieldSpec(c.key, c.value, type: FieldKind.number),
    ], current ?? {'ano': DateTime.now().year - 1});
    if (d == null) return;
    // an empty number becomes 0 in the form; here 0 means "not informed"
    final line = {for (final e in d.entries) e.key: e.key == 'ano' || e.value != 0 ? e.value : null};
    final items = [..._dem.where((x) => x['ano'] != line['ano'] && x['ano'] != current?['ano']), line];
    await widget.onEdit({'demonstrativos': items});
  }

  Future<void> _delete(Doc year) async {
    if (!await confirm(context, 'Excluir o ano ${year['ano']}?')) return;
    await widget.onEdit({'demonstrativos': _dem.where((x) => x['ano'] != year['ano']).toList()});
  }

  @override
  Widget build(BuildContext context) {
    final dem = _dem;
    final vertical = {for (final v in widget.a['vertical'] as List) v['ano']: v as Doc};
    final accounts = _vertical ? accountLabel.keys.where((k) => vertical.values.firstOrNull?.containsKey(k) ?? false) : accountLabel.keys;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(onPressed: _year, icon: const Icon(Icons.add), label: const Text('Ano')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 80),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('Valores na unidade dos relatórios (ex.: R\$ mil). Toque no ano para editar. '
                  'Fonte: DFP/ITR na CVM ou o release de resultados no site de RI.'),
              FilterChip(label: const Text('Análise vertical (% da receita)'), selected: _vertical,
                  onSelected: (v) => setState(() => _vertical = v)),
            ],
          ),
          if (dem.isEmpty)
            const Padding(padding: EdgeInsets.all(24), child: Text('Nenhum ano cadastrado.'))
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columnSpacing: 20,
                columns: [
                  const DataColumn(label: Text('Conta')),
                  for (final d in dem)
                    DataColumn(
                      numeric: true,
                      label: InkWell(
                        onTap: () => _year(d),
                        onLongPress: () => _delete(d),
                        child: Text('${d['ano']}', style: TextStyle(color: Theme.of(context).colorScheme.primary)),
                      ),
                    ),
                ],
                rows: [
                  for (final c in accounts)
                    DataRow(cells: [
                      DataCell(Text(accountLabel[c]!)),
                      for (final d in dem)
                        DataCell(Text(_vertical ? pct(nn(vertical[d['ano']]?[c])) : number(nn(d[c]), decimals: 0))),
                    ]),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Indicators extends StatelessWidget {
  const _Indicators({required this.a});

  final Doc a;

  @override
  Widget build(BuildContext context) {
    final series = [for (final i in a['indicadores'] as List) i as Doc];
    if (series.isEmpty) return const Center(child: Text('Preencha os demonstrativos para calcular os indicadores.'));
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columnSpacing: 20,
            columns: [
              const DataColumn(label: Text('Indicador')),
              for (final i in series) DataColumn(numeric: true, label: Text('${i['ano']}')),
            ],
            rows: [
              for (final (k, label, ehPct) in _indicators)
                DataRow(cells: [
                  DataCell(Text(label)),
                  for (final i in series)
                    DataCell(Text(
                      ehPct ? pct(nn(i[k])) : number(nn(i[k]), decimals: _absolute.contains(k) ? 0 : 2),
                      style: TextStyle(color: k.startsWith('cresc') && i[k] != null ? valueColor(nn(i[k]), cs) : null),
                    )),
                ]),
            ],
          ),
        ),
      ],
    );
  }
}

class _Reports extends StatelessWidget {
  const _Reports({required this.company, required this.files, required this.onEdit});

  final Doc company;
  final FilesApi files;
  final Future<void> Function(Doc) onEdit;

  List<Doc> get _list => [for (final r in company['relatorios'] as List) r as Doc];

  Future<void> _attach(BuildContext context) async {
    final chosen = await FilePicker.pickFiles(
      dialogTitle: 'Relatório (DFP, ITR, release, apresentação)',
      type: FileType.custom,
      allowedExtensions: acceptedExtensions,
    );
    if (chosen.isEmpty || !context.mounted) return;
    final info = await form(context, 'Anexar ${chosen.first.name}', const [
      FormFieldSpec('tipo', 'Tipo', type: FieldKind.option, options: {
        'dfp': 'DFP (anual)', 'itr': 'ITR (trimestral)', 'release': 'Release de resultados',
        'apresentacao': 'Apresentação', 'fre': 'Formulário de referência', 'outro': 'Outro',
      }),
      FormFieldSpec('periodo', 'Período', help: 'ex.: 2025, 3T25'),
    ]);
    if (info == null || !context.mounted) return;
    final bytes = await chosen.first.xFile.readAsBytes();
    if (!context.mounted) return;
    await tentar(context, () async {
      final (a, _) = await files.send(chosen.first.name, bytes, pasta: 'Finanças/${company['ticker']}');
      await onEdit({
        'relatorios': [
          ..._list,
          {'arquivo_id': a.id, 'titulo': a.title, 'tipo': info['tipo'], 'periodo': info['periodo'], 'data': iso(DateTime.now())},
        ],
      });
    }, ok: 'Anexado; também aparece no módulo Arquivos');
  }

  @override
  Widget build(BuildContext context) {
    final items = _list;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _attach(context), icon: const Icon(Icons.attach_file), label: const Text('Anexar')),
      body: items.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Anexe DFP, ITR, releases e apresentações. Eles ficam na pasta Finanças/<ticker> do módulo '
                    'Arquivos, onde você lê, grifa e anota.', textAlign: TextAlign.center),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 80),
              children: [
                for (final (i, r) in items.indexed)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.picture_as_pdf_outlined),
                      title: Text(r['titulo'] as String? ?? 'relatório'),
                      subtitle: Text('${r['tipo'] ?? ''} · ${r['periodo'] ?? ''} · anexado em ${dataBr(r['data'] as String?)}'),
                      onTap: () => tentar(context, () async {
                        final a = await files.fetch(r['arquivo_id'] as String);
                        if (context.mounted) await openFile(context, files, a);
                      }),
                      trailing: IconButton(
                        tooltip: 'Desvincular (o arquivo continua no módulo Arquivos)',
                        icon: const Icon(Icons.link_off),
                        onPressed: () => onEdit({'relatorios': [...items]..removeAt(i)}),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _Annotations extends StatelessWidget {
  const _Annotations({required this.company, required this.onEdit});

  final Doc company;
  final Future<void> Function(Doc) onEdit;

  static const _campos = [
    FormFieldSpec('titulo', 'Título'),
    FormFieldSpec('texto', 'Anotação', type: FieldKind.longText, isRequired: true),
  ];

  @override
  Widget build(BuildContext context) {
    final items = [for (final a in company['anotacoes'] as List) a as Doc];
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final d = await form(context, 'Nova anotação', _campos);
          if (d != null) await onEdit({'anotacoes': [{...d, 'data': iso(DateTime.now())}, ...items]});
        },
        icon: const Icon(Icons.note_add_outlined),
        label: const Text('Anotação'),
      ),
      body: items.isEmpty
          ? const Center(child: Text('Registre leituras de relatórios, teleconferências, fatos relevantes e dúvidas.'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 80),
              children: [
                for (final (i, a) in items.indexed)
                  Section(
                    title: (a['titulo'] as String? ?? '').isEmpty ? dataBr(a['data'] as String?) : a['titulo'] as String,
                    subtitle: dataBr(a['data'] as String?),
                    stocks: [
                      MenuItem(
                        onEdit: () async {
                          final d = await form(context, 'Anotação', _campos, a);
                          if (d != null) await onEdit({'anotacoes': [...items]..[i] = {...a, ...d}});
                        },
                        onDelete: () => onEdit({'anotacoes': [...items]..removeAt(i)}),
                      ),
                    ],
                    child: SelectableText(a['texto'] as String),
                  ),
              ],
            ),
    );
  }
}
