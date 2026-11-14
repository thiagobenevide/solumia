/// Catalog exercise (`/api/saude/exercicios`): from the mini-gym base or created by the user.
class Exercise {
  Exercise({
    required this.id,
    required this.name,
    required this.area,
    required this.group,
    required this.equipment,
    required this.series,
    required this.reps,
    required this.loadKg,
    required this.instructions,
    required this.custom,
    required this.hasImage,
    required this.hasSequence,
  });

  factory Exercise.fromJson(Map<String, dynamic> j) => Exercise(
    id: j['id'] as String,
    name: j['nome'] as String,
    area: j['area'] as String,
    group: j['grupo'] as String? ?? '',
    equipment: j['equipamento'] as String? ?? '',
    series: j['series'] as int,
    reps: j['repeticoes'] as String,
    loadKg: (j['carga_kg'] as num?)?.toDouble(),
    instructions: j['instrucoes'] as String? ?? '',
    custom: j['personalizado'] as bool? ?? false,
    hasImage: j['imagem_propria'] == true || j['ref'] != null,
    hasSequence: j['imagem_propria'] != true && j['ref'] != null,
  );

  final String id;
  final String name;
  final String area;
  final String group;
  final String equipment;
  final int series;
  final String reps;
  final double? loadKg;
  final String instructions;
  final bool custom;

  /// Has a photo (uploaded by the user or from free-exercise-db).
  final bool hasImage;

  /// Has both images of the movement (start and end), the free-exercise-db ones.
  final bool hasSequence;

  Map<String, dynamic> toJson() => {
    'nome': name,
    'area': area,
    'grupo': group,
    'equipamento': equipment,
    'series': series,
    'repeticoes': reps,
    'carga_kg': loadKg,
    'instrucoes': instructions,
  };
}

/// An exercise placed on a schedule day, with what was planned and whether it was done.
class ItemAgenda {
  ItemAgenda({
    required this.id,
    required this.data,
    required this.exerciseId,
    required this.order,
    required this.series,
    required this.reps,
    required this.loadKg,
    required this.observation,
    required this.done,
  });

  factory ItemAgenda.fromJson(Map<String, dynamic> j) => ItemAgenda(
    id: j['id'] as String,
    data: DateTime.parse(j['data'] as String),
    exerciseId: j['exercicio_id'] as String,
    order: j['ordem'] as int,
    series: j['series'] as int,
    reps: j['repeticoes'] as String,
    loadKg: (j['carga_kg'] as num?)?.toDouble(),
    observation: j['observacao'] as String? ?? '',
    done: j['feito'] as bool? ?? false,
  );

  final String id;
  final DateTime data;
  final String exerciseId;
  final int order;
  final int series;
  final String reps;
  final double? loadKg;
  final String observation;
  final bool done;

  /// "3 × 12 · 20 kg"
  String get summary => '$series × $reps${loadKg == null ? '' : ' · ${formatLoad(loadKg!)} kg'}';
}

String formatLoad(double kg) => kg == kg.roundToDouble() ? '${kg.toInt()}' : '$kg'.replaceAll('.', ',');

/// What is dragged to the calendar: a new exercise from the library or an already placed item
/// (which changes day).
sealed class DragPayload {}

class ExerciseDrag extends DragPayload {
  ExerciseDrag(this.exercise);

  final Exercise exercise;
}

class ItemDrag extends DragPayload {
  ItemDrag(this.item);

  final ItemAgenda item;
}
