import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../models.dart';
import 'graph.dart';
import 'processes_tab.dart';
import 'time_series.dart';
import 'util.dart';

/// Machine monitor, like the panel's Monitor page: operation graph, GPU/CPU/memory/
/// llama.cpp/power cards, series of the last 10 min, esteira processes (with the log), helper programs,
/// fila e arquivos alterados.
class MonitorTab extends StatelessWidget {
  const MonitorTab({super.key, required this.api});

  final ApiEsteira api;

  @override
  Widget build(BuildContext context) => Sondagem<Machine>(
    intervalo: const Duration(seconds: 2),
    carregar: api.machine,
    construir: (context, m, _) => ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Section(
          'Grafo da operação',
          acao: TextButton.icon(
            icon: const Icon(Icons.list_alt, size: 18),
            label: const Text('Processos'),
            onPressed: () => abrirTela(context, (_) => Scaffold(
                  appBar: AppBar(title: const Text('Processos')),
                  body: ProcessesTab(api: api),
                )),
          ),
        ),
        const Text('Toque num nó para ver como funciona, as chamadas de LLM e as métricas. Arraste para mover, roda para zoom.'),
        const SizedBox(height: 8),
        SizedBox(height: 460, child: OperationGraph(api: api)),
        if (m.collecting)
          ..._body(context, m)
        else
          const Empty('O monitor do painel está começando a coletar…', icone: Icons.sensors),
      ],
    ),
  );

  static double _n(Object? v) => v is num ? v.toDouble() : 0;

  List<Widget> _body(BuildContext context, Machine m) {
    final gpu = m.gpu, cpu = m.cpu, ram = m.ram, e = m.energia;
    List<(num, num?)> series(String k) => [for (final h in m.history) (h['t'] as num, h[k] as num?)];
    return [
      const Section('Máquina'),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          if (gpu != null)
            _Card(
              titulo: 'GPU',
              subtitulo: '${gpu['nome']}',
              icone: Icons.memory,
              lines: [
                _bar('Uso', _n(gpu['uso']), 100, '%'),
                _bar('VRAM', _n(gpu['vram_mb']) / 1024, _n(gpu['vram_total_mb']) / 1024, ' GB'),
                _bar('Potência', _n(gpu['watts']), _n(gpu['limite_w']), ' W'),
                _text('Temperatura', '${gpu['temp'] ?? '—'} °C', alert: _n(gpu['temp']) >= 83),
                _text('Ventoinha · clock', '${gpu['ventoinha'] ?? '—'}% · ${gpu['clock_mhz'] ?? '—'} MHz'),
              ],
            ),
          if (cpu != null)
            _Card(
              titulo: 'CPU',
              subtitulo: '${cpu['nucleos']} núcleos',
              icone: Icons.developer_board,
              lines: [
                _bar('Uso', _n(cpu['uso']), 100, '%'),
                _text(
                  'Temperatura',
                  cpu['temp'] == null ? '—' : '${cpu['temp']} °C',
                  alert: _n(cpu['temp']) >= 83,
                ),
                _text('Potência', cpu['watts'] == null ? '—' : '${cpu['watts']} W'),
              ],
            ),
          if (ram != null)
            _Card(
              titulo: 'Memória',
              icone: Icons.storage,
              lines: [_bar('RAM', _n(ram['usada_gb']), _n(ram['total_gb']), ' GB')],
            ),
          _Card(
            titulo: 'llama.cpp',
            subtitulo: 'modelos na VRAM',
            icone: Icons.psychology_outlined,
            lines: [
              if (m.ollama.isEmpty) _text('', 'nenhum modelo carregado'),
              for (final mod in m.ollama) _text('${mod['modelo']}', '${mod['vram_gb']} GB'),
            ],
          ),
          _Card(
            titulo: 'Energia',
            subtitulo: 'desde que o painel subiu',
            icone: Icons.bolt,
            lines: [
              _text(
                'Consumo',
                '${e['kwh'] ?? 0} kWh (GPU ${e['gpu_wh'] ?? 0} Wh · CPU ${e['cpu_wh'] ?? 0} Wh)',
              ),
              _text('Custo', 'R\$ ${e['reais'] ?? 0} (R\$ ${e['tarifa'] ?? '—'}/kWh)'),
              _text('Tempo', '${e['horas'] ?? 0} h'),
            ],
          ),
        ],
      ),
      const Section('Últimos 10 minutos'),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 24,
            runSpacing: 16,
            children: [
              for (final (titulo, chave, unit, maximum) in const [
                ('GPU · uso', 'gpu_uso', '%', 100.0),
                ('GPU · temperatura', 'gpu_temp', '°C', 100.0),
                ('GPU · potência', 'gpu_w', 'W', null),
                ('CPU · uso', 'cpu_uso', '%', 100.0),
                ('CPU · temperatura', 'cpu_temp', '°C', 100.0),
                ('CPU · potência', 'cpu_w', 'W', null),
              ])
                SizedBox(
                  width: 300,
                  child: TimeSeries(
                    titulo: titulo,
                    unit: unit,
                    points: series(chave),
                    maximum: maximum,
                  ),
                ),
            ],
          ),
        ),
      ),
      const Section('Processos da esteira agora'),
      if (m.esteira.isEmpty) const Text('Nenhum processo da esteira rodando.'),
      for (final p in m.esteira) _LiveProcess(p),
      const Section('Programas auxiliares'),
      Card(
        child: Column(
          children: [
            if (m.groups.isEmpty) const ListTile(title: Text('Nenhum.')),
            for (final g in m.groups)
              ListTile(
                dense: true,
                leading: EnginePill('${g['motor']}'),
                title: Text('${g['rotulo']}${(g['n'] as num? ?? 1) > 1 ? ' ×${g['n']}' : ''}'),
                // metrics in the subtitle: in the trailing they squeezed the name on the phone
                subtitle: Text('CPU ${g['cpu']}% · RAM ${g['ram_mb']} MB · VRAM ${g['vram_mb']} MB'),
              ),
          ],
        ),
      ),
      const Section('Fila do painel'),
      Card(
        child: Column(
          children: [
            if (m.queue.isEmpty) const ListTile(title: Text('Fila vazia.')),
            for (final t in m.queue)
              ListTile(dense: true, leading: StatePill(t.state), title: Text('${t.command} ${t.ep}')),
          ],
        ),
      ),
      const Section('Arquivos alterados (15 min)'),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: m.files.isEmpty
              ? const Text('Nenhum.')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final a in m.files.take(60))
                      Text(
                        '${_ha(a['seg'] as num?)}  ${a['caminho']}',
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      ),
                  ],
                ),
        ),
      ),
    ];
  }

  static String _ha(num? s) => s == null
      ? ''
      : s < 60
      ? 'há ${s.round()}s'
      : 'há ${(s / 60).round()} min';

  static Widget _bar(String label, double valor, double maximum, String unit) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 4,
    children: [
      _text(label, '${valor.toStringAsFixed(valor < 10 ? 1 : 0)} / ${maximum.toStringAsFixed(0)}$unit'),
      LinearProgressIndicator(value: maximum > 0 ? (valor / maximum).clamp(0, 1) : null),
    ],
  );

  static Widget _text(String label, String valor, {bool alert = false}) => Row(
    children: [
      Expanded(child: Text(label)),
      Flexible(
        child: Text(
          valor,
          textAlign: TextAlign.right,
          style: TextStyle(
            fontFeatures: const [FontFeature.tabularFigures()],
            color: alert ? Colors.redAccent : null,
          ),
        ),
      ),
    ],
  );
}

class _LiveProcess extends StatelessWidget {
  const _LiveProcess(this.p);

  final Json p;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 8),
    child: ExpansionTile(
      leading: EnginePill('${p['motor']}'),
      title: Text('./dark ${p['comando']}', style: const TextStyle(fontFamily: 'monospace')),
      subtitle: Text('pid ${p['pid']} · CPU ${p['cpu']}% · RAM ${p['ram_mb']} MB · VRAM ${p['vram_mb']} MB'),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final l in p['linhas'] as List? ?? const [])
          Text('$l', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
      ],
    ),
  );
}

class _Card extends StatelessWidget {
  const _Card({required this.titulo, this.subtitulo, required this.icone, required this.lines});

  final String titulo;
  final String? subtitulo;
  final IconData icone;
  final List<Widget> lines;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 340,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 10,
          children: [
            Row(
              spacing: 8,
              children: [
                Icon(icone),
                Text(titulo, style: Theme.of(context).textTheme.titleMedium),
                if (subtitulo != null)
                  Expanded(
                    child: Text(
                      subtitulo!,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
            ...lines,
          ],
        ),
      ),
    ),
  );
}
