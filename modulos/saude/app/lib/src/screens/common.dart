import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../health_api.dart';
import '../models.dart';

/// What the calendar views need from the workouts screen.
class Agenda {
  Agenda({
    required this.api,
    required this.dayItems,
    required this.exercise,
    required this.drop,
    required this.openItem,
    required this.toggleDone,
    required this.openDay,
    required this.imageVersion,
  });

  final HealthApi api;
  final List<ItemAgenda> Function(DateTime day) dayItems;
  final Exercise? Function(String id) exercise;
  final void Function(DragPayload drag, DateTime day) drop;
  final void Function(ItemAgenda item) openItem;
  final void Function(ItemAgenda item) toggleDone;
  final void Function(DateTime day) openDay;

  /// Changes when a photo is swapped, so the thumbnails reload.
  final int Function(String exerciseId) imageVersion;
}

/// Exercise photo (or an icon, if there is none).
class ExerciseImage extends StatelessWidget {
  const ExerciseImage({super.key, required this.api, required this.exercise, this.n = 0, this.version = 0, this.size});

  final HealthApi api;
  final Exercise? exercise;
  final int n;
  final int version;
  final double? size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final empty = Container(
      width: size,
      height: size,
      color: colors.surfaceContainerHighest,
      child: Icon(Icons.fitness_center, color: colors.outline, size: (size ?? 48) * 0.5),
    );
    final e = exercise;
    if (e == null || !e.hasImage) return empty;
    return Image.network(
      api.imageUrl(e.id, n: n, version: version).toString(),
      headers: api.cabecalhos,
      width: size,
      height: size,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => empty,
    );
  }
}

/// Dragging with the mouse starts on click; on touch (Android), with a long press, so it does not fight
/// the scrolling.
class DraggableItem extends StatelessWidget {
  const DraggableItem({super.key, required this.dado, required this.label, required this.child});

  final DragPayload dado;
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ghost = Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(8),
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(label, style: Theme.of(context).textTheme.labelLarge),
      ),
    );
    final tap = switch (defaultTargetPlatform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    final faded = Opacity(opacity: 0.4, child: child);
    return tap
        ? LongPressDraggable<DragPayload>(data: dado, feedback: ghost, childWhenDragging: faded, child: child)
        : Draggable<DragPayload>(data: dado, feedback: ghost, childWhenDragging: faded, child: child);
  }
}

/// Area of a day that accepts dragged exercises and items; it is highlighted while something hovers.
class DayTarget extends StatelessWidget {
  const DayTarget({super.key, required this.agenda, required this.day, required this.child});

  final Agenda agenda;
  final DateTime day;
  final Widget child;

  @override
  Widget build(BuildContext context) => DragTarget<DragPayload>(
    onAcceptWithDetails: (d) => agenda.drop(d.data, day),
    builder: (context, candidates, _) => AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: BoxDecoration(
        color: candidates.isEmpty ? null : Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
        border: candidates.isEmpty ? null : Border.all(color: Theme.of(context).colorScheme.primary, width: 2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: child,
    ),
  );
}

/// Card of a placed exercise: draggable to another day, a tap opens the editing.
class ItemCard extends StatelessWidget {
  const ItemCard({super.key, required this.agenda, required this.item, this.compact = false});

  final Agenda agenda;
  final ItemAgenda item;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final e = agenda.exercise(item.exerciseId);
    final name = e?.name ?? item.exerciseId;
    final topic = Theme.of(context);
    final struck = item.done
        ? TextStyle(decoration: TextDecoration.lineThrough, color: topic.colorScheme.outline)
        : null;
    final Widget content;
    if (compact) {
      content = Container(
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: item.done ? topic.colorScheme.surfaceContainerHighest : topic.colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: topic.textTheme.labelSmall?.merge(struck)),
      );
    } else {
      content = LayoutBuilder(
        builder: (context, c) => c.maxWidth < 200 ? _stacked(context, e, name, struck) : _inline(e, name, struck),
      );
    }
    return DraggableItem(
      dado: ItemDrag(item),
      label: name,
      child: compact ? GestureDetector(onTap: () => agenda.openItem(item), child: content) : content,
    );
  }

  /// Narrow column (week on the PC, small window): image on top, name, sets and the "feito" below,
  /// instead of squeezing everything in one line.
  Widget _stacked(BuildContext context, Exercise? e, String name, TextStyle? struck) {
    final topic = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => agenda.openItem(item),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 10,
              // No size: the image fills the AspectRatio space (cover).
              child: ExerciseImage(api: agenda.api, exercise: e, version: agenda.imageVersion(item.exerciseId)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
              child: Text(
                name,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: topic.textTheme.labelMedium?.merge(struck),
              ),
            ),
            Row(
              children: [
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    item.summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: topic.textTheme.labelSmall?.copyWith(color: topic.colorScheme.onSurfaceVariant),
                  ),
                ),
                SizedBox.square(
                  dimension: 32,
                  child: Checkbox(
                    value: item.done,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: (_) => agenda.toggleDone(item),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _inline(Exercise? e, String name, TextStyle? struck) => Card(
        margin: const EdgeInsets.only(bottom: 6),
        child: ListTile(
          dense: true,
          contentPadding: const EdgeInsets.only(left: 6, right: 0),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: ExerciseImage(
              api: agenda.api,
              exercise: e,
              size: 44,
              version: agenda.imageVersion(item.exerciseId),
            ),
          ),
          title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: struck),
          subtitle: Text(item.summary),
          trailing: Checkbox(value: item.done, onChanged: (_) => agenda.toggleDone(item)),
          onTap: () => agenda.openItem(item),
        ),
      );
}
