import 'dart:math';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../electronics_api.dart';
import '../calculations.dart';
import '../models.dart';
import '../simulation.dart';
import 'chart.dart';

/// Project simulation in ngspice (worker): picks the analysis, runs it and shows the multimeter (operating
/// point) or the oscilloscope (transient, AC, DC sweep). [save] saves the schematic first; [onRead]
/// gets the reading of each probe (id → text) after an operating point.
class SimulationScreen extends StatefulWidget {
  const SimulationScreen({super.key, required this.api, required this.project, required this.save, this.onRead});

  final ElectronicsApi api;
  final Project project;
  final Future<void> Function() save;
  final void Function(Map<String, String>)? onRead;

  @override
  State<SimulationScreen> createState() => _SimulationScreenState();
}

class _SimulationScreenState extends State<SimulationScreen> {
  Analysis _analysis = Analysis.op;
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
  String? _source;
  late Future<Spice> _spice = _loadSpice();

  bool _running = false, _cancel = false, _table = false, _db = true;
  String _state = '';
  String? _error;
  SimulationResult? _result;

  /// Signal → position in the palette, while visible (the color does not change when another signal comes in or out).
  final Map<String, int> _color = {};

  Future<Spice> _loadSpice() async {
    await widget.save();
    final s = await widget.api.spice(widget.project.id);
    if (mounted && _source == null && s.sources.isNotEmpty) setState(() => _source = s.sources.first);
    return s;
  }

  @override
  void dispose() {
    _cancel = true;
    for (final c in _campos.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _v(String key) => _campos[key]!.text.trim();

  /// Request body; error text when some field is not a number.
  (Map<String, dynamic>?, String?) _request() {
    final keys = switch (_analysis) {
      Analysis.op => <String>[],
      Analysis.tran => ['tran.passo', 'tran.fim'],
      Analysis.ac => ['ac.pontos', 'ac.inicio', 'ac.fim'],
      Analysis.dc => ['dc.inicio', 'dc.fim', 'dc.passo'],
    };
    for (final k in keys) {
      if (readValue(_v(k)) == null) return (null, 'Valor inválido em "${k.split('.').last}": ${_v(k)}');
    }
    if (_analysis == Analysis.dc && _source == null) return (null, 'O circuito não tem fonte para varrer.');
    return (
      {
        'analise': _analysis.name,
        for (final k in keys) k.split('.').last: k == 'ac.pontos' ? readValue(_v(k))!.round() : _v(k),
        if (_analysis == Analysis.dc) 'fonte': _source,
      },
      null,
    );
  }

  Future<void> _simulate() async {
    final (request, problem) = _request();
    if (request == null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _running = true;
      _cancel = false;
      _error = null;
      _state = 'gravando';
    });
    try {
      await widget.save();
      setState(() => _spice = widget.api.spice(widget.project.id));
      final r = await widget.api.simulate(
        widget.project.id,
        request,
        cancelled: () => _cancel,
        aoMudar: (e) {
          if (mounted) setState(() => _state = e);
        },
      );
      if (!mounted) return;
      setState(() {
        _result = r;
        _color.clear();
        if (r is SimCurves) {
          final initial = {...r.series.keys.where((k) => SimCurves.unitOf(k) == 'V'), ...r.series.keys}.take(4);
          for (final s in initial) {
            _connect(s);
          }
        }
      });
      if (r is OperatingPoint && widget.onRead != null) widget.onRead!(await _readProbes(r));
    } on ApiErro catch (e) {
      if (mounted) setState(() => _error = e.mensagem);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  /// Voltage of the net each `v` probe touches (ground = 0 V) and current of the component of each `i` probe.
  Future<Map<String, String>> _readProbes(OperatingPoint r) async {
    if (widget.project.probes.isEmpty) return {};
    final n = await widget.api.netlist(widget.project.id);
    final terra = RegExp(r'^(0|[ADP]?GND\w*)$');
    final readings = <String, String>{};
    for (final s in (n['sondas'] as List? ?? []).cast<Map<String, dynamic>>()) {
      final id = s['id'] as String;
      if (s['tipo'] == 'i') {
        final i = r.currents['${s['ref']}'.toUpperCase()];
        if (i != null) readings[id] = format(i, 'A');
      } else if (s['rede'] case final String net) {
        final v = r.voltages[net] ?? (terra.hasMatch(net.toUpperCase()) ? 0.0 : null);
        if (v != null) readings[id] = format(v, 'V');
      }
    }
    return readings;
  }

  bool _connect(String series) {
    final freeSlots = [for (var i = 0; i < signalColors.length; i++) i]..removeWhere(_color.values.contains);
    if (freeSlots.isEmpty) return false;
    _color[series] = freeSlots.first;
    return true;
  }

  void _toggle(String series) {
    setState(() {
      if (_color.remove(series) != null) return;
      if (!_connect(series)) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No máximo 8 sinais ao mesmo tempo.')));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final largo = MediaQuery.sizeOf(context).width >= 900;
    final config = _config(context);
    final result = DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(tabs: [Tab(text: 'Resultado'), Tab(text: 'Netlist SPICE')]),
          Expanded(child: TabBarView(children: [_resultArea(context), _netlist(context)])),
        ],
      ),
    );
    return Scaffold(
      appBar: AppBar(title: Text('Simulação · ${widget.project.title}')),
      body: largo
          ? Row(
              children: [
                SizedBox(width: 320, child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: config)),
                const VerticalDivider(width: 1),
                Expanded(child: result),
              ],
            )
          : Column(
              children: [
                ExpansionTile(
                  initiallyExpanded: _result == null,
                  title: Text(_analysis.name),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [config],
                ),
                Expanded(child: result),
              ],
            ),
    );
  }

  Widget _input(String key, String label, String hint) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: TextField(
      controller: _campos[key],
      decoration: InputDecoration(labelText: label, helperText: hint, isDense: true),
    ),
  );

  Widget _config(BuildContext context) => FutureBuilder(
    future: _spice,
    builder: (context, s) {
      final sources = s.data?.sources ?? const <String>[];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Análise', style: Theme.of(context).textTheme.titleSmall),
          RadioGroup<Analysis>(
            groupValue: _analysis,
            onChanged: (a) => setState(() => _analysis = a ?? _analysis),
            child: Column(
              children: [
                for (final a in Analysis.values)
                  RadioListTile<Analysis>(
                    value: a,
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(a.name),
                    subtitle: Text(a.hint),
                  ),
              ],
            ),
          ),
          ...switch (_analysis) {
            Analysis.op => [const Text('Sem parâmetros: calcula o circuito parado (DC).')],
            Analysis.tran => [
              _input('tran.passo', 'Passo', 'ex.: 10u (10 µs)'),
              _input('tran.fim', 'Duração', 'ex.: 10m (10 ms)'),
            ],
            Analysis.ac => [
              _input('ac.pontos', 'Pontos por década', 'ex.: 20'),
              _input('ac.inicio', 'Frequência inicial (Hz)', 'ex.: 10'),
              _input('ac.fim', 'Frequência final (Hz)', 'ex.: 100k'),
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('A fonte de sinal precisa de "AC 1" no valor (ex.: "DC 0 AC 1").'),
              ),
            ],
            Analysis.dc => [
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: DropdownButtonFormField<String>(
                  initialValue: sources.contains(_source) ? _source : null,
                  decoration: const InputDecoration(labelText: 'Fonte varrida', isDense: true),
                  items: [for (final f in sources) DropdownMenuItem(value: f, child: Text(f))],
                  onChanged: (f) => setState(() => _source = f),
                ),
              ),
              _input('dc.inicio', 'De', 'ex.: 0'),
              _input('dc.fim', 'Até', 'ex.: 5'),
              _input('dc.passo', 'Passo', 'ex.: 0.1'),
            ],
          },
          const SizedBox(height: 20),
          if (_running)
            Row(
              spacing: 12,
              children: [
                const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                Expanded(child: Text(switch (_state) { 'fila' => 'Na fila do worker…', 'rodando' => 'ngspice rodando…', _ => 'Preparando…' })),
                TextButton(onPressed: () => _cancel = true, child: const Text('Cancelar')),
              ],
            )
          else
            FilledButton.icon(onPressed: _simulate, icon: const Icon(Icons.play_arrow), label: const Text('Simular')),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          if (s.hasData && s.data!.ignored.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Card(
                child: ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('Avisos da simulação'),
                  subtitle: Text(s.data!.ignored.join('\n')),
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
        child: SelectableText(s.data!.text, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
      );
    },
  );

  Widget _resultArea(BuildContext context) => switch (_result) {
    null => const Center(child: Text('Escolha a análise e toque em Simular.')),
    OperatingPoint r => _multimeter(context, r),
    SimCurves r => _oscilloscope(context, r),
  };

  Widget _multimeter(BuildContext context, OperatingPoint r) {
    Widget table(String title, Map<String, double> valueList, String unit) => Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            for (final e in (valueList.entries.toList()..sort((a, b) => a.key.compareTo(b.key))))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Expanded(child: Text(e.key, style: const TextStyle(fontFamily: 'monospace'))),
                    Text(format(e.value, unit), style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            if (valueList.isEmpty) const Text('—'),
          ],
        ),
      ),
    );
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        table('Tensões nas redes (em relação ao GND)', r.voltages, 'V'),
        table('Correntes', r.currents, 'A'),
      ],
    );
  }

  Widget _oscilloscope(BuildContext context, SimCurves r) {
    final ac = r.analysis == Analysis.ac;
    final visible = [for (final s in r.series.keys) if (_color.containsKey(s)) s];
    final colors = {for (final s in visible) s: signalColors[_color[s]!]};
    List<double> valueList(String s) =>
        ac && _db ? [for (final v in r.series[s]!) v > 0 ? 20 * log(v) / ln10 : double.nan] : r.series[s]!;
    // One quantity per chart: never two y axes.
    final groups = <String, List<String>>{};
    for (final s in visible) {
      groups.putIfAbsent(ac && _db ? 'dB' : SimCurves.unitOf(s), () => []).add(s);
    }
    final legend = Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final s in r.series.keys)
          FilterChip(
            avatar: CircleAvatar(backgroundColor: colors[s] ?? Colors.transparent, radius: 6),
            label: Text(s, style: const TextStyle(fontFamily: 'monospace')),
            selected: colors.containsKey(s),
            showCheckmark: false,
            onSelected: (_) => _toggle(s),
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
              Expanded(child: legend),
              if (ac)
                SegmentedButton<bool>(
                  segments: const [ButtonSegment(value: true, label: Text('dB')), ButtonSegment(value: false, label: Text('V/V'))],
                  selected: {_db},
                  onSelectionChanged: (s) => setState(() => _db = s.first),
                ),
              IconButton(
                tooltip: _table ? 'Ver gráfico' : 'Ver tabela',
                onPressed: () => setState(() => _table = !_table),
                icon: Icon(_table ? Icons.show_chart : Icons.table_rows_outlined),
              ),
            ],
          ),
          if (visible.isEmpty)
            const Expanded(child: Center(child: Text('Escolha um sinal acima.')))
          else if (_table)
            Expanded(child: _curvesTable(r, visible, valueList, ac && _db ? 'dB' : null))
          else
            for (final g in groups.entries)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      switch (g.key) { 'A' => 'Corrente', 'dB' => 'Ganho (dB)', _ => ac ? 'Ganho (V/V)' : 'Tensão' },
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    Expanded(
                      child: CurvesChart(
                        x: r.axis,
                        series: {for (final s in g.value) s: valueList(s)},
                        colors: colors,
                        unitX: r.axisUnit,
                        unitY: g.key == 'dB' ? 'dB' : (ac ? '' : g.key),
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

  /// The same data as a table (at most 200 rows, evenly sampled).
  Widget _curvesTable(SimCurves r, List<String> visible, List<double> Function(String) valueList, String? fixedUnit) {
    final n = r.axis.length;
    final step = max(1, (n / 200).ceil());
    final data = {for (final s in visible) s: valueList(s)};
    return SingleChildScrollView(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: [
            DataColumn(label: Text(r.axisName), numeric: true),
            for (final s in visible) DataColumn(label: Text(s), numeric: true),
          ],
          rows: [
            for (var i = 0; i < n; i += step)
              DataRow(
                cells: [
                  DataCell(Text(format(r.axis[i], r.axisUnit))),
                  for (final s in visible)
                    DataCell(Text(i < data[s]!.length ? format(data[s]![i], fixedUnit ?? SimCurves.unitOf(s)) : '—')),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
