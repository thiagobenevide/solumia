import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../modelos.dart';
import 'grafo.dart';
import 'util.dart';

/// Cada `./dark` pesado, do terminal ou da fila, com as vagas da máquina e do Claude.
class ProcessosAba extends StatelessWidget {
  const ProcessosAba({super.key, required this.api});

  final ApiEsteira api;

  @override
  Widget build(BuildContext context) => Sondagem<Json>(
    intervalo: const Duration(seconds: 5),
    carregar: api.processos,
    construir: (context, d, _) {
      final lista = [for (final p in d['processos'] as List) p as Json];
      final vagas = d['vagas'] as Json;
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
              for (final MapEntry(key: v, value: dono) in vagas.entries)
                SeloEstado(
                  dono == null ? 'ok' : 'rodando',
                  texto:
                      '${v == 'machine' ? 'Máquina (GPU/local)' : 'Claude'}: '
                      '${dono == null ? 'livre' : 'ocupada por ${(dono as Json)['command']}'}',
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (lista.isEmpty) const Vazio('Nenhum processo registrado ainda.'),
          for (final p in lista)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: SeloEstado(estadoDaApi(p['state'])),
                title: Text(
                  './dark ${p['command']} ${(p['args'] as List? ?? const []).join(' ')}',
                  style: const TextStyle(fontFamily: 'monospace'),
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${p['slot'] == 'claude' ? 'Claude' : 'máquina'} · ${p['queue'] != null ? 'fila' : 'terminal'} · '
                  '${diaHora(_data(p['start']))} · ${duracao((p['duration'] as num?)?.toDouble())}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => abrirProcesso(context, api, '${p['id']}'),
              ),
            ),
        ],
      );
    },
  );
}

DateTime? _data(Object? t) => t is num ? DateTime.fromMillisecondsSinceEpoch((t * 1000).round()) : null;

void abrirProcesso(BuildContext context, ApiEsteira api, String id) => abrirTela(context, (_) => ProcessoTela(api: api, id: id));

/// Um processo: estado, o que faz agora (progresso, tarefas, chamada de LLM ao vivo com o texto parcial),
/// caminho pela operação, recursos, chamadas de LLM, eventos e log; parar se estiver rodando.
class ProcessoTela extends StatelessWidget {
  const ProcessoTela({super.key, required this.api, required this.id});

  final ApiEsteira api;
  final String id;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Processo')),
    body: Sondagem<Json>(
      intervalo: const Duration(seconds: 2),
      carregar: () => api.processo(id),
      construir: (context, d, _) {
        final p = d['processo'] as Json;
        final vivo = d['vivo'] as Json?;
        final r = d['recursos'] as Json?;
        final s = (d['resumo'] as Json?) ?? const {};
        final inicio = _data(p['start']);
        final fim = _data(p['end']) ?? DateTime.now();
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
                SeloEstado(estadoDaApi(p['state'])),
                Text(p['slot'] == 'claude' ? 'vaga Claude (em paralelo)' : 'vaga da máquina'),
                Text('motor ${p['engine']}'),
                Text(p['queue'] != null ? 'da fila' : 'do terminal'),
                Text('pid ${p['pid']}'),
                if (inicio != null)
                  Text(
                    'início ${hora(inicio)} · duração ${duracao(fim.difference(inicio).inSeconds.toDouble())}',
                  ),
                if ('${p['error'] ?? ''}'.isNotEmpty)
                  Text('${p['error']}', style: const TextStyle(color: Colors.redAccent)),
                if (p['state'] == 'running')
                  OutlinedButton.icon(
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('Parar processo'),
                    onPressed: () => _parar(context),
                  ),
              ],
            ),
            if (vivo != null) ...[const Secao('Agora'), _Agora(vivo)],
            const Secao('Caminho pela operação'),
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
                        '${n['nome'] ?? n['no']}${n['seg'] != null ? ' · ${duracao((n['seg'] as num).toDouble())}' : ''}',
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const Secao('Recursos e LLM'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Indicador('CPU', r == null ? '—' : '${(r['cpu'] as num).toStringAsFixed(0)}%'),
                Indicador('RAM', r == null ? '—' : '${r['ram_mb']} MB'),
                Indicador('VRAM', r == null ? '—' : '${r['vram_mb']} MB'),
                Indicador(
                  'Chamadas',
                  '${s['chamadas'] ?? 0}',
                  sub: (s['falhas'] ?? 0) > 0 ? '${s['falhas']} falhas' : null,
                ),
                Indicador('Do cache', '${s['cache'] ?? 0}'),
                Indicador('Tokens gerados', '${s['tokens_saida'] ?? 0}'),
                Indicador('Tempo em LLM', duracao((s['seg_llm'] as num?)?.toDouble() ?? 0)),
                Indicador('Claude', dolares(s['custo_usd'] as num?, casas: 4)),
              ],
            ),
            Secao('Chamadas de LLM (últimas ${(d['chamadas'] as List).length})'),
            for (final c in (d['chamadas'] as List).cast<Json>().take(30)) ChamadaLlm(c),
            const Secao('Eventos'),
            for (final e in (d['eventos'] as List).cast<Json>().take(80))
              Text(
                '${'${e['t']}'.length >= 19 ? '${e['t']}'.substring(11, 19) : e['t']}  ${e['stage']}  ${e['kind']}  ${e['message']}',
                style: mono,
              ),
            const Secao('Log'),
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

  Future<void> _parar(BuildContext context) async {
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
      await acaoComAviso(context, () async {
        await api.pararProcesso(id);
        return 'Processo parado.';
      });
    }
  }
}

/// O que o processo faz agora: passo, progresso, tarefas com tamanho e a chamada de LLM ao vivo.
class _Agora extends StatelessWidget {
  const _Agora(this.v);

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
                '${g['message'] ?? ''} · ${g['i']}/${g['n']}${g['remaining'] != null ? ' · resta ${duracao((g['remaining'] as num).toDouble())}' : ''}',
              ),
              LinearProgressIndicator(
                value: (g['n'] as num? ?? 0) > 0 ? (g['i'] as num) / (g['n'] as num) : null,
              ),
            ],
            for (final t in ((v['tasks'] as Json?) ?? const {}).values.cast<Json>()) ...[
              Text(
                '${t['label']} · ${_tam(t['done'], t['unit'])}${t['total'] != null ? ' / ${_tam(t['total'], t['unit'])}' : ''}',
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

  static String _tam(Object? v, Object? unidade) => unidade == 'bytes' && v is num
      ? '${(v / (1 << 20)).toStringAsFixed(1)} MB'
      : '$v${unidade != null ? ' $unidade' : ''}';
}
