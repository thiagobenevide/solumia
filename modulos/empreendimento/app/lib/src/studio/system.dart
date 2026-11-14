import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../models.dart';
import '../screens/util.dart';

/// Render engine dependencies (install with one button) and the LLM bench (which local model plays each role).
class SystemScreen extends StatelessWidget {
  const SystemScreen({super.key, required this.api});

  final ApiEsteira api;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Estúdio · motor e IA local')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Sondagem<Json>(
          intervalo: const Duration(seconds: 10),
          carregar: api.dependencies,
          construir: (context, d, _) {
            Widget item(String label, Object? v) => ListTile(
              dense: true,
              leading: Icon(v != null && v != false ? Icons.check_circle : Icons.error_outline,
                  color: v != null && v != false ? Colors.green : Colors.orange),
              title: Text(label),
              subtitle: Text(v is String ? v : (v == true ? 'ok' : 'falta')),
            );
            final missing = [d['node'], d['pacotes'], d['chromium'], d['ffmpeg'], d['opencv']].any((v) => v == null || v == false);
            return Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const ListTile(title: Text('Motor de render (HyperFrames)')),
                  item('Node', d['node']),
                  item('HyperFrames e Playwright', d['pacotes']),
                  item('Chromium', d['chromium']),
                  item('ffmpeg', d['ffmpeg']),
                  item('OpenCV (rosto do apresentador)', d['opencv']),
                  item('llama.cpp', d['llama']),
                  item('Modelo de texto', d['modelo_texto']),
                  item('Modelo de visão', d['modelo_visao']),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: FilledButton.icon(
                      icon: const Icon(Icons.download),
                      label: Text(missing ? 'Instalar o que falta' : 'Tudo instalado'),
                      onPressed: missing
                          ? () => actionWithWarning(context, () async {
                              await api.installDependencies();
                              return 'Instalação na fila (acompanhe em Processos)';
                            })
                          : null,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        const Section('Bancada de LLM'),
        Sondagem<Json>(
          intervalo: const Duration(seconds: 30),
          carregar: api.bench,
          construir: (context, b, _) {
            final res = b['resultado'] as Json?;
            final tasks = (b['gabarito'] as Json).keys.toList();
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Gabarito: ${(b['gabarito'] as Json).entries.map((e) => '${e.key} ${e.value}').join(' · ')}'),
                    const SizedBox(height: 8),
                    if (res == null)
                      const Text('Nenhuma rodada ainda.')
                    else
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: DataTable(
                          columns: [
                            const DataColumn(label: Text('modelo')),
                            const DataColumn(label: Text('VRAM')),
                            for (final t in tasks) DataColumn(label: Text(t)),
                          ],
                          rows: [
                            for (final m in (res['modelos'] as Json).entries)
                              DataRow(
                                cells: [
                                  DataCell(Text(m.key)),
                                  DataCell(Text('${(m.value as Json)['vram_gb'] ?? '—'} GB')),
                                  for (final t in tasks)
                                    DataCell(Text(_note(((m.value as Json)['tarefas'] as Json)[t] as Json?))),
                                ],
                              ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 8),
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.speed),
                      label: const Text('Rodar a bancada (todos os modelos)'),
                      onPressed: () => actionWithWarning(context, () async {
                        await api.runBench();
                        return 'Bancada na fila (usa a GPU)';
                      }),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        const Section('Base de treino (fine-tune do modelo local)'),
        Sondagem<Json>(
          intervalo: const Duration(seconds: 30),
          carregar: api.training,
          construir: (context, t, recarregar) {
            final cases = t['casos'] as Json;
            final minimum = t['minimo'] as Json;
            final last = t['ultima'] as Json?;
            final environment = t['ambiente'] == true;
            final pronta = cases.entries.any((e) => (e.value as num) >= (minimum[e.key] as num));
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final e in cases.entries)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            SizedBox(width: 110, child: Text(e.key)),
                            Expanded(
                              child: LinearProgressIndicator(
                                value: ((e.value as num) / (minimum[e.key] as num)).clamp(0, 1).toDouble(),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text('${e.value}/${minimum[e.key]}'),
                          ],
                        ),
                      ),
                    const SizedBox(height: 8),
                    Text(last == null
                        ? 'Nenhuma exportação ainda.'
                        : 'Última exportação: ${last['em']} '
                              '(${(last['tarefas'] as Json).entries.map((e) => '${e.key} ${(e.value as Json)['treino']}+${(e.value as Json)['validacao']}').join(' · ')})'),
                    if (!environment)
                      const Text('Ambiente de treino ausente (.venv-treino com unsloth).',
                          style: TextStyle(color: Colors.orange)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton.tonalIcon(
                          icon: const Icon(Icons.save_alt),
                          label: const Text('Exportar a base'),
                          onPressed: () => actionWithWarning(context, () async {
                            final r = await api.exportTraining();
                            recarregar();
                            return 'Base exportada em ${r['pasta']}';
                          }),
                        ),
                        FilledButton.icon(
                          icon: const Icon(Icons.model_training),
                          label: const Text('Treinar LoRA (GPU, horas)'),
                          onPressed: environment && last != null && pronta
                              ? () => actionWithWarning(context, () async {
                                  await api.trainLora();
                                  return 'Treino na fila; o modelo novo aparece em Opções';
                                })
                              : null,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    ),
  );

  static String _note(Json? t) {
    if (t == null) return '—';
    final n = (t['balanceada'] ?? t['nota']) as num;
    return '${n.toStringAsFixed(2)} · ${t['ms']} ms';
  }
}
