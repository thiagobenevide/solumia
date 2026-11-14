/// Colunas do Kanban, na ordem do quadro (`rotinas/board.py`).
enum Coluna {
  pendente('Pendentes'),
  execucao('Em execução'),
  concluida('Concluídas');

  const Coluna(this.rotulo);

  final String rotulo;

  static Coluna doNome(String nome) => values.firstWhere((c) => c.name == nome, orElse: () => pendente);
}

const prioridades = {'baixa': 'Baixa', 'media': 'Média', 'alta': 'Alta'};

class Tarefa {
  Tarefa({
    required this.id,
    required this.titulo,
    required this.descricao,
    required this.prioridade,
    required this.tags,
    required this.prazo,
    required this.coluna,
    required this.ordem,
    required this.tempoTotal,
    required this.rodando,
    DateTime? recebidaEm,
  }) : recebidaEm = recebidaEm ?? DateTime.now();

  factory Tarefa.fromJson(Map<String, dynamic> j) => Tarefa(
    id: j['id'] as String,
    titulo: j['titulo'] as String,
    descricao: j['descricao'] as String? ?? '',
    prioridade: j['prioridade'] as String? ?? 'media',
    tags: [for (final t in j['tags'] as List? ?? const []) '$t'],
    prazo: j['prazo'] == null ? null : DateTime.tryParse(j['prazo'] as String),
    coluna: Coluna.doNome(j['coluna'] as String),
    ordem: j['ordem'] as int? ?? 0,
    tempoTotal: Duration(seconds: j['tempo_total'] as int? ?? 0),
    rodando: j['rodando_desde'] != null,
  );

  final String id;
  final String titulo;
  final String descricao;
  final String prioridade;
  final List<String> tags;
  final DateTime? prazo;
  final Coluna coluna;
  final int ordem;
  final bool rodando;

  /// Tempo acumulado quando o servidor respondeu ([recebidaEm]).
  final Duration tempoTotal;
  final DateTime recebidaEm;

  /// Tempo gasto até [agora], contando o cronômetro aberto.
  Duration tempoEm(DateTime agora) => rodando ? tempoTotal + agora.difference(recebidaEm) : tempoTotal;

  bool atrasadaEm(DateTime agora) =>
      prazo != null && coluna != Coluna.concluida && DateTime(agora.year, agora.month, agora.day).isAfter(prazo!);
}

class Resumo {
  const Resumo({required this.contagem, required this.tempoHoje});

  factory Resumo.fromJson(Map<String, dynamic> j) => Resumo(
    contagem: {for (final c in Coluna.values) c: (j['colunas'] as Map)[c.name] as int? ?? 0},
    tempoHoje: Duration(seconds: j['tempo_hoje'] as int? ?? 0),
  );

  final Map<Coluna, int> contagem;
  final Duration tempoHoje;
}

/// `1h05min`, `12min`, ou `mm:ss` com [segundos].
String formatarDuracao(Duration d, {bool segundos = false}) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  String dois(int n) => n.toString().padLeft(2, '0');
  if (segundos) return h > 0 ? '$h:${dois(m)}:${dois(s)}' : '${dois(m)}:${dois(s)}';
  return h > 0 ? '${h}h${dois(m)}min' : '${m}min';
}
