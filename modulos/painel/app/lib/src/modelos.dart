String dataIso(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Bloco da agenda do dia (`HH:MM` locais).
class Bloco {
  Bloco({
    this.id,
    required this.titulo,
    required this.inicio,
    required this.fim,
    this.prioridade = 'media',
    this.tarefaId,
    this.prazo,
    this.feito = false,
  });

  factory Bloco.fromJson(Map<String, dynamic> j) => Bloco(
    id: j['id'] as String?,
    titulo: j['titulo'] as String,
    inicio: j['inicio'] as String,
    fim: j['fim'] as String,
    prioridade: j['prioridade'] as String? ?? 'media',
    tarefaId: j['tarefa_id'] as String?,
    prazo: j['prazo'] as String?,
    feito: j['feito'] as bool? ?? false,
  );

  final String? id;
  String titulo;
  String inicio;
  String fim;
  String prioridade;
  final String? tarefaId;
  final String? prazo;
  bool feito;

  Map<String, dynamic> toJson() => {
    'id': ?id,
    'titulo': titulo,
    'inicio': inicio,
    'fim': fim,
    'prioridade': prioridade,
    'tarefa_id': ?tarefaId,
    'prazo': ?prazo,
    'feito': feito,
  };
}

class Agenda {
  Agenda(this.data, this.blocos, this.contestacoes);

  factory Agenda.fromJson(Map<String, dynamic> j) => Agenda(
    j['data'] as String,
    [for (final b in j['blocos'] as List) Bloco.fromJson(b as Map<String, dynamic>)],
    [for (final c in j['contestacoes'] as List? ?? const []) c as String],
  );

  final String data;
  final List<Bloco> blocos;

  /// Só vem ao salvar: entregas prioritárias que a edição tirou do dia ou empurrou.
  final List<String> contestacoes;
}

class Alerta {
  const Alerta(this.nivel, this.texto);

  /// `critico` ou `aviso`.
  final String nivel;
  final String texto;
}

class Disciplina {
  Disciplina({
    required this.indice,
    required this.dentro,
    required this.blocosFeitos,
    required this.blocosVencidos,
    required this.metasNoRitmo,
    required this.metasTotal,
    required this.blocoAtual,
    required this.alertas,
  });

  factory Disciplina.fromJson(Map<String, dynamic> j) => Disciplina(
    indice: j['indice'] as int?,
    dentro: j['dentro'] as bool,
    blocosFeitos: j['blocos']['feitos'] as int,
    blocosVencidos: j['blocos']['vencidos'] as int,
    metasNoRitmo: j['metas']['no_ritmo'] as int,
    metasTotal: j['metas']['total'] as int,
    blocoAtual: j['bloco_atual'] == null ? null : Bloco.fromJson(j['bloco_atual'] as Map<String, dynamic>),
    alertas: [for (final a in j['alertas'] as List) Alerta(a['nivel'] as String, a['texto'] as String)],
  );

  /// 0–100; nulo quando ainda não há nada para medir no dia.
  final int? indice;
  final bool dentro;
  final int blocosFeitos;
  final int blocosVencidos;
  final int metasNoRitmo;
  final int metasTotal;
  final Bloco? blocoAtual;
  final List<Alerta> alertas;
}

class Meta {
  Meta({
    required this.id,
    required this.titulo,
    required this.frequencia,
    required this.alvo,
    required this.unidade,
    required this.feito,
    required this.esperado,
  });

  factory Meta.fromJson(Map<String, dynamic> j) => Meta(
    id: j['id'] as String,
    titulo: j['titulo'] as String,
    frequencia: j['frequencia'] as String,
    alvo: (j['alvo'] as num).toDouble(),
    unidade: j['unidade'] as String,
    feito: (j['feito'] as num).toDouble(),
    esperado: (j['esperado'] as num).toDouble(),
  );

  final String id;
  final String titulo;

  /// `diaria` ou `semanal`.
  final String frequencia;
  final double alvo;
  final String unidade;
  final double feito;

  /// Quanto já deveria estar feito agora (na semana, proporcional aos dias corridos).
  final double esperado;

  bool get noRitmo => feito >= esperado;
}

/// Ação que o cobrador executou durante a conversa (criar tarefa, mexer na agenda, …).
class Executada {
  const Executada(this.tipo, this.ok, this.detalhe);

  final String tipo;
  final bool ok;
  final String detalhe;
}

class Resposta {
  Resposta(this.texto, this.executadas, {this.transcricao, this.links = const []});

  factory Resposta.fromJson(Map<String, dynamic> j) => Resposta(
    j['resposta'] as String,
    [
      for (final e in j['executadas'] as List? ?? const [])
        Executada(e['tipo'] as String, e['ok'] as bool, e['detalhe'] as String),
    ],
    transcricao: j['transcricao'] as String?,
    links: [
      for (final l in j['links'] as List? ?? const []) ('${l['titulo']}', '${l['url']}'),
    ],
  );

  final String texto;
  final List<Executada> executadas;

  /// Páginas consultadas quando a resposta veio da internet (título, endereço).
  final List<(String, String)> links;

  /// Só nas mensagens de voz: o que o worker entendeu do áudio.
  final String? transcricao;

  /// O que ler em voz alta: a resposta, ou as ações quando o LLM só agiu e não escreveu nada.
  String get falada => texto.trim().isNotEmpty ? texto : executadas.map((e) => e.detalhe).join('. ');

  /// Texto do balão: a resposta seguida das ações (✔ feita, ✖ falhou).
  String get completa => [
    texto,
    for (final e in executadas) '${e.ok ? '✔' : '✖'} ${e.detalhe}',
    for (final (titulo, url) in links.take(3)) '🔗 $titulo — $url',
  ].where((l) => l.isNotEmpty).join('\n');
}

/// Uso de um provedor de LLM na janela do dashboard.
class UsoProvedor {
  UsoProvedor.fromJson(this.nome, Map<String, dynamic> j)
    : pedidos = j['pedidos'] as int,
      erros = j['erros'] as int,
      disponibilidade = (j['disponibilidade_pct'] as num).toDouble(),
      p50 = j['latencia_p50_ms'] as int?,
      p95 = j['latencia_p95_ms'] as int?,
      tokensEntrada = j['tokens_entrada'] as int,
      tokensSaida = j['tokens_saida'] as int;

  final String nome;
  final int pedidos;
  final int erros;
  final double disponibilidade;
  final int? p50;
  final int? p95;
  final int tokensEntrada;
  final int tokensSaida;
}

class Dashboard {
  Dashboard.fromJson(Map<String, dynamic> j)
    : provedores = [
        for (final MapEntry(:key, :value) in (j['provedores'] as Map<String, dynamic>).entries)
          UsoProvedor.fromJson(key, value as Map<String, dynamic>),
      ],
      configurados = [for (final c in j['configurados'] as List) '$c'],
      workers = [for (final w in j['workers'] as List) w as Map<String, dynamic>],
      recentes = [for (final r in j['recentes'] as List) r as Map<String, dynamic>];

  final List<UsoProvedor> provedores;
  final List<String> configurados;

  /// `{id, modelos, visto_ha_s, recursos: {cpu_pct, ram_pct, gpus: [...]}}`.
  final List<Map<String, dynamic>> workers;

  /// Últimos pedidos, do mais novo: `{em, provedor, tarefa, modelo, ms, erro, tokens_*}`.
  final List<Map<String, dynamic>> recentes;
}
