List<String> _strings(dynamic v) => [for (final x in (v as List? ?? const [])) '$x'];

/// Areas, statuses, languages and levels accepted by the backend (`/api/estudos/opcoes`).
class StudyOptions {
  StudyOptions.fromJson(Map<String, dynamic> j)
    : areas = _strings(j['areas']),
      status = _strings(j['status']),
      languages = {for (final e in (j['idiomas'] as Map).entries) '${e.key}': '${e.value}'},
      levels = _strings(j['niveis']),
      citationTypes = _strings(j['tipos_citacao']),
      contentTypes = _strings(j['tipos_conteudo']),
      statusUso = _strings(j['status_uso']);

  final List<String> areas, status, levels, citationTypes, contentTypes, statusUso;
  final Map<String, String> languages;
}

/// Book or article, with the synthesis note (Obsidian) linked by [noteId].
class Reading {
  Reading.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      title = j['titulo'] as String,
      author = j['autor'] as String? ?? '',
      type = j['tipo'] as String? ?? 'livro',
      area = j['area'] as String,
      status = j['status'] as String,
      pages = j['paginas'] as int?,
      currentPage = j['pagina_atual'] as int? ?? 0,
      noteId = j['nota_id'] as String?,
      fileId = j['arquivo_id'] as String?,
      url = j['url'] as String? ?? '',
      tags = _strings(j['tags']);

  final String id, title, author, type, area, status, url;
  final int? pages;
  final int currentPage;
  final String? noteId;

  /// PDF of the reading in Arquivos (the Linguagem writing can start from it).
  final String? fileId;
  final List<String> tags;

  double? get progress => pages == null ? null : (currentPage / pages!).clamp(0, 1).toDouble();
}

class Marco {
  Marco.fromJson(Map<String, dynamic> j)
    : level = j['nivel'] as String,
      totalHours = (j['horas_total'] as num).toDouble(),
      hoursLeft = (j['horas_faltando'] as num).toDouble(),
      isCompleted = j['concluido'] as bool,
      forecast = j['previsao'] == null ? null : DateTime.parse(j['previsao'] as String);

  final String level;
  final double totalHours, hoursLeft;
  final bool isCompleted;
  final DateTime? forecast;
}

/// Track of a language: pace (minutes × weekdays), level and forecast of each milestone.
class Track {
  Track.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      language = j['idioma'] as String,
      name = j['nome'] as String,
      startLevel = j['nivel_inicial'] as String,
      targetLevel = j['nivel_alvo'] as String,
      currentLevel = j['nivel_atual'] as String,
      minutesPerDay = j['minutos_por_dia'] as int,
      weekdays = [for (final d in j['dias_semana'] as List) d as int],
      start = DateTime.parse(j['inicio'] as String),
      hours = (j['horas'] as num).toDouble(),
      marcos = [for (final m in j['marcos'] as List) Marco.fromJson(m)];

  final String id, language, name, startLevel, targetLevel, currentLevel;
  final int minutesPerDay;
  final List<int> weekdays;
  final DateTime start;
  final double hours;
  final List<Marco> marcos;
}

class ScheduleBlock {
  ScheduleBlock.fromJson(Map<String, dynamic> j)
    : skill = j['habilidade'] as String,
      title = j['titulo'] as String,
      minutes = j['minutos'] as int,
      descricao = j['descricao'] as String;

  final String skill, title, descricao;
  final int minutes;
}

/// One day of the generated schedule, with the blocks and the minutes already logged.
class StudyDay {
  StudyDay.fromJson(Map<String, dynamic> j)
    : data = DateTime.parse(j['data'] as String),
      level = j['nivel'] as String,
      theme = j['tema'] as String,
      minutes = j['minutos'] as int,
      doneMinutes = j['feito_minutos'] as int? ?? 0,
      blocks = [for (final b in j['blocos'] as List) ScheduleBlock.fromJson(b)];

  final DateTime data;
  final String level, theme;
  final int minutes, doneMinutes;
  final List<ScheduleBlock> blocks;

  bool get done => doneMinutes > 0;
}

class GraphNode {
  GraphNode.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      title = j['titulo'] as String,
      type = j['tipo'] as String? ?? 'nota',
      tags = _strings(j['tags']),
      degree = j['grau'] as int? ?? 0;

  final String id, title, type;
  final List<String> tags;
  final int degree;
}

class Edge {
  Edge.fromJson(Map<String, dynamic> j)
    : de = j['de'] as String,
      to = j['para'] as String,
      type = j['tipo'] as String;

  final String de, to, type;
}

/// Reading project (pre-thesis, video…): gathers excerpts, comments and handwritten notes made in the
/// Arquivos module with the project active (or linked from the highlight panel).
class ReadingProject {
  ReadingProject.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      name = j['nome'] as String,
      descricao = j['descricao'] as String? ?? '',
      color = j['cor'] as int? ?? 0xFF3F51B5,
      sections = _strings(j['secoes']),
      excerpts = j['trechos'] as int? ?? 0,
      comments = j['comentarios'] as int? ?? 0,
      handwritings = j['manuscritos'] as int? ?? 0,
      papers = j['trabalhos'] as int? ?? 0,
      updated = DateTime.tryParse(j['atualizado'] as String? ?? '');

  final String id, name, descricao;
  final int color, excerpts, comments, handwritings, papers;
  final List<String> sections;
  final DateTime? updated;
}

/// Read paper (article, book…) with the citation sheet; [code] = T001…
class MatrixPaper {
  MatrixPaper.fromJson(Map<String, dynamic> j)
    : code = j['codigo'] as String,
      fileId = j['arquivo_id'] as String,
      readingId = j['leitura_id'] as String?,
      title = j['titulo'] as String? ?? '',
      author = j['autor'] as String? ?? '',
      citationAuthor = j['autor_citacao'] as String? ?? '',
      year = j['ano'] as String? ?? '',
      reference = j['referencia'] as String? ?? '',
      publicationType = j['tipo_publicacao'] as String? ?? '',
      venue = j['veiculo'] as String? ?? '',
      doi = j['doi'] as String? ?? '',
      language = j['idioma'] as String? ?? '',
      excerpts = j['trechos'] as int? ?? 0,
      usedItems = j['usados'] as int? ?? 0;

  final String code, fileId, title, author, citationAuthor, year, reference, publicationType, venue, doi, language;
  final String? readingId;
  final int excerpts, usedItems;
}

/// Matrix item: marked excerpt, comment written on the page or handwritten note (per page).
class MatrixItem {
  MatrixItem.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      type = j['tipo'] as String,
      code = j['codigo'] as String? ?? '',
      paper = j['trabalho'] as String? ?? '',
      fileId = j['arquivo_id'] as String,
      fileTitle = j['arquivo_titulo'] as String? ?? '',
      page = j['pagina'] as int? ?? 0,
      text = j['texto'] as String? ?? '',
      translation = j['traducao'] as String? ?? '',
      comment = j['comentario'] as String? ?? '',
      color = j['cor'] as int?,
      parentheticalCitation = j['citacao_parentetica'] as String? ?? '',
      narrativeCitation = j['citacao_narrativa'] as String? ?? '',
      strokes = [for (final t in j['tracos'] as List? ?? const []) HandStroke.fromJson(t as Map<String, dynamic>)],
      classification = {
        for (final e in (j['classificacao'] as Map? ?? const {}).entries) '${e.key}': '${e.value ?? ''}',
      };

  final String id, type, code, paper, fileId, fileTitle, text, translation, comment;
  final String parentheticalCitation, narrativeCitation;
  final int page;
  final int? color;
  final List<HandStroke> strokes;
  final Map<String, String> classification;

  String field(String name) => classification[name] ?? '';

  bool get used => field('status_uso') == 'Usado';

  /// Text for search: everything that shows on the card.
  String get search =>
      [text, translation, comment, fileTitle, narrativeCitation, ...classification.values].join(' ').toLowerCase();
}

/// Handwritten stroke (x, y, pressure points in PDF points of the page).
class HandStroke {
  HandStroke.fromJson(Map<String, dynamic> j)
    : color = j['cor'] as int? ?? 0xFF111111,
      thickness = (j['espessura'] as num? ?? 2).toDouble(),
      marker = j['pincel'] == 'marcador',
      points = [for (final v in j['pontos'] as List? ?? const []) (v as num).toDouble()];

  final int color;
  final double thickness;
  final bool marker;
  final List<double> points;
}

class Matrix {
  Matrix.fromJson(Map<String, dynamic> j)
    : project = ReadingProject.fromJson(j['projeto'] as Map<String, dynamic>),
      papers = [for (final t in j['trabalhos'] as List) MatrixPaper.fromJson(t as Map<String, dynamic>)],
      itens = [for (final i in j['itens'] as List) MatrixItem.fromJson(i as Map<String, dynamic>)];

  final ReadingProject project;
  final List<MatrixPaper> papers;
  final List<MatrixItem> itens;
}
