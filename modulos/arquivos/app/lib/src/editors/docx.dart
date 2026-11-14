import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// DOCX ⇄ Quill Delta conversion for the simple rich text editor.
///
/// Reads paragraphs (headings, alignment, lists, indent), runs (bold, italic, underline,
/// tachado, fonte, tamanho, cor, realce, sobrescrito/subscrito), tabs, quebras, hyperlinks,
/// track changes (`w:ins`/`w:del` with author and date → [insertionAttribute]/[deletionAttribute])
/// and comments (`comments.xml` → [Comment], excerpt marked with [commentAttribute]).
/// On save it swaps only the body of `word/document.xml` (the final `w:sectPr` stays) and touches the minimum in
/// styles/numbering/rels/comments/settings; the rest of the zip stays the same.

const _nsW = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const _nsR = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _nsRels = 'http://schemas.openxmlformats.org/package/2006/relationships';
const _nsTipos = 'http://schemas.openxmlformats.org/package/2006/content-types';
const _linkRel = '$_nsR/hyperlink';
const _numberingRel = '$_nsR/numbering';
const _commentsRel = '$_nsR/comments';
const _numberingType = 'application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml';
const _commentsType = 'application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml';

const _docPath = 'word/document.xml';
const _stylesPath = 'word/styles.xml';
const _numberingPath = 'word/numbering.xml';
const _commentsPath = 'word/comments.xml';
const _settingsPath = 'word/settings.xml';
const _relsPath = 'word/_rels/document.xml.rels';
const _typesPath = '[Content_Types].xml';

const _changesNotice = 'alterações de formatação rastreadas (ficam aceitas)';

/// Delta attributes for revisions: value = [revisionMark] (`autor|data ISO`).
const insertionAttribute = 'rev_ins';
const deletionAttribute = 'rev_del';

/// Ids of the comments covering the excerpt, comma separated.
const commentAttribute = 'comentario';

String revisionMark(String author, DateTime data) => '$author|${_dataWord(data)}';

/// Author and date of a revision mark.
({String author, DateTime? data}) readMark(String mark) {
  final i = mark.lastIndexOf('|');
  if (i < 0) return (author: mark, data: null);
  return (author: mark.substring(0, i), data: DateTime.tryParse(mark.substring(i + 1)));
}

List<String> commentIds(Object? value) =>
    value is String ? value.split(',').where((s) => s.isNotEmpty).toList() : const [];

String _dataWord(DateTime d) => '${d.toUtc().toIso8601String().split('.').first.replaceAll('Z', '')}Z';

/// Word comment (from the advisor, the reviewer or mine).
class Comment {
  Comment({required this.id, required this.author, required this.text, DateTime? data, String? initial})
    : data = data ?? DateTime.now(),
      initial = initial ?? _initials(author);

  final String id;
  final String author;
  final String text;
  final DateTime data;
  final String initial;

  Comment withText(String isNew) => Comment(id: id, author: author, text: isNew, data: data, initial: initial);

  static String _initials(String author) =>
      author.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).map((p) => p[0].toUpperCase()).take(3).join();
}

/// File that is not a readable .docx.
class InvalidDocx implements Exception {
  InvalidDocx(this.mensagem);

  final String mensagem;

  @override
  String toString() => mensagem;
}

class DocxDocument {
  DocxDocument._(this._zip, this.delta, this.warnings, this.comments, this.tracking);

  final Archive _zip;

  /// Quill ops (`insert` + `attributes`), always ending in `\n`.
  final List<Map<String, dynamic>> delta;

  /// What the simple editor does not keep and is lost on saving from here ("tabelas", "imagens"…).
  final List<String> warnings;

  /// Comments of `word/comments.xml`, in file order.
  final List<Comment> comments;

  /// The document asks for "Controlar alterações" on (`w:trackRevisions` in settings.xml).
  final bool tracking;

  static DocxDocument read(Uint8List bytes) {
    final Archive zip;
    try {
      zip = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw InvalidDocx('Não é um .docx válido (o arquivo não é um pacote zip). .doc, .odt e .rtf não abrem aqui.');
    }
    final doc = _readXml(zip, _docPath) ?? (throw InvalidDocx('Não é um .docx válido: falta word/document.xml.'));
    final root = doc.rootElement;
    if (root.name.namespaceUri != _nsW) {
      throw InvalidDocx('Formato de .docx não suportado (OOXML "Strict" ou outro). Use "Abrir com…".');
    }
    final body = root.getElement('body', namespaceUri: _nsW);
    final reader = _Reader(
      styles: _styleNames(_readXml(zip, _stylesPath)),
      numbering: _listFormats(_readXml(zip, _numberingPath)),
      links: _linkTargets(_readXml(zip, _relsPath)),
    );
    if (body != null) reader.block(body);
    final secoes = body?.findElements('sectPr', namespaceUri: _nsW).length ?? 0;
    if (secoes > 1) reader.warnings.add('seções múltiplas');
    final adjustments = _readXml(zip, _settingsPath);
    final tracking = adjustments?.rootElement.getElement('trackRevisions', namespaceUri: _nsW) != null;
    return DocxDocument._(zip, reader.close(), reader.warnings.toList(), _readComments(zip), tracking);
  }

  /// New .docx: the original with the body swapped for the [delta]. [comments] replaces `comments.xml`
  /// (default: the ones read); [track] turns Word's "Controlar alterações" on/off.
  Uint8List save(List<Map<String, dynamic>> delta, {List<Comment>? comments, bool? track}) {
    final doc = _readXml(_zip, _docPath)!;
    final root = doc.rootElement;
    _declareW(root);
    var body = root.getElement('body', namespaceUri: _nsW);
    if (body == null) {
      body = _element('<w:body/>');
      root.children.add(body);
    }
    final items = comments ?? this.comments;
    final writer = _Writer(
      zip: _zip,
      runPrefix: _ensurePrefix(root, 'r', _nsR),
      comments: {for (final c in items) c.id},
      firstId: items.map((c) => int.tryParse(c.id) ?? 0).fold(0, (a, b) => a > b ? a : b) + 1,
    );
    final bodyXml = writer.body(_lines(delta));
    final section = body.childElements.where((e) => e.name.local == 'sectPr').lastOrNull?.copy();
    body.children.clear();
    body.children.addAll(_elements(bodyXml, runPrefix: writer.runPrefix));
    if (section != null) body.children.add(section);
    if (items.isNotEmpty || _zip.findFile(_commentsPath) != null) writer.saveComments(items);
    if (track != null) writer.track(track);

    final swapped = <String, String>{_docPath: doc.toXmlString(), ...writer.swapped()};
    final expense = Archive();
    for (final f in _zip.files) {
      if (!f.isFile || writer.removed.contains(f.name)) continue;
      final isNew = swapped.remove(f.name);
      expense.add(ArchiveFile.bytes(f.name, isNew != null ? utf8.encode(isNew) : f.content));
    }
    swapped.forEach((name, xml) => expense.add(ArchiveFile.bytes(name, utf8.encode(xml))));
    return ZipEncoder().encodeBytes(expense);
  }
}

// ---------------------------------------------------------------- utilidades XML

XmlDocument? _readXml(Archive zip, String name) {
  final f = zip.findFile(name);
  if (f == null) return null;
  try {
    return XmlDocument.parse(utf8.decode(f.content, allowMalformed: true));
  } on XmlException catch (e) {
    throw InvalidDocx('Não é um .docx válido: XML quebrado em $name ($e).');
  }
}

XmlElement? _w(XmlElement? e, String name) => e?.getElement(name, namespaceUri: _nsW);

String? _val(XmlElement? e) => e?.getAttribute('val', namespaceUri: _nsW);

/// Word on/off property (`<w:b/>`, `<w:b w:val="0"/>`).
bool _links(XmlElement? e) => e != null && !const {'0', 'false', 'off', 'none'}.contains(_val(e));

/// Prefix declared at the root for [ns]; declares [suggested] if missing.
String _ensurePrefix(XmlElement root, String suggested, String ns) {
  for (final a in root.attributes) {
    if (a.name.prefix == 'xmlns' && a.value == ns) return a.name.local;
  }
  root.attributes.add(XmlAttribute(XmlName.qualified('xmlns:$suggested'), ns));
  return suggested;
}

/// Ensures `xmlns:w` at the root: the generated excerpts always use the `w` prefix.
void _declareW(XmlElement root) {
  if (root.getAttribute('xmlns:w') == null) root.attributes.add(XmlAttribute(XmlName.qualified('xmlns:w'), _nsW));
}

/// Elements of an XML excerpt with `w`/`r` prefixes (the namespaces are resolved on reading).
List<XmlElement> _elements(String xml, {String runPrefix = 'r'}) => XmlDocument.parse(
  '<x xmlns:w="$_nsW" xmlns:$runPrefix="$_nsR">$xml</x>',
).rootElement.childElements.map((e) => e.copy()).toList();

XmlElement _element(String xml) => _elements(xml).single;

String _esc(String s) => s
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String _withoutAccent(String s) => s
    .replaceAll(RegExp('[áàâã]'), 'a')
    .replaceAll(RegExp('[éê]'), 'e')
    .replaceAll('í', 'i')
    .replaceAll(RegExp('[óôõ]'), 'o')
    .replaceAll('ú', 'u')
    .replaceAll('ç', 'c');

/// styleId → style name (lowercase).
Map<String, String> _styleNames(XmlDocument? styles) {
  final names = <String, String>{};
  for (final s in styles?.rootElement.findElements('style', namespaceUri: _nsW) ?? const <XmlElement>[]) {
    final id = s.getAttribute('styleId', namespaceUri: _nsW);
    if (id != null) names[id] = (_val(_w(s, 'name')) ?? id).toLowerCase();
  }
  return names;
}

/// Heading level (1..6) by the style name or id; `Title` becomes heading 1.
int? _headingLevel(String? id, Map<String, String> styles) {
  if (id == null) return null;
  for (final name in [styles[id], id.toLowerCase()]) {
    if (name == null) continue;
    final n = _withoutAccent(name).replaceAll(' ', '');
    if (n == 'title' || n == 'titulo' || n == 'ttulo') return 1;
    final m = RegExp(r'^(heading|titulo|ttulo)(\d)$').firstMatch(n);
    if (m != null) return int.parse(m[2]!).clamp(1, 6);
  }
  return null;
}

/// List format by numId → ilvl → numFmt (`bullet`, `decimal`…).
Map<String, Map<String, String>> _listFormats(XmlDocument? numbering) {
  if (numbering == null) return {};
  final root = numbering.rootElement;
  final abstractNums = {
    for (final a in root.findElements('abstractNum', namespaceUri: _nsW))
      a.getAttribute('abstractNumId', namespaceUri: _nsW): {
        for (final l in a.findElements('lvl', namespaceUri: _nsW))
          l.getAttribute('ilvl', namespaceUri: _nsW) ?? '0': _val(_w(l, 'numFmt')) ?? 'decimal',
      },
  };
  return {
    for (final n in root.findElements('num', namespaceUri: _nsW))
      n.getAttribute('numId', namespaceUri: _nsW) ?? '': abstractNums[_val(_w(n, 'abstractNumId'))] ?? const {},
  };
}

List<Comment> _readComments(Archive zip) {
  final xml = _readXml(zip, _commentsPath);
  if (xml == null) return [];
  return [
    for (final c in xml.rootElement.findElements('comment', namespaceUri: _nsW))
      Comment(
        id: c.getAttribute('id', namespaceUri: _nsW) ?? '',
        author: c.getAttribute('author', namespaceUri: _nsW) ?? 'Autor desconhecido',
        initial: c.getAttribute('initials', namespaceUri: _nsW),
        data: DateTime.tryParse(c.getAttribute('date', namespaceUri: _nsW) ?? ''),
        text: c
            .findElements('p', namespaceUri: _nsW)
            .map(
              (p) => p.descendantElements
                  .where((t) => t.name.local == 't' && t.name.namespaceUri == _nsW)
                  .map((t) => t.innerText)
                  .join(),
            )
            .join('\n')
            .trim(),
      ),
  ];
}

/// Word highlight (`w:highlight`) → RGB color.
const _highlights = {
  'yellow': 'FFFF00', 'green': '00FF00', 'cyan': '00FFFF', 'magenta': 'FF00FF', 'blue': '0000FF',
  'red': 'FF0000', 'darkBlue': '000080', 'darkCyan': '008080', 'darkGreen': '008000',
  'darkMagenta': '800080', 'darkRed': '800000', 'darkYellow': '808000', 'darkGray': '808080',
  'lightGray': 'C0C0C0', 'black': '000000', 'white': 'FFFFFF',
};

/// Quill `#RRGGBB`/`#AARRGGBB` → Word `RRGGBB` (null if it is not a color).
String? _hex(Object? color) {
  if (color is! String) return null;
  var h = color.replaceAll('#', '').toUpperCase();
  if (h.length == 8) h = h.substring(2);
  return RegExp(r'^[0-9A-F]{6}$').hasMatch(h) ? h : null;
}

/// Quill size (points or small/large/huge) → Word half-points.
int? _midpoints(Object? size) {
  final pt = switch (size) {
    'small' => 9.0,
    'large' => 18.0,
    'huge' => 24.0,
    num n => n.toDouble(),
    String s => double.tryParse(s),
    _ => null,
  };
  return pt == null || pt <= 0 ? null : (pt * 2).round().clamp(2, 3276);
}

/// rId → alvo dos hyperlinks.
Map<String, String> _linkTargets(XmlDocument? rels) => {
  for (final r in rels?.rootElement.childElements ?? const <XmlElement>[])
    if (r.getAttribute('Type') == _linkRel && r.getAttribute('Id') != null) r.getAttribute('Id')!: r.getAttribute('Target') ?? '',
};

// ---------------------------------------------------------------- leitura

class _Reader {
  _Reader({required this.styles, required this.numbering, required this.links});

  final Map<String, String> styles;
  final Map<String, Map<String, String>> numbering;
  final Map<String, String> links;
  final warnings = <String>{};
  final _ops = <Map<String, dynamic>>[];

  /// Open comments (`commentRangeStart` without the `End` yet) — they cross paragraphs.
  final _comments = <String>{};

  /// Ongoing revision: (attribute, mark) of the `w:ins`/`w:del` wrapping the content.
  (String, String)? _revision;

  void _withRevision(String attribute, XmlElement e, void Function() read) {
    final antes = _revision;
    final author = e.getAttribute('author', namespaceUri: _nsW) ?? 'Autor desconhecido';
    final data = DateTime.tryParse(e.getAttribute('date', namespaceUri: _nsW) ?? '');
    _revision = (attribute, data == null ? author : revisionMark(author, data));
    read();
    _revision = antes;
  }

  void _insert(String text, Map<String, dynamic> attributes) {
    if (text.isEmpty) return;
    final last = _ops.lastOrNull;
    if (last != null && _same(last['attributes'] as Map<String, dynamic>?, attributes)) {
      last['insert'] = (last['insert'] as String) + text;
      return;
    }
    _ops.add({'insert': text, if (attributes.isNotEmpty) 'attributes': Map<String, dynamic>.of(attributes)});
  }

  static bool _same(Map<String, dynamic>? a, Map<String, dynamic> b) {
    a ??= const {};
    return a.length == b.length && a.entries.every((e) => b[e.key] == e.value);
  }

  List<Map<String, dynamic>> close() {
    if (_ops.isEmpty) _ops.add({'insert': '\n'});
    return _ops;
  }

  /// Block content: body, table cell, content control.
  void block(XmlElement parent) {
    for (final e in parent.childElements) {
      if (e.name.namespaceUri != _nsW) {
        if (e.name.local == 'oMathPara') warnings.add('equações');
        continue;
      }
      switch (e.name.local) {
        case 'p':
          _paragraph(e);
        case 'tbl':
          // The cell text becomes loose paragraphs; the grid is lost.
          warnings.add('tabelas');
          for (final line in e.findElements('tr', namespaceUri: _nsW)) {
            for (final cell in line.findElements('tc', namespaceUri: _nsW)) {
              block(cell);
            }
          }
        case 'sdt':
          final c = _w(e, 'sdtContent');
          if (c != null) block(c);
        case 'customXml':
          block(e);
        case 'ins' || 'moveTo':
          _withRevision(insertionAttribute, e, () => block(e));
        case 'del' || 'moveFrom':
          _withRevision(deletionAttribute, e, () => block(e));
        case 'altChunk':
          warnings.add('conteúdo incorporado');
      }
    }
  }

  void _paragraph(XmlElement p) {
    final pPr = _w(p, 'pPr');
    final blockAttr = <String, dynamic>{};
    if (pPr != null) {
      if (_w(pPr, 'sectPr') != null) warnings.add('seções múltiplas');
      if (_w(pPr, 'pPrChange') != null) warnings.add(_changesNotice);
      final estilo = _val(_w(pPr, 'pStyle'));
      final level = _headingLevel(estilo, styles);
      if (level != null) blockAttr['header'] = level;
      final jc = _val(_w(pPr, 'jc'));
      switch (jc) {
        case 'center':
          blockAttr['align'] = 'center';
        case 'right' || 'end':
          blockAttr['align'] = 'right';
        case 'both' || 'distribute':
          blockAttr['align'] = 'justify';
      }
      final numPr = _w(pPr, 'numPr');
      final numId = _val(_w(numPr, 'numId'));
      final ilvl = int.tryParse(_val(_w(numPr, 'ilvl')) ?? '') ?? 0;
      final styleName = styles[estilo] ?? '';
      if (numId != null && numId != '0') {
        final formats = numbering[numId];
        final fmt = formats == null ? 'bullet' : (formats['$ilvl'] ?? formats['0'] ?? 'decimal');
        blockAttr['list'] = fmt == 'bullet' ? 'bullet' : 'ordered';
        if (ilvl > 0) blockAttr['indent'] = ilvl.clamp(1, 8);
      } else if (styleName.startsWith('list bullet')) {
        blockAttr['list'] = 'bullet';
      } else if (styleName.startsWith('list number')) {
        blockAttr['list'] = 'ordered';
      } else {
        final ind = _w(pPr, 'ind');
        final left = int.tryParse(
          ind?.getAttribute('left', namespaceUri: _nsW) ?? ind?.getAttribute('start', namespaceUri: _nsW) ?? '',
        );
        if (left != null && left >= 600) blockAttr['indent'] = (left / 720).round().clamp(1, 8);
      }
    }
    _content(p, null, blockAttr);
    _insert('\n', blockAttr);
  }

  /// Paragraph content: runs, hyperlinks and wrappers.
  void _content(XmlElement parent, String? link, Map<String, dynamic> blockAttr) {
    for (final e in parent.childElements) {
      if (e.name.namespaceUri != _nsW) {
        if (e.name.local == 'oMath') warnings.add('equações');
        continue;
      }
      switch (e.name.local) {
        case 'r':
          _run(e, link, blockAttr);
        case 'hyperlink':
          final id = e.getAttribute('id', namespaceUri: _nsR);
          _content(e, id == null ? link : (links[id] ?? link), blockAttr);
        case 'ins' || 'moveTo':
          _withRevision(insertionAttribute, e, () => _content(e, link, blockAttr));
        case 'del' || 'moveFrom':
          _withRevision(deletionAttribute, e, () => _content(e, link, blockAttr));
        case 'fldSimple':
          warnings.add('campos automáticos (sumário, numeração de página…)');
          _content(e, link, blockAttr);
        case 'smartTag' || 'customXml':
          _content(e, link, blockAttr);
        case 'sdt':
          final c = _w(e, 'sdtContent');
          if (c != null) _content(c, link, blockAttr);
        case 'commentRangeStart':
          _comments.add(e.getAttribute('id', namespaceUri: _nsW) ?? '');
        case 'commentRangeEnd':
          _comments.remove(e.getAttribute('id', namespaceUri: _nsW) ?? '');
      }
    }
  }

  void _run(XmlElement r, String? link, Map<String, dynamic> blockAttr) {
    final rPr = _w(r, 'rPr');
    final attr = <String, dynamic>{};
    if (rPr != null) {
      if (_links(_w(rPr, 'b'))) attr['bold'] = true;
      if (_links(_w(rPr, 'i'))) attr['italic'] = true;
      if (_links(_w(rPr, 'u'))) attr['underline'] = true;
      if (_links(_w(rPr, 'strike')) || _links(_w(rPr, 'dstrike'))) attr['strike'] = true;
      if (_w(rPr, 'rPrChange') != null) warnings.add(_changesNotice);
      final sources = _w(rPr, 'rFonts');
      final source = sources?.getAttribute('ascii', namespaceUri: _nsW) ?? sources?.getAttribute('hAnsi', namespaceUri: _nsW);
      if (source != null && source.isNotEmpty) attr['font'] = source;
      final sz = int.tryParse(_val(_w(rPr, 'sz')) ?? '');
      if (sz != null && sz > 0) attr['size'] = sz.isEven ? '${sz ~/ 2}' : '${sz / 2}';
      final color = _hex(_val(_w(rPr, 'color')));
      if (color != null && color != '000000') attr['color'] = '#$color';
      final highlighting = _highlights[_val(_w(rPr, 'highlight'))] ?? _hex(_w(rPr, 'shd')?.getAttribute('fill', namespaceUri: _nsW));
      if (highlighting != null && highlighting != 'FFFFFF') attr['background'] = '#$highlighting';
      switch (_val(_w(rPr, 'vertAlign'))) {
        case 'superscript':
          attr['script'] = 'super';
        case 'subscript':
          attr['script'] = 'sub';
      }
    }
    if (link != null && link.isNotEmpty) attr['link'] = link;
    if (_revision case (final key, final mark)) attr[key] = mark;
    if (_comments.isNotEmpty) attr[commentAttribute] = (_comments.toList()..sort()).join(',');
    for (final c in r.childElements) {
      if (c.name.namespaceUri != _nsW) {
        if (c.name.local == 'AlternateContent') _media(c);
        continue;
      }
      switch (c.name.local) {
        case 't' || 'delText':
          _insert(c.innerText.replaceAll('\r', '').replaceAll('\n', ' '), attr);
        case 'tab':
          _insert('\t', attr);
        case 'br' || 'cr':
          // Quill has no soft line break: the break becomes a new paragraph.
          final type = c.getAttribute('type', namespaceUri: _nsW);
          if (type == 'page' || type == 'column') warnings.add('quebras de página');
          _insert('\n', blockAttr);
        case 'noBreakHyphen':
          _insert('-', attr);
        case 'drawing' || 'pict' || 'object':
          _media(c);
        case 'footnoteReference':
          warnings.add('notas de rodapé');
        case 'endnoteReference':
          warnings.add('notas de fim');
        case 'fldChar':
          warnings.add('campos automáticos (sumário, numeração de página…)');
      }
    }
  }

  void _media(XmlElement e) {
    final box = e.descendantElements.any((d) => d.name.local == 'txbxContent');
    warnings.add(box ? 'caixas de texto' : 'imagens e objetos');
  }
}

// ---------------------------------------------------------------- saving

typedef _Excerpt = (String text, Map<String, dynamic> attr);
typedef _Row = (List<_Excerpt> excerpts, Map<String, dynamic> block);

List<_Row> _lines(List<Map<String, dynamic>> delta) {
  final lines = <_Row>[];
  var current = <_Excerpt>[];
  for (final op in delta) {
    final ins = op['insert'];
    if (ins is! String) continue; // embeds (image, formula) do not exist in the simple editor
    final attr = (op['attributes'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    final parts = ins.split('\n');
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].isNotEmpty) current.add((parts[i], attr));
      if (i < parts.length - 1) {
        lines.add((current, attr));
        current = [];
      }
    }
  }
  if (current.isNotEmpty) lines.add((current, const {}));
  return lines;
}

class _Writer {
  _Writer({required this.zip, required this.runPrefix, required this.comments, required int firstId})
    : _annotationId = firstId;

  final Archive zip;
  final String runPrefix;

  /// Comment ids that exist (marks in the text of deleted comments are ignored).
  final Set<String> comments;

  /// Zip parts that go away (comment extensions that would point to paragraphs that no longer exist).
  final removed = <String>{};

  // w:id of ins/del: unique among the annotations, after the comment ids.
  int _annotationId;
  final _openFiles = <String>{};
  XmlDocument? _settings;

  XmlDocument? _styles;
  XmlDocument? _numbering;
  XmlDocument? _rels;
  XmlDocument? _types;
  bool _stylesChanged = false, _numberingChanged = false, _relsChanged = false, _typesChanged = false;
  bool _stylesRead = false;

  // Lists: base numId of each type and restart numIds (ordered) already used in this save.
  final _numBase = <String, String>{};
  var _numberedBlocks = 0;
  String? _previousType;

  /// XML of the paragraphs (without the `w:sectPr`).
  String body(List<_Row> lines) {
    final s = StringBuffer();
    for (var k = 0; k < lines.length; k++) {
      final (excerpts, block) = lines[k];
      s.write('<w:p>');
      s.write(_pPr(block));
      _runs(s, excerpts);
      // Closes at the end of the paragraph the comments that do not continue into the next.
      final following = k + 1 < lines.length ? lines[k + 1].$1.firstOrNull?.$2 : null;
      _commentsUpTo(s, following == null ? const {} : _validIds(following));
      s.write('</w:p>');
    }
    return s.toString();
  }

  Set<String> _validIds(Map<String, dynamic> attr) =>
      commentIds(attr[commentAttribute]).where(comments.contains).toSet();

  /// Opens/closes comment marks so exactly [ids] stay open.
  void _commentsUpTo(StringBuffer s, Set<String> ids) {
    for (final id in _openFiles.difference(ids).toList()..sort()) {
      s.write('<w:commentRangeEnd w:id="${_esc(id)}"/><w:r><w:commentReference w:id="${_esc(id)}"/></w:r>');
      _openFiles.remove(id);
    }
    for (final id in ids.difference(_openFiles).toList()..sort()) {
      s.write('<w:commentRangeStart w:id="${_esc(id)}"/>');
      _openFiles.add(id);
    }
  }

  Map<String, String> swapped() => {
    if (_stylesChanged) _stylesPath: _styles!.toXmlString(),
    if (_numberingChanged) _numberingPath: _numbering!.toXmlString(),
    if (_relsChanged) _relsPath: _rels!.toXmlString(),
    if (_typesChanged) _typesPath: _types!.toXmlString(),
    _commentsPath: ?_commentsXml,
    if (_settings != null) _settingsPath: _settings!.toXmlString(),
  };

  String? _commentsXml;

  /// Rewrites `comments.xml` (creates the part, the relationship and the type if missing). The extensions
  /// (commentsExtended/Ids/Extensible: replies and "resolved") go away, because they cite old paragraphs.
  void saveComments(List<Comment> items) {
    final s = StringBuffer('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:comments xmlns:w="$_nsW">');
    for (final c in items) {
      s.write(
        '<w:comment w:id="${_esc(c.id)}" w:author="${_esc(c.author)}" w:date="${_dataWord(c.data)}" '
        'w:initials="${_esc(c.initial)}">',
      );
      final lines = c.text.split('\n');
      for (var i = 0; i < lines.length; i++) {
        s.write('<w:p>');
        if (i == 0) s.write('<w:r><w:annotationRef/></w:r>');
        s.write('<w:r><w:t xml:space="preserve">${_esc(lines[i])}</w:t></w:r></w:p>');
      }
      s.write('</w:comment>');
    }
    s.write('</w:comments>');
    _commentsXml = s.toString();

    final root = _docRels.rootElement;
    if (!root.childElements.any((r) => r.getAttribute('Type') == _commentsRel)) {
      _newRelationship(_commentsRel, 'comments.xml');
      _overrideType('/$_commentsPath', _commentsType);
    }
    for (final r in root.childElements.toList()) {
      final type = r.getAttribute('Type') ?? '';
      if (!RegExp(r'/(commentsExtended|commentsIds|commentsExtensible)$').hasMatch(type)) continue;
      final target = 'word/${r.getAttribute('Target') ?? ''}';
      removed.add(target);
      root.children.remove(r);
      _relsChanged = true;
      final types = _docTypes;
      final override = types?.rootElement.childElements.where((e) => e.getAttribute('PartName') == '/$target').firstOrNull;
      if (override != null) {
        types!.rootElement.children.remove(override);
        _typesChanged = true;
      }
    }
  }

  void _overrideType(String part, String type) {
    final types = _docTypes;
    if (types == null || types.rootElement.childElements.any((e) => e.getAttribute('PartName') == part)) return;
    types.rootElement.children.add(
      XmlElement(XmlName.qualified('Override', namespaceUri: _nsTipos), [
        XmlAttribute(XmlName.qualified('PartName'), part),
        XmlAttribute(XmlName.qualified('ContentType'), type),
      ]),
    );
    _typesChanged = true;
  }

  // w:settings elements that come before w:trackRevisions in the schema.
  static const _beforeTracking = {
    'writeProtection', 'view', 'zoom', 'removePersonalInformation', 'removeDateAndTime',
    'doNotDisplayPageBoundaries', 'displayBackgroundShape', 'printPostScriptOverText',
    'printFractionalCharacterWidth', 'printFormsData', 'embedTrueTypeFonts', 'embedSystemFonts',
    'saveSubsetFonts', 'saveFormsData', 'mirrorMargins', 'alignBordersAndEdges',
    'bordersDoNotSurroundHeader', 'bordersDoNotSurroundFooter', 'gutterAtTop', 'hideSpellingErrors',
    'hideGrammaticalErrors', 'activeWritingStyle', 'proofState', 'formsDesign', 'attachedTemplate',
    'linkStyles', 'stylePaneFormatFilter', 'stylePaneSortMethod', 'documentType', 'mailMerge', 'revisionView',
  };

  /// Turns `w:trackRevisions` on/off (Word keeps marking the changes of whoever opens it there).
  void track(bool link) {
    final adjustments = _readXml(zip, _settingsPath);
    if (adjustments == null) return; // without settings.xml it is not worth creating the part just for this
    final root = adjustments.rootElement;
    final current = root.getElement('trackRevisions', namespaceUri: _nsW);
    if ((current != null) == link) return;
    if (link) {
      _declareW(root);
      final antes = root.childElements.where((e) => _beforeTracking.contains(e.name.local)).lastOrNull;
      final isNew = _element('<w:trackRevisions/>');
      root.children.insert(antes == null ? 0 : root.children.indexOf(antes) + 1, isNew);
    } else {
      root.children.remove(current);
    }
    _settings = adjustments;
  }

  String _pPr(Map<String, dynamic> block) {
    final s = StringBuffer();
    final header = block['header'];
    if (header is int && header >= 1) s.write('<w:pStyle w:val="${_esc(_headingStyle(header.clamp(1, 6)))}"/>');
    final items = block['list'];
    final level = (block['indent'] is int ? block['indent'] as int : 0).clamp(0, 8);
    final type = switch (items) {
      'ordered' => 'ordered',
      'bullet' || 'checked' || 'unchecked' => 'bullet',
      _ => null,
    };
    if (type != null) {
      final numId = _listNum(type, newBlock: type == 'ordered' && _previousType != 'ordered');
      s.write('<w:numPr><w:ilvl w:val="$level"/><w:numId w:val="$numId"/></w:numPr>');
    } else if (level > 0) {
      s.write('<w:ind w:left="${720 * level}"/>');
    }
    _previousType = type;
    final jc = switch (block['align']) {
      'center' => 'center',
      'right' => 'right',
      'justify' => 'both',
      _ => null,
    };
    if (jc != null) s.write('<w:jc w:val="$jc"/>');
    return s.isEmpty ? '' : '<w:pPr>$s</w:pPr>';
  }

  static int _ate(List<_Excerpt> excerpts, int i, bool Function(Map<String, dynamic>) equal) {
    var end = i + 1;
    while (end < excerpts.length && equal(excerpts[end].$2)) {
      end++;
    }
    return end;
  }

  static String? _linkDe(Map<String, dynamic> attr) {
    final l = attr['link'];
    return l is String && l.isNotEmpty ? l : null;
  }

  /// (tag, mark) of the excerpt revision: `ins`, `del` or none.
  static (String?, String?) _revisionOf(Map<String, dynamic> attr) {
    final del = attr[deletionAttribute];
    if (del is String) return ('del', del);
    final ins = attr[insertionAttribute];
    if (ins is String) return ('ins', ins);
    return (null, null);
  }

  void _runs(StringBuffer s, List<_Excerpt> excerpts) {
    var i = 0;
    while (i < excerpts.length) {
      final link = _linkDe(excerpts[i].$2);
      final end = _ate(excerpts, i, (a) => _linkDe(a) == link);
      if (link != null) s.write('<w:hyperlink $runPrefix:id="${_idLink(link)}" w:history="1">');
      _revisions(s, excerpts.sublist(i, end), link: link != null);
      if (link != null) s.write('</w:hyperlink>');
      i = end;
    }
  }

  void _revisions(StringBuffer s, List<_Excerpt> excerpts, {required bool link}) {
    var i = 0;
    while (i < excerpts.length) {
      final rev = _revisionOf(excerpts[i].$2);
      final end = _ate(excerpts, i, (a) => _revisionOf(a) == rev);
      final (tag, mark) = rev;
      if (tag != null) {
        final (:author, :data) = readMark(mark!);
        s.write('<w:$tag w:id="${_annotationId++}" w:author="${_esc(author)}"');
        if (data != null) s.write(' w:date="${_dataWord(data)}"');
        s.write('>');
      }
      for (var j = i; j < end; j++) {
        _commentsUpTo(s, _validIds(excerpts[j].$2));
        _run(s, excerpts[j], link: link, deleted: tag == 'del');
      }
      if (tag != null) s.write('</w:$tag>');
      i = end;
    }
  }

  void _run(StringBuffer s, _Excerpt excerpt, {bool link = false, bool deleted = false}) {
    final (text, attr) = excerpt;
    final rPr = StringBuffer();
    final linkStyle = link ? _styleId('hyperlink', type: 'character') : null;
    if (linkStyle != null) rPr.write('<w:rStyle w:val="${_esc(linkStyle)}"/>');
    final source = attr['font'];
    if (source is String && source.isNotEmpty) {
      final f = _esc(source);
      rPr.write('<w:rFonts w:ascii="$f" w:hAnsi="$f" w:cs="$f"/>');
    }
    if (attr['bold'] == true) rPr.write('<w:b/>');
    if (attr['italic'] == true) rPr.write('<w:i/>');
    if (attr['strike'] == true) rPr.write('<w:strike/>');
    final color = _hex(attr['color']);
    if (color != null) {
      rPr.write('<w:color w:val="$color"/>');
    } else if (link && linkStyle == null) {
      rPr.write('<w:color w:val="0563C1"/>');
    }
    final sz = _midpoints(attr['size']);
    if (sz != null) rPr.write('<w:sz w:val="$sz"/><w:szCs w:val="$sz"/>');
    final background = _hex(attr['background']);
    final highlighting = background == null ? null : _highlights.entries.where((e) => e.value == background).firstOrNull?.key;
    if (highlighting != null) rPr.write('<w:highlight w:val="$highlighting"/>');
    if (attr['underline'] == true || (link && linkStyle == null)) rPr.write('<w:u w:val="single"/>');
    if (background != null && highlighting == null) rPr.write('<w:shd w:val="clear" w:color="auto" w:fill="$background"/>');
    switch (attr['script']) {
      case 'super':
        rPr.write('<w:vertAlign w:val="superscript"/>');
      case 'sub':
        rPr.write('<w:vertAlign w:val="subscript"/>');
    }
    s.write('<w:r>');
    if (rPr.isNotEmpty) s.write('<w:rPr>$rPr</w:rPr>');
    final tag = deleted ? 'w:delText' : 'w:t';
    final parts = text.split('\t');
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) s.write('<w:tab/>');
      if (parts[i].isNotEmpty) s.write('<$tag xml:space="preserve">${_esc(parts[i])}</$tag>');
    }
    s.write('</w:r>');
  }

  // ---- estilos

  XmlDocument? get _docStyles {
    if (!_stylesRead) {
      _styles = _readXml(zip, _stylesPath);
      _stylesRead = true;
    }
    return _styles;
  }

  String? _styleId(String name, {String type = 'paragraph'}) {
    for (final st in _docStyles?.rootElement.findElements('style', namespaceUri: _nsW) ?? const <XmlElement>[]) {
      if ((st.getAttribute('type', namespaceUri: _nsW) ?? 'paragraph') == type &&
          (_val(_w(st, 'name')) ?? '').toLowerCase() == name) {
        return st.getAttribute('styleId', namespaceUri: _nsW);
      }
    }
    return null;
  }

  String _headingStyle(int n) {
    final existing = _styleId('heading $n');
    if (existing != null) return existing;
    final id = 'Heading$n';
    final styles = _docStyles;
    if (styles != null) {
      // Minimal style so the heading does not become a normal paragraph in Word.
      const sizes = {1: 32, 2: 28, 3: 26, 4: 24, 5: 22, 6: 22};
      final root = styles.rootElement;
      _declareW(root);
      const w = 'w';
      root.children.add(
        _element(
          '<$w:style $w:type="paragraph" $w:styleId="$id"><$w:name $w:val="heading $n"/>'
          '<$w:basedOn $w:val="Normal"/><$w:next $w:val="Normal"/><$w:qFormat/>'
          '<$w:pPr><$w:keepNext/><$w:spacing $w:before="240" $w:after="60"/><$w:outlineLvl $w:val="${n - 1}"/></$w:pPr>'
          '<$w:rPr><$w:b/><$w:sz $w:val="${sizes[n]}"/></$w:rPr></$w:style>',
        ),
      );
      _stylesChanged = true;
    }
    return id;
  }

  // ---- listas

  XmlDocument get _docNumbering {
    if (_numbering != null) return _numbering!;
    final existing = _readXml(zip, _numberingPath);
    if (existing != null) return _numbering = existing;
    // Document without numbering.xml: creates the part, the relationship and the content type.
    _numberingChanged = true;
    _newRelationship(_numberingRel, 'numbering.xml');
    final types = _docTypes;
    if (types != null &&
        !types.rootElement.childElements.any((e) => e.getAttribute('PartName') == '/$_numberingPath')) {
      types.rootElement.children.add(
        XmlElement(XmlName.qualified('Override', namespaceUri: _nsTipos), [
          XmlAttribute(XmlName.qualified('PartName'), '/$_numberingPath'),
          XmlAttribute(XmlName.qualified('ContentType'), _numberingType),
        ]),
      );
      _typesChanged = true;
    }
    return _numbering = XmlDocument.parse(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:numbering xmlns:w="$_nsW"/>',
    );
  }

  /// numId for a list paragraph. Each numbered block after the first restarts at 1 through
  /// a `w:num` with `startOverride`, reusing the existing ones so they do not pile up on every save.
  String _listNum(String type, {required bool newBlock}) {
    final base = _numBase[type] ??= _findOrCreateNum(type);
    if (type != 'ordered' || !newBlock) return base;
    final block = _numberedBlocks++;
    if (block == 0) return base;
    final root = _docNumbering.rootElement;
    final abstractNum = _abstractOf(base);
    final restartPoints = root
        .findElements('num', namespaceUri: _nsW)
        .where((n) {
          final id = n.getAttribute('numId', namespaceUri: _nsW);
          return id != base &&
              _val(_w(n, 'abstractNumId')) == abstractNum &&
              n
                  .findElements('lvlOverride', namespaceUri: _nsW)
                  .any((o) => o.getAttribute('ilvl', namespaceUri: _nsW) == '0' && _val(_w(o, 'startOverride')) == '1');
        })
        .map((n) => n.getAttribute('numId', namespaceUri: _nsW)!)
        .toList();
    if (block - 1 < restartPoints.length) return restartPoints[block - 1];
    return _newNum(abstractNum!, restart: true);
  }

  String? _abstractOf(String numId) => _val(
    _w(
      _docNumbering.rootElement
          .findElements('num', namespaceUri: _nsW)
          .firstWhere((n) => n.getAttribute('numId', namespaceUri: _nsW) == numId),
      'abstractNumId',
    ),
  );

  String _findOrCreateNum(String type) {
    final root = _docNumbering.rootElement;
    final formats = {
      for (final a in root.findElements('abstractNum', namespaceUri: _nsW))
        a.getAttribute('abstractNumId', namespaceUri: _nsW): _val(
          _w(
            a.findElements('lvl', namespaceUri: _nsW).where((l) => l.getAttribute('ilvl', namespaceUri: _nsW) == '0').firstOrNull,
            'numFmt',
          ),
        ),
    };
    for (final n in root.findElements('num', namespaceUri: _nsW)) {
      final fmt = formats[_val(_w(n, 'abstractNumId'))];
      if (fmt == null) continue;
      final isHighlighter = fmt == 'bullet';
      if ((type == 'bullet') == isHighlighter && fmt != 'none') return n.getAttribute('numId', namespaceUri: _nsW)!;
    }
    return _newNum(_newAbstract(type, root));
  }

  String _newAbstract(String type, XmlElement root) {
    _declareW(root);
    const w = 'w';
    final ids = root
        .findElements('abstractNum', namespaceUri: _nsW)
        .map((a) => int.tryParse(a.getAttribute('abstractNumId', namespaceUri: _nsW) ?? '') ?? 0);
    final id = ids.fold(-1, (a, b) => a > b ? a : b) + 1;
    const markers = ['•', '◦', '▪'];
    const formats = ['decimal', 'lowerLetter', 'lowerRoman'];
    final levels = StringBuffer();
    for (var i = 0; i < 9; i++) {
      final (fmt, text) = type == 'bullet' ? ('bullet', markers[i % 3]) : (formats[i % 3], '%${i + 1}.');
      levels.write(
        '<$w:lvl $w:ilvl="$i"><$w:start $w:val="1"/><$w:numFmt $w:val="$fmt"/><$w:lvlText $w:val="$text"/>'
        '<$w:lvlJc $w:val="left"/><$w:pPr><$w:ind $w:left="${720 * (i + 1)}" $w:hanging="360"/></$w:pPr></$w:lvl>',
      );
    }
    final isNew = _element(
      '<$w:abstractNum $w:abstractNumId="$id"><$w:multiLevelType $w:val="hybridMultilevel"/>$levels</$w:abstractNum>',
    );
    // In the schema the abstractNums come before all the nums.
    final firstNum = root.findElements('num', namespaceUri: _nsW).firstOrNull;
    if (firstNum != null) {
      root.children.insert(root.children.indexOf(firstNum), isNew);
    } else {
      root.children.add(isNew);
    }
    _numberingChanged = true;
    return '$id';
  }

  String _newNum(String abstractNum, {bool restart = false}) {
    final root = _docNumbering.rootElement;
    _declareW(root);
    const w = 'w';
    final ids = root
        .findElements('num', namespaceUri: _nsW)
        .map((n) => int.tryParse(n.getAttribute('numId', namespaceUri: _nsW) ?? '') ?? 0);
    final id = ids.fold(0, (a, b) => a > b ? a : b) + 1;
    final restartPoint = restart ? '<$w:lvlOverride $w:ilvl="0"><$w:startOverride $w:val="1"/></$w:lvlOverride>' : '';
    final isNew = _element('<$w:num $w:numId="$id"><$w:abstractNumId $w:val="$abstractNum"/>$restartPoint</$w:num>');
    final cleanup = root.getElement('numIdMacAtCleanup', namespaceUri: _nsW);
    if (cleanup != null) {
      root.children.insert(root.children.indexOf(cleanup), isNew);
    } else {
      root.children.add(isNew);
    }
    _numberingChanged = true;
    return '$id';
  }

  // ---- relationships and types

  XmlDocument get _docRels => _rels ??=
      _readXml(zip, _relsPath) ??
      (() {
        _relsChanged = true;
        return XmlDocument.parse(
          '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="$_nsRels"/>',
        );
      })();

  XmlDocument? get _docTypes => _types ??= _readXml(zip, _typesPath);

  String _idLink(String target) {
    for (final r in _docRels.rootElement.childElements) {
      if (r.getAttribute('Type') == _linkRel && r.getAttribute('Target') == target) return r.getAttribute('Id')!;
    }
    return _newRelationship(_linkRel, target, external: true);
  }

  String _newRelationship(String type, String target, {bool external = false}) {
    final root = _docRels.rootElement;
    final usedItems = root.childElements.map((r) => r.getAttribute('Id')).toSet();
    var n = usedItems.length + 1;
    while (usedItems.contains('rId$n')) {
      n++;
    }
    root.children.add(
      XmlElement(XmlName.qualified('Relationship', namespaceUri: _nsRels), [
        XmlAttribute(XmlName.qualified('Id'), 'rId$n'),
        XmlAttribute(XmlName.qualified('Type'), type),
        XmlAttribute(XmlName.qualified('Target'), target),
        if (external) XmlAttribute(XmlName.qualified('TargetMode'), 'External'),
      ]),
    );
    _relsChanged = true;
    return 'rId$n';
  }
}
