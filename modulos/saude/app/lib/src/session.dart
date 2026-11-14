/// Workout guide session (`/api/saude/sessoes`). The state comes from the server; here we only compute
/// what to show every second (remaining rest, workout time), with the server clock.
class WorkoutSession {
  WorkoutSession._(this.j, this._offset);

  /// [receivedAt]: local time the reply arrived, to correct the clock difference.
  factory WorkoutSession.fromJson(Map<String, dynamic> j, {DateTime? receivedAt}) {
    final local = receivedAt ?? DateTime.now();
    final now = j['agora'] == null ? local : DateTime.parse(j['agora'] as String);
    return WorkoutSession._(j, now.difference(local));
  }

  final Map<String, dynamic> j;
  final Duration _offset;

  String get id => j['id'] as String;
  DateTime get data => DateTime.parse(j['data'] as String);
  DateTime get start => DateTime.parse(j['inicio'] as String);
  int get restSeconds => j['descanso_s'] as int;
  String get status => j['estado'] as String;
  Map<String, dynamic> get controle => j['controle'] as Map<String, dynamic>;
  Map<String, dynamic>? get summary => j['resumo'] as Map<String, dynamic>?;
  Map<String, dynamic>? get frequency => j['frequencia'] as Map<String, dynamic>?;
  List<SessionExercise> get exercises => [
    for (final (n, e) in (j['exercicios'] as List).indexed) SessionExercise(n, e as Map<String, dynamic>),
  ];

  bool get paused => controle['pausado'] as bool;
  int get score => controle['indice'] as int;

  SessionExercise? get current {
    final l = exercises;
    return score < l.length ? l[score] : null;
  }

  DateTime serverNow([DateTime? local]) => (local ?? DateTime.now()).add(_offset);

  DateTime? _instant(String key) {
    final v = controle[key];
    return v == null ? null : DateTime.parse(v as String);
  }

  /// Remaining rest seconds (frozen when paused); null outside the rest.
  int? restRemaining([DateTime? local]) {
    if (controle['fase'] != 'descanso') return null;
    if (paused) return controle['descanso_restante_s'] as int? ?? 0;
    final ate = _instant('descanso_ate');
    if (ate == null) return 0;
    final s = (ate.difference(serverNow(local)).inMilliseconds / 1000).ceil();
    return s < 0 ? 0 : s;
  }

  /// "exercicio", "descanso", "fim" or "concluida"; an expired rest already counts as the next set.
  String phase([DateTime? local]) {
    final f = controle['fase'] as String;
    if (f == 'descanso' && !paused && restRemaining(local) == 0) return 'exercicio';
    return f;
  }

  /// Workout time without the breaks.
  Duration active([DateTime? local]) {
    final end = j['fim'] == null ? serverNow(local) : DateTime.parse(j['fim'] as String);
    var breakTime = Duration(seconds: controle['pausa_total_s'] as int? ?? 0);
    final pausedAt = _instant('pausado_em');
    if (paused && pausedAt != null) breakTime += end.difference(pausedAt);
    final d = end.difference(start) - breakTime;
    return d.isNegative ? Duration.zero : d;
  }

  /// Seconds since the start of the current set (for timed exercises).
  int setTime([DateTime? local]) {
    final start = _instant('inicio_serie');
    if (start == null) return 0;
    final ate = paused ? (_instant('pausado_em') ?? serverNow(local)) : serverNow(local);
    final s = ate.difference(start).inSeconds;
    return s < 0 ? 0 : s;
  }

  /// Watch heartbeats right now, if the last sample is less than 30 s old.
  int? currentHr([DateTime? local]) {
    final f = j['fc_atual'] as Map<String, dynamic>?;
    if (f == null || status != 'andamento') return null;
    final age = serverNow(local).difference(DateTime.parse(f['em'] as String));
    return age.inSeconds > 30 ? null : (f['bpm'] as num).round();
  }

  bool get watchHr => frequency?['origem'] == 'relogio';

  int get setsDone => exercises.fold(0, (t, e) => t + e.series.length);
  int get plannedSets => exercises.fold(0, (t, e) => t + (e.skipped ? e.series.length : e.planned));
}

class SessionExercise {
  SessionExercise(this.score, this.j);

  final int score;
  final Map<String, dynamic> j;

  String get exerciseId => j['exercicio_id'] as String;
  String get name => j['nome'] as String;
  String get instructions => j['instrucoes'] as String? ?? '';
  Map<String, dynamic> get isPlanned => j['planejado'] as Map<String, dynamic>;
  int get planned => isPlanned['series'] as int;
  String get reps => isPlanned['repeticoes'] as String;
  double? get plannedLoad => (isPlanned['carga_kg'] as num?)?.toDouble();
  int? get tempoMeta => (j['meta'] as Map)['tempo_s'] as int?;
  int? get repsMax => (j['meta'] as Map)['max'] as int?;
  Map<String, dynamic>? get anterior => j['anterior'] as Map<String, dynamic>?;
  Map<String, dynamic>? get suggestion => j['sugestao'] as Map<String, dynamic>?;
  List<Map<String, dynamic>> get series => [for (final s in j['series'] as List) s as Map<String, dynamic>];
  bool get skipped => j['pulado'] as bool? ?? false;
  bool get complete => series.length >= planned;

  /// Load for the next set: the last done one, otherwise the suggested, otherwise the planned.
  double? get initialLoad {
    if (series.isNotEmpty) return (series.last['carga_kg'] as num?)?.toDouble();
    final s = suggestion;
    if (s != null && s.containsKey('carga_kg')) return (s['carga_kg'] as num?)?.toDouble();
    return plannedLoad;
  }

  int get initialReps {
    if (series.isNotEmpty && series.last['repeticoes'] != null) return series.last['repeticoes'] as int;
    return (suggestion?['repeticoes'] as int?) ?? repsMax ?? 10;
  }
}

/// "1:05" or "1:02:03".
String watch(int withSeconds) {
  final h = withSeconds ~/ 3600, m = (withSeconds % 3600) ~/ 60, s = withSeconds % 60;
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}
