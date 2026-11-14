import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../modelos.dart';
import 'util.dart';

/// Dataset das Craft Apps (EffectCraft, FilmCraft, PhotoCraft): exemplos por tarefa × mínimo de treino, nota da
/// bancada sem treino, adaptadores LoRA por app e o estado do backup no Google Drive.
class DatasetAba extends StatelessWidget {
  const DatasetAba({super.key, required this.api});

  final ApiEsteira api;

  @override
  Widget build(BuildContext context) => Sondagem<(Json, Json)>(
    intervalo: const Duration(seconds: 30),
    carregar: () async => (await api.dataset(), await api.backup()),
    construir: (context, dados, _) {
      final (d, b) = dados;
      final tarefas = [for (final t in d['tarefas'] as List) t as Json];
      final adaptadores = [for (final a in d['adaptadores'] as List) a as Json];
      final bancada = d['bancada'] as Json;
      final promovidos = d['promovidos'] as Json;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Cada geração e cada correção sua nas Craft Apps vira exemplo. Uma tarefa só é treinada quando passa do '
            'mínimo, e o adaptador só entra em uso se ganhar do modelo sem treino na bancada.',
          ),
          const Secao('Tarefas'),
          Card(
            child: Column(
              children: [
                for (final t in tarefas) _Tarefa(t, bancada[t['tarefa']] as Json?),
              ],
            ),
          ),
          const Secao('Adaptadores'),
          Card(
            child: Column(
              children: [
                for (final app in promovidos.keys)
                  ListTile(
                    dense: true,
                    title: Text(app),
                    trailing: Text(promovidos[app] == null ? 'sem adaptador em uso' : '${promovidos[app]}'),
                  ),
                for (final a in adaptadores)
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

class _Tarefa extends StatelessWidget {
  const _Tarefa(this.t, this.notas);

  final Json t;
  final Json? notas;

  @override
  Widget build(BuildContext context) {
    final minimo = (t['minimo'] as num?)?.toInt() ?? 0;
    final sft = (t['sft'] as num?)?.toInt() ?? 0;
    final melhor = notas?.values.map((v) => ((v as Json)['nota'] as num?) ?? 0).fold<num>(0, (a, b) => a > b ? a : b);
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
          if (minimo > 0) LinearProgressIndicator(value: (sft / minimo).clamp(0, 1).toDouble()),
        ],
      ),
      trailing: Text(
        melhor == null ? '$sft/$minimo' : '$sft/$minimo\nbancada ${melhor.toStringAsFixed(2)}',
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
    final teste = b['teste'] as Json?;
    final cor = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Secao('Backup no Google Drive'),
        if (b['configurado'] != true)
          const Vazio('Backup ainda não rodou (infra/scripts/backup).')
        else ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Indicador(
                'Último backup',
                '${b['ultimo'] ?? '—'}'.replaceFirst('T', ' '),
                cor: b['atrasado'] == true || (b['erros'] as num? ?? 0) > 0 ? cor.error : null,
                sub: '${b['erros']} módulo(s) com erro',
              ),
              Indicador(
                'Teste de restauração',
                teste == null ? 'nunca' : '${teste['estado']}',
                sub: teste == null ? 'mensal, dia 1' : '${teste['modulo']} · ${teste['fim']}',
                cor: teste != null && teste['estado'] != 'ok' ? cor.error : null,
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
