import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../modelos.dart';
import 'grafo.dart';
import 'processos_aba.dart';
import 'serie_temporal.dart';
import 'util.dart';

/// Monitor da máquina, como a página Monitor do painel: grafo da operação, cartões de GPU/CPU/memória/
/// llama.cpp/energia, séries dos últimos 10 min, processos da esteira (com o log), programas auxiliares,
/// fila e arquivos alterados.
class MonitorAba extends StatelessWidget {
  const MonitorAba({super.key, required this.api});

  final ApiEsteira api;

  @override
  Widget build(BuildContext context) => Sondagem<Maquina>(
    intervalo: const Duration(seconds: 2),
    carregar: api.maquina,
    construir: (context, m, _) => ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Secao(
          'Grafo da operação',
          acao: TextButton.icon(
            icon: const Icon(Icons.list_alt, size: 18),
            label: const Text('Processos'),
            onPressed: () => abrirTela(context, (_) => Scaffold(
                  appBar: AppBar(title: const Text('Processos')),
                  body: ProcessosAba(api: api),
                )),
          ),
        ),
        const Text('Toque num nó para ver como funciona, as chamadas de LLM e as métricas. Arraste para mover, roda para zoom.'),
        const SizedBox(height: 8),
        SizedBox(height: 460, child: GrafoOperacao(api: api)),
        if (m.coletando)
          ..._corpo(context, m)
        else
          const Vazio('O monitor do painel está começando a coletar…', icone: Icons.sensors),
      ],
    ),
  );

  static double _n(Object? v) => v is num ? v.toDouble() : 0;

  List<Widget> _corpo(BuildContext context, Maquina m) {
    final gpu = m.gpu, cpu = m.cpu, ram = m.ram, e = m.energia;
    List<(num, num?)> serie(String k) => [for (final h in m.historico) (h['t'] as num, h[k] as num?)];
    return [
      const Secao('Máquina'),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          if (gpu != null)
            _Cartao(
              titulo: 'GPU',
              subtitulo: '${gpu['nome']}',
              icone: Icons.memory,
              linhas: [
                _barra('Uso', _n(gpu['uso']), 100, '%'),
                _barra('VRAM', _n(gpu['vram_mb']) / 1024, _n(gpu['vram_total_mb']) / 1024, ' GB'),
                _barra('Potência', _n(gpu['watts']), _n(gpu['limite_w']), ' W'),
                _texto('Temperatura', '${gpu['temp'] ?? '—'} °C', alerta: _n(gpu['temp']) >= 83),
                _texto('Ventoinha · clock', '${gpu['ventoinha'] ?? '—'}% · ${gpu['clock_mhz'] ?? '—'} MHz'),
              ],
            ),
          if (cpu != null)
            _Cartao(
              titulo: 'CPU',
              subtitulo: '${cpu['nucleos']} núcleos',
              icone: Icons.developer_board,
              linhas: [
                _barra('Uso', _n(cpu['uso']), 100, '%'),
                _texto(
                  'Temperatura',
                  cpu['temp'] == null ? '—' : '${cpu['temp']} °C',
                  alerta: _n(cpu['temp']) >= 83,
                ),
                _texto('Potência', cpu['watts'] == null ? '—' : '${cpu['watts']} W'),
              ],
            ),
          if (ram != null)
            _Cartao(
              titulo: 'Memória',
              icone: Icons.storage,
              linhas: [_barra('RAM', _n(ram['usada_gb']), _n(ram['total_gb']), ' GB')],
            ),
          _Cartao(
            titulo: 'llama.cpp',
            subtitulo: 'modelos na VRAM',
            icone: Icons.psychology_outlined,
            linhas: [
              if (m.ollama.isEmpty) _texto('', 'nenhum modelo carregado'),
              for (final mod in m.ollama) _texto('${mod['modelo']}', '${mod['vram_gb']} GB'),
            ],
          ),
          _Cartao(
            titulo: 'Energia',
            subtitulo: 'desde que o painel subiu',
            icone: Icons.bolt,
            linhas: [
              _texto(
                'Consumo',
                '${e['kwh'] ?? 0} kWh (GPU ${e['gpu_wh'] ?? 0} Wh · CPU ${e['cpu_wh'] ?? 0} Wh)',
              ),
              _texto('Custo', 'R\$ ${e['reais'] ?? 0} (R\$ ${e['tarifa'] ?? '—'}/kWh)'),
              _texto('Tempo', '${e['horas'] ?? 0} h'),
            ],
          ),
        ],
      ),
      const Secao('Últimos 10 minutos'),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 24,
            runSpacing: 16,
            children: [
              for (final (titulo, chave, unidade, maximo) in const [
                ('GPU · uso', 'gpu_uso', '%', 100.0),
                ('GPU · temperatura', 'gpu_temp', '°C', 100.0),
                ('GPU · potência', 'gpu_w', 'W', null),
                ('CPU · uso', 'cpu_uso', '%', 100.0),
                ('CPU · temperatura', 'cpu_temp', '°C', 100.0),
                ('CPU · potência', 'cpu_w', 'W', null),
              ])
                SizedBox(
                  width: 300,
                  child: SerieTemporal(
                    titulo: titulo,
                    unidade: unidade,
                    pontos: serie(chave),
                    maximo: maximo,
                  ),
                ),
            ],
          ),
        ),
      ),
      const Secao('Processos da esteira agora'),
      if (m.esteira.isEmpty) const Text('Nenhum processo da esteira rodando.'),
      for (final p in m.esteira) _ProcessoVivo(p),
      const Secao('Programas auxiliares'),
      Card(
        child: Column(
          children: [
            if (m.grupos.isEmpty) const ListTile(title: Text('Nenhum.')),
            for (final g in m.grupos)
              ListTile(
                dense: true,
                leading: SeloMotor('${g['motor']}'),
                title: Text('${g['rotulo']}${(g['n'] as num? ?? 1) > 1 ? ' ×${g['n']}' : ''}'),
                // métricas no subtítulo: no trailing elas espremiam o nome no celular
                subtitle: Text('CPU ${g['cpu']}% · RAM ${g['ram_mb']} MB · VRAM ${g['vram_mb']} MB'),
              ),
          ],
        ),
      ),
      const Secao('Fila do painel'),
      Card(
        child: Column(
          children: [
            if (m.fila.isEmpty) const ListTile(title: Text('Fila vazia.')),
            for (final t in m.fila)
              ListTile(dense: true, leading: SeloEstado(t.estado), title: Text('${t.comando} ${t.ep}')),
          ],
        ),
      ),
      const Secao('Arquivos alterados (15 min)'),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: m.arquivos.isEmpty
              ? const Text('Nenhum.')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final a in m.arquivos.take(60))
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

  static Widget _barra(String rotulo, double valor, double maximo, String unidade) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 4,
    children: [
      _texto(rotulo, '${valor.toStringAsFixed(valor < 10 ? 1 : 0)} / ${maximo.toStringAsFixed(0)}$unidade'),
      LinearProgressIndicator(value: maximo > 0 ? (valor / maximo).clamp(0, 1) : null),
    ],
  );

  static Widget _texto(String rotulo, String valor, {bool alerta = false}) => Row(
    children: [
      Expanded(child: Text(rotulo)),
      Flexible(
        child: Text(
          valor,
          textAlign: TextAlign.right,
          style: TextStyle(
            fontFeatures: const [FontFeature.tabularFigures()],
            color: alerta ? Colors.redAccent : null,
          ),
        ),
      ),
    ],
  );
}

class _ProcessoVivo extends StatelessWidget {
  const _ProcessoVivo(this.p);

  final Json p;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 8),
    child: ExpansionTile(
      leading: SeloMotor('${p['motor']}'),
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

class _Cartao extends StatelessWidget {
  const _Cartao({required this.titulo, this.subtitulo, required this.icone, required this.linhas});

  final String titulo;
  final String? subtitulo;
  final IconData icone;
  final List<Widget> linhas;

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
            ...linhas,
          ],
        ),
      ),
    ),
  );
}
