import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../models.dart';
import 'graph.dart';
import 'util.dart';

/// Each heavy `./dark`, from the terminal or the queue, with the machine and Claude slots.
class ProcessesTab extends StatelessWidget {
  const ProcessesTab({super.key, required this.api});

  final ApiEsteira api;

  @override
  Widget build(BuildContext context) => Sondagem<Json>(
    intervalo: const Duration(seconds: 5),
    carregar: api.processes,
    construir: (context, d, _) {
      final list = [for (final p in d['processos'] as List) p as Json];
      final slots = d['vagas'] as Json;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Cada ./dark pesado, do terminal ou da fila. Abra um para ver só ele: o que faz agora, por onde passou, '
            'chamadas de LLM, eventos e log.',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final MapEntry(key: v, value: owner) in slots.entries)
                StatePill(
                  owner == null ? 'ok' : 'rodando',
                  texto:
                      '${v == 'machine' ? 'Máquina (GPU/local)' : 'Claude'}: '
                      '${owner == null ? 'livre' : 'ocupada por ${(owner as Json)['command']}'}',
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (list.isEmpty) const Empty('Nenhum processo registrado ainda.'),
          for (final p in list)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: StatePill(apiState(p['state'])),
                title: Text(
                  './dark ${p['command']} ${(p['args'] as List? ?? const []).join(' ')}',
                  style: const TextStyle(fontFamily: 'monospace'),
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${p['slot'] == 'claude' ? 'Claude' : 'máquina'} · ${p['queue'] != null ? 'fila' : 'terminal'} · '
                  '${dayHour(_data(p['start']))} · ${duration((p['duration'] as num?)?.toDouble())}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openProcess(context, api, '${p['id']}'),
              ),
            ),
        ],
      );
    },
  );
}

DateTime? _data(Object? t) => t is num ? DateTime.fromMillisecondsSinceEpoch((t * 1000).round()) : null;

void openProcess(BuildContext context, ApiEsteira api, String id) => abrirTela(context, (_) => ProcessScreen(api: api, id: id));

/// One process: state, what it does now (progress, tasks, live LLM call with the partial text),
/// path through the operation, resources, LLM calls, events and log; stop it if it is running.
class ProcessScreen extends StatelessWidget {
  const ProcessScreen({super.key, required this.api, required this.id});

  final ApiEsteira api;
  final String id;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Processo')),
    body: Sondagem<Json>(
      intervalo: const Duration(seconds: 2),
      carregar: () => api.process(id),
      construir: (context, d, _) {
        final p = d['processo'] as Json;
        final live = d['vivo'] as Json?;
        final r = d['recursos'] as Json?;
        final s = (d['resumo'] as Json?) ?? const {};
        final start = _data(p['start']);
        final end = _data(p['end']) ?? DateTime.now();
        const mono = TextStyle(fontFamily: 'monospace', fontSize: 12);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SelectableText(
              './dark ${p['command']} ${(p['args'] as List? ?? const []).join(' ')}',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontFamily: 'monospace'),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                StatePill(apiState(p['state'])),
                Text(p['slot'] == 'claude' ? 'vaga Claude (em paralelo)' : 'vaga da máquina'),
                Text('motor ${p['engine']}'),
                Text(p['queue'] != null ? 'da fila' : 'do terminal'),
                Text('pid ${p['pid']}'),
                if (start != null)
                  Text(
                    'início ${hour(start)} · duração ${duration(end.difference(start).inSeconds.toDouble())}',
                  ),
                if ('${p['error'] ?? ''}'.isNotEmpty)
                  Text('${p['error']}', style: const TextStyle(color: Colors.redAccent)),
                if (p['state'] == 'running')
                  OutlinedButton.icon(
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('Parar processo'),
                    onPressed: () => _stop(context),
                  ),
              ],
            ),
            if (live != null) ...[const Section('Agora'), _Now(live)],
            const Section('Caminho pela operação'),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if ((d['caminho'] as List).isEmpty)
                  const Text('Sem passos registrados (processo antigo ou etapa sem rastro).'),
                for (final (i, n) in (d['caminho'] as List).cast<Json>().indexed) ...[
                  if (i > 0) const Icon(Icons.arrow_forward, size: 14),
                  Tooltip(
                    message: '${n['detalhe'] ?? ''}',
                    child: Chip(
                      label: Text(
                        '${n['nome'] ?? n['no']}${n['seg'] != null ? ' · ${duration((n['seg'] as num).toDouble())}' : ''}',
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const Section('Recursos e LLM'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Indicator('CPU', r == null ? '—' : '${(r['cpu'] as num).toStringAsFixed(0)}%'),
                Indicator('RAM', r == null ? '—' : '${r['ram_mb']} MB'),
                Indicator('VRAM', r == null ? '—' : '${r['vram_mb']} MB'),
                Indicator(
                  'Chamadas',
                  '${s['chamadas'] ?? 0}',
                  sub: (s['falhas'] ?? 0) > 0 ? '${s['falhas']} falhas' : null,
                ),
                Indicator('Do cache', '${s['cache'] ?? 0}'),
                Indicator('Tokens gerados', '${s['tokens_saida'] ?? 0}'),
                Indicator('Tempo em LLM', duration((s['seg_llm'] as num?)?.toDouble() ?? 0)),
                Indicator('Claude', dollars(s['custo_usd'] as num?, places: 4)),
              ],
            ),
            Section('Chamadas de LLM (últimas ${(d['chamadas'] as List).length})'),
            for (final c in (d['chamadas'] as List).cast<Json>().take(30)) LlmCall(c),
            const Section('Eventos'),
            for (final e in (d['eventos'] as List).cast<Json>().take(80))
              Text(
                '${'${e['t']}'.length >= 19 ? '${e['t']}'.substring(11, 19) : e['t']}  ${e['stage']}  ${e['kind']}  ${e['message']}',
                style: mono,
              ),
            const Section('Log'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  (d['log'] as List).isEmpty ? '(sem log)' : (d['log'] as List).join('\n'),
                  style: mono,
                ),
              ),
            ),
          ],
        );
      },
    ),
  );

  Future<void> _stop(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Parar este processo e tudo o que ele abriu?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Voltar')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Parar')),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await actionWithWarning(context, () async {
        await api.stopProcess(id);
        return 'Processo parado.';
      });
    }
  }
}

/// What the process does now: step, progress, tasks with size and the live LLM call.
class _Now extends StatelessWidget {
  const _Now(this.v);

  final Json v;

  @override
  Widget build(BuildContext context) {
    final g = v['progress'] as Json?;
    final c = v['call'] as Json?;
    final agora = DateTime.now().millisecondsSinceEpoch / 1000;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 10,
          children: [
            Text('${v['nome'] ?? v['node'] ?? ''}', style: Theme.of(context).textTheme.titleMedium),
            if ('${v['detail'] ?? ''}'.isNotEmpty) Text('${v['detail']}'),
            if (g != null) ...[
              Text(
                '${g['message'] ?? ''} · ${g['i']}/${g['n']}${g['remaining'] != null ? ' · resta ${duration((g['remaining'] as num).toDouble())}' : ''}',
              ),
              LinearProgressIndicator(
                value: (g['n'] as num? ?? 0) > 0 ? (g['i'] as num) / (g['n'] as num) : null,
              ),
            ],
            for (final t in ((v['tasks'] as Json?) ?? const {}).values.cast<Json>()) ...[
              Text(
                '${t['label']} · ${_size(t['done'], t['unit'])}${t['total'] != null ? ' / ${_size(t['total'], t['unit'])}' : ''}',
              ),
              LinearProgressIndicator(
                value: t['total'] != null && (t['total'] as num) > 0
                    ? (t['done'] as num) / (t['total'] as num)
                    : null,
              ),
            ],
            if (c != null) ...[
              Text(
                '${c['engine']} · ${c['name']} · ${c['model']} — ${c['tokens'] ?? 0}'
                '${c['params'] is Map && (c['params'] as Map)['num_predict'] != null ? '/${(c['params'] as Map)['num_predict']}' : ''} tokens · '
                '${c['first'] != null && agora - (c['first'] as num) > 0.5 ? '${((c['tokens'] ?? 0) / (agora - (c['first'] as num))).toStringAsFixed(1)} tok/s' : (c['engine'] == 'claude' ? 'aguardando o Claude' : 'lendo o prompt')}',
              ),
              Container(
                constraints: const BoxConstraints(maxHeight: 200),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(8)),
                child: SingleChildScrollView(
                  reverse: true,
                  child: Text(
                    '${c['partial'] ?? '…'}',
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _size(Object? v, Object? unit) => unit == 'bytes' && v is num
      ? '${(v / (1 << 20)).toStringAsFixed(1)} MB'
      : '$v${unit != null ? ' $unit' : ''}';
}
