typedef Doc = Map<String, dynamic>;

String iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// `2027-01-24` → `24/01/2027` (curto: `24/01`).
String dataBr(String? isoData, {bool short = false}) {
  if (isoData == null || isoData.length < 10) return '—';
  final p = isoData.substring(0, 10).split('-');
  return short ? '${p[2]}/${p[1]}' : '${p[2]}/${p[1]}/${p[0]}';
}

class Deadline {
  Deadline.fromJson(Doc j)
    : id = j['id'] as String? ?? '',
      title = j['titulo'] as String,
      data = j['data'] as String,
      time = j['hora'] as String? ?? '',
      type = j['tipo'] as String? ?? 'outro',
      detail = j['detalhe'] as String? ?? '',
      origin = j['origem'] as String? ?? 'edital';

  final String id, title, data, time, type, detail, origin;
}

class Task {
  Task.fromJson(Doc j)
    : id = j['id'] as String,
      data = j['data'] as String,
      type = j['tipo'] as String,
      discipline = j['disciplina'] as String? ?? '',
      title = j['titulo'] as String,
      detail = j['detalhe'] as String? ?? '',
      minuteCount = j['minutos'] as int,
      done = j['feito'] as bool? ?? false,
      key = j['chave'] as String?;

  final String id, data, type, discipline, title, detail;
  final int minuteCount;
  final String? key;
  bool done;
}

class Topic {
  Topic.fromJson(Doc j)
    : title = j['titulo'] as String,
      content = j['conteudo'] as String? ?? '',
      hours = (j['horas'] as num?)?.toDouble() ?? 0,
      priority = j['prioridade'] as String? ?? 'media';

  final String title, content, priority;
  final double hours;
}

class Discipline {
  Discipline.fromJson(Doc j)
    : name = j['nome'] as String,
      modulo = j['modulo'] as String? ?? '',
      questions = j['questoes'] as int? ?? 0,
      topics = [for (final t in j['topicos'] as List? ?? const []) Topic.fromJson(t as Doc)];

  final String name, modulo;
  final int questions;
  final List<Topic> topics;
}

/// List item (`GET /api/concursos`).
class ExamSummary {
  ExamSummary.fromJson(Doc j)
    : id = j['id'] as String,
      name = j['nome'] as String,
      board = j['banca'] as String? ?? '',
      cargo = j['cargo'] as String? ?? '',
      examDate = j['data_prova'] as String?,
      daysToExam = j['dias_para_prova'] as int?,
      state = j['estado'] as String,
      hasNotice = j['tem_edital'] as bool? ?? false,
      tasks = j['tarefas'] as int? ?? 0,
      doneCount = j['feitas'] as int? ?? 0,
      overdue = j['atrasadas'] as int? ?? 0,
      nextDeadline = j['proximo_prazo'] == null ? null : Deadline.fromJson(j['proximo_prazo'] as Doc);

  final String id, name, board, cargo, state;
  final String? examDate;
  final int? daysToExam;
  final bool hasNotice;
  final int tasks, doneCount, overdue;
  final Deadline? nextDeadline;

  double get progress => tasks == 0 ? 0 : doneCount / tasks;
}

/// Concurso completo (`GET /api/concursos/{id}`).
class Exam {
  Exam.fromJson(Doc j)
    : id = j['id'] as String,
      name = j['nome'] as String,
      board = j['banca'] as String? ?? '',
      cargo = j['cargo'] as String? ?? '',
      examDate = j['data_prova'] as String?,
      weekdayMinutes = j['minutos_util'] as int? ?? 120,
      weekendMinutes = j['minutos_fds'] as int? ?? 240,
      notes = j['observacoes'] as String? ?? '',
      noticeName = (j['edital'] as Doc?)?['nome'] as String?,
      state = (j['geracao'] as Doc)['estado'] as String,
      error = (j['geracao'] as Doc)['erro'] as String? ?? '',
      structure = j['estrutura'] as Doc?,
      planSummary = j['resumo_plano'] as Doc?,
      deadlines = [for (final p in j['prazos'] as List) Deadline.fromJson(p as Doc)],
      tasks = [for (final t in j['tarefas'] as List) Task.fromJson(t as Doc)],
      status = ExamSummary.fromJson(j['situacao'] as Doc),
      radar = j['radar'] as Doc?;

  final String id, name, board, cargo, notes, state, error;
  final String? examDate, noticeName;
  final int weekdayMinutes, weekendMinutes;
  final Doc? structure, planSummary;
  final List<Deadline> deadlines;
  final List<Task> tasks;
  final ExamSummary status;

  /// Radar sheet when the exam came from there: opening, registration, nearest exam location.
  final Doc? radar;

  bool get generating => state == 'gerando';

  List<Discipline> get subjects => [
    for (final d in structure?['disciplinas'] as List? ?? const []) Discipline.fromJson(d as Doc),
  ];

  List<String> get strategy => [for (final s in structure?['estrategia'] as List? ?? const []) s as String];
}

class Alert {
  Alert.fromJson(Doc j)
    : level = j['nivel'] as String,
      text = j['texto'] as String,
      examId = j['concurso_id'] as String?;

  final String level, text;
  final String? examId;
}

/// City with coordinates; on exam locations, `km`/`horas` of the route from the origin.
class Local {
  Local.fromJson(Doc j)
    : city = j['cidade'] as String? ?? '',
      uf = j['uf'] as String? ?? '',
      lat = (j['lat'] as num).toDouble(),
      lon = (j['lon'] as num).toDouble(),
      km = (j['km'] as num?)?.toInt(),
      straightKm = (j['km_reta'] as num?)?.toInt(),
      hours = (j['horas'] as num?)?.toDouble(),
      estimated = j['estimada'] as bool? ?? false,
      supposed = j['suposto'] as bool? ?? false;

  final String city, uf;
  final double lat, lon;
  final int? km, straightKm;
  final double? hours;
  final bool estimated, supposed;

  String get name => '$city/$uf';
}

class ItJob {
  ItJob.fromJson(Doc j)
    : cargo = j['cargo'] as String,
      openings = j['vagas'] as int? ?? 0,
      reserveList = j['cadastro_reserva'] as bool? ?? false,
      salary = (j['salario'] as num?)?.toDouble() ?? 0,
      requirements = j['requisitos'] as String? ?? '';

  final String cargo, requirements;
  final int openings;
  final bool reserveList;
  final double salary;
}

/// IT exam found by the radar (PCI + local LLM).
class ItemRadar {
  ItemRadar.fromJson(Doc j)
    : id = j['id'] as String,
      agency = j['orgao'] as String,
      uf = j['uf'] as String? ?? '',
      url = j['url'] as String,
      board = j['banca'] as String? ?? '',
      noticeUrl = j['edital_url'] as String? ?? '',
      registrationLink = j['link_inscricao'] as String? ?? '',
      registrationStart = j['inscricoes_inicio'] as String? ?? '',
      registrationEnd = (j['inscricoes_fim'] as String?) ?? (j['inscricao_ate'] as String? ?? ''),
      examDate = j['data_prova'] as String? ?? '',
      examTime = j['horario_prova'] as String? ?? '',
      fee = j['taxa'] as String? ?? '',
      summary = j['resumo'] as String? ?? '',
      level = j['nivel'] as String? ?? '',
      status = j['situacao'] as String? ?? '',
      source = j['fonte'] as String? ?? 'pci',
      sphere = j['esfera'] as String? ?? '',
      openings = [for (final v in j['vagas_ti'] as List? ?? const []) ItJob.fromJson(v as Doc)],
      totalOpenings = j['total_vagas_ti'] as int? ?? 0,
      maxSalary = (j['salario_max'] as num?)?.toDouble() ?? 0,
      headquarters = j['sede'] == null ? null : Local.fromJson(j['sede'] as Doc),
      places = [for (final l in j['locais_prova'] as List? ?? const []) Local.fromJson(l as Doc)],
      nearest = j['mais_proximo'] == null ? null : Local.fromJson(j['mais_proximo'] as Doc);

  final String id, agency, uf, url, board, noticeUrl, registrationLink, registrationStart, registrationEnd;
  final String examDate, examTime, fee, summary, level;

  /// `aberto` or `previsto` (only on those found by Claude); `fonte`: `pci` or `claude`.
  final String status, source;

  /// `federal`, `estadual` or `municipal`.
  final String sphere;
  final List<ItJob> openings;
  final int totalOpenings;
  final double maxSalary;
  final Local? headquarters, nearest;
  final List<Local> places;
}

class Radar {
  Radar.fromJson(Doc j)
    : updated = j['atualizado'] as String?,
      error = j['erro'] as String? ?? '',
      collecting = j['coletando'] as bool? ?? false,
      pending = j['pendentes'] as int? ?? 0,
      failures = j['falhas'] as int? ?? 0,
      researchingClaude = j['pesquisando_claude'] as bool? ?? false,
      claudeEm = (j['claude'] as Doc?)?['em'] as String?,
      claudeFound = (j['claude'] as Doc?)?['achados'] as int? ?? 0,
      claudeError = (j['claude'] as Doc?)?['erro'] as String? ?? '',
      origin = j['origem'] == null ? null : Local.fromJson(j['origem'] as Doc),
      itens = [for (final i in j['itens'] as List) ItemRadar.fromJson(i as Doc)];

  Radar._com(Radar r, this.itens)
    : updated = r.updated,
      error = r.error,
      collecting = r.collecting,
      pending = r.pending,
      failures = r.failures,
      researchingClaude = r.researchingClaude,
      claudeEm = r.claudeEm,
      claudeFound = r.claudeFound,
      claudeError = r.claudeError,
      origin = r.origin;

  /// Only the exams of the [spheres] (empty = all).
  Radar onlySpheres(Set<String> spheres) =>
      spheres.isEmpty ? this : Radar._com(this, [for (final i in itens) if (spheres.contains(i.sphere)) i]);

  final String? updated;
  final String error;
  final bool collecting;
  final int pending;
  final int failures;
  final bool researchingClaude;
  final String? claudeEm;
  final int claudeFound;
  final String claudeError;
  final Local? origin;
  final List<ItemRadar> itens;
}

class TravelRoute {
  TravelRoute.fromJson(Doc j)
    : km = (j['km'] as num).toInt(),
      hours = (j['horas'] as num).toDouble(),
      estimated = j['estimada'] as bool? ?? false,
      points = [
        for (final p in j['linha'] as List) (((p as List)[0] as num).toDouble(), (p[1] as num).toDouble()),
      ];

  final int km;
  final double hours;
  final bool estimated;

  /// (lat, lon) pairs of the road, from the origin to the exam location.
  final List<(double, double)> points;
}

/// `13994.78` → `R$ 13.994,78`.
String real(double v) {
  final parts = v.toStringAsFixed(2).split('.');
  final whole = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => '.');
  return 'R\$ $whole,${parts[1]}';
}

/// `2.5` horas → `2h30`.
String duration(double hours) {
  final h = hours.floor();
  final m = ((hours - h) * 60).round();
  return m == 0 ? '${h}h' : '${h}h${m.toString().padLeft(2, '0')}';
}

class Question {
  Question.fromJson(Doc j)
    : n = j['n'] as int,
      discipline = j['disciplina'] as String? ?? '',
      topic = j['topico'] as String? ?? '',
      statement = j['enunciado'] as String,
      choices = [for (final a in j['alternativas'] as List) a as String],
      correctAnswer = j['correta'] as int?,
      comment = j['comentario'] as String?;

  final int n;
  final String discipline, topic, statement;
  final List<String> choices;
  final int? correctAnswer;
  final String? comment;
}

class MockExam {
  MockExam.fromJson(Doc j)
    : id = j['id'] as String,
      title = j['titulo'] as String,
      state = j['estado'] as String,
      error = j['erro'] as String? ?? '',
      minuteCount = j['minutos'] as int? ?? 0,
      created = j['criado'] as String,
      questions = [for (final q in j['questoes'] as List) Question.fromJson(q as Doc)],
      answers = (j['respostas'] as List?)?.cast<int?>(),
      result = j['resultado'] as Doc?;

  final String id, title, state, error, created;
  final int minuteCount;
  final List<Question> questions;
  final List<int?>? answers;
  final Doc? result;

  bool get answered => answers != null;
}

class StudyMaterial {
  StudyMaterial.fromJson(Doc j)
    : title = j['titulo'] as String,
      url = j['url'] as String,
      type = j['tipo'] as String? ?? 'outro',
      discipline = j['disciplina'] as String? ?? '',
      descricao = j['descricao'] as String? ?? '';

  final String title, url, type, discipline, descricao;
}

/// Update of a followed rumor (becomes a notification on the day it is registered).
class RumorUpdate {
  RumorUpdate.fromJson(Doc j)
    : text = j['texto'] as String? ?? '',
      phase = j['fase'] as String? ?? '',
      source = RumorSource.fromJson(j['fonte'] as Doc? ?? const {}),
      registeredAt = j['registrada_em'] as String? ?? '';

  final String text;
  final String phase;
  final RumorSource source;
  final String registeredAt;
}

class RumorSource {
  RumorSource.fromJson(Doc j) : name = j['nome'] as String? ?? '', url = j['url'] as String? ?? '';

  final String name;
  final String url;
}

/// Rumor/forecast of an IT exam (no notice yet), with the sources.
class Rumor {
  Rumor.fromJson(Doc j)
    : id = j['id'] as String,
      agency = j['orgao'] as String? ?? '',
      uf = j['uf'] as String? ?? '',
      sphere = j['esfera'] as String? ?? '',
      phase = j['fase'] as String? ?? 'rumor',
      cargosTi = [for (final c in j['cargos_ti'] as List? ?? const []) c as String],
      plannedOpenings = j['vagas_previstas'] as int? ?? 0,
      newsDate = j['data_noticia'] as String? ?? '',
      summary = j['resumo'] as String? ?? '',
      followed = j['acompanhado'] as bool? ?? false,
      sources = [for (final f in j['fontes'] as List? ?? const []) RumorSource.fromJson(f as Doc)],
      updates = [for (final n in j['novidades'] as List? ?? const []) RumorUpdate.fromJson(n as Doc)];

  final String id;
  final String agency;
  final String uf;
  final String sphere;
  final String phase;
  final List<String> cargosTi;
  final int plannedOpenings;
  final String newsDate;
  final String summary;
  final bool followed;
  final List<RumorSource> sources;
  final List<RumorUpdate> updates;
}

class Rumors {
  Rumors.fromJson(Doc j)
    : researching = j['pesquisando'] as bool? ?? false,
      searchedAt = (j['busca'] as Doc?)?['em'] as String?,
      searchError = (j['busca'] as Doc?)?['erro'] as String? ?? '',
      itens = [for (final i in j['itens'] as List) Rumor.fromJson(i as Doc)];

  final bool researching;
  final String? searchedAt;
  final String searchError;
  final List<Rumor> itens;
}
