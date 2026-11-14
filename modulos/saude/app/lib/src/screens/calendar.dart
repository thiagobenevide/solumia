import 'package:flutter/material.dart';

import '../dates.dart';
import 'common.dart';

/// Month grid: 6 weeks; each day takes dragged exercises and, on tap, opens the day.
class VistaMes extends StatelessWidget {
  const VistaMes({super.key, required this.agenda, required this.focus});

  final Agenda agenda;
  final DateTime focus;

  @override
  Widget build(BuildContext context) {
    final topic = Theme.of(context);
    final days = gradeMes(focus);
    return Column(
      children: [
        Row(
          children: [
            for (final d in weekdays)
              Expanded(child: Center(child: Text(d, style: topic.textTheme.labelMedium))),
          ],
        ),
        const SizedBox(height: 4),
        Expanded(
          child: Column(
            children: [
              for (var s = 0; s < 6; s++)
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final d in days.sublist(s * 7, s * 7 + 7))
                        Expanded(child: _MonthCell(agenda: agenda, day: d, doMes: d.month == focus.month)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MonthCell extends StatelessWidget {
  const _MonthCell({required this.agenda, required this.day, required this.doMes});

  final Agenda agenda;
  final DateTime day;
  final bool doMes;

  @override
  Widget build(BuildContext context) {
    final topic = Theme.of(context);
    final itens = agenda.dayItems(day);
    final isToday = sameDay(day, today());
    return Padding(
      padding: const EdgeInsets.all(1),
      child: DayTarget(
        agenda: agenda,
        day: day,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => agenda.openDay(day),
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: doMes ? topic.colorScheme.surfaceContainerLow : null,
              borderRadius: BorderRadius.circular(8),
            ),
            child: LayoutBuilder(
              builder: (context, c) {
                // how many cards fit below the day number (each one ~18 px)
                final fits = ((c.maxHeight - 22) / 18).floor().clamp(0, 99);
                final show = itens.length > fits ? (fits - 1).clamp(0, 99) : itens.length;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.topLeft,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: isToday
                            ? BoxDecoration(color: topic.colorScheme.primary, borderRadius: BorderRadius.circular(10))
                            : null,
                        child: Text(
                          '${day.day}',
                          style: topic.textTheme.labelMedium?.copyWith(
                            color: isToday
                                ? topic.colorScheme.onPrimary
                                : doMes
                                ? null
                                : topic.colorScheme.outline,
                          ),
                        ),
                      ),
                    ),
                    for (final i in itens.take(show)) ItemCard(agenda: agenda, item: i, compact: true),
                    if (show < itens.length)
                      Text('+${itens.length - show}', style: topic.textTheme.labelSmall),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Week from Monday to Sunday: 7 columns on a wide screen; a list of days on a narrow one.
class WeekView extends StatelessWidget {
  const WeekView({super.key, required this.agenda, required this.focus});

  final Agenda agenda;
  final DateTime focus;

  @override
  Widget build(BuildContext context) {
    final days = [for (var i = 0; i < 7; i++) addDays(weekStart(focus), i)];
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth >= 640) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final d in days) Expanded(child: _DayColumn(agenda: agenda, day: d))],
          );
        }
        return ListView(
          children: [
            for (final d in days)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _DayColumn(agenda: agenda, day: d, scrollable: false),
              ),
          ],
        );
      },
    );
  }
}

class _DayColumn extends StatelessWidget {
  const _DayColumn({required this.agenda, required this.day, this.scrollable = true});

  final Agenda agenda;
  final DateTime day;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final topic = Theme.of(context);
    final itens = agenda.dayItems(day);
    final isToday = sameDay(day, today());
    final cards = [for (final i in itens) ItemCard(agenda: agenda, item: i)];
    return Padding(
      padding: const EdgeInsets.all(2),
      child: DayTarget(
        agenda: agenda,
        day: day,
        child: Container(
          constraints: const BoxConstraints(minHeight: 72),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: topic.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(8),
            border: isToday ? Border.all(color: topic.colorScheme.primary) : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                onTap: () => agenda.openDay(day),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    scrollable ? '${weekdays[day.weekday - 1]} ${day.day}' : longDay(day),
                    style: topic.textTheme.titleSmall?.copyWith(color: isToday ? topic.colorScheme.primary : null),
                  ),
                ),
              ),
              if (scrollable) Expanded(child: ListView(children: cards)) else ...cards,
              if (itens.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text('arraste exercícios aqui', style: topic.textTheme.bodySmall?.copyWith(color: topic.colorScheme.outline)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One day: the exercises in order, with reordering and large cards.
class DayView extends StatelessWidget {
  const DayView({super.key, required this.agenda, required this.focus, required this.reorder});

  final Agenda agenda;
  final DateTime focus;
  final void Function(List<String> orderedIds) reorder;

  @override
  Widget build(BuildContext context) {
    final itens = agenda.dayItems(focus);
    final topic = Theme.of(context);
    final done = itens.where((i) => i.done).length;
    return DayTarget(
      agenda: agenda,
      day: focus,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                Expanded(child: Text(longDay(focus), style: topic.textTheme.titleMedium)),
                if (itens.isNotEmpty) Text('$done de ${itens.length} feitos'),
              ],
            ),
          ),
          if (itens.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: LinearProgressIndicator(value: done / itens.length),
            ),
          Expanded(
            child: itens.isEmpty
                ? Center(
                    child: Text(
                      'Nenhum exercício neste dia.\nArraste da biblioteca ou use o + de cada exercício.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: topic.colorScheme.outline),
                    ),
                  )
                : ReorderableListView(
                    padding: const EdgeInsets.all(8),
                    buildDefaultDragHandles: false,
                    onReorderItem: (de, to) {
                      final ids = [for (final i in itens) i.id];
                      ids.insert(to, ids.removeAt(de));
                      reorder(ids);
                    },
                    children: [
                      for (final (n, i) in itens.indexed)
                        Row(
                          key: ValueKey(i.id),
                          children: [
                            ReorderableDragStartListener(
                              index: n,
                              child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.drag_indicator)),
                            ),
                            Expanded(child: ItemCard(agenda: agenda, item: i)),
                          ],
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
