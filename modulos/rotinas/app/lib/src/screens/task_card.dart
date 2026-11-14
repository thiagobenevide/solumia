import 'package:flutter/material.dart';

import '../models.dart';

class TaskCard extends StatelessWidget {
  const TaskCard({
    super.key,
    required this.task,
    required this.now,
    required this.onToggleTimer,
    required this.onEdit,
    required this.onMove,
    required this.onReset,
    required this.onDelete,
  });

  final Task task;
  final DateTime now;
  final VoidCallback onToggleTimer;
  final VoidCallback onEdit;
  final ValueChanged<BoardColumn> onMove;
  final VoidCallback onReset;
  final VoidCallback onDelete;

  Color _priorityColor(ColorScheme c) => switch (task.priority) {
    'alta' => c.error,
    'baixa' => c.outline,
    _ => c.tertiary,
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final t = task;
    final concluida = t.column == BoardColumn.concluida;
    final isOverdue = t.overdueAt(now);
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: t.running ? BorderSide(color: colors.primary, width: 2) : BorderSide.none,
      ),
      child: InkWell(
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              Row(
                children: [
                  Container(
                    width: 4,
                    height: 20,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(color: _priorityColor(colors), borderRadius: BorderRadius.circular(2)),
                  ),
                  Expanded(
                    child: Text(
                      t.title,
                      style: text.titleSmall?.copyWith(decoration: concluida ? TextDecoration.lineThrough : null),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _Menu(task: t, onMove: onMove, onEdit: onEdit, onReset: onReset, onDelete: onDelete),
                ],
              ),
              if (t.description.isNotEmpty)
                Text(t.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.bodySmall),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (t.due != null)
                    _Badge(
                      icon: Icons.event_outlined,
                      text: '${t.due!.day}/${t.due!.month}',
                      color: isOverdue ? colors.error : null,
                    ),
                  for (final tag in t.tags) _Badge(icon: Icons.sell_outlined, text: tag),
                ],
              ),
              Row(
                children: [
                  Icon(Icons.timer_outlined, size: 16, color: t.running ? colors.primary : colors.outline),
                  const SizedBox(width: 4),
                  Text(
                    formatDuration(t.timeAt(now), withSeconds: t.running),
                    style: text.labelMedium?.copyWith(
                      color: t.running ? colors.primary : null,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const Spacer(),
                  if (!concluida)
                    IconButton(
                      tooltip: t.running ? 'Pausar' : 'Iniciar cronômetro',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(t.running ? Icons.pause_circle : Icons.play_circle_outline),
                      color: colors.primary,
                      onPressed: onToggleTimer,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 2,
      children: [
        Icon(icon, size: 14, color: c),
        Text(text, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: c)),
      ],
    );
  }
}

class _Menu extends StatelessWidget {
  const _Menu({
    required this.task,
    required this.onMove,
    required this.onEdit,
    required this.onReset,
    required this.onDelete,
  });

  final Task task;
  final ValueChanged<BoardColumn> onMove;
  final VoidCallback onEdit;
  final VoidCallback onReset;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => PopupMenuButton<VoidCallback>(
    tooltip: 'Ações',
    icon: const Icon(Icons.more_vert, size: 20),
    onSelected: (action) => action(),
    itemBuilder: (_) => [
      for (final c in BoardColumn.values)
        if (c != task.column)
          PopupMenuItem(value: () => onMove(c), child: Text('Mover para ${c.label.toLowerCase()}')),
      const PopupMenuDivider(),
      PopupMenuItem(value: onEdit, child: const Text('Editar')),
      if (task.totalTime > Duration.zero || task.running)
        PopupMenuItem(value: onReset, child: const Text('Zerar tempo')),
      PopupMenuItem(value: onDelete, child: const Text('Excluir')),
    ],
  );
}
