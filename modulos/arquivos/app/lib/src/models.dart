import 'dart:math';
import 'dart:ui';

/// A library file (`/api/arquivos`).
/// Formats with their own viewer; the rest (spreadsheets, statements…) falls into [other].
enum FileFormat {
  pdf('PDF', ['pdf']),
  docx('DOCX', ['docx', 'doc', 'odt', 'rtf']),
  pptx('PPTX', ['pptx', 'ppt', 'odp']),
  xlsx('XLSX', ['xlsx', 'xls', 'ods']),
  csv('CSV', ['csv']),
  xml('XML', ['xml']),
  other('Outros', []);

  const FileFormat(this.label, this.extensions);

  final String label;
  final List<String> extensions;

  static FileFormat fromExtension(String ext) =>
      values.firstWhere((f) => f.extensions.contains(ext.toLowerCase()), orElse: () => other);
}

class FileItem {
  FileItem({
    required this.id,
    required this.title,
    required this.nomeOriginal,
    required this.extension,
    required this.type,
    required this.size,
    this.sha256 = '',
    required this.pasta,
    required this.tags,
    required this.status,
    required this.error,
    required this.highlights,
    required this.updated,
  });

  factory FileItem.fromJson(Map<String, dynamic> j) => FileItem(
    id: j['id'] as String,
    title: j['titulo'] as String,
    nomeOriginal: j['nome_original'] as String,
    extension: j['extensao'] as String,
    type: j['tipo'] as String,
    size: j['tamanho'] as int,
    sha256: j['sha256'] as String? ?? '',
    pasta: j['pasta'] as String? ?? '',
    tags: [...(j['tags'] as List? ?? const []).cast<String>()],
    status: j['status'] as String,
    error: j['erro'] as String?,
    highlights: j['destaques'] as int? ?? 0,
    updated: DateTime.parse(j['atualizado'] as String),
  );

  final String id;
  final String title;
  final String nomeOriginal;
  final String extension;

  /// `pdf`, `documento`, `apresentacao`, `planilha`, `extrato` (both come from Finanças) or `xml` (no PDF).
  final String type;
  final int size;

  /// Changes when the original is edited (in the app, in an external editor or on another device).
  final String sha256;
  final String pasta;
  final List<String> tags;

  /// `pronto`, `convertendo` or `erro`.
  final String status;
  final String? error;
  final int highlights;
  final DateTime updated;

  bool get pronto => status == 'pronto';

  /// Extension group used in the library filter and to pick the viewer.
  FileFormat get formatStr => FileFormat.fromExtension(extension);

  Map<String, dynamic> toJson() => {
    'id': id,
    'titulo': title,
    'nome_original': nomeOriginal,
    'extensao': extension,
    'tipo': type,
    'tamanho': size,
    'sha256': sha256,
    'pasta': pasta,
    'tags': tags,
    'status': status,
    'erro': error,
    'destaques': highlights,
    'atualizado': updated.toIso8601String(),
  };
}

/// Freehand drawing brushes. The name is what goes into the JSON.
enum Brush { caneta, lapis, caligrafia, marcador }

/// Point of a stroke in PDF points of the page (origin at the top-left corner, as displayed) and
/// pressure from 0 to 1.
class InkPoint {
  const InkPoint(this.x, this.y, this.p);

  final double x;
  final double y;
  final double p;

  Offset get offset => Offset(x, y);
}

/// Annotation element: everything saved has an `id` and a `pagina` (0 = first).
abstract class SlideElement {
  String get id;
  int get page;

  /// Reading projects (Estudos module) the element belongs to.
  List<String> get projects;
  SlideElement withProjects(List<String> projects);
  Map<String, dynamic> toJson();
}

List<String> _projects(Map<String, dynamic> j) => [...(j['projetos'] as List? ?? const []).cast<String>()];

class InkStroke implements SlideElement {
  InkStroke({
    required this.id,
    required this.page,
    required this.brush,
    required this.color,
    required this.thickness,
    required this.points,
    this.projects = const [],
  });

  factory InkStroke.fromJson(Map<String, dynamic> j) {
    final p = (j['pontos'] as List).cast<num>();
    return InkStroke(
      id: j['id'] as String,
      page: j['pagina'] as int,
      brush: Brush.values.asNameMap()[j['pincel']] ?? Brush.caneta,
      color: Color(j['cor'] as int),
      thickness: (j['espessura'] as num).toDouble(),
      points: [
        for (var i = 0; i + 2 < p.length; i += 3) InkPoint(p[i].toDouble(), p[i + 1].toDouble(), p[i + 2].toDouble()),
      ],
      projects: _projects(j),
    );
  }

  @override
  final String id;
  @override
  final int page;
  final Brush brush;
  final Color color;
  final double thickness;
  final List<InkPoint> points;
  @override
  final List<String> projects;

  @override
  InkStroke withProjects(List<String> projects) =>
      InkStroke(id: id, page: page, brush: brush, color: color, thickness: thickness, points: points, projects: projects);

  /// Rectangle containing the stroke, with the thickness.
  Rect get bounds {
    if (points.isEmpty) return Rect.zero;
    var r = Rect.fromPoints(points.first.offset, points.first.offset);
    for (final p in points) {
      r = r.expandToInclude(Rect.fromPoints(p.offset, p.offset));
    }
    return r.inflate(thickness);
  }

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'pagina': page,
    'pincel': brush.name,
    'cor': color.toARGB32(),
    'espessura': thickness,
    // Flat x, y, pressure list with two decimals: a long stroke takes only a few KB.
    'pontos': [
      for (final p in points) ...[_round(p.x), _round(p.y), _round(p.p)],
    ],
    if (projects.isNotEmpty) 'projetos': projects,
  };
}

/// Excerpt marked with the smart highlighter: stores the text to become a note reference.
class Highlight implements SlideElement {
  Highlight({
    required this.id,
    required this.page,
    required this.text,
    required this.color,
    required this.rectangles,
    this.comment = '',
    this.translation = '',
    required this.created,
    this.projects = const [],
  });

  factory Highlight.fromJson(Map<String, dynamic> j) => Highlight(
    id: j['id'] as String,
    page: j['pagina'] as int,
    text: j['texto'] as String? ?? '',
    color: Color(j['cor'] as int),
    rectangles: [
      for (final r in (j['retangulos'] as List? ?? const []).cast<List>())
        Rect.fromLTRB(
          (r[0] as num).toDouble(),
          (r[1] as num).toDouble(),
          (r[2] as num).toDouble(),
          (r[3] as num).toDouble(),
        ),
    ],
    comment: j['comentario'] as String? ?? '',
    translation: j['traducao'] as String? ?? '',
    created: DateTime.tryParse(j['criado'] as String? ?? '') ?? DateTime.now(),
    projects: _projects(j),
  );

  @override
  final String id;
  @override
  final int page;
  final String text;
  final Color color;
  final List<Rect> rectangles;
  final String comment;

  /// Translation into Portuguese (the original excerpt is usually in English).
  final String translation;
  final DateTime created;
  @override
  final List<String> projects;

  Highlight copy({String? comment, String? translation, List<String>? projects}) => Highlight(
    id: id,
    page: page,
    text: text,
    color: color,
    rectangles: rectangles,
    comment: comment ?? this.comment,
    translation: translation ?? this.translation,
    created: created,
    projects: projects ?? this.projects,
  );

  Highlight withComment(String c) => copy(comment: c);

  @override
  Highlight withProjects(List<String> projects) => copy(projects: projects);

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'pagina': page,
    'texto': text,
    'cor': color.toARGB32(),
    'retangulos': [
      for (final r in rectangles) [_round(r.left), _round(r.top), _round(r.right), _round(r.bottom)],
    ],
    'comentario': comment,
    if (translation.isNotEmpty) 'traducao': translation,
    'criado': created.toUtc().toIso8601String(),
    if (projects.isNotEmpty) 'projetos': projects,
  };
}

/// Text box written over the page.
class AnnotatedText implements SlideElement {
  AnnotatedText({
    required this.id,
    required this.page,
    required this.position,
    required this.text,
    required this.color,
    required this.size,
    this.projects = const [],
  });

  factory AnnotatedText.fromJson(Map<String, dynamic> j) => AnnotatedText(
    id: j['id'] as String,
    page: j['pagina'] as int,
    position: Offset((j['x'] as num).toDouble(), (j['y'] as num).toDouble()),
    text: j['texto'] as String,
    color: Color(j['cor'] as int),
    size: (j['tamanho'] as num).toDouble(),
    projects: _projects(j),
  );

  @override
  final String id;
  @override
  final int page;
  final Offset position;
  final String text;
  final Color color;
  final double size;
  @override
  final List<String> projects;

  AnnotatedText withText(String t) =>
      AnnotatedText(id: id, page: page, position: position, text: t, color: color, size: size, projects: projects);

  @override
  AnnotatedText withProjects(List<String> projects) => AnnotatedText(
    id: id,
    page: page,
    position: position,
    text: text,
    color: color,
    size: size,
    projects: projects,
  );

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'pagina': page,
    'x': _round(position.dx),
    'y': _round(position.dy),
    'texto': text,
    'cor': color.toARGB32(),
    'tamanho': size,
    if (projects.isNotEmpty) 'projetos': projects,
  };
}

/// Immutable state of a file's annotations. Each edit produces a new one (which gives undo for
/// free and allows merging with the server by comparing with the last synced version).
class Annotations {
  const Annotations({this.version = 0, this.strokes = const [], this.highlights = const [], this.texts = const []});

  factory Annotations.fromJson(Map<String, dynamic> j) => Annotations(
    version: j['versao'] as int? ?? 0,
    strokes: [for (final t in (j['tracos'] as List? ?? const [])) InkStroke.fromJson(t as Map<String, dynamic>)],
    highlights: [for (final d in (j['destaques'] as List? ?? const [])) Highlight.fromJson(d as Map<String, dynamic>)],
    texts: [for (final t in (j['textos'] as List? ?? const [])) AnnotatedText.fromJson(t as Map<String, dynamic>)],
  );

  final int version;
  final List<InkStroke> strokes;
  final List<Highlight> highlights;
  final List<AnnotatedText> texts;

  Map<String, dynamic> toJson({required int baseVersion}) => {
    'versao_base': baseVersion,
    'tracos': [for (final t in strokes) t.toJson()],
    'destaques': [for (final d in highlights) d.toJson()],
    'textos': [for (final t in texts) t.toJson()],
  };

  Annotations copy({int? version, List<InkStroke>? strokes, List<Highlight>? highlights, List<AnnotatedText>? texts}) =>
      Annotations(
        version: version ?? this.version,
        strokes: strokes ?? this.strokes,
        highlights: highlights ?? this.highlights,
        texts: texts ?? this.texts,
      );

  Annotations adicionar(SlideElement e) => switch (e) {
    InkStroke t => copy(strokes: [...strokes, t]),
    Highlight d => copy(highlights: [...highlights, d]),
    AnnotatedText t => copy(texts: [...texts, t]),
    _ => this,
  };

  Annotations replace(SlideElement e) => switch (e) {
    InkStroke t => copy(strokes: [for (final x in strokes) x.id == t.id ? t : x]),
    Highlight d => copy(highlights: [for (final x in highlights) x.id == d.id ? d : x]),
    AnnotatedText t => copy(texts: [for (final x in texts) x.id == t.id ? t : x]),
    _ => this,
  };

  Annotations remover(Set<String> ids) => copy(
    strokes: [
      for (final t in strokes)
        if (!ids.contains(t.id)) t,
    ],
    highlights: [
      for (final d in highlights)
        if (!ids.contains(d.id)) d,
    ],
    texts: [
      for (final t in texts)
        if (!ids.contains(t.id)) t,
    ],
  );

  /// Merges what changed here since [base] (the last synced version) with what came from the
  /// [server]: local additions and edits go in, local removals go out, the rest is the server's.
  static Annotations merge(Annotations base, Annotations local, Annotations server) {
    List<T> items<T extends SlideElement>(List<T> b, List<T> l, List<T> s) {
      final idsBase = {for (final e in b) e.id: e};
      final localItems = {for (final e in l) e.id: e};
      final removed = idsBase.keys.where((id) => !localItems.containsKey(id)).toSet();
      final changedItems = {
        for (final e in l)
          if (!identical(idsBase[e.id], e)) e.id: e,
      };
      final result = [
        for (final e in s)
          if (!removed.contains(e.id)) changedItems.remove(e.id) ?? e,
      ];
      return [...result, ...changedItems.values];
    }

    return Annotations(
      version: server.version,
      strokes: items(base.strokes, local.strokes, server.strokes),
      highlights: items(base.highlights, local.highlights, server.highlights),
      texts: items(base.texts, local.texts, server.texts),
    );
  }
}

/// Highlight of any file, as `/api/arquivos/destaques` returns it.
class Reference {
  Reference({required this.highlight, required this.fileId, required this.fileTitle, required this.citation});

  factory Reference.fromJson(Map<String, dynamic> j) => Reference(
    highlight: Highlight.fromJson(j),
    fileId: j['arquivo_id'] as String,
    fileTitle: j['arquivo_titulo'] as String,
    citation: j['referencia'] as String,
  );

  /// Same citation format the server builds (`referencia()` in `arquivos/biblioteca.py`).
  factory Reference.de(Highlight d, FileItem a) {
    final text = d.text.split(RegExp(r'\s+')).join(' ').trim();
    return Reference(
      highlight: d,
      fileId: a.id,
      fileTitle: a.title,
      citation: '${text.isEmpty ? '' : '> $text\n'}— [[${a.title}]], p. ${d.page + 1}',
    );
  }

  final Highlight highlight;
  final String fileId;
  final String fileTitle;

  /// Ready Markdown citation (`> trecho\n— [[Título]], p. N`).
  final String citation;
}

final _random = Random();

/// Short id, unique enough for the elements of a file.
String newId() =>
    DateTime.now().microsecondsSinceEpoch.toRadixString(36) + _random.nextInt(1 << 20).toRadixString(36);

double _round(double v) => (v * 100).roundToDouble() / 100;
