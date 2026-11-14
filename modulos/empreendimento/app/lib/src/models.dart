// Mirror of the JSON of `esteira/web/api.py` (`/api/v1`). Missing fields become neutral values:
// the esteira writes stages little by little and not every episode has everything.

typedef Json = Map<String, dynamic>;

double? _num(Object? v) => v is num ? v.toDouble() : null;

// The esteira core (`esteira/core`) speaks English; the API JSON keys still use the Portuguese vocabulary.
const _apiStates = {
  'running': 'rodando',
  'error': 'erro',
  'aborted': 'abortado',
  'pending': 'pendente',
  'cancelled': 'cancelado',
  'interrupted': 'interrompido',
};
const _apiKinds = {'start': 'inicio', 'end': 'fim', 'warning': 'aviso', 'error': 'erro', 'output': 'saida'};

String apiState(Object? v) => _apiStates['$v'] ?? '${v ?? ''}';

String apiKind(Object? v) => _apiKinds['$v'] ?? '${v ?? ''}';

const pipelineStages = [
  'clean', 'scenes', 'curate', 'fetch', 'evaluate', 'graphics', 'assemble', 'thumb', //
];

class Channel {
  Channel.fromJson(Json j)
    : id = j['id'] as String,
      scripts = j['roteiros'] as int? ?? 0,
      episodes = j['episodios'] as int? ?? 0;

  final String id;
  final int scripts;
  final int episodes;
}

class Progress {
  Progress.fromJson(Json j)
    : doneSteps = j['feitas'] as int? ?? 0,
      total = j['total'] as int? ?? pipelineStages.length,
      rodando = j['rodando'] as String?,
      erro = j['erro'] as String?,
      outdated = j['desatualizado'] as bool? ?? false,
      finalReady = j['final'] as bool? ?? false;

  final int doneSteps;
  final int total;
  final String? rodando;
  final String? erro;
  final bool outdated;
  final bool finalReady;

  double get fraction => total == 0 ? 0 : doneSteps / total;

  /// State in one word, in order of importance for whoever is following.
  String get state => rodando != null
      ? 'rodando'
      : erro != null
      ? 'erro'
      : finalReady
      ? 'ok'
      : 'pendente';
}

class Thumbnail {
  Thumbnail.fromJson(Json j) : slot = j['vaga'] as int, url = j['url'] as String;

  final int slot;
  final String url;
}

class EpisodeSummary {
  EpisodeSummary.fromJson(Json j)
    : id = j['id'] as String,
      channel = j['canal'] as String,
      numero = j['numero'] as String,
      titulo = j['titulo'] as String? ?? '',
      prog = Progress.fromJson(j['prog'] as Json),
      thumbs = [for (final t in j['thumbs'] as List? ?? const []) Thumbnail.fromJson(t as Json)];

  final String id;
  final String channel;
  final String numero;
  final String titulo;
  final Progress prog;
  final List<Thumbnail> thumbs;
}

class Stage {
  Stage.fromJson(Json j)
    : id = j['id'] as String,
      nome = j['nome'] as String? ?? j['id'] as String,
      status = apiState(j['status'] ?? 'pending'),
      msg = j['message'] as String? ?? '',
      warnings = j['warnings'] as int? ?? 0,
      done = j['i'] as int?,
      total = j['n'] as int?,
      secondsLeft = _num(j['remaining']),
      durationSeconds = _num(j['duration']),
      start = DateTime.tryParse(j['start'] as String? ?? '');

  final String id;
  final String nome;
  final String status;
  final String msg;
  final int warnings;
  final int? done;
  final int? total;
  final double? secondsLeft;
  final double? durationSeconds;
  final DateTime? start;

  double? get fraction => done != null && total != null && total! > 0 ? done! / total! : null;
}

class Event {
  Event.fromJson(Json j)
    : t = DateTime.tryParse(j['t'] as String? ?? ''),
      stage = j['stage'] as String? ?? '',
      kind = apiKind(j['kind']),
      msg = j['message'] as String? ?? '';

  final DateTime? t;
  final String stage;
  final String kind;
  final String msg;
}

class Episode extends EpisodeSummary {
  Episode.fromJson(super.j)
    : stages = [for (final e in j['etapas'] as List) Stage.fromJson(e as Json)],
      events = [for (final e in j['eventos'] as List? ?? const []) Event.fromJson(e as Json)],
      spentClaude = _num(j['gasto_claude']) ?? 0,
      video = j['video'] as String?,
      mainThumb = j['thumb'] as String?,
      vertical = j['vertical'] as bool? ?? false,
      modo = j['modo'] as String? ?? 'dark',
      camera = j['camera'] as Json?,
      withoutCamera = j['sem_camera'] as bool? ?? false,
      parts = j['partes'] as int? ?? 0,
      notes = j['notas'] as int? ?? 0,
      quotes = j['citacoes'] as int? ?? 0,
      sources = [for (final f in j['fontes'] as List? ?? const []) f as Json],
      hasProjectFilmCraft = j['fcproj'] as bool? ?? false,
      manuais = [for (final m in j['manuais'] as List? ?? const []) '$m'],
      aiEngine = j['motor_ia'] as String? ?? '',
      super.fromJson();

  final List<Stage> stages;
  final List<Event> events;
  final double spentClaude;
  final String? video;
  final String? mainThumb;
  final bool vertical;

  /// `dark` (narration + stock banks) or `apresentador` (camera on V1 + B-roll).
  final String modo;
  final Json? camera;
  final bool withoutCamera;
  final int parts;
  final int notes;
  final int quotes;
  final List<Json> sources;
  final bool hasProjectFilmCraft;

  /// FilmCraft projects edited by hand and kept before a new assembly.
  final List<String> manuais;
  final String aiEngine;
}

class Script {
  Script.fromJson(Json j)
    : channel = j['canal'] as String,
      numero = j['numero'] as int? ?? 0,
      short = j['short'] as String? ?? '',
      titulo = j['titulo'] as String? ?? '',
      format = j['formato'] as String? ?? '16:9',
      status = j['status'] as String? ?? '',
      caminho = j['caminho'] as String,
      audio = j['audio'] as bool? ?? false,
      audioMb = j['audio_mb'] as int?,
      modo = j['modo'] as String? ?? 'dark',
      definedMode = j['modo_definido'] as bool? ?? false,
      quotes = j['citacoes'] as int? ?? 0,
      ep = j['ep'] as String?,
      template = j['template'] as String?,
      prog = j['prog'] == null ? null : Progress.fromJson(j['prog'] as Json);

  final String channel;
  final int numero;
  final String short;
  final String titulo;
  final String format;
  final String status;
  final String caminho;
  final bool audio;
  final int? audioMb;
  final String modo;

  /// `false`: the script does not say `modo:` and the value came from the project or the channel profile.
  final bool definedMode;

  /// `> [!cite]` blocks (citations with PDF) in the vault script.
  final int quotes;
  final String? ep;

  /// Template (`id@N`) chosen for the Studio production.
  final String? template;
  final Progress? prog;

  /// Can be sent to production: it already has recorded narration or it already is an episode.
  bool get produzivel => audio || ep != null;

  String get label => '${numero.toString().padLeft(3, '0')}$short';
}

class Task {
  Task.fromJson(Json j)
    : id = j['id'] as int,
      ep = j['ep'] as String,
      command = j['comando'] as String,
      args = [for (final a in j['args'] as List? ?? const []) '$a'],
      slot = j['vaga'] as String? ?? 'machine',
      state = j['estado'] as String,
      created = DateTime.tryParse(j['criado'] as String? ?? ''),
      start = DateTime.tryParse(j['inicio'] as String? ?? ''),
      end = DateTime.tryParse(j['fim'] as String? ?? ''),
      prog = j['prog'] == null ? null : Progress.fromJson(j['prog'] as Json),
      process = j['processo'] as String?;

  final int id;
  final String ep;
  final String command;
  final List<String> args;
  final String slot;
  final String state;
  final DateTime? created;
  final DateTime? start;
  final DateTime? end;
  final Progress? prog;

  /// Id of the process (`/processos/{id}`) that ran or runs this task.
  final String? process;

  bool get active => state == 'na fila' || state == 'rodando';
}

class ProductionQueue {
  ProductionQueue.fromJson(Json j)
    : tasks = [for (final t in j['tarefas'] as List) Task.fromJson(t as Json)],
      slots = {
        for (final MapEntry(:key, :value) in (j['vagas'] as Json).entries)
          key: value == null ? null : '${(value as Json)['command'] ?? 'ocupada'}',
      };

  final List<Task> tasks;

  /// Slot → what takes it now (null: free).
  final Map<String, String?> slots;
}

class Machine {
  Machine.fromJson(Json j)
    : gpu = j['gpu'] as Json?,
      cpu = j['cpu'] as Json?,
      ram = j['ram'] as Json?,
      ollama = [for (final m in j['ollama'] as List? ?? const []) m as Json],
      energia = j['energia'] as Json? ?? const {},
      esteira = [for (final p in j['esteira'] as List? ?? const []) p as Json],
      groups = [for (final g in j['grupos'] as List? ?? const []) g as Json],
      files = [for (final a in j['arquivos'] as List? ?? const []) a as Json],
      history = [for (final h in j['hist'] as List? ?? const []) h as Json],
      queue = [for (final t in j['fila'] as List? ?? const []) Task.fromJson(t as Json)];

  final Json? gpu;
  final Json? cpu;
  final Json? ram;
  final List<Json> ollama;
  final Json energia;

  /// `./dark` processes alive now, with the last log lines of each one.
  final List<Json> esteira;

  /// Helper programs (llama.cpp, Chromium, FilmCraft…) summed per kind.
  final List<Json> groups;

  /// Files changed in the last 15 min (`caminho`, `seg` since the change).
  final List<Json> files;

  /// Samples from the last 10 min: `t`, `gpu_uso`, `gpu_w`, `gpu_temp`, `cpu_uso`, `cpu_w`, `cpu_temp`.
  final List<Json> history;
  final List<Task> queue;

  bool get collecting => gpu != null || cpu != null;
}
