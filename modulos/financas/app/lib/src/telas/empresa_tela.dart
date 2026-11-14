import 'package:agent_arquivos/agent_arquivos.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api_financas.dart';
import '../formato.dart';
import 'comuns.dart';
import 'investimentos_tela.dart';

const rotuloConta = {
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

/// Indicadores por ano: (chave, rótulo, é percentual).
const _indicadores = [
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

/// Valores em R\$ (sem casas); os demais são razões.
const _absolutos = {'ebitda', 'divida_liquida', 'fcl'};

class EmpresaTela extends StatefulWidget {
  const EmpresaTela({super.key, required this.api, required this.arquivos, required this.id});

  final ApiFinancas api;
  final ApiArquivos arquivos;
  final String id;

  @override
  State<EmpresaTela> createState() => _EmpresaTelaState();
}

class _EmpresaTelaState extends State<EmpresaTela> {
  late Future<(Doc, List<Doc>)> _dados = _carregar();

  Future<(Doc, List<Doc>)> _carregar() => (widget.api.analise(widget.id), widget.api.questionario()).wait;

  void _recarregar() => setState(() => _dados = _carregar());

  Future<void> _editar(Doc dados) async {
    if (await tentar(context, () => widget.api.editar('empresas', widget.id, dados))) _recarregar();
  }

  @override
  Widget build(BuildContext context) => Esperar(
    futuro: _dados,
    recarregar: _recarregar,
    construir: (d) {
      final (a, perguntas) = d;
      final e = a['empresa'] as Doc;
      return DefaultTabController(
        length: 6,
        child: Scaffold(
          appBar: AppBar(
            title: Text('${e['ticker']} · ${e['nome']}'),
            actions: [
              IconButton(
                tooltip: 'Atualizar pela CVM (DRE, ações e cotação)',
                icon: const Icon(Icons.sync),
                onPressed: () async {
                  if (await tentar(context, () => widget.api.importarCvm(widget.id), ok: 'Atualizada pela CVM')) _recarregar();
                },
              ),
              IconButton(
                tooltip: 'Editar cadastro',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () async {
                  final dados = await formulario(context, 'Empresa', camposEmpresa, e);
                  if (dados != null) await _editar(dados);
                },
              ),
              IconButton(
                tooltip: 'Excluir',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  if (!await confirmar(context, 'Excluir ${e['ticker']} e toda a análise?') || !context.mounted) return;
                  if (await tentar(context, () => widget.api.excluir('empresas', widget.id)) && context.mounted) {
                    Navigator.pop(context);
                  }
                },
              ),
            ],
            bottom: const TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(text: 'Resumo'),
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
              _Resumo(a: a, aoEditar: _editar),
              _Demonstrativos(a: a, aoEditar: _editar),
              _Indicadores(a: a),
              ListView(
                padding: const EdgeInsets.all(8),
                children: [
                  Secao(
                    titulo: 'Questionário da empresa',
                    subtitulo: 'edite as perguntas em Investimentos › Questionário',
                    child: Respostas(
                      perguntas: perguntas.where((p) => p['alvo'] == 'empresa').toList(),
                      respostas: Map<String, dynamic>.from(e['respostas'] as Map),
                      aoSalvar: (r) => _editar({'respostas': r}),
                    ),
                  ),
                ],
              ),
              _Relatorios(empresa: e, arquivos: widget.arquivos, aoEditar: _editar),
              _Anotacoes(empresa: e, aoEditar: _editar),
            ],
          ),
        ),
      );
    },
  );
}

class _Resumo extends StatelessWidget {
  const _Resumo({required this.a, required this.aoEditar});

  final Doc a;
  final Future<void> Function(Doc) aoEditar;

  @override
  Widget build(BuildContext context) {
    final e = a['empresa'] as Doc;
    final v = a['valuation'] as Doc;
    final q = a['questionario'] as Doc;
    final setor = a['setor'] as Doc?;
    final veredito = a['veredito'] as String;
    String num2(dynamic x) => numero(nn(x));
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        GradeIndicadores(
          children: [
            Indicador('Nota final', a['nota_final'] == null ? '—' : numero(nn(a['nota_final']), casas: 0),
                cor: corVeredito(veredito), detalhe: veredito, icone: Icons.verified_outlined),
            Indicador('Questionário', q['nota'] == null ? '—' : numero(nn(q['nota']), casas: 0),
                detalhe: '${q['respondidas']}/${q['total']} respondidas · peso 50%'),
            Indicador('Indicadores', a['nota_indicadores'] == null ? '—' : numero(nn(a['nota_indicadores']), casas: 0),
                detalhe: 'checagens automáticas · peso 30%'),
            Indicador('Setor', setor?['nota'] == null ? '—' : numero(nn(setor!['nota']), casas: 0),
                detalhe: setor == null ? 'cadastre o setor "${e['setor']}"' : '${setor['nome']} · peso 20%'),
          ],
        ),
        GradeIndicadores(
          children: [
            Indicador('Cotação', moeda(nn(v['cotacao']))),
            Indicador('Valor de mercado', moeda(nn(v['valor_mercado']))),
            Indicador('P/L', num2(v['pl'])),
            Indicador('P/VP', num2(v['pvp'])),
            Indicador('EV/EBITDA', num2(v['ev_ebitda'])),
            Indicador('EV/EBIT', num2(v['ev_ebit'])),
            Indicador('PSR', num2(v['psr'])),
            Indicador('Dividend yield', pct(nn(v['dy']))),
            Indicador('FCL yield', pct(nn(v['fcl_yield']))),
            Indicador('CAGR receita', pct(nn(a['cagr_receita']))),
            Indicador('CAGR lucro', pct(nn(a['cagr_lucro']))),
            Indicador('Preço Graham', moeda(nn(v['preco_graham'])), detalhe: '√(22,5 × LPA × VPA)'),
            Indicador('Preço Bazin', moeda(nn(v['preco_bazin'])), detalhe: 'dividendo por ação / 6%'),
            Indicador('Preço teto', moeda(nn(v['preco_teto'])), detalhe: 'margem de segurança ${pct(nn(v['margem_seguranca']))}',
                cor: v['margem_seguranca'] == null ? null : corValor(nn(v['margem_seguranca']), Theme.of(context).colorScheme)),
          ],
        ),
        Colunas(
          esquerda: [
            Secao(
              titulo: 'Checagens automáticas',
              subtitulo: 'último ano dos demonstrativos',
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
                      trailing: c['valor'] == null ? null : Text(numero(nn(c['valor']))),
                    ),
                ],
              ),
            ),
            if ((q['blocos'] as Map).isNotEmpty)
              Secao(
                titulo: 'Questionário por bloco',
                child: Column(
                  spacing: 8,
                  children: [
                    for (final b in (q['blocos'] as Map).entries)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        spacing: 4,
                        children: [Text('${b.key} · ${pct(nn(b.value))}'), BarraProgresso(nn(b.value))],
                      ),
                  ],
                ),
              ),
          ],
          direita: [
            _TextoEditavel(titulo: 'Tese de investimento', valor: e['tese'] as String, aoSalvar: (t) => aoEditar({'tese': t})),
            _TextoEditavel(titulo: 'Riscos', valor: e['riscos'] as String, aoSalvar: (t) => aoEditar({'riscos': t})),
            if ((e['descricao'] as String).isNotEmpty) Secao(titulo: 'O que faz', child: Text(e['descricao'] as String)),
          ],
        ),
      ],
    );
  }
}

class _TextoEditavel extends StatelessWidget {
  const _TextoEditavel({required this.titulo, required this.valor, required this.aoSalvar});

  final String titulo;
  final String valor;
  final ValueChanged<String> aoSalvar;

  @override
  Widget build(BuildContext context) => Secao(
    titulo: titulo,
    acoes: [
      IconButton(
        icon: const Icon(Icons.edit_outlined, size: 18),
        onPressed: () async {
          final d = await formulario(context, titulo, [Campo('t', titulo, tipo: TipoCampo.longo)], {'t': valor});
          if (d != null) aoSalvar(d['t'] as String);
        },
      ),
    ],
    child: Text(valor.isEmpty ? 'Ainda não escrito.' : valor),
  );
}

class _Demonstrativos extends StatefulWidget {
  const _Demonstrativos({required this.a, required this.aoEditar});

  final Doc a;
  final Future<void> Function(Doc) aoEditar;

  @override
  State<_Demonstrativos> createState() => _DemonstrativosState();
}

class _DemonstrativosState extends State<_Demonstrativos> {
  var _vertical = false;

  List<Doc> get _dem => [for (final d in widget.a['demonstrativos'] as List) d as Doc];

  Future<void> _ano([Doc? atual]) async {
    final d = await formulario(context, atual == null ? 'Novo ano' : 'Ano ${atual['ano']}', [
      const Campo('ano', 'Ano', tipo: TipoCampo.inteiro, obrigatorio: true),
      for (final c in rotuloConta.entries) Campo(c.key, c.value, tipo: TipoCampo.numero),
    ], atual ?? {'ano': DateTime.now().year - 1});
    if (d == null) return;
    // número vazio vira 0 no formulário; aqui 0 significa "não informado"
    final linha = {for (final e in d.entries) e.key: e.key == 'ano' || e.value != 0 ? e.value : null};
    final lista = [..._dem.where((x) => x['ano'] != linha['ano'] && x['ano'] != atual?['ano']), linha];
    await widget.aoEditar({'demonstrativos': lista});
  }

  Future<void> _excluir(Doc ano) async {
    if (!await confirmar(context, 'Excluir o ano ${ano['ano']}?')) return;
    await widget.aoEditar({'demonstrativos': _dem.where((x) => x['ano'] != ano['ano']).toList()});
  }

  @override
  Widget build(BuildContext context) {
    final dem = _dem;
    final vertical = {for (final v in widget.a['vertical'] as List) v['ano']: v as Doc};
    final contas = _vertical ? rotuloConta.keys.where((k) => vertical.values.firstOrNull?.containsKey(k) ?? false) : rotuloConta.keys;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(onPressed: _ano, icon: const Icon(Icons.add), label: const Text('Ano')),
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
                        onTap: () => _ano(d),
                        onLongPress: () => _excluir(d),
                        child: Text('${d['ano']}', style: TextStyle(color: Theme.of(context).colorScheme.primary)),
                      ),
                    ),
                ],
                rows: [
                  for (final c in contas)
                    DataRow(cells: [
                      DataCell(Text(rotuloConta[c]!)),
                      for (final d in dem)
                        DataCell(Text(_vertical ? pct(nn(vertical[d['ano']]?[c])) : numero(nn(d[c]), casas: 0))),
                    ]),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Indicadores extends StatelessWidget {
  const _Indicadores({required this.a});

  final Doc a;

  @override
  Widget build(BuildContext context) {
    final serie = [for (final i in a['indicadores'] as List) i as Doc];
    if (serie.isEmpty) return const Center(child: Text('Preencha os demonstrativos para calcular os indicadores.'));
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
              for (final i in serie) DataColumn(numeric: true, label: Text('${i['ano']}')),
            ],
            rows: [
              for (final (k, rotulo, ehPct) in _indicadores)
                DataRow(cells: [
                  DataCell(Text(rotulo)),
                  for (final i in serie)
                    DataCell(Text(
                      ehPct ? pct(nn(i[k])) : numero(nn(i[k]), casas: _absolutos.contains(k) ? 0 : 2),
                      style: TextStyle(color: k.startsWith('cresc') && i[k] != null ? corValor(nn(i[k]), cs) : null),
                    )),
                ]),
            ],
          ),
        ),
      ],
    );
  }
}

class _Relatorios extends StatelessWidget {
  const _Relatorios({required this.empresa, required this.arquivos, required this.aoEditar});

  final Doc empresa;
  final ApiArquivos arquivos;
  final Future<void> Function(Doc) aoEditar;

  List<Doc> get _lista => [for (final r in empresa['relatorios'] as List) r as Doc];

  Future<void> _anexar(BuildContext context) async {
    final escolhidos = await FilePicker.pickFiles(
      dialogTitle: 'Relatório (DFP, ITR, release, apresentação)',
      type: FileType.custom,
      allowedExtensions: extensoesAceitas,
    );
    if (escolhidos.isEmpty || !context.mounted) return;
    final info = await formulario(context, 'Anexar ${escolhidos.first.name}', const [
      Campo('tipo', 'Tipo', tipo: TipoCampo.opcao, opcoes: {
        'dfp': 'DFP (anual)', 'itr': 'ITR (trimestral)', 'release': 'Release de resultados',
        'apresentacao': 'Apresentação', 'fre': 'Formulário de referência', 'outro': 'Outro',
      }),
      Campo('periodo', 'Período', ajuda: 'ex.: 2025, 3T25'),
    ]);
    if (info == null || !context.mounted) return;
    final bytes = await escolhidos.first.xFile.readAsBytes();
    if (!context.mounted) return;
    await tentar(context, () async {
      final (a, _) = await arquivos.enviar(escolhidos.first.name, bytes, pasta: 'Finanças/${empresa['ticker']}');
      await aoEditar({
        'relatorios': [
          ..._lista,
          {'arquivo_id': a.id, 'titulo': a.titulo, 'tipo': info['tipo'], 'periodo': info['periodo'], 'data': iso(DateTime.now())},
        ],
      });
    }, ok: 'Anexado; também aparece no módulo Arquivos');
  }

  @override
  Widget build(BuildContext context) {
    final lista = _lista;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _anexar(context), icon: const Icon(Icons.attach_file), label: const Text('Anexar')),
      body: lista.isEmpty
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
                for (final (i, r) in lista.indexed)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.picture_as_pdf_outlined),
                      title: Text(r['titulo'] as String? ?? 'relatório'),
                      subtitle: Text('${r['tipo'] ?? ''} · ${r['periodo'] ?? ''} · anexado em ${dataBr(r['data'] as String?)}'),
                      onTap: () => tentar(context, () async {
                        final a = await arquivos.obter(r['arquivo_id'] as String);
                        if (context.mounted) await abrirArquivo(context, arquivos, a);
                      }),
                      trailing: IconButton(
                        tooltip: 'Desvincular (o arquivo continua no módulo Arquivos)',
                        icon: const Icon(Icons.link_off),
                        onPressed: () => aoEditar({'relatorios': [...lista]..removeAt(i)}),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _Anotacoes extends StatelessWidget {
  const _Anotacoes({required this.empresa, required this.aoEditar});

  final Doc empresa;
  final Future<void> Function(Doc) aoEditar;

  static const _campos = [
    Campo('titulo', 'Título'),
    Campo('texto', 'Anotação', tipo: TipoCampo.longo, obrigatorio: true),
  ];

  @override
  Widget build(BuildContext context) {
    final lista = [for (final a in empresa['anotacoes'] as List) a as Doc];
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final d = await formulario(context, 'Nova anotação', _campos);
          if (d != null) await aoEditar({'anotacoes': [{...d, 'data': iso(DateTime.now())}, ...lista]});
        },
        icon: const Icon(Icons.note_add_outlined),
        label: const Text('Anotação'),
      ),
      body: lista.isEmpty
          ? const Center(child: Text('Registre leituras de relatórios, teleconferências, fatos relevantes e dúvidas.'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 80),
              children: [
                for (final (i, a) in lista.indexed)
                  Secao(
                    titulo: (a['titulo'] as String? ?? '').isEmpty ? dataBr(a['data'] as String?) : a['titulo'] as String,
                    subtitulo: dataBr(a['data'] as String?),
                    acoes: [
                      MenuItem(
                        aoEditar: () async {
                          final d = await formulario(context, 'Anotação', _campos, a);
                          if (d != null) await aoEditar({'anotacoes': [...lista]..[i] = {...a, ...d}});
                        },
                        aoExcluir: () => aoEditar({'anotacoes': [...lista]..removeAt(i)}),
                      ),
                    ],
                    child: SelectableText(a['texto'] as String),
                  ),
              ],
            ),
    );
  }
}
