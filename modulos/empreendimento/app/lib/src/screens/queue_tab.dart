import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../models.dart';
import 'processes_tab.dart';
import 'util.dart';

/// Production queue: two slots (machine and Claude) and the tasks, newest to oldest.
class QueueTab extends StatelessWidget {
  const QueueTab({super.key, required this.api});

  final ApiEsteira api;

  @override
  Widget build(BuildContext context) => Sondagem<ProductionQueue>(
    intervalo: const Duration(seconds: 2),
    carregar: api.queue,
    construir: (context, queue, recarregar) => ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final MapEntry(key: slot, value: owner) in queue.slots.entries)
              StatePill(owner == null ? 'livre' : 'rodando', texto: '${slot == 'machine' ? 'máquina' : slot}: ${owner ?? 'livre'}'),
            TextButton.icon(
              icon: const Icon(Icons.cleaning_services_outlined),
              label: const Text('Limpar concluídas'),
              onPressed: () => actionWithWarning(context, () async {
                await api.cleanQueue();
                await recarregar();
                return 'Concluídas removidas da fila.';
              }),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _GenerateScript(api: api),
        const SizedBox(height: 12),
        if (queue.tasks.isEmpty) const Empty('Fila vazia.'),
        for (final t in queue.tasks) _TaskLine(api: api, t: t, recarregar: recarregar),
      ],
    ),
  );
}

class _TaskLine extends StatelessWidget {
  const _TaskLine({required this.api, required this.t, required this.recarregar});

  final ApiEsteira api;
  final Task t;
  final Future<void> Function() recarregar;

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final end = t.end ?? DateTime.now();
    final p = t.prog;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: t.process == null ? null : () => openProcess(context, api, t.process!),
        leading: Icon(iconOfState(t.state), color: corDoEstado(cores, t.state)),
        title: Text('${t.command} ${t.ep} ${t.args.join(' ')}'.trim()),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 4,
          children: [
            Text(
              [
                t.state,
                'vaga ${t.slot == 'machine' ? 'máquina' : t.slot}',
                'criada ${dayHour(t.created)}',
                if (t.start != null) 'duração ${duration(end.difference(t.start!).inSeconds.toDouble())}',
              ].join(' · '),
            ),
            if (t.state == 'rodando' && p != null) ...[
              LinearProgressIndicator(value: p.fraction),
              Text('${p.rodando ?? ''} · ${p.doneSteps}/${p.total} etapas'),
            ],
          ],
        ),
        trailing: t.active
            ? IconButton(
                tooltip: 'Cancelar',
                icon: const Icon(Icons.stop_circle_outlined),
                onPressed: () => _cancel(context),
              )
            : null,
      ),
    );
  }

  Future<void> _cancel(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancelar tarefa?'),
        content: Text(
          t.state == 'rodando'
              ? '“${t.command} ${t.ep}” está rodando e será interrompida.'
              : '“${t.command} ${t.ep}” sai da fila.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Voltar')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Cancelar tarefa')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await actionWithWarning(context, () async {
      await api.cancelar(t.id);
      await recarregar();
      return 'Tarefa cancelada.';
    });
  }
}

/// `./dark script canal:N [--to M]`: writes scripts from the channel plan into the vault (local LLM or Claude).
class _GenerateScript extends StatefulWidget {
  const _GenerateScript({required this.api});

  final ApiEsteira api;

  @override
  State<_GenerateScript> createState() => _GenerateScriptState();
}

class _GenerateScriptState extends State<_GenerateScript> {
  final _target = TextEditingController();
  final _until = TextEditingController();
  String _engine = 'local';

  @override
  void dispose() {
    _target.dispose();
    _until.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text('Roteiro do plano'),
          SizedBox(
            width: 150,
            child: TextField(
              controller: _target,
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'finlumia:51',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          SizedBox(
            width: 110,
            child: TextField(
              controller: _until,
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'até (opcional)',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          DropdownButton<String>(
            value: _engine,
            items: const [
              DropdownMenuItem(value: 'local', child: Text('LLM local (ocupa a máquina)')),
              DropdownMenuItem(value: 'claude', child: Text('Claude (em paralelo; conta no teto)')),
            ],
            onChanged: (v) => setState(() => _engine = v ?? 'local'),
          ),
          FilledButton.tonal(
            onPressed: () => actionWithWarning(context, () async {
              final entrou = await widget.api.generateScript(
                _target.text.trim(),
                until: _until.text.trim(),
                engine: _engine,
              );
              return entrou ? 'Roteiro na fila.' : 'Esse roteiro já estava na fila.';
            }),
            child: const Text('Pôr na fila'),
          ),
        ],
      ),
    ),
  );
}
