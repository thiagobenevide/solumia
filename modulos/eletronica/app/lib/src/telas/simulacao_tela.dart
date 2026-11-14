import 'dart:math';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_eletronica.dart';
import '../calculos.dart';
import '../modelos.dart';
import '../simulacao.dart';
import 'grafico.dart';

/// Simulação do projeto no ngspice (worker): escolhe a análise, roda e mostra o multímetro (ponto de
/// operação) ou o osciloscópio (transiente, AC, varredura DC). [gravar] grava o esquemático antes; [aoLer]
/// recebe a leitura de cada ponta de prova (id → texto) depois de um ponto de operação.
class SimulacaoTela extends StatefulWidget {
  const SimulacaoTela({super.key, required this.api, required this.projeto, required this.gravar, this.aoLer});

  final ApiEletronica api;
  final Projeto projeto;
  final Future<void> Function() gravar;
  final void Function(Map<String, String>)? aoLer;

  @override
  State<SimulacaoTela> createState() => _SimulacaoTelaState();
}

class _SimulacaoTelaState extends State<SimulacaoTela> {
  Analise _analise = Analise.op;
  final _campos = <String, TextEditingController>{
    'tran.passo': TextEditingController(text: '10u'),
    'tran.fim': TextEditingController(text: '10m'),
    'ac.pontos': TextEditingController(text: '20'),
    'ac.inicio': TextEditingController(text: '10'),
    'ac.fim': TextEditingController(text: '100k'),
    'dc.inicio': TextEditingController(text: '0'),
    'dc.fim': TextEditingController(text: '5'),
    'dc.passo': TextEditingController(text: '0.1'),
  };
  String? _fonte;
  late Future<Spice> _spice = _carregarSpice();

  bool _rodando = false, _cancelar = false, _tabela = false, _db = true;
  String _estado = '';
  String? _erro;
  Resultado? _resultado;

  /// Sinal → posição na paleta, enquanto visível (a cor não muda quando outro sinal entra ou sai).
  final Map<String, int> _cor = {};

  Future<Spice> _carregarSpice() async {
    await widget.gravar();
    final s = await widget.api.spice(widget.projeto.id);
    if (mounted && _fonte == null && s.fontes.isNotEmpty) setState(() => _fonte = s.fontes.first);
    return s;
  }

  @override
  void dispose() {
    _cancelar = true;
    for (final c in _campos.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _v(String chave) => _campos[chave]!.text.trim();

  /// Corpo do pedido; texto do erro quando algum campo não é número.
  (Map<String, dynamic>?, String?) _pedido() {
    final chaves = switch (_analise) {
      Analise.op => <String>[],
      Analise.tran => ['tran.passo', 'tran.fim'],
      Analise.ac => ['ac.pontos', 'ac.inicio', 'ac.fim'],
      Analise.dc => ['dc.inicio', 'dc.fim', 'dc.passo'],
    };
    for (final k in chaves) {
      if (lerValor(_v(k)) == null) return (null, 'Valor inválido em "${k.split('.').last}": ${_v(k)}');
    }
    if (_analise == Analise.dc && _fonte == null) return (null, 'O circuito não tem fonte para varrer.');
    return (
      {
        'analise': _analise.name,
        for (final k in chaves) k.split('.').last: k == 'ac.pontos' ? lerValor(_v(k))!.round() : _v(k),
        if (_analise == Analise.dc) 'fonte': _fonte,
      },
      null,
    );
  }

  Future<void> _simular() async {
    final (pedido, problema) = _pedido();
    if (pedido == null) {
      setState(() => _erro = problema);
      return;
    }
    setState(() {
      _rodando = true;
      _cancelar = false;
      _erro = null;
      _estado = 'gravando';
    });
    try {
      await widget.gravar();
      setState(() => _spice = widget.api.spice(widget.projeto.id));
      final r = await widget.api.simular(
        widget.projeto.id,
        pedido,
        cancelado: () => _cancelar,
        aoMudar: (e) {
          if (mounted) setState(() => _estado = e);
        },
      );
      if (!mounted) return;
      setState(() {
        _resultado = r;
        _cor.clear();
        if (r is Curvas) {
          final iniciais = {...r.series.keys.where((k) => Curvas.unidadeDe(k) == 'V'), ...r.series.keys}.take(4);
          for (final s in iniciais) {
            _ligar(s);
          }
        }
      });
      if (r is PontoOperacao && widget.aoLer != null) widget.aoLer!(await _lerSondas(r));
    } on ApiErro catch (e) {
      if (mounted) setState(() => _erro = e.mensagem);
    } catch (e) {
      if (mounted) setState(() => _erro = '$e');
    } finally {
      if (mounted) setState(() => _rodando = false);
    }
  }

  /// Tensão da rede onde cada ponta `v` encosta (terra = 0 V) e corrente do componente de cada ponta `i`.
  Future<Map<String, String>> _lerSondas(PontoOperacao r) async {
    if (widget.projeto.sondas.isEmpty) return {};
    final n = await widget.api.netlist(widget.projeto.id);
    final terra = RegExp(r'^(0|[ADP]?GND\w*)$');
    final leituras = <String, String>{};
    for (final s in (n['sondas'] as List? ?? []).cast<Map<String, dynamic>>()) {
      final id = s['id'] as String;
      if (s['tipo'] == 'i') {
        final i = r.correntes['${s['ref']}'.toUpperCase()];
        if (i != null) leituras[id] = formatar(i, 'A');
      } else if (s['rede'] case final String rede) {
        final v = r.tensoes[rede] ?? (terra.hasMatch(rede.toUpperCase()) ? 0.0 : null);
        if (v != null) leituras[id] = formatar(v, 'V');
      }
    }
    return leituras;
  }

  bool _ligar(String serie) {
    final livres = [for (var i = 0; i < coresSinais.length; i++) i]..removeWhere(_cor.values.contains);
    if (livres.isEmpty) return false;
    _cor[serie] = livres.first;
    return true;
  }

  void _alternar(String serie) {
    setState(() {
      if (_cor.remove(serie) != null) return;
      if (!_ligar(serie)) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No máximo 8 sinais ao mesmo tempo.')));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final largo = MediaQuery.sizeOf(context).width >= 900;
    final config = _configuracao(context);
    final resultado = DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(tabs: [Tab(text: 'Resultado'), Tab(text: 'Netlist SPICE')]),
          Expanded(child: TabBarView(children: [_areaResultado(context), _netlist(context)])),
        ],
      ),
    );
    return Scaffold(
      appBar: AppBar(title: Text('Simulação · ${widget.projeto.titulo}')),
      body: largo
          ? Row(
              children: [
                SizedBox(width: 320, child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: config)),
                const VerticalDivider(width: 1),
                Expanded(child: resultado),
              ],
            )
          : Column(
              children: [
                ExpansionTile(
                  initiallyExpanded: _resultado == null,
                  title: Text(_analise.nome),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [config],
                ),
                Expanded(child: resultado),
              ],
            ),
    );
  }

  Widget _campo(String chave, String rotulo, String dica) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: TextField(
      controller: _campos[chave],
      decoration: InputDecoration(labelText: rotulo, helperText: dica, isDense: true),
    ),
  );

  Widget _configuracao(BuildContext context) => FutureBuilder(
    future: _spice,
    builder: (context, s) {
      final fontes = s.data?.fontes ?? const <String>[];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Análise', style: Theme.of(context).textTheme.titleSmall),
          RadioGroup<Analise>(
            groupValue: _analise,
            onChanged: (a) => setState(() => _analise = a ?? _analise),
            child: Column(
              children: [
                for (final a in Analise.values)
                  RadioListTile<Analise>(
                    value: a,
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(a.nome),
                    subtitle: Text(a.dica),
                  ),
              ],
            ),
          ),
          ...switch (_analise) {
            Analise.op => [const Text('Sem parâmetros: calcula o circuito parado (DC).')],
            Analise.tran => [
              _campo('tran.passo', 'Passo', 'ex.: 10u (10 µs)'),
              _campo('tran.fim', 'Duração', 'ex.: 10m (10 ms)'),
            ],
            Analise.ac => [
              _campo('ac.pontos', 'Pontos por década', 'ex.: 20'),
              _campo('ac.inicio', 'Frequência inicial (Hz)', 'ex.: 10'),
              _campo('ac.fim', 'Frequência final (Hz)', 'ex.: 100k'),
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('A fonte de sinal precisa de "AC 1" no valor (ex.: "DC 0 AC 1").'),
              ),
            ],
            Analise.dc => [
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: DropdownButtonFormField<String>(
                  initialValue: fontes.contains(_fonte) ? _fonte : null,
                  decoration: const InputDecoration(labelText: 'Fonte varrida', isDense: true),
                  items: [for (final f in fontes) DropdownMenuItem(value: f, child: Text(f))],
                  onChanged: (f) => setState(() => _fonte = f),
                ),
              ),
              _campo('dc.inicio', 'De', 'ex.: 0'),
              _campo('dc.fim', 'Até', 'ex.: 5'),
              _campo('dc.passo', 'Passo', 'ex.: 0.1'),
            ],
          },
          const SizedBox(height: 20),
          if (_rodando)
            Row(
              spacing: 12,
              children: [
                const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                Expanded(child: Text(switch (_estado) { 'fila' => 'Na fila do worker…', 'rodando' => 'ngspice rodando…', _ => 'Preparando…' })),
                TextButton(onPressed: () => _cancelar = true, child: const Text('Cancelar')),
              ],
            )
          else
            FilledButton.icon(onPressed: _simular, icon: const Icon(Icons.play_arrow), label: const Text('Simular')),
          if (_erro != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_erro!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          if (s.hasData && s.data!.ignorados.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Card(
                child: ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('Avisos da simulação'),
                  subtitle: Text(s.data!.ignorados.join('\n')),
                ),
              ),
            ),
        ],
      );
    },
  );

  Widget _netlist(BuildContext context) => FutureBuilder(
    future: _spice,
    builder: (context, s) {
      if (s.hasError) return Center(child: Text('Não gerou a netlist: ${s.error}'));
      if (!s.hasData) return const Center(child: CircularProgressIndicator());
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SelectableText(s.data!.texto, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
      );
    },
  );

  Widget _areaResultado(BuildContext context) => switch (_resultado) {
    null => const Center(child: Text('Escolha a análise e toque em Simular.')),
    PontoOperacao r => _multimetro(context, r),
    Curvas r => _osciloscopio(context, r),
  };

  Widget _multimetro(BuildContext context, PontoOperacao r) {
    Widget tabela(String titulo, Map<String, double> valores, String unidade) => Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(titulo, style: Theme.of(context).textTheme.titleSmall),
            for (final e in (valores.entries.toList()..sort((a, b) => a.key.compareTo(b.key))))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Expanded(child: Text(e.key, style: const TextStyle(fontFamily: 'monospace'))),
                    Text(formatar(e.value, unidade), style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            if (valores.isEmpty) const Text('—'),
          ],
        ),
      ),
    );
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        tabela('Tensões nas redes (em relação ao GND)', r.tensoes, 'V'),
        tabela('Correntes', r.correntes, 'A'),
      ],
    );
  }

  Widget _osciloscopio(BuildContext context, Curvas r) {
    final ac = r.analise == Analise.ac;
    final visiveis = [for (final s in r.series.keys) if (_cor.containsKey(s)) s];
    final cores = {for (final s in visiveis) s: coresSinais[_cor[s]!]};
    List<double> valores(String s) =>
        ac && _db ? [for (final v in r.series[s]!) v > 0 ? 20 * log(v) / ln10 : double.nan] : r.series[s]!;
    // Uma grandeza por gráfico: nunca dois eixos y.
    final grupos = <String, List<String>>{};
    for (final s in visiveis) {
      grupos.putIfAbsent(ac && _db ? 'dB' : Curvas.unidadeDe(s), () => []).add(s);
    }
    final legenda = Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final s in r.series.keys)
          FilterChip(
            avatar: CircleAvatar(backgroundColor: cores[s] ?? Colors.transparent, radius: 6),
            label: Text(s, style: const TextStyle(fontFamily: 'monospace')),
            selected: cores.containsKey(s),
            showCheckmark: false,
            onSelected: (_) => _alternar(s),
          ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          Row(
            children: [
              Expanded(child: legenda),
              if (ac)
                SegmentedButton<bool>(
                  segments: const [ButtonSegment(value: true, label: Text('dB')), ButtonSegment(value: false, label: Text('V/V'))],
                  selected: {_db},
                  onSelectionChanged: (s) => setState(() => _db = s.first),
                ),
              IconButton(
                tooltip: _tabela ? 'Ver gráfico' : 'Ver tabela',
                onPressed: () => setState(() => _tabela = !_tabela),
                icon: Icon(_tabela ? Icons.show_chart : Icons.table_rows_outlined),
              ),
            ],
          ),
          if (visiveis.isEmpty)
            const Expanded(child: Center(child: Text('Escolha um sinal acima.')))
          else if (_tabela)
            Expanded(child: _tabelaCurvas(r, visiveis, valores, ac && _db ? 'dB' : null))
          else
            for (final g in grupos.entries)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      switch (g.key) { 'A' => 'Corrente', 'dB' => 'Ganho (dB)', _ => ac ? 'Ganho (V/V)' : 'Tensão' },
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    Expanded(
                      child: GraficoCurvas(
                        x: r.eixo,
                        series: {for (final s in g.value) s: valores(s)},
                        cores: cores,
                        unidadeX: r.eixoUnidade,
                        unidadeY: g.key == 'dB' ? 'dB' : (ac ? '' : g.key),
                        logX: ac,
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  /// Os mesmos dados em tabela (no máximo 200 linhas, amostradas por igual).
  Widget _tabelaCurvas(Curvas r, List<String> visiveis, List<double> Function(String) valores, String? unidadeFixa) {
    final n = r.eixo.length;
    final passo = max(1, (n / 200).ceil());
    final dados = {for (final s in visiveis) s: valores(s)};
    return SingleChildScrollView(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: [
            DataColumn(label: Text(r.eixoNome), numeric: true),
            for (final s in visiveis) DataColumn(label: Text(s), numeric: true),
          ],
          rows: [
            for (var i = 0; i < n; i += passo)
              DataRow(
                cells: [
                  DataCell(Text(formatar(r.eixo[i], r.eixoUnidade))),
                  for (final s in visiveis)
                    DataCell(Text(i < dados[s]!.length ? formatar(dados[s]![i], unidadeFixa ?? Curvas.unidadeDe(s)) : '—')),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
