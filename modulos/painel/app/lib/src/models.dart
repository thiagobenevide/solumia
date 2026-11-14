String isoDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Block of the day schedule (local `HH:MM`).
class ScheduleBlock {
  ScheduleBlock({
    this.id,
    required this.title,
    required this.start,
    required this.end,
    this.priority = 'media',
    this.taskId,
    this.due,
    this.done = false,
  });

  factory ScheduleBlock.fromJson(Map<String, dynamic> j) => ScheduleBlock(
    id: j['id'] as String?,
    title: j['titulo'] as String,
    start: j['inicio'] as String,
    end: j['fim'] as String,
    priority: j['prioridade'] as String? ?? 'media',
    taskId: j['tarefa_id'] as String?,
    due: j['prazo'] as String?,
    done: j['feito'] as bool? ?? false,
  );

  final String? id;
  String title;
  String start;
  String end;
  String priority;
  final String? taskId;
  final String? due;
  bool done;

  Map<String, dynamic> toJson() => {
    'id': ?id,
    'titulo': title,
    'inicio': start,
    'fim': end,
    'prioridade': priority,
    'tarefa_id': ?taskId,
    'prazo': ?due,
    'feito': done,
  };
}

class Agenda {
  Agenda(this.data, this.blocks, this.objections);

  factory Agenda.fromJson(Map<String, dynamic> j) => Agenda(
    j['data'] as String,
    [for (final b in j['blocos'] as List) ScheduleBlock.fromJson(b as Map<String, dynamic>)],
    [for (final c in j['contestacoes'] as List? ?? const []) c as String],
  );

  final String data;
  final List<ScheduleBlock> blocks;

  /// Only comes back on save: priority deliveries that the edit removed from the day or pushed back.
  final List<String> objections;
}

class Alert {
  const Alert(this.level, this.text);

  /// `critico` or `aviso`.
  final String level;
  final String text;
}

class Discipline {
  Discipline({
    required this.score,
    required this.inside,
    required this.blocksDone,
    required this.blocksOverdue,
    required this.goalsOnTrack,
    required this.goalsTotal,
    required this.currentBlock,
    required this.alerts,
  });

  factory Discipline.fromJson(Map<String, dynamic> j) => Discipline(
    score: j['indice'] as int?,
    inside: j['dentro'] as bool,
    blocksDone: j['blocos']['feitos'] as int,
    blocksOverdue: j['blocos']['vencidos'] as int,
    goalsOnTrack: j['metas']['no_ritmo'] as int,
    goalsTotal: j['metas']['total'] as int,
    currentBlock: j['bloco_atual'] == null ? null : ScheduleBlock.fromJson(j['bloco_atual'] as Map<String, dynamic>),
    alerts: [for (final a in j['alertas'] as List) Alert(a['nivel'] as String, a['texto'] as String)],
  );

  /// 0–100; null when there is nothing to measure in the day yet.
  final int? score;
  final bool inside;
  final int blocksDone;
  final int blocksOverdue;
  final int goalsOnTrack;
  final int goalsTotal;
  final ScheduleBlock? currentBlock;
  final List<Alert> alerts;
}

class Goal {
  Goal({
    required this.id,
    required this.title,
    required this.frequency,
    required this.target,
    required this.unit,
    required this.done,
    required this.expected,
  });

  factory Goal.fromJson(Map<String, dynamic> j) => Goal(
    id: j['id'] as String,
    title: j['titulo'] as String,
    frequency: j['frequencia'] as String,
    target: (j['alvo'] as num).toDouble(),
    unit: j['unidade'] as String,
    done: (j['feito'] as num).toDouble(),
    expected: (j['esperado'] as num).toDouble(),
  );

  final String id;
  final String title;

  /// `diaria` or `semanal`.
  final String frequency;
  final double target;
  final String unit;
  final double done;

  /// How much should be done by now (in the week, proportional to the elapsed days).
  final double expected;

  bool get onTrack => done >= expected;
}

/// Action the coach executed during the conversation (create a task, change the schedule, …).
class ExecutedAction {
  const ExecutedAction(this.type, this.ok, this.detail);

  final String type;
  final bool ok;
  final String detail;
}

class CoachReply {
  CoachReply(this.text, this.actions, {this.transcription, this.links = const []});

  factory CoachReply.fromJson(Map<String, dynamic> j) => CoachReply(
    j['resposta'] as String,
    [
      for (final e in j['executadas'] as List? ?? const [])
        ExecutedAction(e['tipo'] as String, e['ok'] as bool, e['detalhe'] as String),
    ],
    transcription: j['transcricao'] as String?,
    links: [
      for (final l in j['links'] as List? ?? const []) ('${l['titulo']}', '${l['url']}'),
    ],
  );

  final String text;
  final List<ExecutedAction> actions;

  /// Pages consulted when the reply came from the internet (title, address).
  final List<(String, String)> links;

  /// Only on voice messages: what the worker understood from the audio.
  final String? transcription;

  /// What to read aloud: the reply, or the actions when the LLM only acted and wrote nothing.
  String get spokenText => text.trim().isNotEmpty ? text : actions.map((e) => e.detail).join('. ');

  /// Bubble text: the reply followed by the actions (✔ done, ✖ failed).
  String get fullText => [
    text,
    for (final e in actions) '${e.ok ? '✔' : '✖'} ${e.detail}',
    for (final (title, url) in links.take(3)) '🔗 $title — $url',
  ].where((l) => l.isNotEmpty).join('\n');
}

/// Usage of an LLM provider in the dashboard window.
class ProviderUsage {
  ProviderUsage.fromJson(this.name, Map<String, dynamic> j)
    : requests = j['pedidos'] as int,
      errors = j['erros'] as int,
      availability = (j['disponibilidade_pct'] as num).toDouble(),
      p50 = j['latencia_p50_ms'] as int?,
      p95 = j['latencia_p95_ms'] as int?,
      tokensIn = j['tokens_entrada'] as int,
      tokensOut = j['tokens_saida'] as int;

  final String name;
  final int requests;
  final int errors;
  final double availability;
  final int? p50;
  final int? p95;
  final int tokensIn;
  final int tokensOut;
}

class Dashboard {
  Dashboard.fromJson(Map<String, dynamic> j)
    : providers = [
        for (final MapEntry(:key, :value) in (j['provedores'] as Map<String, dynamic>).entries)
          ProviderUsage.fromJson(key, value as Map<String, dynamic>),
      ],
      configured = [for (final c in j['configurados'] as List) '$c'],
      workers = [for (final w in j['workers'] as List) w as Map<String, dynamic>],
      recent = [for (final r in j['recentes'] as List) r as Map<String, dynamic>];

  final List<ProviderUsage> providers;
  final List<String> configured;

  /// `{id, modelos, visto_ha_s, recursos: {cpu_pct, ram_pct, gpus: [...]}}`.
  final List<Map<String, dynamic>> workers;

  /// Latest requests, newest first: `{em, provedor, tarefa, modelo, ms, erro, tokens_*}`.
  final List<Map<String, dynamic>> recent;
}
