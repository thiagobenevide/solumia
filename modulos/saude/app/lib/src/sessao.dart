/// Sessão do guia de treino (`/api/saude/sessoes`). O estado vem do servidor; aqui só se calcula o
/// que mostrar a cada segundo (descanso que falta, tempo de treino), com o relógio do servidor.
class SessaoTreino {
  SessaoTreino._(this.j, this._offset);

  /// [recebidaEm]: hora local em que a resposta chegou, para acertar a diferença de relógio.
  factory SessaoTreino.fromJson(Map<String, dynamic> j, {DateTime? recebidaEm}) {
    final local = recebidaEm ?? DateTime.now();
    final agora = j['agora'] == null ? local : DateTime.parse(j['agora'] as String);
    return SessaoTreino._(j, agora.difference(local));
  }

  final Map<String, dynamic> j;
  final Duration _offset;

  String get id => j['id'] as String;
  DateTime get data => DateTime.parse(j['data'] as String);
  DateTime get inicio => DateTime.parse(j['inicio'] as String);
  int get descansoS => j['descanso_s'] as int;
  String get estado => j['estado'] as String;
  Map<String, dynamic> get controle => j['controle'] as Map<String, dynamic>;
  Map<String, dynamic>? get resumo => j['resumo'] as Map<String, dynamic>?;
  Map<String, dynamic>? get frequencia => j['frequencia'] as Map<String, dynamic>?;
  List<ExercicioSessao> get exercicios => [
    for (final (n, e) in (j['exercicios'] as List).indexed) ExercicioSessao(n, e as Map<String, dynamic>),
  ];

  bool get pausado => controle['pausado'] as bool;
  int get indice => controle['indice'] as int;

  ExercicioSessao? get atual {
    final l = exercicios;
    return indice < l.length ? l[indice] : null;
  }

  DateTime agoraServidor([DateTime? local]) => (local ?? DateTime.now()).add(_offset);

  DateTime? _instante(String chave) {
    final v = controle[chave];
    return v == null ? null : DateTime.parse(v as String);
  }

  /// Segundos de descanso que faltam (parado quando pausado); null fora do descanso.
  int? restanteDescanso([DateTime? local]) {
    if (controle['fase'] != 'descanso') return null;
    if (pausado) return controle['descanso_restante_s'] as int? ?? 0;
    final ate = _instante('descanso_ate');
    if (ate == null) return 0;
    final s = (ate.difference(agoraServidor(local)).inMilliseconds / 1000).ceil();
    return s < 0 ? 0 : s;
  }

  /// "exercicio", "descanso", "fim" ou "concluida"; descanso vencido já conta como a próxima série.
  String fase([DateTime? local]) {
    final f = controle['fase'] as String;
    if (f == 'descanso' && !pausado && restanteDescanso(local) == 0) return 'exercicio';
    return f;
  }

  /// Tempo de treino sem as pausas.
  Duration ativo([DateTime? local]) {
    final fim = j['fim'] == null ? agoraServidor(local) : DateTime.parse(j['fim'] as String);
    var pausa = Duration(seconds: controle['pausa_total_s'] as int? ?? 0);
    final pausadoEm = _instante('pausado_em');
    if (pausado && pausadoEm != null) pausa += fim.difference(pausadoEm);
    final d = fim.difference(inicio) - pausa;
    return d.isNegative ? Duration.zero : d;
  }

  /// Segundos desde o começo da série atual (para os exercícios por tempo).
  int tempoSerie([DateTime? local]) {
    final ini = _instante('inicio_serie');
    if (ini == null) return 0;
    final ate = pausado ? (_instante('pausado_em') ?? agoraServidor(local)) : agoraServidor(local);
    final s = ate.difference(ini).inSeconds;
    return s < 0 ? 0 : s;
  }

  /// Batimentos do relógio agora, se a última amostra tem menos de 30 s.
  int? fcAtual([DateTime? local]) {
    final f = j['fc_atual'] as Map<String, dynamic>?;
    if (f == null || estado != 'andamento') return null;
    final idade = agoraServidor(local).difference(DateTime.parse(f['em'] as String));
    return idade.inSeconds > 30 ? null : (f['bpm'] as num).round();
  }

  bool get fcDoRelogio => frequencia?['origem'] == 'relogio';

  int get seriesFeitas => exercicios.fold(0, (t, e) => t + e.series.length);
  int get seriesPlanejadas => exercicios.fold(0, (t, e) => t + (e.pulado ? e.series.length : e.planejadas));
}

class ExercicioSessao {
  ExercicioSessao(this.indice, this.j);

  final int indice;
  final Map<String, dynamic> j;

  String get exercicioId => j['exercicio_id'] as String;
  String get nome => j['nome'] as String;
  String get instrucoes => j['instrucoes'] as String? ?? '';
  Map<String, dynamic> get planejado => j['planejado'] as Map<String, dynamic>;
  int get planejadas => planejado['series'] as int;
  String get repeticoes => planejado['repeticoes'] as String;
  double? get cargaPlanejada => (planejado['carga_kg'] as num?)?.toDouble();
  int? get tempoMeta => (j['meta'] as Map)['tempo_s'] as int?;
  int? get repsMax => (j['meta'] as Map)['max'] as int?;
  Map<String, dynamic>? get anterior => j['anterior'] as Map<String, dynamic>?;
  Map<String, dynamic>? get sugestao => j['sugestao'] as Map<String, dynamic>?;
  List<Map<String, dynamic>> get series => [for (final s in j['series'] as List) s as Map<String, dynamic>];
  bool get pulado => j['pulado'] as bool? ?? false;
  bool get completo => series.length >= planejadas;

  /// Carga para a próxima série: a da última feita, senão a sugerida, senão a planejada.
  double? get cargaInicial {
    if (series.isNotEmpty) return (series.last['carga_kg'] as num?)?.toDouble();
    final s = sugestao;
    if (s != null && s.containsKey('carga_kg')) return (s['carga_kg'] as num?)?.toDouble();
    return cargaPlanejada;
  }

  int get repsIniciais {
    if (series.isNotEmpty && series.last['repeticoes'] != null) return series.last['repeticoes'] as int;
    return (sugestao?['repeticoes'] as int?) ?? repsMax ?? 10;
  }
}

/// "1:05" ou "1:02:03".
String relogio(int segundos) {
  final h = segundos ~/ 3600, m = (segundos % 3600) ~/ 60, s = segundos % 60;
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}
