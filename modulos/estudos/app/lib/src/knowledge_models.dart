/// Knowledge tracks (`/api/estudos/conhecimento`): steps with the chapter hints.
library;

List<String> _strings(dynamic v) => [for (final x in (v as List? ?? const [])) '$x'];

/// The reading of the Leituras tab linked to the book (where the PDF to read and highlight lives).
class LinkedReading {
  LinkedReading.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      status = j['status'] as String? ?? '',
      fileId = j['arquivo_id'] as String?,
      currentPage = j['pagina_atual'] as int? ?? 0;

  final String id, status;
  final String? fileId;
  final int currentPage;
}

class TrackBook {
  TrackBook.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      title = j['titulo'] as String,
      original = j['original'] as String? ?? '',
      author = j['autor'] as String? ?? '',
      edition = j['edicao'] as String? ?? '',
      type = j['tipo'] as String? ?? 'livro',
      url = j['url'] as String? ?? '',
      owned = j['tenho'] as bool? ?? false,
      hints = j['indicacoes'] as int? ?? 0,
      reading = j['leitura'] == null ? null : LinkedReading.fromJson(j['leitura']);

  final String id, title, original, author, edition, type, url;
  final bool owned;
  final int hints;
  final LinkedReading? reading;
}

class ChapterHint {
  ChapterHint.fromJson(Map<String, dynamic> j)
    : score = j['indice'] as int,
      chapters = j['capitulos'] as String,
      focus = j['foco'] as String? ?? '',
      done = j['feita'] as String?,
      book = TrackBook.fromJson(j['livro']);

  final int score;
  final String chapters, focus;

  /// Date it was read (null = to read).
  final String? done;
  final TrackBook book;
}

class TrackStep {
  TrackStep.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      phase = j['fase'] as String,
      title = j['titulo'] as String,
      goal = j['objetivo'] as String? ?? '',
      practice = j['pratica'] as String? ?? '',
      deliverable = j['entregavel'] as String? ?? '',
      fronts = _strings(j['frentes']),
      concepts = _strings(j['conceitos']),
      readings = [for (final x in j['leituras'] as List) ChapterHint.fromJson(x)],
      practiceDone = j['pratica_feita'] as String?,
      noteId = j['nota_id'] as String?,
      progress = (j['progresso'] as num).toDouble(),
      completed = j['concluida'] as bool;

  final String id, phase, title, goal, practice, deliverable;
  final List<String> fronts, concepts;
  final List<ChapterHint> readings;
  final String? practiceDone, noteId;
  final double progress;
  final bool completed;
}

/// What to do now: `leitura` (chapter of a book you own), `conseguir` (missing book) or `pratica`.
class NextUp {
  NextUp.fromJson(Map<String, dynamic> j)
    : type = j['tipo'] as String,
      stepId = j['etapa_id'] as String,
      step = j['etapa'] as String,
      phase = j['fase'] as String,
      practice = j['pratica'] as String? ?? '',
      hint = j['indicacao'] == null ? null : ChapterHint.fromJson(j['indicacao']);

  final String type, stepId, step, phase, practice;
  final ChapterHint? hint;
}

class KnowledgeTrack {
  KnowledgeTrack.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      area = j['area'] as String? ?? '',
      title = j['titulo'] as String,
      descricao = j['descricao'] as String? ?? '',
      fronts = _strings(j['frentes']),
      front = j['frente'] as String?,
      steps = [for (final x in j['etapas'] as List? ?? const []) TrackStep.fromJson(x)],
      totalSteps = j['total_etapas'] as int? ?? 0,
      completedSteps = j['etapas_concluidas'] as int? ?? 0,
      progress = (j['progresso'] as num? ?? 0).toDouble(),
      next = j['proxima'] == null ? null : NextUp.fromJson(j['proxima']);

  final String id, area, title, descricao;
  final List<String> fronts;
  final String? front;
  final List<TrackStep> steps;
  final int totalSteps, completedSteps;
  final double progress;
  final NextUp? next;
}
