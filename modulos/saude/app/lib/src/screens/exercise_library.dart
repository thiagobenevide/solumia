import 'package:flutter/material.dart';

import '../health_api.dart';
import '../models.dart';
import 'common.dart';

/// Drill-down exercises: body area → muscle group → exercise. Each exercise can be dragged
/// to a calendar day; the + places it on the focused day and a tap opens the details.
class ExerciseLibrary extends StatefulWidget {
  const ExerciseLibrary({
    super.key,
    required this.api,
    required this.areas,
    required this.exercises,
    required this.imageVersion,
    required this.adicionar,
    required this.open,
    required this.create,
    this.close,
  });

  final HealthApi api;
  final List<String> areas;
  final List<Exercise> exercises;
  final int Function(String exerciseId) imageVersion;
  final void Function(Exercise e) adicionar;
  final void Function(Exercise e) open;
  final VoidCallback create;
  final VoidCallback? close;

  @override
  State<ExerciseLibrary> createState() => _ExerciseLibraryState();
}

class _ExerciseLibraryState extends State<ExerciseLibrary> {
  String _search = '';

  static String _normal(String s) {
    const de = 'áàâãäéèêëíìîïóòôõöúùûüç';
    const to = 'aaaaaeeeeiiiiooooouuuuc';
    final b = StringBuffer();
    for (final c in s.toLowerCase().split('')) {
      final i = de.indexOf(c);
      b.write(i < 0 ? c : to[i]);
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final topic = Theme.of(context);
    final search = _normal(_search.trim());
    final filtered = search.isEmpty
        ? widget.exercises
        : widget.exercises
              .where((e) => _normal('${e.name} ${e.group} ${e.area} ${e.equipment}').contains(search))
              .toList();
    // known areas in catalog order; the ones created by the user go at the end
    final areas = [
      ...widget.areas,
      ...{for (final e in widget.exercises) e.area}.difference(widget.areas.toSet()),
    ];
    return Material(
      color: topic.colorScheme.surfaceContainerLowest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
            child: Row(
              children: [
                Expanded(child: Text('Exercícios', style: topic.textTheme.titleMedium)),
                IconButton(tooltip: 'Novo exercício', icon: const Icon(Icons.add_circle_outline), onPressed: widget.create),
                if (widget.close != null)
                  IconButton(tooltip: 'Fechar', icon: const Icon(Icons.close), onPressed: widget.close),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: TextField(
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search),
                hintText: 'Buscar (nome, músculo, equipamento)',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final area in areas)
                  if (filtered.any((e) => e.area == area)) _area(area, filtered.where((e) => e.area == area).toList(), search.isNotEmpty),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _area(String area, List<Exercise> items, bool expand) {
    final groups = <String, List<Exercise>>{};
    for (final e in items) {
      groups.putIfAbsent(e.group.isEmpty ? 'Outros' : e.group, () => []).add(e);
    }
    return ExpansionTile(
      key: PageStorageKey('area-$area-$expand'),
      initiallyExpanded: expand,
      leading: Icon(_areaIcon(area)),
      title: Text(area),
      subtitle: Text('${items.length} exercícios'),
      childrenPadding: const EdgeInsets.only(left: 12),
      children: [
        for (final MapEntry(key: group, value: es) in groups.entries)
          ExpansionTile(
            key: PageStorageKey('grupo-$area-$group-$expand'),
            initiallyExpanded: expand || groups.length == 1,
            dense: true,
            title: Text(group),
            trailing: Text('${es.length}'),
            children: [for (final e in es) _exercise(e)],
          ),
      ],
    );
  }

  Widget _exercise(Exercise e) => DraggableItem(
    dado: ExerciseDrag(e),
    label: e.name,
    child: ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 8, right: 0),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: ExerciseImage(api: widget.api, exercise: e, size: 40, version: widget.imageVersion(e.id)),
      ),
      title: Text(e.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text('${e.equipment} · ${e.series} × ${e.reps}', maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: IconButton(
        tooltip: 'Marcar no dia em foco',
        icon: const Icon(Icons.add),
        onPressed: () => widget.adicionar(e),
      ),
      onTap: () => widget.open(e),
    ),
  );

  static IconData _areaIcon(String area) => switch (area) {
    'Peito' => Icons.accessibility_new,
    'Costas' => Icons.airline_seat_flat,
    'Ombros' => Icons.expand_less,
    'Braços' => Icons.fitness_center,
    'Abdômen' => Icons.grid_view,
    'Pernas' => Icons.directions_walk,
    'Glúteos' => Icons.airline_seat_recline_normal,
    'Cardio e luta' => Icons.sports_mma,
    _ => Icons.sports_gymnastics,
  };
}
