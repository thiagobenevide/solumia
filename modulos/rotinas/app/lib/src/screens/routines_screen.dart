import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../routines_api.dart';
import '../models.dart';
import 'assistant.dart';
import 'task_card.dart';
import 'task_editor.dart';

/// Routines Kanban. Phone (< 700): one tab per column and the assistant in a bottom sheet.
/// Tablet/laptop: the three columns side by side, with drag and drop. PC (≥ 1200): the assistant
/// stays pinned on the right.
class RoutinesScreen extends StatefulWidget {
  const RoutinesScreen({super.key, required this.api});

  final RoutinesApi api;

  @override
  State<RoutinesScreen> createState() => _RoutinesScreenState();
}

class _RoutinesScreenState extends State<RoutinesScreen> {
  late final _chat = AssistantChat(widget.api);
  List<Task> _tasks = [];
  BoardSummary? _summary;
  DateTime _summaryAt = DateTime.now();
  String? _error;
  bool _loading = true;
  bool _assistantOpen = true;
  DateTime _now = DateTime.now();
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _reload();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_tasks.any((t) => t.running)) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    _chat.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final (tasks, summary) = await (widget.api.list(), widget.api.summary()).wait;
      if (!mounted) return;
      setState(() {
        _tasks = tasks;
        _summary = summary;
        _summaryAt = _now = DateTime.now();
        _error = null;
        _loading = false;
      });
    } on ParallelWaitError<(List<Task>?, BoardSummary?), (AsyncError?, AsyncError?)> catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '${e.errors.$1?.error ?? e.errors.$2?.error}';
        _loading = false;
      });
    }
  }

  /// Runs the action on the API and reloads the board; failures become a warning.
  Future<void> _run(Future<Object?> Function() action) async {
    try {
      await action();
    } on ApiErro catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
    await _reload();
  }

  Future<void> _newTask([BoardColumn column = BoardColumn.pendente]) async {
    final data = await editTask(context);
    if (data != null) await _run(() => widget.api.create({...data, 'coluna': column.name}));
  }

  Future<void> _edit(Task t) async {
    final data = await editTask(context, t);
    if (data != null) await _run(() => widget.api.save(t.id, data));
  }

  Future<void> _excluir(Task t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Excluir tarefa?'),
        content: Text(t.title),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Excluir')),
        ],
      ),
    );
    if (ok ?? false) await _run(() => widget.api.delete(t.id));
  }

  void _openAssistantSheet() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (c) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(c).height * .8,
        child: Assistant(chat: _chat, onClose: () => Navigator.pop(c)),
      ),
    ),
  );

  List<Task> _inColumn(BoardColumn c) => [for (final t in _tasks) if (t.column == c) t];

  Widget _card(Task t) => TaskCard(
    key: ValueKey(t.id),
    task: t,
    now: _now,
    onToggleTimer: () => _run(() => widget.api.timer(t.id, t.running ? 'pausar' : 'iniciar')),
    onEdit: () => _edit(t),
    onMove: (c) => _run(() => widget.api.move(t.id, c)),
    onReset: () => _run(() => widget.api.timer(t.id, 'zerar')),
    onDelete: () => _excluir(t),
  );

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && _tasks.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            FilledButton.tonal(onPressed: _reload, child: const Text('Tentar de novo')),
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, c) {
        final phone = c.maxWidth < 700;
        final pc = c.maxWidth >= 1200;
        final bar = _TopBar(
          summary: _summary,
          active: _tasks.where((t) => t.running).firstOrNull,
          timeToday: _timeToday(),
          now: _now,
          compact: phone,
          onPause: (t) => _run(() => widget.api.timer(t.id, 'pausar')),
          onNew: phone ? null : _newTask,
          onAssistant: pc ? () => setState(() => _assistantOpen = !_assistantOpen) : _openAssistantSheet,
          onReload: _reload,
        );
        if (phone) return _phone(bar);
        return Column(
          children: [
            bar,
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final col in BoardColumn.values)
                    Expanded(
                      child: _KanbanColumn(
                        column: col,
                        tasks: _inColumn(col),
                        card: _card,
                        onDrop: (t, order) => _run(() => widget.api.move(t.id, col, order)),
                        onNew: col == BoardColumn.concluida ? null : () => _newTask(col),
                      ),
                    ),
                  if (pc && _assistantOpen) ...[
                    const VerticalDivider(width: 1),
                    SizedBox(
                      width: 360,
                      child: Assistant(
                        chat: _chat,
                        onClose: () => setState(() => _assistantOpen = false),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Duration _timeToday() {
    final today = _summary?.timeToday ?? Duration.zero;
    return _tasks.any((t) => t.running) ? today + _now.difference(_summaryAt) : today;
  }

  Widget _phone(Widget bar) => DefaultTabController(
    length: BoardColumn.values.length,
    child: Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton(
        tooltip: 'Nova tarefa',
        onPressed: _newTask,
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          bar,
          TabBar(
            // Scrollable: "Em execução (12)" does not fit in a third of the phone's 360 dp.
            isScrollable: true,
            tabAlignment: TabAlignment.center,
            tabs: [
              for (final c in BoardColumn.values) Tab(text: '${c.label} (${_summary?.counts[c] ?? _inColumn(c).length})'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                for (final c in BoardColumn.values)
                  RefreshIndicator(
                    onRefresh: _reload,
                    child: _inColumn(c).isEmpty
                        ? ListView(children: const [_Empty()])
                        : ListView(
                            padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
                            children: [for (final t in _inColumn(c)) _card(t)],
                          ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.summary,
    required this.active,
    required this.timeToday,
    required this.now,
    required this.compact,
    required this.onPause,
    required this.onNew,
    required this.onAssistant,
    required this.onReload,
  });

  final BoardSummary? summary;
  final Task? active;
  final Duration timeToday;
  final DateTime now;
  final bool compact;
  final ValueChanged<Task> onPause;
  final VoidCallback? onNew;
  final VoidCallback onAssistant;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final a = active;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Chip(avatar: const Icon(Icons.today_outlined, size: 18), label: Text('Hoje: ${formatDuration(timeToday)}')),
                if (a != null)
                  InputChip(
                    avatar: Icon(Icons.timer, size: 18, color: colors.primary),
                    label: Text(
                      '${a.title} · ${formatDuration(a.timeAt(now), withSeconds: true)}',
                      overflow: TextOverflow.ellipsis,
                    ),
                    deleteIcon: const Icon(Icons.pause, size: 18),
                    deleteButtonTooltipMessage: 'Pausar',
                    onDeleted: () => onPause(a),
                  ),
              ],
            ),
          ),
          IconButton(tooltip: 'Atualizar', icon: const Icon(Icons.refresh), onPressed: onReload),
          if (compact)
            IconButton(tooltip: 'Assistente', icon: const Icon(Icons.auto_awesome_outlined), onPressed: onAssistant)
          else ...[
            OutlinedButton.icon(
              icon: const Icon(Icons.auto_awesome_outlined),
              label: const Text('Assistente'),
              onPressed: onAssistant,
            ),
            const SizedBox(width: 8),
          ],
          if (onNew != null)
            FilledButton.icon(icon: const Icon(Icons.add), label: const Text('Nova tarefa'), onPressed: onNew),
        ],
      ),
    );
  }
}

class _KanbanColumn extends StatelessWidget {
  const _KanbanColumn({
    required this.column,
    required this.tasks,
    required this.card,
    required this.onDrop,
    required this.onNew,
  });

  final BoardColumn column;
  final List<Task> tasks;
  final Widget Function(Task) card;

  /// Task dropped on this column at the given position (null = at the end).
  final void Function(Task, int?) onDrop;
  final VoidCallback? onNew;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // on touch (phone/tablet) dragging starts with a long press, so it does not fight the scrolling
    final tap = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    return LayoutBuilder(
      builder: (context, c) => DragTarget<Task>(
        onAcceptWithDetails: (d) => onDrop(d.data, null),
        builder: (context, candidates, _) => Container(
          margin: const EdgeInsets.fromLTRB(8, 0, 0, 8),
          decoration: BoxDecoration(
            color: candidates.isEmpty ? colors.surfaceContainerLowest : colors.primaryContainer.withValues(alpha: .25),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              ListTile(
                dense: true,
                title: Text(column.label, style: Theme.of(context).textTheme.titleSmall),
                leading: Badge(label: Text('${tasks.length}'), child: Icon(_icon, color: colors.primary)),
                trailing: onNew == null
                    ? null
                    : IconButton(tooltip: 'Nova tarefa aqui', icon: const Icon(Icons.add), onPressed: onNew),
              ),
              Expanded(
                child: tasks.isEmpty
                    ? const _Empty()
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(6, 0, 6, 24),
                        itemCount: tasks.length,
                        itemBuilder: (context, i) {
                          final t = tasks[i];
                          final draggable = _draggable(t, card(t), c.maxWidth - 28, tap);
                          return DragTarget<Task>(
                            onWillAcceptWithDetails: (d) => d.data.id != t.id,
                            onAcceptWithDetails: (d) => onDrop(d.data, _orderOnDrop(d.data, i)),
                            builder: (context, hovering, _) => Column(
                              children: [
                                if (hovering.isNotEmpty)
                                  Container(height: 3, margin: const EdgeInsets.all(4), color: colors.primary),
                                draggable,
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Dropping on card [i] places it before; in the same column, a task coming from above discounts itself.
  int _orderOnDrop(Task dropped, int i) {
    final origin = tasks.indexWhere((t) => t.id == dropped.id);
    return origin >= 0 && origin < i ? i - 1 : i;
  }

  IconData get _icon => switch (column) {
    BoardColumn.pendente => Icons.inbox_outlined,
    BoardColumn.execucao => Icons.play_circle_outline,
    BoardColumn.concluida => Icons.task_alt,
  };

  Widget _draggable(Task t, Widget child, double width, bool tap) {
    final ghost = Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(width: width, child: child),
    );
    final faded = Opacity(opacity: .35, child: child);
    return tap
        ? LongPressDraggable<Task>(data: t, feedback: ghost, childWhenDragging: faded, child: child)
        : Draggable<Task>(data: t, feedback: ghost, childWhenDragging: faded, child: child);
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Text(
      'Nada aqui',
      textAlign: TextAlign.center,
      style: TextStyle(color: Theme.of(context).colorScheme.outline),
    ),
  );
}
