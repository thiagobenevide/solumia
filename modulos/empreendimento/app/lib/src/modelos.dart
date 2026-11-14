// Espelho do JSON de `esteira/web/api.py` (`/api/v1`). Campos ausentes viram valores neutros:
// a esteira grava etapas aos poucos e nem todo episódio tem tudo.

typedef Json = Map<String, dynamic>;

double? _num(Object? v) => v is num ? v.toDouble() : null;

// O núcleo da esteira (`esteira/core`) fala inglês; as telas ainda usam o vocabulário em português.
const _estadosDaApi = {
  'running': 'rodando',
  'error': 'erro',
  'aborted': 'abortado',
  'pending': 'pendente',
  'cancelled': 'cancelado',
  'interrupted': 'interrompido',
};
const _tiposDaApi = {'start': 'inicio', 'end': 'fim', 'warning': 'aviso', 'error': 'erro', 'output': 'saida'};

String estadoDaApi(Object? v) => _estadosDaApi['$v'] ?? '${v ?? ''}';

String tipoDaApi(Object? v) => _tiposDaApi['$v'] ?? '${v ?? ''}';

const etapasDoPipeline = [
  'limpar', 'cenas', 'curar', 'buscar', 'avaliar', 'graficos', 'montar', 'thumb', //
];

class Canal {
  Canal.fromJson(Json j)
    : id = j['id'] as String,
      roteiros = j['roteiros'] as int? ?? 0,
      episodios = j['episodios'] as int? ?? 0;

  final String id;
  final int roteiros;
  final int episodios;
}

class Progresso {
  Progresso.fromJson(Json j)
    : feitas = j['feitas'] as int? ?? 0,
      total = j['total'] as int? ?? etapasDoPipeline.length,
      rodando = j['rodando'] as String?,
      erro = j['erro'] as String?,
      desatualizado = j['desatualizado'] as bool? ?? false,
      finalPronto = j['final'] as bool? ?? false;

  final int feitas;
  final int total;
  final String? rodando;
  final String? erro;
  final bool desatualizado;
  final bool finalPronto;

  double get fracao => total == 0 ? 0 : feitas / total;

  /// Estado em uma palavra, na ordem de importância para quem acompanha.
  String get estado => rodando != null
      ? 'rodando'
      : erro != null
      ? 'erro'
      : finalPronto
      ? 'ok'
      : 'pendente';
}

class Miniatura {
  Miniatura.fromJson(Json j) : vaga = j['vaga'] as int, url = j['url'] as String;

  final int vaga;
  final String url;
}

class EpisodioResumo {
  EpisodioResumo.fromJson(Json j)
    : id = j['id'] as String,
      canal = j['canal'] as String,
      numero = j['numero'] as String,
      titulo = j['titulo'] as String? ?? '',
      prog = Progresso.fromJson(j['prog'] as Json),
      thumbs = [for (final t in j['thumbs'] as List? ?? const []) Miniatura.fromJson(t as Json)];

  final String id;
  final String canal;
  final String numero;
  final String titulo;
  final Progresso prog;
  final List<Miniatura> thumbs;
}

class Etapa {
  Etapa.fromJson(Json j)
    : id = j['id'] as String,
      nome = j['nome'] as String? ?? j['id'] as String,
      status = estadoDaApi(j['status'] ?? 'pending'),
      msg = j['message'] as String? ?? '',
      avisos = j['warnings'] as int? ?? 0,
      feito = j['i'] as int?,
      total = j['n'] as int?,
      restaSegundos = _num(j['remaining']),
      duracaoSegundos = _num(j['duration']),
      inicio = DateTime.tryParse(j['start'] as String? ?? '');

  final String id;
  final String nome;
  final String status;
  final String msg;
  final int avisos;
  final int? feito;
  final int? total;
  final double? restaSegundos;
  final double? duracaoSegundos;
  final DateTime? inicio;

  double? get fracao => feito != null && total != null && total! > 0 ? feito! / total! : null;
}

class Evento {
  Evento.fromJson(Json j)
    : t = DateTime.tryParse(j['t'] as String? ?? ''),
      etapa = j['stage'] as String? ?? '',
      tipo = tipoDaApi(j['kind']),
      msg = j['message'] as String? ?? '';

  final DateTime? t;
  final String etapa;
  final String tipo;
  final String msg;
}

class Episodio extends EpisodioResumo {
  Episodio.fromJson(super.j)
    : etapas = [for (final e in j['etapas'] as List) Etapa.fromJson(e as Json)],
      eventos = [for (final e in j['eventos'] as List? ?? const []) Evento.fromJson(e as Json)],
      gastoClaude = _num(j['gasto_claude']) ?? 0,
      video = j['video'] as String?,
      thumbPrincipal = j['thumb'] as String?,
      vertical = j['vertical'] as bool? ?? false,
      modo = j['modo'] as String? ?? 'dark',
      camera = j['camera'] as Json?,
      semCamera = j['sem_camera'] as bool? ?? false,
      partes = j['partes'] as int? ?? 0,
      notas = j['notas'] as int? ?? 0,
      citacoes = j['citacoes'] as int? ?? 0,
      fontes = [for (final f in j['fontes'] as List? ?? const []) f as Json],
      temProjetoFilmCraft = j['fcproj'] as bool? ?? false,
      manuais = [for (final m in j['manuais'] as List? ?? const []) '$m'],
      motorIa = j['motor_ia'] as String? ?? '',
      super.fromJson();

  final List<Etapa> etapas;
  final List<Evento> eventos;
  final double gastoClaude;
  final String? video;
  final String? thumbPrincipal;
  final bool vertical;

  /// `dark` (narração + bancos) ou `apresentador` (câmera na V1 + B-roll).
  final String modo;
  final Json? camera;
  final bool semCamera;
  final int partes;
  final int notas;
  final int citacoes;
  final List<Json> fontes;
  final bool temProjetoFilmCraft;

  /// Projetos do FilmCraft editados à mão e guardados antes de uma nova montagem.
  final List<String> manuais;
  final String motorIa;
}

class Roteiro {
  Roteiro.fromJson(Json j)
    : canal = j['canal'] as String,
      numero = j['numero'] as int? ?? 0,
      short = j['short'] as String? ?? '',
      titulo = j['titulo'] as String? ?? '',
      formato = j['formato'] as String? ?? '16:9',
      status = j['status'] as String? ?? '',
      caminho = j['caminho'] as String,
      audio = j['audio'] as bool? ?? false,
      audioMb = j['audio_mb'] as int?,
      modo = j['modo'] as String? ?? 'dark',
      modoDefinido = j['modo_definido'] as bool? ?? false,
      citacoes = j['citacoes'] as int? ?? 0,
      ep = j['ep'] as String?,
      template = j['template'] as String?,
      prog = j['prog'] == null ? null : Progresso.fromJson(j['prog'] as Json);

  final String canal;
  final int numero;
  final String short;
  final String titulo;
  final String formato;
  final String status;
  final String caminho;
  final bool audio;
  final int? audioMb;
  final String modo;

  /// `false`: o roteiro não diz `modo:` e o valor veio do projeto ou do perfil do canal.
  final bool modoDefinido;

  /// Blocos `> [!cite]` (citações com PDF) no roteiro do vault.
  final int citacoes;
  final String? ep;

  /// Template (`id@N`) escolhido para a produção no Estúdio.
  final String? template;
  final Progresso? prog;

  /// Dá para mandar produzir: já tem narração gravada ou já é um episódio.
  bool get produzivel => audio || ep != null;

  String get rotulo => '${numero.toString().padLeft(3, '0')}$short';
}

class Tarefa {
  Tarefa.fromJson(Json j)
    : id = j['id'] as int,
      ep = j['ep'] as String,
      comando = j['comando'] as String,
      args = [for (final a in j['args'] as List? ?? const []) '$a'],
      vaga = j['vaga'] as String? ?? 'machine',
      estado = j['estado'] as String,
      criado = DateTime.tryParse(j['criado'] as String? ?? ''),
      inicio = DateTime.tryParse(j['inicio'] as String? ?? ''),
      fim = DateTime.tryParse(j['fim'] as String? ?? ''),
      prog = j['prog'] == null ? null : Progresso.fromJson(j['prog'] as Json),
      processo = j['processo'] as String?;

  final int id;
  final String ep;
  final String comando;
  final List<String> args;
  final String vaga;
  final String estado;
  final DateTime? criado;
  final DateTime? inicio;
  final DateTime? fim;
  final Progresso? prog;

  /// Id do processo (`/processos/{id}`) que rodou ou roda esta tarefa.
  final String? processo;

  bool get ativa => estado == 'na fila' || estado == 'rodando';
}

class Fila {
  Fila.fromJson(Json j)
    : tarefas = [for (final t in j['tarefas'] as List) Tarefa.fromJson(t as Json)],
      vagas = {
        for (final MapEntry(:key, :value) in (j['vagas'] as Json).entries)
          key: value == null ? null : '${(value as Json)['command'] ?? 'ocupada'}',
      };

  final List<Tarefa> tarefas;

  /// Vaga → o que a ocupa agora (null: livre).
  final Map<String, String?> vagas;
}

class Maquina {
  Maquina.fromJson(Json j)
    : gpu = j['gpu'] as Json?,
      cpu = j['cpu'] as Json?,
      ram = j['ram'] as Json?,
      ollama = [for (final m in j['ollama'] as List? ?? const []) m as Json],
      energia = j['energia'] as Json? ?? const {},
      esteira = [for (final p in j['esteira'] as List? ?? const []) p as Json],
      grupos = [for (final g in j['grupos'] as List? ?? const []) g as Json],
      arquivos = [for (final a in j['arquivos'] as List? ?? const []) a as Json],
      historico = [for (final h in j['hist'] as List? ?? const []) h as Json],
      fila = [for (final t in j['fila'] as List? ?? const []) Tarefa.fromJson(t as Json)];

  final Json? gpu;
  final Json? cpu;
  final Json? ram;
  final List<Json> ollama;
  final Json energia;

  /// Processos `./dark` vivos agora, com as últimas linhas do log de cada um.
  final List<Json> esteira;

  /// Programas auxiliares (llama.cpp, Chromium, FilmCraft…) somados por tipo.
  final List<Json> grupos;

  /// Arquivos alterados nos últimos 15 min (`caminho`, `seg` desde a alteração).
  final List<Json> arquivos;

  /// Amostras dos últimos 10 min: `t`, `gpu_uso`, `gpu_w`, `gpu_temp`, `cpu_uso`, `cpu_w`, `cpu_temp`.
  final List<Json> historico;
  final List<Tarefa> fila;

  bool get coletando => gpu != null || cpu != null;
}
