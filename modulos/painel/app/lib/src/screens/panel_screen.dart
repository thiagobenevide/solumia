import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../panel_api.dart';
import '../models.dart';
import 'coach_chat.dart';
import 'llm_dashboard.dart';

class PanelScreen extends StatefulWidget {
  const PanelScreen({super.key, required this.api});

  final PanelApi api;

  @override
  State<PanelScreen> createState() => _PanelScreenState();
}

class _PanelScreenState extends State<PanelScreen> {
  late final _conversation = CoachConversation(widget.api);

  @override
  void dispose() {
    _conversation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 4,
    child: Column(
      children: [
        const TabBar(
          tabs: [
            Tab(icon: Icon(Icons.today_outlined), text: 'Hoje'),
            Tab(icon: Icon(Icons.forum_outlined), text: 'Cobrador'),
            Tab(icon: Icon(Icons.flag_outlined), text: 'Metas'),
            Tab(icon: Icon(Icons.speed_outlined), text: 'LLMs'),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              _Today(api: widget.api),
              CoachChat(conversation: _conversation),
              _Goals(api: widget.api),
              LlmDashboard(api: widget.api),
            ],
          ),
        ),
      ],
    ),
  );
}

// --- Today: discipline, alerts and editable schedule ---

class _Today extends StatelessWidget {
  const _Today({required this.api});

  final PanelApi api;

  Future<(Discipline, Agenda)> _load() async {
    final day = isoDate(DateTime.now());
    final r = await Future.wait([api.discipline(), api.agenda(day)]);
    return (r[0] as Discipline, r[1] as Agenda);
  }

  @override
  Widget build(BuildContext context) => Sondagem<(Discipline, Agenda)>(
    carregar: _load,
    intervalo: const Duration(seconds: 60),
    construir: (context, data, reload) {
      final (d, ag) = data;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Scoreboard(d: d),
          for (final a in d.alerts) _AlertCard(alert: a),
          const SizedBox(height: 8),
          _DaySchedule(api: api, agenda: ag, aoMudar: reload),
        ],
      );
    },
  );
}

class _Scoreboard extends StatelessWidget {
  const _Scoreboard({required this.d});

  final Discipline d;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = d.score == null ? colors.outline : (d.inside ? colors.primary : colors.error);
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color,
          foregroundColor: colors.onPrimary,
          child: Text(d.score == null ? '–' : '${d.score}'),
        ),
        title: Text(
          d.score == null ? 'Dia ainda sem medição' : (d.inside ? 'Dentro da disciplina' : 'Fora da disciplina'),
        ),
        subtitle: Text(
          'Blocos ${d.blocksDone}/${d.blocksOverdue} cumpridos · metas no ritmo ${d.goalsOnTrack}/${d.goalsTotal}'
          '${d.currentBlock == null ? '' : '\nAgora: ${d.currentBlock!.title} (até ${d.currentBlock!.end})'}',
        ),
      ),
    );
  }
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({required this.alert});

  final Alert alert;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final critical = alert.level == 'critico';
    return Card(
      color: critical ? colors.errorContainer : colors.tertiaryContainer,
      child: ListTile(
        dense: true,
        leading: Icon(critical ? Icons.priority_high : Icons.notifications_active_outlined),
        title: Text(alert.text),
      ),
    );
  }
}

class _DaySchedule extends StatelessWidget {
  const _DaySchedule({required this.api, required this.agenda, required this.aoMudar});

  final PanelApi api;
  final Agenda agenda;
  final Future<void> Function() aoMudar;

  Future<void> _retry(BuildContext context, Future<void> Function() action) async {
    try {
      await action();
    } on ApiErro catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
    await aoMudar();
  }

  /// Edits (or creates, with a null [block]) and saves the whole schedule; shows the coach's objections.
  Future<void> _edit(BuildContext context, ScheduleBlock? block) async {
    final result = await showDialog<_Editing>(context: context, builder: (_) => _BlockEditor(block: block));
    if (result == null || !context.mounted) return;
    final blocks = [...agenda.blocks];
    if (block != null) blocks.remove(block);
    if (result.block != null) blocks.add(result.block!);
    await _retry(context, () async {
      final saved = await api.save(agenda.data, blocks, result.reason);
      if (saved.objections.isNotEmpty && context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.gavel_outlined),
            title: const Text('O cobrador contesta'),
            content: Text(saved.objections.join('\n\n')),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Entendi'))],
          ),
        );
      }
    });
  }

  Future<void> _suggest(BuildContext context) async {
    if (agenda.blocks.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Refazer a agenda?'),
          content: const Text('A sugestão substitui os blocos de hoje.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Refazer')),
          ],
        ),
      );
      if (ok != true || !context.mounted) return;
    }
    await _retry(context, () => api.suggest(agenda.data));
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(child: Text('Agenda de hoje', style: Theme.of(context).textTheme.titleMedium)),
          TextButton.icon(
            icon: const Icon(Icons.auto_fix_high_outlined),
            label: const Text('Sugerir'),
            onPressed: () => _suggest(context),
          ),
          IconButton(tooltip: 'Novo bloco', icon: const Icon(Icons.add), onPressed: () => _edit(context, null)),
        ],
      ),
      if (agenda.blocks.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text('Nenhum bloco. Use “Sugerir” para montar o dia com as tarefas do Kanban.'),
        ),
      for (final b in agenda.blocks)
        Card(
          child: CheckboxListTile(
            value: b.done,
            onChanged: (v) => _retry(context, () => api.mark(agenda.data, b.id!, v ?? false)),
            title: Text(b.title, style: TextStyle(decoration: b.done ? TextDecoration.lineThrough : null)),
            subtitle: Text('${b.start}–${b.end} · prioridade ${b.priority}${b.due == null ? '' : ' · prazo ${b.due}'}'),
            secondary: IconButton(
              tooltip: 'Editar',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _edit(context, b),
            ),
          ),
        ),
    ],
  );
}

/// Editor result: null [block] = delete. [reason] goes to the change history.
class _Editing {
  const _Editing(this.block, this.reason);

  final ScheduleBlock? block;
  final String reason;
}

class _BlockEditor extends StatefulWidget {
  const _BlockEditor({this.block});

  final ScheduleBlock? block;

  @override
  State<_BlockEditor> createState() => _BlockEditorState();
}

class _BlockEditorState extends State<_BlockEditor> {
  late final _title = TextEditingController(text: widget.block?.title);
  late final _start = TextEditingController(text: widget.block?.start ?? '09:00');
  late final _end = TextEditingController(text: widget.block?.end ?? '09:50');
  final _reason = TextEditingController();
  late String _priority = widget.block?.priority ?? 'media';
  final _time = RegExp(r'^\d{2}:\d{2}$');

  @override
  void dispose() {
    for (final c in [_title, _start, _end, _reason]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (_title.text.trim().isEmpty || !_time.hasMatch(_start.text) || !_time.hasMatch(_end.text)) return;
    final b = widget.block;
    Navigator.pop(
      context,
      _Editing(
        ScheduleBlock(
          id: b?.id,
          title: _title.text.trim(),
          start: _start.text,
          end: _end.text,
          priority: _priority,
          taskId: b?.taskId,
          due: b?.due,
          done: b?.done ?? false,
        ),
        _reason.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.block == null ? 'Novo bloco' : 'Editar bloco'),
    content: SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          TextField(controller: _title, autofocus: true, decoration: const InputDecoration(labelText: 'Título')),
          Row(
            spacing: 12,
            children: [
              Expanded(
                child: TextField(controller: _start, decoration: const InputDecoration(labelText: 'Início (HH:MM)')),
              ),
              Expanded(
                child: TextField(controller: _end, decoration: const InputDecoration(labelText: 'Fim (HH:MM)')),
              ),
            ],
          ),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'baixa', label: Text('Baixa')),
              ButtonSegment(value: 'media', label: Text('Média')),
              ButtonSegment(value: 'alta', label: Text('Alta')),
            ],
            selected: {_priority},
            onSelectionChanged: (s) => setState(() => _priority = s.first),
          ),
          TextField(
            controller: _reason,
            decoration: const InputDecoration(labelText: 'Motivo da mudança (o cobrador registra)'),
          ),
        ],
      ),
    ),
    actions: [
      if (widget.block != null)
        TextButton(
          onPressed: () => Navigator.pop(context, _Editing(null, _reason.text.trim())),
          child: const Text('Excluir'),
        ),
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(onPressed: _save, child: const Text('Salvar')),
    ],
  );
}

// --- Goals ---

class _Goals extends StatelessWidget {
  const _Goals({required this.api});

  final PanelApi api;

  Future<void> _newConversation(BuildContext context, Future<void> Function() reload) async {
    final title = TextEditingController();
    final target = TextEditingController(text: '1');
    final unit = TextEditingController(text: 'vez');
    var frequency = 'diaria';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Nova meta'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              TextField(controller: title, autofocus: true, decoration: const InputDecoration(labelText: 'Meta')),
              Row(
                spacing: 12,
                children: [
                  Expanded(
                    child: TextField(
                      controller: target,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Alvo'),
                    ),
                  ),
                  Expanded(
                    child: TextField(controller: unit, decoration: const InputDecoration(labelText: 'Unidade')),
                  ),
                ],
              ),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'diaria', label: Text('Por dia')),
                  ButtonSegment(value: 'semanal', label: Text('Por semana')),
                ],
                selected: {frequency},
                onSelectionChanged: (s) => setState(() => frequency = s.first),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Criar')),
          ],
        ),
      ),
    );
    final value = double.tryParse(target.text.replaceAll(',', '.'));
    if (ok == true && title.text.trim().isNotEmpty && value != null && value > 0) {
      await api.createGoal(title.text.trim(), frequency, value, unit.text.trim());
      await reload();
    }
    for (final c in [title, target, unit]) {
      c.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => Sondagem<List<Goal>>(
    carregar: api.goals,
    intervalo: const Duration(seconds: 60),
    construir: (context, goals, reload) => Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Meta'),
        onPressed: () => _newConversation(context, reload),
      ),
      body: goals.isEmpty
          ? const Center(child: Text('Sem metas. Crie as que o cobrador deve acompanhar.'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
              children: [
                for (final m in goals)
                  Card(
                    child: ListTile(
                      leading: Icon(
                        m.onTrack ? Icons.check_circle_outline : Icons.trending_down,
                        color: m.onTrack ? null : Theme.of(context).colorScheme.error,
                      ),
                      title: Text(m.title),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 4,
                        children: [
                          Text(
                            '${_n(m.done)}/${_n(m.target)} ${m.unit} ${m.frequency == 'diaria' ? 'hoje' : 'na semana'}'
                            ' · esperado agora ${_n(m.expected)}',
                          ),
                          LinearProgressIndicator(value: (m.done / m.target).clamp(0, 1)),
                        ],
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Registrar +1',
                            icon: const Icon(Icons.add_task),
                            onPressed: () async {
                              await api.register(m.id);
                              await reload();
                            },
                          ),
                          IconButton(
                            tooltip: 'Excluir',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              await api.deleteGoal(m.id);
                              await reload();
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    ),
  );
}

String _n(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
