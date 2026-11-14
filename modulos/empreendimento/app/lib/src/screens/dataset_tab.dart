import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../models.dart';
import 'util.dart';

/// Craft Apps dataset (EffectCraft, FilmCraft, PhotoCraft): examples per task × training minimum, bench
/// score without training, LoRA adapters per app and the Google Drive backup state.
class DatasetTab extends StatelessWidget {
  const DatasetTab({super.key, required this.api});

  final ApiEsteira api;

  @override
  Widget build(BuildContext context) => Sondagem<(Json, Json)>(
    intervalo: const Duration(seconds: 30),
    carregar: () async => (await api.dataset(), await api.backup()),
    construir: (context, dados, _) {
      final (d, b) = dados;
      final tasks = [for (final t in d['tarefas'] as List) t as Json];
      final adapters = [for (final a in d['adaptadores'] as List) a as Json];
      final bench = d['bancada'] as Json;
      final promovidos = d['promovidos'] as Json;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Cada geração e cada correção sua nas Craft Apps vira exemplo. Uma tarefa só é treinada quando passa do '
            'mínimo, e o adaptador só entra em uso se ganhar do modelo sem treino na bancada.',
          ),
          const Section('Tarefas'),
          Card(
            child: Column(
              children: [
                for (final t in tasks) _Task(t, bench[t['tarefa']] as Json?),
              ],
            ),
          ),
          const Section('Adaptadores'),
          Card(
            child: Column(
              children: [
                for (final app in promovidos.keys)
                  ListTile(
                    dense: true,
                    title: Text(app),
                    trailing: Text(promovidos[app] == null ? 'sem adaptador em uso' : '${promovidos[app]}'),
                  ),
                for (final a in adapters)
                  ListTile(
                    dense: true,
                    title: Text('${a['nome']} · ${a['casos_treino']} casos'),
                    subtitle: Text(
                      'perda ${a['perda'] ?? '—'} · validação ${a['perda_val'] ?? '—'}'
                      '${a['forcado'] == true ? ' · teste de fumaça' : ''}',
                    ),
                    trailing: Text(a['promovido'] == true ? 'promovido' : 'não promovido'),
                  ),
              ],
            ),
          ),
          _Backup(b),
        ],
      );
    },
  );
}

class _Task extends StatelessWidget {
  const _Task(this.t, this.notes);

  final Json t;
  final Json? notes;

  @override
  Widget build(BuildContext context) {
    final minimum = (t['minimo'] as num?)?.toInt() ?? 0;
    final sft = (t['sft'] as num?)?.toInt() ?? 0;
    final best = notes?.values.map((v) => ((v as Json)['nota'] as num?) ?? 0).fold<num>(0, (a, b) => a > b ? a : b);
    return ListTile(
      dense: true,
      title: Text('${t['tarefa']} · ${t['app']}'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${t['total']} registros · $sft prontos para treino · ${t['dpo_ruim'] ?? 0} negativos · '
            '${t['pendente'] ?? 0} esperando sua revisão',
          ),
          if (minimum > 0) LinearProgressIndicator(value: (sft / minimum).clamp(0, 1).toDouble()),
        ],
      ),
      trailing: Text(
        best == null ? '$sft/$minimum' : '$sft/$minimum\nbancada ${best.toStringAsFixed(2)}',
        textAlign: TextAlign.right,
      ),
    );
  }
}

class _Backup extends StatelessWidget {
  const _Backup(this.b);

  final Json b;

  @override
  Widget build(BuildContext context) {
    final mods = [for (final m in b['modulos'] as List) m as Json];
    final test = b['teste'] as Json?;
    final color = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Section('Backup no Google Drive'),
        if (b['configurado'] != true)
          const Empty('Backup ainda não rodou (infra/scripts/backup).')
        else ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Indicator(
                'Último backup',
                '${b['ultimo'] ?? '—'}'.replaceFirst('T', ' '),
                color: b['atrasado'] == true || (b['erros'] as num? ?? 0) > 0 ? color.error : null,
                sub: '${b['erros']} módulo(s) com erro',
              ),
              Indicator(
                'Teste de restauração',
                test == null ? 'nunca' : '${test['estado']}',
                sub: test == null ? 'mensal, dia 1' : '${test['modulo']} · ${test['fim']}',
                color: test != null && test['estado'] != 'ok' ? color.error : null,
              ),
            ],
          ),
          Card(
            child: Column(
              children: [
                for (final m in mods)
                  ListTile(
                    dense: true,
                    title: Text('${m['modulo']}'),
                    subtitle: m['erro'] == null ? null : Text('${m['erro']}'),
                    trailing: Text(m['horas'] == null ? '${m['estado']}' : 'há ${m['horas']} h'),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
