/// Kanban columns, in board order (`rotinas/board.py`). Value names are the API contract.
enum BoardColumn {
  pendente('Pendentes'),
  execucao('Em execução'),
  concluida('Concluídas');

  const BoardColumn(this.label);

  final String label;

  static BoardColumn fromName(String name) => values.firstWhere((c) => c.name == name, orElse: () => pendente);
}

const priorities = {'baixa': 'Baixa', 'media': 'Média', 'alta': 'Alta'};

class Task {
  Task({
    required this.id,
    required this.title,
    required this.description,
    required this.priority,
    required this.tags,
    required this.due,
    required this.column,
    required this.order,
    required this.totalTime,
    required this.running,
    DateTime? receivedAt,
  }) : receivedAt = receivedAt ?? DateTime.now();

  factory Task.fromJson(Map<String, dynamic> j) => Task(
    id: j['id'] as String,
    title: j['titulo'] as String,
    description: j['descricao'] as String? ?? '',
    priority: j['prioridade'] as String? ?? 'media',
    tags: [for (final t in j['tags'] as List? ?? const []) '$t'],
    due: j['prazo'] == null ? null : DateTime.tryParse(j['prazo'] as String),
    column: BoardColumn.fromName(j['coluna'] as String),
    order: j['ordem'] as int? ?? 0,
    totalTime: Duration(seconds: j['tempo_total'] as int? ?? 0),
    running: j['rodando_desde'] != null,
  );

  final String id;
  final String title;
  final String description;
  final String priority;
  final List<String> tags;
  final DateTime? due;
  final BoardColumn column;
  final int order;
  final bool running;

  /// Time accumulated when the server answered ([receivedAt]).
  final Duration totalTime;
  final DateTime receivedAt;

  /// Time spent up to [now], counting the running timer.
  Duration timeAt(DateTime now) => running ? totalTime + now.difference(receivedAt) : totalTime;

  bool overdueAt(DateTime now) =>
      due != null && column != BoardColumn.concluida && DateTime(now.year, now.month, now.day).isAfter(due!);
}

class BoardSummary {
  const BoardSummary({required this.counts, required this.timeToday});

  factory BoardSummary.fromJson(Map<String, dynamic> j) => BoardSummary(
    counts: {for (final c in BoardColumn.values) c: (j['colunas'] as Map)[c.name] as int? ?? 0},
    timeToday: Duration(seconds: j['tempo_hoje'] as int? ?? 0),
  );

  final Map<BoardColumn, int> counts;
  final Duration timeToday;
}

/// `1h05min`, `12min`, or `mm:ss` with [withSeconds].
String formatDuration(Duration d, {bool withSeconds = false}) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  String twoDigits(int n) => n.toString().padLeft(2, '0');
  if (withSeconds) return h > 0 ? '$h:${twoDigits(m)}:${twoDigits(s)}' : '${twoDigits(m)}:${twoDigits(s)}';
  return h > 0 ? '${h}h${twoDigits(m)}min' : '${m}min';
}
