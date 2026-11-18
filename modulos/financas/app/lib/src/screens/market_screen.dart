import 'dart:async';
import 'dart:math';

import 'package:agent_arquivos/agent_arquivos.dart';
import 'package:agent_core/agent_core.dart';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../finance_api.dart';
import '../format.dart';
import 'common.dart';
import 'company_screen.dart';

double _n(dynamic v) => (v as num?)?.toDouble() ?? 0;
double? _nn(dynamic v) => (v as num?)?.toDouble();

/// Real-time market: top gainers and losers of the day (stocks or FIIs) and the search by ticker or name,
/// which opens the asset sheet. On the phone the lists show one at a time; from tablet up, side by side.
class MarketScreen extends StatefulWidget {
  const MarketScreen({super.key, required this.api, this.files});

  final FinanceApi api;

  /// Reader of the Arquivos module: the CVM documents open inside the app.
  final FilesApi? files;

  @override
  State<MarketScreen> createState() => _MarketScreenState();
}

class _MarketScreenState extends State<MarketScreen> {
  final _search = TextEditingController();
  Timer? _wait;
  List<Doc> _suggestions = const [];
  bool _searching = false;
  String _type = 'stock';
  bool _showGainers = true;
  late Future<Doc> _highlights = widget.api.highlights(type: _type);

  @override
  void dispose() {
    _wait?.cancel();
    _search.dispose();
    super.dispose();
  }

  /// Suggestions while typing (ticker by prefix, name, nickname, similar name), 250 ms after
  /// the last key; a late reply of an old search is dropped.
  void _typed(String text) {
    _wait?.cancel();
    final q = text.trim();
    if (q.length < 2) {
      setState(() => _suggestions = const []);
      return;
    }
    _wait = Timer(const Duration(milliseconds: 250), () async {
      setState(() => _searching = true);
      try {
        final r = await widget.api.suggest(q);
        if (mounted && _search.text.trim() == q) setState(() => _suggestions = r);
      } on ApiErro catch (e) {
        if (mounted) avisar(context, e.mensagem);
      } finally {
        if (mounted) setState(() => _searching = false);
      }
    });
  }

  void _pick(String ticker) {
    FocusScope.of(context).unfocus();
    _open(ticker);
  }

  void _reload() => setState(() => _highlights = widget.api.highlights(type: _type));

  void _open(String q) {
    if (q.trim().isEmpty) return;
    abrirTela<void>(context, (_) => AssetScreen(api: widget.api, files: widget.files, query: q.trim()));
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: () async => _reload(),
    child: ListView(
      padding: const EdgeInsets.all(8),
      children: [
        Padding(
          padding: const EdgeInsets.all(6),
          child: TextField(
            controller: _search,
            textInputAction: TextInputAction.search,
            onChanged: _typed,
            onSubmitted: (q) => _suggestions.isEmpty ? _open(q) : _pick('${(_suggestions.first['tickers'] as List).first}'),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.search),
              hintText: 'Comece a digitar: ITU, Itaú, Petrobras, MXRF, Maxi Renda…',
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_searching) const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  if (_search.text.isNotEmpty)
                    IconButton(
                      tooltip: 'Limpar',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() {
                        _search.clear();
                        _suggestions = const [];
                      }),
                    ),
                  IconButton(icon: const Icon(Icons.arrow_forward), onPressed: () => _open(_search.text)),
                ],
              ),
            ),
          ),
        ),
        if (_suggestions.isNotEmpty) _Suggestions(_suggestions, _pick),
        Section(
          title: 'Destaques do dia',
          subtitle: 'Entre os papéis mais negociados da B3 (atraso de alguns minutos).',
          stocks: [IconButton(tooltip: 'Atualizar', onPressed: _reload, icon: const Icon(Icons.refresh))],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'stock', label: Text('Ações'), icon: Icon(Icons.show_chart)),
                  ButtonSegment(value: 'fund', label: Text('FIIs e fundos'), icon: Icon(Icons.apartment)),
                ],
                selected: {_type},
                onSelectionChanged: (s) {
                  _type = s.first;
                  _reload();
                },
              ),
              Waiting(
                future: _highlights,
                reload: _reload,
                construir: (d) => LayoutBuilder(
                  builder: (context, c) {
                    final gainers = _HighlightsList('Maiores altas', (d['altas'] as List).cast<Doc>(), Colors.green, _open);
                    final losers = _HighlightsList('Maiores baixas', (d['baixas'] as List).cast<Doc>(), Colors.red, _open);
                    if (c.maxWidth >= 700) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 12,
                        children: [Expanded(child: gainers), Expanded(child: losers)],
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(value: true, label: Text('Altas'), icon: Icon(Icons.trending_up)),
                            ButtonSegment(value: false, label: Text('Baixas'), icon: Icon(Icons.trending_down)),
                          ],
                          selected: {_showGainers},
                          onSelectionChanged: (s) => setState(() => _showGainers = s.first),
                        ),
                        _showGainers ? gainers : losers,
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Search result: company or FII, sector and one button per ticker (ITUB3, ITUB4…).
class _Suggestions extends StatelessWidget {
  const _Suggestions(this.itens, this.pick);

  final List<Doc> itens;
  final ValueChanged<String> pick;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    child: Column(
      children: [
        for (final x in itens)
          ListTile(
            dense: true,
            leading: Icon(x['tipo'] == 'fii' ? Icons.apartment : Icons.show_chart),
            title: Text('${x['nome']}', maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [x['tipo'] == 'fii' ? 'FII' : 'Ação', '${x['setor'] ?? ''}', if (x['situacao'] != 'Ativo') '${x['situacao']}']
                  .where((t) => t.isNotEmpty)
                  .join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => pick('${(x['tickers'] as List).first}'),
            trailing: Wrap(
              spacing: 4,
              children: [
                for (final t in (x['tickers'] as List).take(4))
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    label: Text('$t', style: const TextStyle(fontWeight: FontWeight.w600)),
                    onPressed: () => pick('$t'),
                  ),
              ],
            ),
          ),
      ],
    ),
  );
}

class _HighlightsList extends StatelessWidget {
  const _HighlightsList(this.title, this.itens, this.color, this.open);

  final String title;
  final List<Doc> itens;
  final Color color;
  final ValueChanged<String> open;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall),
      ),
      for (final (i, x) in itens.indexed)
        InkWell(
          onTap: () => open('${x['ticker']}'),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(
              spacing: 10,
              children: [
                SizedBox(width: 22, child: Text('${i + 1}', style: Theme.of(context).textTheme.bodySmall)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${x['ticker']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text('${x['nome'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(currency(_nn(x['preco']))),
                    Text(
                      '${_n(x['variacao_pct']) > 0 ? '+' : ''}${number(_n(x['variacao_pct']))}%',
                      style: TextStyle(color: color, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
    ],
  );
}

/// Asset sheet: stock (quote, dividends, CVM income statement/balance sheet/cash flow and the linked documents)
/// or FII (monthly report: P/VP, DY, equity, composition and management reports).
class AssetScreen extends StatelessWidget {
  const AssetScreen({super.key, required this.api, required this.query, this.files});

  final FinanceApi api;
  final FilesApi? files;
  final String query;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(query.toUpperCase())),
    body: MarketSheet(api: api, files: files, query: query),
  );
}

/// The market sheet of a ticker or name (quote, indicators, valuation, dividends, CVM documents),
/// building up in parts while the server reads CVM. Also the "Mercado" tab of a followed company
/// ([canFollow] false: it is already followed).
class MarketSheet extends StatefulWidget {
  const MarketSheet({super.key, required this.api, required this.query, this.files, this.canFollow = true});

  final FinanceApi api;
  final FilesApi? files;
  final String query;
  final bool canFollow;

  @override
  State<MarketSheet> createState() => _MarketSheetState();
}

class _MarketSheetState extends State<MarketSheet> with AutomaticKeepAliveClientMixin {
  /// Inside the company tabs: switching tabs does not fetch the sheet again.
  @override
  bool get wantKeepAlive => true;

  late Future<Doc> _dados = _runSearch();

  /// Incomplete sheet while the server reads CVM: the screen builds up in parts.
  Doc? _partial;

  Future<Doc> _runSearch() => widget.api.asset(widget.query,
      isCancelled: () => !mounted, onPartial: (p) => mounted ? setState(() => _partial = p) : null);

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<Doc>(
      future: _dados,
      builder: (context, s) {
        if (s.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 12,
                children: [
                  Text(s.error is ApiErro ? (s.error! as ApiErro).mensagem : '${s.error}', textAlign: TextAlign.center),
                  FilledButton(
                    onPressed: () => setState(() {
                      _partial = null;
                      _dados = _runSearch();
                    }),
                    child: const Text('Tentar de novo'),
                  ),
                ],
              ),
            ),
          );
        }
        if (!s.hasData && _partial?['tipo'] == 'acao') {
          return _StockSheet(api: widget.api, files: widget.files, d: _partial!, canFollow: widget.canFollow);
        }
        if (!s.hasData) {
          return const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 12,
              children: [
                CircularProgressIndicator(),
                Text('Buscando cotação e dados oficiais da CVM…\n(a primeira consulta baixa os arquivos e demora mais)',
                    textAlign: TextAlign.center),
              ],
            ),
          );
        }
        final d = s.data!;
        return d['tipo'] == 'fii' ? _FiiSheet(d) : _StockSheet(api: widget.api, files: widget.files, d: d, canFollow: widget.canFollow);
      },
    );
  }
}

/// Two columns from landscape tablet up; one column on the phone.
class _Sheet extends StatelessWidget {
  const _Sheet({required this.principal, required this.lateral});

  final List<Widget> principal;
  final List<Widget> lateral;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) => c.maxWidth >= 1000
        ? SingleChildScrollView(
            padding: const EdgeInsets.all(8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: principal)),
                Expanded(flex: 2, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: lateral)),
              ],
            ),
          )
        : ListView(padding: const EdgeInsets.all(8), children: [...principal, ...lateral]),
  );
}

Widget _header(BuildContext context, Doc d, String subtitle) {
  final cot = d['cotacao'] as Doc? ?? const {};
  final change = _nn(cot['variacao_pct']);
  final color = change == null ? null : (change >= 0 ? Colors.green : Colors.red);
  return Section(
    title: '${d['ticker']} · ${d['nome']}',
    subtitle: subtitle,
    child: Wrap(
      spacing: 16,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.end,
      children: [
        Text(currency(_nn(cot['preco'])), style: Theme.of(context).textTheme.headlineMedium),
        if (change != null)
          Text('${change >= 0 ? '+' : ''}${number(change)}% hoje',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(color: color)),
        if (cot['horario'] != null) Text('às ${'${cot['horario']}'.replaceFirst('T', ' ')}', style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}

/// Downloads the CVM document straight from the device: the PDF (release, presentation) or, in the DFP/ITR
/// ZIP package, the largest PDF inside (the full statements). CVM refuses connections from the VPS.
Future<Uint8List> _cvmPdf(String url) async {
  final r = await http
      .get(Uri.parse(url), headers: {'User-Agent': 'Mozilla/5.0'})
      .timeout(const Duration(minutes: 3));
  if (r.statusCode != 200) throw ApiErro(r.statusCode, 'A CVM respondeu ${r.statusCode}.');
  final b = r.bodyBytes;
  if (b.length > 4 && String.fromCharCodes(b.sublist(0, 4)) == '%PDF') return b;
  if (b.length > 2 && b[0] == 0x50 && b[1] == 0x4b) {
    final pdfs = ZipDecoder().decodeBytes(b).files.where((f) => f.isFile && f.name.toLowerCase().endsWith('.pdf'));
    if (pdfs.isNotEmpty) return pdfs.reduce((x, y) => x.size >= y.size ? x : y).content;
  }
  throw ApiErro(0, 'O documento da CVM não tem PDF dentro.');
}

Widget _link(BuildContext context, IconData icone, String title, String url, {String? detail, Widget? extra}) => ListTile(
  dense: true,
  contentPadding: EdgeInsets.zero,
  leading: Icon(icone),
  title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
  subtitle: detail == null ? null : Text(detail),
  onTap: () => abrirLink(context, url),
  trailing: extra ?? const Icon(Icons.open_in_new, size: 18),
);

class _StockSheet extends StatelessWidget {
  const _StockSheet({required this.api, required this.d, this.files, this.canFollow = true});

  final bool canFollow;

  final FinanceApi api;
  final FilesApi? files;
  final Doc d;

  /// CVM document: downloads through the VPS, stores it in Arquivos and opens it in the app reader (highlight and annotate).
  Widget _doc(BuildContext context, IconData icone, String title, String url, String detail) => ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    leading: Icon(icone),
    title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitle: Text(detail),
    onTap: () => _openInApp(context, url, title),
    trailing: IconButton(
      tooltip: 'Abrir no navegador',
      icon: const Icon(Icons.open_in_new, size: 18),
      onPressed: () => abrirLink(context, url),
    ),
  );

  /// Becomes a background task (bell). The device downloads from CVM and opens the preview with "Salvar" (goes
  /// to Arquivos › Finanças/`ticker` and opens in the reader). If the device cannot (web, CORS),
  /// the VPS downloads and stores it in Arquivos.
  void _openInApp(BuildContext context, String url, String title) {
    final reader = files;
    if (reader == null) {
      abrirLink(context, url);
      return;
    }
    final ticker = '${d['ticker']}';
    Tarefas.instancia.rodar<Object>(
      '$ticker: $title',
      (t) async {
        if (!kIsWeb) {
          t.atualizar(detalhe: 'Baixando da CVM…');
          try {
            return await _cvmPdf(url);
          } catch (_) {
            t.conferir();
          }
        }
        t.atualizar(detalhe: 'A VPS está baixando da CVM…');
        final stored = await api.storeDocument(url, title, ticker, isCancelled: () => t.cancelada);
        t.conferir();
        t.atualizar(detalhe: 'Trazendo o PDF para o aparelho…', progresso: 0);
        final a = await reader.fetch(stored['id'] as String);
        // Stays on the device: the reader opens right away, also offline.
        await reader.offline.download(a, task: t);
        return a;
      },
      abrir: (c, r) => r is Uint8List
          ? openPreview(c, reader, '$ticker $title.pdf', r, pasta: 'Finanças/$ticker')
          : openFile(c, reader, r as FileItem),
    );
    avisar(context, 'Baixando em segundo plano. Acompanhe no sino 🔔; aviso quando ficar pronto.');
  }

  @override
  Widget build(BuildContext context) {
    final years = ((d['demonstrativos'] as List?) ?? const []).cast<Doc>();
    final missing = ((d['carregando'] as List?) ?? const []).toSet();
    Widget? waiting(String part) => missing.contains(part) ? const LinearProgressIndicator() : null;
    final last = years.isEmpty ? const <String, dynamic>{} : years.last;
    final div = d['proventos'] as Doc? ?? const {};
    final docs = d['documentos'] as Doc? ?? const {};
    final series = ((d['indicadores'] as List?) ?? const []).cast<Doc>();
    final ind = series.isEmpty ? const <String, dynamic>{} : series.last;
    final v = d['valuation'] as Doc? ?? const {};
    final financial = ind['financeira'] == true;
    return _Sheet(
      principal: [
        _header(context, d, '${d['setor']} · ${d['atividade']}'),
        Section(
          title: 'Indicadores${last['ano'] == null ? '' : ' de ${last['ano']}'}',
          subtitle: financial
              ? 'Banco/seguradora: EBITDA, ROIC e dívida não se aplicam; olhe ROE, P/L, P/VP e dividendos.'
              : 'Demonstrações consolidadas entregues à CVM e cotação do dia.',
          stocks: [
            if (canFollow)
              TextButton.icon(
                onPressed: years.isEmpty ? null : () => _follow(context),
                icon: const Icon(Icons.add_chart),
                label: const Text('Acompanhar'),
              ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              if (missing.contains('demonstrativos') || missing.contains('cotacao'))
                Row(
                  spacing: 8,
                  children: [
                    const Expanded(child: LinearProgressIndicator()),
                    Text(
                      years.isEmpty ? 'Lendo a CVM…' : 'Já chegaram ${years.length} ano(s); lendo os outros…',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              for (final (title, itens) in _groups(d, last, ind, v, div, financial))
                if (itens.isNotEmpty) ...[
                  Text(title, style: Theme.of(context).textTheme.titleSmall),
                  IndicatorGrid(children: itens),
                ],
            ],
          ),
        ),
        if (series.length > 1) Section(title: 'Indicadores por ano', child: _IndicatorsTable(series, financial)),
        if (years.isNotEmpty) Section(title: 'DRE, balanço e caixa por ano', child: _YearsTable(years)),
      ],
      lateral: [
        Section(
          title: 'Releases e comunicados',
          subtitle: 'Toque para abrir aqui no app; ↗ abre no navegador.',
          child: waiting('documentos') ?? Column(
            children: [
              for (final r in ((docs['releases_e_comunicados'] as List?) ?? const []).cast<Doc>())
                _doc(
                  context,
                  Icons.description_outlined,
                  '${r['assunto']}'.isEmpty ? '${r['tipo']}' : '${r['assunto']}',
                  '${r['link']}',
                  '${dataBr(r['data'] as String?)} · ${r['categoria']}',
                ),
            ],
          ),
        ),
        Section(
          title: 'Demonstrações completas (DFP e ITR)',
          subtitle: 'Toque para abrir o PDF aqui no app; "Salvar" guarda em Arquivos › Finanças.',
          child: waiting('documentos') ?? Column(
            children: [
              for (final r in ((docs['anuais_dfp'] as List?) ?? const []).cast<Doc>())
                _doc(context, Icons.event_note, 'Demonstrações anuais (DFP) ${'${r['referencia']}'.substring(0, 4)}',
                    '${r['link']}', 'entregue em ${dataBr(r['entregue'] as String?)} · PDF completo'),
              for (final r in ((docs['trimestrais_itr'] as List?) ?? const []).cast<Doc>())
                _doc(context, Icons.date_range, 'Trimestral (ITR) ${dataBr(r['referencia'] as String?)}', '${r['link']}',
                    'entregue em ${dataBr(r['entregue'] as String?)} · PDF completo'),
            ],
          ),
        ),
        Section(
          title: 'Páginas da empresa',
          child: Column(
            children: [
              if ('${d['site']}'.isNotEmpty) _link(context, Icons.language, 'Site / Relações com Investidores', '${d['site']}'),
              for (final e in ((docs['paginas'] as Doc?) ?? const {}).entries)
                _link(context, Icons.link, switch (e.key) {
                  'cvm_rad' => 'Todos os documentos na CVM',
                  'b3' => 'Página na B3',
                  'status_invest' => 'Status Invest',
                  _ => e.key,
                }, '${e.value}'),
            ],
          ),
        ),
      ],
    );
  }

  /// Registers it in Investimentos › Empresas (or uses the existing one) with a 6-year income statement, share
  /// count and quote, and opens the full analysis.
  Future<void> _follow(BuildContext context) async {
    String? id;
    final ok = await tentar(context, () async {
      final existing = await api.list('empresas');
      final found = existing.where((e) => '${e['ticker']}'.toUpperCase() == '${d['ticker']}'.toUpperCase());
      final e = found.isNotEmpty
          ? found.first
          : await api.create('empresas', {
              'ticker': d['ticker'],
              'nome': d['nome'],
              'cnpj': d['cnpj'],
              'site': d['site'],
              'setor': d['setor'] ?? '',
              'descricao': d['atividade'] ?? '',
              // the sheet already has today's quote: without it the valuation cards stay empty
              if ((d['cotacao'] as Doc?)?['preco'] case final num preco) 'cotacao': preco,
            });
      id = e['id'] as String;
      await api.importCvm(id!);
    }, ok: 'Em Investimentos › Empresas, com DRE de 6 anos, ações e cotação');
    final reader = files;
    if (ok && id != null && reader != null && context.mounted) {
      await abrirTela<void>(context, (_) => CompanyScreen(api: api, files: reader, id: id!));
    }
  }
}

/// Sheet panel in groups; each number with a short explanation of what is good.
List<(String, List<Widget>)> _groups(Doc d, Doc year, Doc ind, Doc v, Doc div, bool financial) {
  String n2(dynamic x) => x == null ? '—' : number(_n(x));
  String p1(dynamic x) => x == null ? '—' : pct(_n(x));
  Color? color(dynamic x, bool Function(double) good) => x == null ? null : (good(_n(x)) ? Colors.green : Colors.orange);
  final dy = div['dy_12m_pct'] ?? v['dy'];
  return [
    (
      'Preço e valuation',
      [
        Indicator('P/L', n2(v['pl']), color: color(v['pl'], (x) => x > 0 && x <= 15), detail: 'anos de lucro para pagar o preço'),
        Indicator('P/VP', n2(v['pvp']), color: color(v['pvp'], (x) => x <= 2), detail: 'preço ÷ patrimônio por ação'),
        if (!financial)
          Indicator('EV/EBITDA', n2(v['ev_ebitda']), color: color(v['ev_ebitda'], (x) => x > 0 && x <= 8), detail: 'valor da firma ÷ geração operacional'),
        Indicator('Dividend yield 12m', p1(dy), color: color(dy, (x) => x >= 6),
            detail: div['total_12m'] == null ? 'Bazin pede 6% ou mais' : '${currency(_n(div['total_12m']))} por ação'),
        Indicator('Valor de mercado', _mil(_nn(v['valor_mercado'])), detail: 'cotação × ações'),
        Indicator('LPA', currency(_nn(ind['lpa'])), detail: 'lucro por ação'),
        Indicator('VPA', currency(_nn(ind['vpa'])), detail: 'patrimônio por ação'),
        Indicator('Preço Graham', currency(_nn(v['preco_graham'])), detail: '√(22,5 × LPA × VPA)'),
        Indicator('Preço Bazin', currency(_nn(v['preco_bazin'])), detail: 'dividendo por ação ÷ 6%'),
      ],
    ),
    (
      'Rentabilidade e margens',
      [
        Indicator('ROE', p1(ind['roe']), color: color(ind['roe'], (x) => x >= 15), detail: 'lucro ÷ patrimônio; bom ≥ 15%'),
        if (!financial) Indicator('ROIC', p1(ind['roic']), color: color(ind['roic'], (x) => x >= 10), detail: 'retorno do capital investido'),
        Indicator('ROA', p1(ind['roa']), detail: 'lucro ÷ ativo total'),
        if (!financial) Indicator('Margem bruta', p1(ind['margem_bruta'])),
        if (!financial) Indicator('Margem EBITDA', p1(ind['margem_ebitda'])),
        Indicator('Margem líquida', p1(ind['margem_liquida']), color: color(ind['margem_liquida'], (x) => x >= 10)),
      ],
    ),
    (
      'Endividamento e caixa',
      [
        if (!financial) ...[
          Indicator('Dív. líquida/EBITDA', n2(ind['divida_liquida_ebitda']),
              color: color(ind['divida_liquida_ebitda'], (x) => x <= 2.5), detail: 'anos de geração para pagar a dívida'),
          Indicator('Dív. líquida/PL', n2(ind['divida_liquida_pl'])),
          Indicator('Liquidez corrente', n2(ind['liquidez_corrente']), color: color(ind['liquidez_corrente'], (x) => x >= 1),
              detail: 'ativo ÷ passivo de curto prazo'),
          Indicator('Fluxo de caixa livre', _mil(_nn(ind['fcl'])), detail: 'caixa operacional − capex'),
        ],
        Indicator('Conversão de caixa', p1(ind['conversao_caixa']), color: color(ind['conversao_caixa'], (x) => x >= 80),
            detail: 'caixa operacional ÷ lucro'),
        Indicator('Payout', p1(ind['payout']), detail: 'dividendos pagos ÷ lucro'),
      ],
    ),
    (
      'Tamanho e crescimento',
      [
        Indicator('Receita líquida', _mil(_nn(year['receita_liquida'])),
            detail: ind['cresc_receita'] == null ? null : '${pct(_n(ind['cresc_receita']))} no ano'),
        Indicator('Lucro líquido', _mil(_nn(year['lucro_liquido'])),
            color: _nn(year['lucro_liquido']) == null ? null : (_n(year['lucro_liquido']) >= 0 ? Colors.green : Colors.red),
            detail: ind['cresc_lucro'] == null ? null : '${pct(_n(ind['cresc_lucro']))} no ano'),
        Indicator('CAGR receita', p1(d['cagr_receita']), detail: 'crescimento médio ao ano'),
        Indicator('CAGR lucro', p1(d['cagr_lucro']), detail: 'crescimento médio ao ano'),
      ],
    ),
  ];
}

/// Indicators year by year (the trend matters more than a single year's number).
class _IndicatorsTable extends StatelessWidget {
  const _IndicatorsTable(this.series, this.financial);

  final List<Doc> series;
  final bool financial;

  static const lines = [
    ('margem_bruta', 'Margem bruta', true, false),
    ('margem_ebitda', 'Margem EBITDA', true, false),
    ('margem_liquida', 'Margem líquida', true, true),
    ('roe', 'ROE', true, true),
    ('roic', 'ROIC', true, false),
    ('divida_liquida_ebitda', 'Dív. líq./EBITDA', false, false),
    ('liquidez_corrente', 'Liquidez corrente', false, false),
    ('conversao_caixa', 'Conversão de caixa', true, true),
    ('payout', 'Payout', true, true),
    ('lpa', 'LPA (R\$)', false, true),
    ('vpa', 'VPA (R\$)', false, true),
    ('cresc_receita', 'Cresc. receita', true, true),
    ('cresc_lucro', 'Cresc. lucro', true, true),
  ];

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: DataTable(
      columnSpacing: 18,
      headingRowHeight: 36,
      dataRowMinHeight: 30,
      dataRowMaxHeight: 34,
      columns: [const DataColumn(label: Text('')), for (final a in series) DataColumn(numeric: true, label: Text('${a['ano']}'))],
      rows: [
        for (final (key, label, ehPct, bank) in lines)
          if ((bank || !financial) && series.any((a) => a[key] != null))
            DataRow(cells: [
              DataCell(Text(label)),
              for (final a in series)
                DataCell(Text(a[key] == null ? '—' : (ehPct ? pct(_n(a[key])) : number(_n(a[key]))))),
            ]),
      ],
    ),
  );
}

String _mil(double? v) {
  if (v == null) return '—';
  final brl = v * 1000;
  final a = brl.abs();
  final s = a >= 1e9 ? '${number(a / 1e9, decimals: 1)} bi' : (a >= 1e6 ? '${number(a / 1e6, decimals: 1)} mi' : number(a, decimals: 0));
  return '${v < 0 ? '-' : ''}R\$ $s';
}

/// Year × account table; scrolls horizontally when the screen is narrow.
class _YearsTable extends StatelessWidget {
  const _YearsTable(this.years);

  final List<Doc> years;

  static const lines = [
    ('receita_liquida', 'Receita líquida'),
    ('lucro_bruto', 'Lucro bruto'),
    ('ebit', 'EBIT'),
    ('resultado_financeiro', 'Resultado financeiro'),
    ('lucro_liquido', 'Lucro líquido'),
    ('patrimonio_liquido', 'Patrimônio líquido'),
    ('divida_bruta', 'Dívida bruta'),
    ('caixa', 'Caixa'),
    ('fco', 'Caixa operacional'),
    ('capex', 'Investimentos (capex)'),
    ('dividendos', 'Dividendos pagos'),
  ];

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: DataTable(
      columnSpacing: 18,
      headingRowHeight: 36,
      dataRowMinHeight: 30,
      dataRowMaxHeight: 34,
      columns: [const DataColumn(label: Text('')), for (final a in years) DataColumn(numeric: true, label: Text('${a['ano']}'))],
      rows: [
        for (final (key, label) in lines)
          if (years.any((a) => a[key] != null))
            DataRow(cells: [DataCell(Text(label)), for (final a in years) DataCell(Text(_mil(_nn(a[key]))))]),
      ],
    ),
  );
}

class _FiiSheet extends StatelessWidget {
  const _FiiSheet(this.d);

  final Doc d;

  @override
  Widget build(BuildContext context) {
    final months = (d['meses'] as List).cast<Doc>();
    final last = months.isEmpty ? const <String, dynamic>{} : months.last;
    final div = d['proventos'] as Doc? ?? const {};
    final links = d['links'] as Doc? ?? const {};
    final composition = (d['composicao'] as List).cast<Doc>();
    return _Sheet(
      principal: [
        _header(context, d, '${d['segmento']} · gestão ${'${d['gestao']}'.toLowerCase()} · ${d['administrador']}'),
        Section(
          title: 'Indicadores',
          subtitle: 'Informe mensal à CVM (${mesBr('${last['mes'] ?? ''}')}) e proventos dos últimos 12 meses.',
          child: IndicatorGrid(
            children: [
              Indicator('P/VP', d['p_vp'] == null ? '—' : number(_n(d['p_vp'])),
                  color: d['p_vp'] == null ? null : (_n(d['p_vp']) <= 1 ? Colors.green : Colors.orange),
                  detail: 'abaixo de 1 = cota mais barata que o patrimônio'),
              Indicator('Dividend yield 12m', div['dy_12m_pct'] == null ? '—' : pct(_n(div['dy_12m_pct'])),
                  detail: div['total_12m'] == null ? null : '${currency(_n(div['total_12m']))} por cota'),
              Indicator('Valor patrimonial', currency(_nn(last['valor_patrimonial_cota'])), detail: 'por cota'),
              Indicator('Patrimônio', _mil(_n(last['patrimonio_liquido']) / 1000)),
              Indicator('Cotistas', number(_n(last['cotistas']), decimals: 0)),
              Indicator('Taxa de adm.', last['taxa_adm_pct'] == null ? '—' : pct(_n(last['taxa_adm_pct'])), detail: 'no mês'),
            ],
          ),
        ),
        if (months.isNotEmpty)
          Section(title: 'Dividend yield mensal (% do patrimônio)', child: _DyBars(months)),
      ],
      lateral: [
        if (composition.isNotEmpty)
          Section(
            title: 'Onde o dinheiro está',
            child: Column(
              spacing: 8,
              children: [
                for (final c in composition)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 2,
                    children: [
                      Row(children: [Expanded(child: Text('${c['item']}')), Text(pct(_n(c['pct'])))]),
                      LinearProgressIndicator(value: _n(c['pct']) / 100),
                    ],
                  ),
              ],
            ),
          ),
        Section(
          title: 'Relatórios e páginas',
          child: Column(
            children: [
              if (links['relatorios_fnet'] != null)
                _link(context, Icons.folder_open, 'Relatórios gerenciais e informes (FNET/B3)', '${links['relatorios_fnet']}',
                    detail: 'relatório gerencial, informes mensais e trimestrais, fatos relevantes'),
              if (links['status_invest'] != null) _link(context, Icons.link, 'Status Invest', '${links['status_invest']}'),
              if ('${d['site'] ?? ''}'.isNotEmpty) _link(context, Icons.language, 'Site do administrador', '${d['site']}'),
            ],
          ),
        ),
      ],
    );
  }
}

class _DyBars extends StatelessWidget {
  const _DyBars(this.months);

  final List<Doc> months;

  @override
  Widget build(BuildContext context) {
    final valueList = [for (final m in months) _n(m['dy_mes_pct'])];
    final larger = valueList.fold<double>(0.01, max);
    final color = Theme.of(context).colorScheme.primary;
    return SizedBox(
      height: 150,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        spacing: 4,
        children: [
          for (final (i, v) in valueList.indexed)
            Expanded(
              child: Tooltip(
                message: '${mesBr('${months[i]['mes']}')}: ${pct(v)}',
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FittedBox(child: Text(number(v), style: Theme.of(context).textTheme.labelSmall)),
                    Container(height: max(2, 100 * v / larger), color: color),
                    FittedBox(child: Text('${months[i]['mes']}'.substring(5), style: Theme.of(context).textTheme.labelSmall)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
