import 'dart:async';
import 'dart:math';

import 'package:agent_arquivos/agent_arquivos.dart';
import 'package:agent_core/agent_core.dart';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../api_financas.dart';
import '../formato.dart';
import 'comuns.dart';
import 'empresa_tela.dart';

double _n(dynamic v) => (v as num?)?.toDouble() ?? 0;
double? _nn(dynamic v) => (v as num?)?.toDouble();

/// Mercado em tempo real: maiores altas e baixas do dia (ações ou FIIs) e a busca por ticker ou nome,
/// que abre a ficha do ativo. No celular as listas ficam uma de cada vez; do tablet em diante, lado a lado.
class MercadoTela extends StatefulWidget {
  const MercadoTela({super.key, required this.api, this.arquivos});

  final ApiFinancas api;

  /// Leitor do módulo Arquivos: os documentos da CVM abrem dentro do app.
  final ApiArquivos? arquivos;

  @override
  State<MercadoTela> createState() => _MercadoTelaState();
}

class _MercadoTelaState extends State<MercadoTela> {
  final _busca = TextEditingController();
  Timer? _espera;
  List<Doc> _sugestoes = const [];
  bool _buscando = false;
  String _tipo = 'stock';
  bool _verAltas = true;
  late Future<Doc> _destaques = widget.api.destaques(tipo: _tipo);

  @override
  void dispose() {
    _espera?.cancel();
    _busca.dispose();
    super.dispose();
  }

  /// Sugestões enquanto digita (ticker pelo começo, nome, apelido, nome parecido), 250 ms depois
  /// da última tecla; resposta atrasada de uma busca antiga é descartada.
  void _digitou(String texto) {
    _espera?.cancel();
    final q = texto.trim();
    if (q.length < 2) {
      setState(() => _sugestoes = const []);
      return;
    }
    _espera = Timer(const Duration(milliseconds: 250), () async {
      setState(() => _buscando = true);
      try {
        final r = await widget.api.sugerir(q);
        if (mounted && _busca.text.trim() == q) setState(() => _sugestoes = r);
      } on ApiErro catch (e) {
        if (mounted) avisar(context, e.mensagem);
      } finally {
        if (mounted) setState(() => _buscando = false);
      }
    });
  }

  void _escolher(String ticker) {
    FocusScope.of(context).unfocus();
    _abrir(ticker);
  }

  void _recarregar() => setState(() => _destaques = widget.api.destaques(tipo: _tipo));

  void _abrir(String q) {
    if (q.trim().isEmpty) return;
    abrirTela<void>(context, (_) => AtivoTela(api: widget.api, arquivos: widget.arquivos, consulta: q.trim()));
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: () async => _recarregar(),
    child: ListView(
      padding: const EdgeInsets.all(8),
      children: [
        Padding(
          padding: const EdgeInsets.all(6),
          child: TextField(
            controller: _busca,
            textInputAction: TextInputAction.search,
            onChanged: _digitou,
            onSubmitted: (q) => _sugestoes.isEmpty ? _abrir(q) : _escolher('${(_sugestoes.first['tickers'] as List).first}'),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.search),
              hintText: 'Comece a digitar: ITU, Itaú, Petrobras, MXRF, Maxi Renda…',
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_buscando) const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  if (_busca.text.isNotEmpty)
                    IconButton(
                      tooltip: 'Limpar',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() {
                        _busca.clear();
                        _sugestoes = const [];
                      }),
                    ),
                  IconButton(icon: const Icon(Icons.arrow_forward), onPressed: () => _abrir(_busca.text)),
                ],
              ),
            ),
          ),
        ),
        if (_sugestoes.isNotEmpty) _Sugestoes(_sugestoes, _escolher),
        Secao(
          titulo: 'Destaques do dia',
          subtitulo: 'Entre os papéis mais negociados da B3 (atraso de alguns minutos).',
          acoes: [IconButton(tooltip: 'Atualizar', onPressed: _recarregar, icon: const Icon(Icons.refresh))],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'stock', label: Text('Ações'), icon: Icon(Icons.show_chart)),
                  ButtonSegment(value: 'fund', label: Text('FIIs e fundos'), icon: Icon(Icons.apartment)),
                ],
                selected: {_tipo},
                onSelectionChanged: (s) {
                  _tipo = s.first;
                  _recarregar();
                },
              ),
              Esperar(
                futuro: _destaques,
                recarregar: _recarregar,
                construir: (d) => LayoutBuilder(
                  builder: (context, c) {
                    final altas = _ListaDestaques('Maiores altas', (d['altas'] as List).cast<Doc>(), Colors.green, _abrir);
                    final baixas = _ListaDestaques('Maiores baixas', (d['baixas'] as List).cast<Doc>(), Colors.red, _abrir);
                    if (c.maxWidth >= 700) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 12,
                        children: [Expanded(child: altas), Expanded(child: baixas)],
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
                          selected: {_verAltas},
                          onSelectionChanged: (s) => setState(() => _verAltas = s.first),
                        ),
                        _verAltas ? altas : baixas,
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

/// Resultado da busca: empresa ou FII, setor e um botão por ticker (ITUB3, ITUB4…).
class _Sugestoes extends StatelessWidget {
  const _Sugestoes(this.itens, this.escolher);

  final List<Doc> itens;
  final ValueChanged<String> escolher;

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
            onTap: () => escolher('${(x['tickers'] as List).first}'),
            trailing: Wrap(
              spacing: 4,
              children: [
                for (final t in (x['tickers'] as List).take(4))
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    label: Text('$t', style: const TextStyle(fontWeight: FontWeight.w600)),
                    onPressed: () => escolher('$t'),
                  ),
              ],
            ),
          ),
      ],
    ),
  );
}

class _ListaDestaques extends StatelessWidget {
  const _ListaDestaques(this.titulo, this.itens, this.cor, this.abrir);

  final String titulo;
  final List<Doc> itens;
  final Color cor;
  final ValueChanged<String> abrir;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(titulo, style: Theme.of(context).textTheme.titleSmall),
      ),
      for (final (i, x) in itens.indexed)
        InkWell(
          onTap: () => abrir('${x['ticker']}'),
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
                    Text(moeda(_nn(x['preco']))),
                    Text(
                      '${_n(x['variacao_pct']) > 0 ? '+' : ''}${numero(_n(x['variacao_pct']))}%',
                      style: TextStyle(color: cor, fontWeight: FontWeight.w600),
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

/// Ficha de um ativo: ação (cotação, proventos, DRE/balanço/fluxo da CVM e os documentos com link)
/// ou FII (informe mensal: P/VP, DY, patrimônio, composição e relatórios gerenciais).
class AtivoTela extends StatefulWidget {
  const AtivoTela({super.key, required this.api, required this.consulta, this.arquivos});

  final ApiFinancas api;
  final ApiArquivos? arquivos;
  final String consulta;

  @override
  State<AtivoTela> createState() => _AtivoTelaState();
}

class _AtivoTelaState extends State<AtivoTela> {
  late Future<Doc> _dados = _buscar();

  /// Ficha incompleta enquanto o servidor lê a CVM: a tela vai montando por partes.
  Doc? _parcial;

  Future<Doc> _buscar() => widget.api.ativo(widget.consulta,
      cancelado: () => !mounted, aoParcial: (p) => mounted ? setState(() => _parcial = p) : null);

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.consulta.toUpperCase())),
    body: FutureBuilder<Doc>(
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
                      _parcial = null;
                      _dados = _buscar();
                    }),
                    child: const Text('Tentar de novo'),
                  ),
                ],
              ),
            ),
          );
        }
        if (!s.hasData && _parcial?['tipo'] == 'acao') {
          return _FichaAcao(api: widget.api, arquivos: widget.arquivos, d: _parcial!);
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
        return d['tipo'] == 'fii' ? _FichaFii(d) : _FichaAcao(api: widget.api, arquivos: widget.arquivos, d: d);
      },
    ),
  );
}

/// Duas colunas do tablet deitado em diante; uma coluna no celular.
class _Ficha extends StatelessWidget {
  const _Ficha({required this.principal, required this.lateral});

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

Widget _cabecalho(BuildContext context, Doc d, String subtitulo) {
  final cot = d['cotacao'] as Doc? ?? const {};
  final variacao = _nn(cot['variacao_pct']);
  final cor = variacao == null ? null : (variacao >= 0 ? Colors.green : Colors.red);
  return Secao(
    titulo: '${d['ticker']} · ${d['nome']}',
    subtitulo: subtitulo,
    child: Wrap(
      spacing: 16,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.end,
      children: [
        Text(moeda(_nn(cot['preco'])), style: Theme.of(context).textTheme.headlineMedium),
        if (variacao != null)
          Text('${variacao >= 0 ? '+' : ''}${numero(variacao)}% hoje',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(color: cor)),
        if (cot['horario'] != null) Text('às ${'${cot['horario']}'.replaceFirst('T', ' ')}', style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}

/// Baixa o documento da CVM direto do aparelho: o PDF (release, apresentação) ou, no pacote ZIP do
/// DFP/ITR, o maior PDF lá dentro (as demonstrações completas). A CVM recusa conexões da VPS.
Future<Uint8List> _pdfDaCvm(String url) async {
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

Widget _link(BuildContext context, IconData icone, String titulo, String url, {String? detalhe, Widget? extra}) => ListTile(
  dense: true,
  contentPadding: EdgeInsets.zero,
  leading: Icon(icone),
  title: Text(titulo, maxLines: 2, overflow: TextOverflow.ellipsis),
  subtitle: detalhe == null ? null : Text(detalhe),
  onTap: () => abrirLink(context, url),
  trailing: extra ?? const Icon(Icons.open_in_new, size: 18),
);

class _FichaAcao extends StatelessWidget {
  const _FichaAcao({required this.api, required this.d, this.arquivos});

  final ApiFinancas api;
  final ApiArquivos? arquivos;
  final Doc d;

  /// Documento da CVM: baixa pela VPS, guarda no Arquivos e abre no leitor do app (grifar e anotar).
  Widget _doc(BuildContext context, IconData icone, String titulo, String url, String detalhe) => ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    leading: Icon(icone),
    title: Text(titulo, maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitle: Text(detalhe),
    onTap: () => _abrirNoApp(context, url, titulo),
    trailing: IconButton(
      tooltip: 'Abrir no navegador',
      icon: const Icon(Icons.open_in_new, size: 18),
      onPressed: () => abrirLink(context, url),
    ),
  );

  /// Vira tarefa em segundo plano (sino). O aparelho baixa da CVM e abre a prévia com "Salvar" (vai
  /// para Arquivos › Finanças/`ticker` e abre no leitor). Se o aparelho não conseguir (web, CORS),
  /// a VPS baixa e já guarda no Arquivos.
  void _abrirNoApp(BuildContext context, String url, String titulo) {
    final leitor = arquivos;
    if (leitor == null) {
      abrirLink(context, url);
      return;
    }
    final ticker = '${d['ticker']}';
    Tarefas.instancia.rodar<Object>(
      '$ticker: $titulo',
      (t) async {
        if (!kIsWeb) {
          t.atualizar(detalhe: 'Baixando da CVM…');
          try {
            return await _pdfDaCvm(url);
          } catch (_) {
            t.conferir();
          }
        }
        t.atualizar(detalhe: 'A VPS está baixando da CVM…');
        final guardado = await api.guardarDocumento(url, titulo, ticker, cancelado: () => t.cancelada);
        t.conferir();
        t.atualizar(detalhe: 'Trazendo o PDF para o aparelho…', progresso: 0);
        final a = await leitor.obter(guardado['id'] as String);
        // Fica no aparelho: o leitor abre na hora, também sem conexão.
        await leitor.offline.baixar(a, tarefa: t);
        return a;
      },
      abrir: (c, r) => r is Uint8List
          ? abrirPrevia(c, leitor, '$ticker $titulo.pdf', r, pasta: 'Finanças/$ticker')
          : abrirArquivo(c, leitor, r as Arquivo),
    );
    avisar(context, 'Baixando em segundo plano. Acompanhe no sino 🔔; aviso quando ficar pronto.');
  }

  @override
  Widget build(BuildContext context) {
    final anos = ((d['demonstrativos'] as List?) ?? const []).cast<Doc>();
    final falta = ((d['carregando'] as List?) ?? const []).toSet();
    Widget? esperando(String parte) => falta.contains(parte) ? const LinearProgressIndicator() : null;
    final ultimo = anos.isEmpty ? const <String, dynamic>{} : anos.last;
    final prov = d['proventos'] as Doc? ?? const {};
    final docs = d['documentos'] as Doc? ?? const {};
    final serie = ((d['indicadores'] as List?) ?? const []).cast<Doc>();
    final ind = serie.isEmpty ? const <String, dynamic>{} : serie.last;
    final v = d['valuation'] as Doc? ?? const {};
    final financeira = ind['financeira'] == true;
    return _Ficha(
      principal: [
        _cabecalho(context, d, '${d['setor']} · ${d['atividade']}'),
        Secao(
          titulo: 'Indicadores${ultimo['ano'] == null ? '' : ' de ${ultimo['ano']}'}',
          subtitulo: financeira
              ? 'Banco/seguradora: EBITDA, ROIC e dívida não se aplicam; olhe ROE, P/L, P/VP e dividendos.'
              : 'Demonstrações consolidadas entregues à CVM e cotação do dia.',
          acoes: [
            TextButton.icon(
              onPressed: anos.isEmpty ? null : () => _acompanhar(context),
              icon: const Icon(Icons.add_chart),
              label: const Text('Acompanhar'),
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              if (falta.contains('demonstrativos') || falta.contains('cotacao'))
                Row(
                  spacing: 8,
                  children: [
                    const Expanded(child: LinearProgressIndicator()),
                    Text(
                      anos.isEmpty ? 'Lendo a CVM…' : 'Já chegaram ${anos.length} ano(s); lendo os outros…',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              for (final (titulo, itens) in _grupos(d, ultimo, ind, v, prov, financeira))
                if (itens.isNotEmpty) ...[
                  Text(titulo, style: Theme.of(context).textTheme.titleSmall),
                  GradeIndicadores(children: itens),
                ],
            ],
          ),
        ),
        if (serie.length > 1) Secao(titulo: 'Indicadores por ano', child: _TabelaIndicadores(serie, financeira)),
        if (anos.isNotEmpty) Secao(titulo: 'DRE, balanço e caixa por ano', child: _TabelaAnos(anos)),
      ],
      lateral: [
        Secao(
          titulo: 'Releases e comunicados',
          subtitulo: 'Toque para abrir aqui no app; ↗ abre no navegador.',
          child: esperando('documentos') ?? Column(
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
        Secao(
          titulo: 'Demonstrações completas (DFP e ITR)',
          subtitulo: 'Toque para abrir o PDF aqui no app; "Salvar" guarda em Arquivos › Finanças.',
          child: esperando('documentos') ?? Column(
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
        Secao(
          titulo: 'Páginas da empresa',
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

  /// Cadastra em Investimentos › Empresas (ou usa a que já existe) com DRE de 6 anos, número de
  /// ações e cotação, e abre a análise completa.
  Future<void> _acompanhar(BuildContext context) async {
    String? id;
    final ok = await tentar(context, () async {
      final existentes = await api.listar('empresas');
      final achada = existentes.where((e) => '${e['ticker']}'.toUpperCase() == '${d['ticker']}'.toUpperCase());
      final e = achada.isNotEmpty
          ? achada.first
          : await api.criar('empresas', {
              'ticker': d['ticker'],
              'nome': d['nome'],
              'cnpj': d['cnpj'],
              'site': d['site'],
              'setor': d['setor'] ?? '',
              'descricao': d['atividade'] ?? '',
            });
      id = e['id'] as String;
      await api.importarCvm(id!);
    }, ok: 'Em Investimentos › Empresas, com DRE de 6 anos, ações e cotação');
    final leitor = arquivos;
    if (ok && id != null && leitor != null && context.mounted) {
      await abrirTela<void>(context, (_) => EmpresaTela(api: api, arquivos: leitor, id: id!));
    }
  }
}

/// Painel da ficha em grupos; cada número com a explicação curta do que é bom.
List<(String, List<Widget>)> _grupos(Doc d, Doc ano, Doc ind, Doc v, Doc prov, bool financeira) {
  String n2(dynamic x) => x == null ? '—' : numero(_n(x));
  String p1(dynamic x) => x == null ? '—' : pct(_n(x));
  Color? cor(dynamic x, bool Function(double) bom) => x == null ? null : (bom(_n(x)) ? Colors.green : Colors.orange);
  final dy = prov['dy_12m_pct'] ?? v['dy'];
  return [
    (
      'Preço e valuation',
      [
        Indicador('P/L', n2(v['pl']), cor: cor(v['pl'], (x) => x > 0 && x <= 15), detalhe: 'anos de lucro para pagar o preço'),
        Indicador('P/VP', n2(v['pvp']), cor: cor(v['pvp'], (x) => x <= 2), detalhe: 'preço ÷ patrimônio por ação'),
        if (!financeira)
          Indicador('EV/EBITDA', n2(v['ev_ebitda']), cor: cor(v['ev_ebitda'], (x) => x > 0 && x <= 8), detalhe: 'valor da firma ÷ geração operacional'),
        Indicador('Dividend yield 12m', p1(dy), cor: cor(dy, (x) => x >= 6),
            detalhe: prov['total_12m'] == null ? 'Bazin pede 6% ou mais' : '${moeda(_n(prov['total_12m']))} por ação'),
        Indicador('Valor de mercado', _mil(_nn(v['valor_mercado'])), detalhe: 'cotação × ações'),
        Indicador('LPA', moeda(_nn(ind['lpa'])), detalhe: 'lucro por ação'),
        Indicador('VPA', moeda(_nn(ind['vpa'])), detalhe: 'patrimônio por ação'),
        Indicador('Preço Graham', moeda(_nn(v['preco_graham'])), detalhe: '√(22,5 × LPA × VPA)'),
        Indicador('Preço Bazin', moeda(_nn(v['preco_bazin'])), detalhe: 'dividendo por ação ÷ 6%'),
      ],
    ),
    (
      'Rentabilidade e margens',
      [
        Indicador('ROE', p1(ind['roe']), cor: cor(ind['roe'], (x) => x >= 15), detalhe: 'lucro ÷ patrimônio; bom ≥ 15%'),
        if (!financeira) Indicador('ROIC', p1(ind['roic']), cor: cor(ind['roic'], (x) => x >= 10), detalhe: 'retorno do capital investido'),
        Indicador('ROA', p1(ind['roa']), detalhe: 'lucro ÷ ativo total'),
        if (!financeira) Indicador('Margem bruta', p1(ind['margem_bruta'])),
        if (!financeira) Indicador('Margem EBITDA', p1(ind['margem_ebitda'])),
        Indicador('Margem líquida', p1(ind['margem_liquida']), cor: cor(ind['margem_liquida'], (x) => x >= 10)),
      ],
    ),
    (
      'Endividamento e caixa',
      [
        if (!financeira) ...[
          Indicador('Dív. líquida/EBITDA', n2(ind['divida_liquida_ebitda']),
              cor: cor(ind['divida_liquida_ebitda'], (x) => x <= 2.5), detalhe: 'anos de geração para pagar a dívida'),
          Indicador('Dív. líquida/PL', n2(ind['divida_liquida_pl'])),
          Indicador('Liquidez corrente', n2(ind['liquidez_corrente']), cor: cor(ind['liquidez_corrente'], (x) => x >= 1),
              detalhe: 'ativo ÷ passivo de curto prazo'),
          Indicador('Fluxo de caixa livre', _mil(_nn(ind['fcl'])), detalhe: 'caixa operacional − capex'),
        ],
        Indicador('Conversão de caixa', p1(ind['conversao_caixa']), cor: cor(ind['conversao_caixa'], (x) => x >= 80),
            detalhe: 'caixa operacional ÷ lucro'),
        Indicador('Payout', p1(ind['payout']), detalhe: 'dividendos pagos ÷ lucro'),
      ],
    ),
    (
      'Tamanho e crescimento',
      [
        Indicador('Receita líquida', _mil(_nn(ano['receita_liquida'])),
            detalhe: ind['cresc_receita'] == null ? null : '${pct(_n(ind['cresc_receita']))} no ano'),
        Indicador('Lucro líquido', _mil(_nn(ano['lucro_liquido'])),
            cor: _nn(ano['lucro_liquido']) == null ? null : (_n(ano['lucro_liquido']) >= 0 ? Colors.green : Colors.red),
            detalhe: ind['cresc_lucro'] == null ? null : '${pct(_n(ind['cresc_lucro']))} no ano'),
        Indicador('CAGR receita', p1(d['cagr_receita']), detalhe: 'crescimento médio ao ano'),
        Indicador('CAGR lucro', p1(d['cagr_lucro']), detalhe: 'crescimento médio ao ano'),
      ],
    ),
  ];
}

/// Indicadores ano a ano (tendência importa mais que o número de um ano só).
class _TabelaIndicadores extends StatelessWidget {
  const _TabelaIndicadores(this.serie, this.financeira);

  final List<Doc> serie;
  final bool financeira;

  static const linhas = [
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
      columns: [const DataColumn(label: Text('')), for (final a in serie) DataColumn(numeric: true, label: Text('${a['ano']}'))],
      rows: [
        for (final (chave, rotulo, ehPct, banco) in linhas)
          if ((banco || !financeira) && serie.any((a) => a[chave] != null))
            DataRow(cells: [
              DataCell(Text(rotulo)),
              for (final a in serie)
                DataCell(Text(a[chave] == null ? '—' : (ehPct ? pct(_n(a[chave])) : numero(_n(a[chave]))))),
            ]),
      ],
    ),
  );
}

String _mil(double? v) {
  if (v == null) return '—';
  final reais = v * 1000;
  final a = reais.abs();
  final s = a >= 1e9 ? '${numero(a / 1e9, casas: 1)} bi' : (a >= 1e6 ? '${numero(a / 1e6, casas: 1)} mi' : numero(a, casas: 0));
  return '${v < 0 ? '-' : ''}R\$ $s';
}

/// Tabela ano × conta; rola na horizontal quando a tela é estreita.
class _TabelaAnos extends StatelessWidget {
  const _TabelaAnos(this.anos);

  final List<Doc> anos;

  static const linhas = [
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
      columns: [const DataColumn(label: Text('')), for (final a in anos) DataColumn(numeric: true, label: Text('${a['ano']}'))],
      rows: [
        for (final (chave, rotulo) in linhas)
          if (anos.any((a) => a[chave] != null))
            DataRow(cells: [DataCell(Text(rotulo)), for (final a in anos) DataCell(Text(_mil(_nn(a[chave]))))]),
      ],
    ),
  );
}

class _FichaFii extends StatelessWidget {
  const _FichaFii(this.d);

  final Doc d;

  @override
  Widget build(BuildContext context) {
    final meses = (d['meses'] as List).cast<Doc>();
    final ultimo = meses.isEmpty ? const <String, dynamic>{} : meses.last;
    final prov = d['proventos'] as Doc? ?? const {};
    final links = d['links'] as Doc? ?? const {};
    final composicao = (d['composicao'] as List).cast<Doc>();
    return _Ficha(
      principal: [
        _cabecalho(context, d, '${d['segmento']} · gestão ${'${d['gestao']}'.toLowerCase()} · ${d['administrador']}'),
        Secao(
          titulo: 'Indicadores',
          subtitulo: 'Informe mensal à CVM (${mesBr('${ultimo['mes'] ?? ''}')}) e proventos dos últimos 12 meses.',
          child: GradeIndicadores(
            children: [
              Indicador('P/VP', d['p_vp'] == null ? '—' : numero(_n(d['p_vp'])),
                  cor: d['p_vp'] == null ? null : (_n(d['p_vp']) <= 1 ? Colors.green : Colors.orange),
                  detalhe: 'abaixo de 1 = cota mais barata que o patrimônio'),
              Indicador('Dividend yield 12m', prov['dy_12m_pct'] == null ? '—' : pct(_n(prov['dy_12m_pct'])),
                  detalhe: prov['total_12m'] == null ? null : '${moeda(_n(prov['total_12m']))} por cota'),
              Indicador('Valor patrimonial', moeda(_nn(ultimo['valor_patrimonial_cota'])), detalhe: 'por cota'),
              Indicador('Patrimônio', _mil(_n(ultimo['patrimonio_liquido']) / 1000)),
              Indicador('Cotistas', numero(_n(ultimo['cotistas']), casas: 0)),
              Indicador('Taxa de adm.', ultimo['taxa_adm_pct'] == null ? '—' : pct(_n(ultimo['taxa_adm_pct'])), detalhe: 'no mês'),
            ],
          ),
        ),
        if (meses.isNotEmpty)
          Secao(titulo: 'Dividend yield mensal (% do patrimônio)', child: _BarrasDy(meses)),
      ],
      lateral: [
        if (composicao.isNotEmpty)
          Secao(
            titulo: 'Onde o dinheiro está',
            child: Column(
              spacing: 8,
              children: [
                for (final c in composicao)
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
        Secao(
          titulo: 'Relatórios e páginas',
          child: Column(
            children: [
              if (links['relatorios_fnet'] != null)
                _link(context, Icons.folder_open, 'Relatórios gerenciais e informes (FNET/B3)', '${links['relatorios_fnet']}',
                    detalhe: 'relatório gerencial, informes mensais e trimestrais, fatos relevantes'),
              if (links['status_invest'] != null) _link(context, Icons.link, 'Status Invest', '${links['status_invest']}'),
              if ('${d['site'] ?? ''}'.isNotEmpty) _link(context, Icons.language, 'Site do administrador', '${d['site']}'),
            ],
          ),
        ),
      ],
    );
  }
}

class _BarrasDy extends StatelessWidget {
  const _BarrasDy(this.meses);

  final List<Doc> meses;

  @override
  Widget build(BuildContext context) {
    final valores = [for (final m in meses) _n(m['dy_mes_pct'])];
    final maior = valores.fold<double>(0.01, max);
    final cor = Theme.of(context).colorScheme.primary;
    return SizedBox(
      height: 150,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        spacing: 4,
        children: [
          for (final (i, v) in valores.indexed)
            Expanded(
              child: Tooltip(
                message: '${mesBr('${meses[i]['mes']}')}: ${pct(v)}',
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FittedBox(child: Text(numero(v), style: Theme.of(context).textTheme.labelSmall)),
                    Container(height: max(2, 100 * v / maior), color: cor),
                    FittedBox(child: Text('${meses[i]['mes']}'.substring(5), style: Theme.of(context).textTheme.labelSmall)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
