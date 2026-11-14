/// XLSX spreadsheet read and written straight in the zip (without the `excel` package, incompatible with xml 7).
///
/// On save only the XML of the changed sheets is rewritten; styles, charts, images and the rest of the
/// package stay as they were. Rows and columns are 0-based in the API (`cellRef(0, 0)` = `A1`).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

const maxRows = 1048576;
const maxColumns = 16384;

/// XLSX that cannot be opened; [mensagem] in Portuguese to show the user.
class InvalidXlsx implements Exception {
  InvalidXlsx(this.mensagem);

  final String mensagem;

  @override
  String toString() => mensagem;
}

/// `0` → `A`, `27` → `AB`.
String columnLetters(int column) {
  var n = column + 1;
  var s = '';
  while (n > 0) {
    s = String.fromCharCode(65 + (n - 1) % 26) + s;
    n = (n - 1) ~/ 26;
  }
  return s;
}

/// `A` → `0`, `AB` → `27`.
int columnFromLetters(String letters) {
  if (letters.isEmpty) throw const FormatException('Coluna vazia');
  var n = 0;
  for (final u in letters.toUpperCase().codeUnits) {
    if (u < 65 || u > 90) throw FormatException('Coluna inválida: $letters');
    n = n * 26 + (u - 64);
  }
  return n - 1;
}

/// `(2, 1)` → `B3`.
String cellRef(int line, int column) => '${columnLetters(column)}${line + 1}';

final _reSimpleRef = RegExp(r'^\$?([A-Za-z]{1,3})\$?(\d+)$');

/// `B3` (or `$B$3`) → `(2, 1)`.
(int, int) readRef(String ref) {
  final m = _reSimpleRef.firstMatch(ref.trim());
  if (m == null) throw FormatException('Referência inválida: $ref');
  return (int.parse(m[2]!) - 1, columnFromLetters(m[1]!));
}

/// Workbook: sheets in workbook order and the original zip to rewrite.
class Pasta {
  Pasta._(this._zip, this.tabs, this._workbook, this._workbookRels);

  final Archive _zip;
  final String _workbook;
  final String _workbookRels;
  final List<FileTab> tabs;

  bool get changedFlag => tabs.any((a) => a.changedFlag);

  static Pasta read(Uint8List bytes) {
    final Archive zip;
    try {
      zip = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw InvalidXlsx('O arquivo não é um XLSX válido (zip corrompido ou protegido por senha).');
    }
    String? text(String path) {
      final f = zip.find(path);
      return f == null ? null : utf8.decode(f.content, allowMalformed: true);
    }

    XmlDocument xml(String path) {
      final t = text(path);
      if (t == null) throw InvalidXlsx('XLSX incompleto: falta $path.');
      try {
        return XmlDocument.parse(t);
      } on XmlException {
        throw InvalidXlsx('XLSX com XML inválido em $path.');
      }
    }

    var workbook = 'xl/workbook.xml';
    if (zip.find('_rels/.rels') != null) {
      for (final r in _relationships(xml('_rels/.rels'))) {
        if (r.type.endsWith('/officeDocument')) workbook = _resolver('', r.target);
      }
    }
    if (zip.find(workbook) == null) throw InvalidXlsx('O arquivo não é uma planilha XLSX (falta o workbook).');
    final pasta = workbook.contains('/') ? workbook.substring(0, workbook.lastIndexOf('/') + 1) : '';
    final workbookRels = '${pasta}_rels/${workbook.substring(pasta.length)}.rels';
    final rels = zip.find(workbookRels) == null ? <_Relationship>[] : _relationships(xml(workbookRels));

    final shared = <String>[];
    for (final r in rels.where((r) => r.type.endsWith('/sharedStrings'))) {
      final doc = xml(_resolver(pasta, r.target));
      shared.addAll(doc.rootElement.findElements('si', namespaceUri: '*').map(_richText));
    }

    final tabs = <FileTab>[];
    for (final s in xml(workbook).findAllElements('sheet', namespaceUri: '*')) {
      final id = s.getAttribute('id', namespaceUri: '*');
      final rel = rels.where((r) => r.id == id && r.type.endsWith('/worksheet')).firstOrNull;
      if (rel == null) continue; // chart or macro sheet: stays in the zip, without an editor
      final path = _resolver(pasta, rel.target);
      final t = text(path);
      if (t == null) throw InvalidXlsx('XLSX incompleto: falta $path.');
      tabs.add(FileTab._(s.getAttribute('name') ?? 'Planilha${tabs.length + 1}', path, t, shared));
    }
    if (tabs.isEmpty) throw InvalidXlsx('A planilha não tem nenhuma aba de células.');
    final p = Pasta._(zip, tabs, workbook, workbookRels);
    for (final a in tabs) {
      a._pasta = p;
    }
    return p;
  }

  /// New zip: changed sheets rewritten; with any change the `calcChain.xml` goes away and the
  /// workbook asks for a recalculation on open (the cached formula values became stale).
  Uint8List save() {
    final swaps = <String, String>{for (final a in tabs.where((a) => a.changedFlag)) a._path: a._buildXml()};
    final remover = <String>{};
    if (swaps.isNotEmpty) {
      final pasta = _workbook.substring(0, _workbook.lastIndexOf('/') + 1);
      final rels = _textOf(_workbookRels);
      if (rels != null) {
        final doc = XmlDocument.parse(rels);
        for (final r in doc.findAllElements('Relationship', namespaceUri: '*').toList()) {
          if ((r.getAttribute('Type') ?? '').endsWith('/calcChain')) {
            remover.add(_resolver(pasta, r.getAttribute('Target') ?? ''));
            r.remove();
          }
        }
        if (remover.isNotEmpty) swaps[_workbookRels] = doc.toXmlString();
      }
      final types = _textOf('[Content_Types].xml');
      if (types != null && remover.isNotEmpty) {
        final doc = XmlDocument.parse(types);
        for (final o in doc.findAllElements('Override', namespaceUri: '*').toList()) {
          if (remover.contains((o.getAttribute('PartName') ?? '').replaceFirst(RegExp('^/'), ''))) o.remove();
        }
        swaps['[Content_Types].xml'] = doc.toXmlString();
      }
      swaps[_workbook] = _recomputeOnOpen(_textOf(_workbook)!);
    }
    final isNew = Archive();
    for (final f in _zip.files) {
      if (remover.contains(f.name)) continue;
      final t = swaps[f.name];
      isNew.add(t == null ? f : ArchiveFile.bytes(f.name, utf8.encode(t)));
    }
    return ZipEncoder().encodeBytes(isNew);
  }

  String? _textOf(String path) {
    final f = _zip.find(path);
    return f == null ? null : utf8.decode(f.content, allowMalformed: true);
  }

  static String _recomputeOnOpen(String xml) {
    final doc = XmlDocument.parse(xml);
    final root = doc.rootElement;
    final calc = root.findElements('calcPr', namespaceUri: '*').firstOrNull;
    if (calc != null) {
      calc.setAttribute('fullCalcOnLoad', '1');
    } else {
      // Schema order: calcPr comes right after sheets/functionGroups/externalReferences/definedNames.
      const antes = {'sheets', 'functionGroups', 'externalReferences', 'definedNames'};
      final anchor = root.childElements.where((e) => antes.contains(e.localName)).lastOrNull;
      final p = root.name.prefix;
      final isNew = XmlDocumentFragment.parse('<${p == null ? '' : '$p:'}calcPr fullCalcOnLoad="1"/>').firstElementChild!.copy();
      if (anchor == null) {
        root.children.add(isNew);
      } else {
        root.children.insert(root.children.indexOf(anchor) + 1, isNew);
      }
    }
    return doc.toXmlString();
  }
}

/// A sheet of cells. The XML is parsed only on first access.
class FileTab {
  FileTab._(this.name, this._path, this._xmlOriginal, this._shared);

  final String name;
  final String _path;
  final String _xmlOriginal;
  final List<String> _shared;
  late final Pasta _pasta;
  bool changedFlag = false;

  final _grade = <_Row?>[];
  final _operations = <_Operation>[];
  bool _loaded = false;
  int? _rowsCache;
  int? _columnsCache;

  /// Rows up to the last one with content.
  int get lines {
    _load();
    return _rowsCache ??= () {
      for (var i = _grade.length - 1; i >= 0; i--) {
        if (_grade[i]?.cells.any((c) => c != null) ?? false) return i + 1;
      }
      return 0;
    }();
  }

  /// Columns up to the last one with content in any row.
  int get columns {
    _load();
    return _columnsCache ??= _grade.fold<int>(0, (n, l) {
      if (l == null) return n;
      for (var c = l.cells.length - 1; c >= n; c--) {
        if (l.cells[c] != null) return c + 1;
      }
      return n;
    });
  }

  /// Displayed value (formula cache; boolean as VERDADEIRO/FALSO; date as a number).
  String cell(int line, int column) => _em(line, column)?.shown ?? '';

  /// What gets edited: `=FÓRMULA` or the value.
  String content(int line, int column) {
    final c = _em(line, column);
    if (c == null) return '';
    return c.formula != null ? '=${c.formula}' : c.shown;
  }

  /// Formula without the `=`, or `null`.
  String? formula(int line, int column) => _em(line, column)?.formula;

  /// Text starting with `=` becomes a formula; a number (decimal point or comma) becomes a number; empty
  /// clears the value but keeps the cell style.
  void setValue(int line, int column, String value) {
    _validate(line, column);
    if (content(line, column) == value) return;
    final estilo = _em(line, column)?.estilo;
    final _Cell? nova;
    if (value.isEmpty) {
      nova = estilo == null ? null : _Cell(shown: '', estilo: estilo);
    } else if (value.length > 1 && value.startsWith('=')) {
      nova = _Cell(shown: value, formula: value.substring(1), estilo: estilo);
    } else if (_number(value) case final n?) {
      nova = _Cell(shown: n, estilo: estilo, number: true);
    } else {
      nova = _Cell(shown: value, estilo: estilo);
    }
    while (_grade.length <= line) {
      _grade.add(null);
    }
    final l = _grade[line] ??= _Row({});
    while (l.cells.length <= column) {
      l.cells.add(null);
    }
    l.cells[column] = nova;
    _changed();
  }

  void insertRow(int line) => _structure(_Operation(true, line, 1));
  void deleteRow(int line) => _structure(_Operation(true, line, -1));
  void insertColumn(int column) => _structure(_Operation(false, column, 1));
  void deleteColumn(int column) => _structure(_Operation(false, column, -1));

  // ---------------------------------------------------------------- interno

  _Cell? _em(int line, int column) {
    _load();
    if (line < 0 || line >= _grade.length) return null;
    final l = _grade[line];
    return l == null || column < 0 || column >= l.cells.length ? null : l.cells[column];
  }

  void _validate(int line, int column) {
    RangeError.checkValueInInterval(line, 0, maxRows - 1, 'linha');
    RangeError.checkValueInInterval(column, 0, maxColumns - 1, 'coluna');
  }

  void _changed() {
    changedFlag = true;
    _rowsCache = null;
    _columnsCache = null;
  }

  void _structure(_Operation op) {
    _load();
    _validate(op.line ? op.score : 0, op.line ? 0 : op.score);
    if (op.line) {
      if (op.delta > 0) {
        if (op.score < _grade.length) _grade.insert(op.score, null);
      } else if (op.score < _grade.length) {
        _grade.removeAt(op.score);
      }
    } else {
      for (final l in _grade) {
        if (l == null || op.score >= l.cells.length) continue;
        op.delta > 0 ? l.cells.insert(op.score, null) : l.cells.removeAt(op.score);
      }
    }
    _operations.add(op);
    _changed();
    // Formulas of this sheet (references without a sheet or with its name) and of the others pointing here.
    for (final a in _pasta.tabs) {
      a._load();
      var touched = false;
      for (final l in a._grade) {
        for (final c in l?.cells ?? const <_Cell?>[]) {
          if (c?.formula == null) continue;
          final f = _swapRefs(c!.formula!, (tab) => tab == null ? identical(a, this) : _sameName(tab, name), op.mapItems);
          if (c.matrix != null) c.matrix = _mapRanges(c.matrix!, op.mapItems) ?? c.matrix;
          if (f != c.formula) {
            c.formula = f;
            touched = true;
          }
        }
      }
      if (touched && !identical(a, this)) a._changed();
    }
  }

  void _load() {
    if (_loaded) return;
    _loaded = true;
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(_xmlOriginal);
    } on XmlException {
      throw InvalidXlsx('XLSX com XML inválido em $_path.');
    }
    final data = doc.rootElement.findElements('sheetData', namespaceUri: '*').firstOrNull;
    if (data == null) return;
    // Shared formulas: the first cell (master) has the text; the others only the `si`.
    final masters = <String, (String, int, int)>{};
    final pending = <(_Cell, String, int, int)>[];
    var line = -1;
    for (final row in data.findElements('row', namespaceUri: '*')) {
      final r = int.tryParse(row.getAttribute('r') ?? '');
      line = r != null ? r - 1 : line + 1;
      if (line < 0 || line >= maxRows) continue;
      final attributes = {
        for (final a in row.attributes)
          if (a.localName != 'r' && a.localName != 'spans') a.name.qualified: a.value,
      };
      final l = _Row(attributes);
      var column = -1;
      for (final c in row.findElements('c', namespaceUri: '*')) {
        final ref = c.getAttribute('r');
        column = ref == null ? column + 1 : (_tryRef(ref)?.$2 ?? column + 1);
        if (column >= maxColumns) continue;
        final cell = _readCell(c);
        final f = c.findElements('f', namespaceUri: '*').firstOrNull;
        if (f != null && f.getAttribute('t') == 'shared') {
          final si = f.getAttribute('si') ?? '';
          if (f.innerText.isNotEmpty) {
            masters[si] = (f.innerText, line, column);
          } else {
            pending.add((cell, si, line, column));
          }
        }
        while (l.cells.length <= column) {
          l.cells.add(null);
        }
        l.cells[column] = cell;
      }
      while (_grade.length <= line) {
        _grade.add(null);
      }
      _grade[line] = l;
    }
    for (final (cell, si, line, column) in pending) {
      final m = masters[si];
      if (m == null) continue;
      final (text, ml, mc) = m;
      cell.formula = _swapRefs(text, (_) => true, (a, b, isLine) {
        final d = isLine ? line - ml : column - mc;
        return (a + d, b + d);
      }, relative: true);
    }
  }

  _Cell _readCell(XmlElement c) {
    final type = c.getAttribute('t');
    final v = c.findElements('v', namespaceUri: '*').firstOrNull?.innerText ?? '';
    final f = c.findElements('f', namespaceUri: '*').firstOrNull;
    final i = int.tryParse(v) ?? -1;
    final shown = switch (type) {
      's' => i >= 0 && i < _shared.length ? _shared[i] : '',
      'inlineStr' => c.findElements('is', namespaceUri: '*').map(_richText).join(),
      'b' => v == '1' ? 'VERDADEIRO' : 'FALSO',
      _ => v,
    };
    return _Cell(
      shown: shown,
      estilo: c.getAttribute('s'),
      xml: c,
      formula: f == null || f.getAttribute('t') == 'dataTable' ? null : f.innerText,
      dataTable: f?.getAttribute('t') == 'dataTable',
      matrix: f?.getAttribute('t') == 'array' ? f!.getAttribute('ref') : null,
    );
  }

  /// Sheet XML with the `sheetData` rebuilt from the model and the sheet's fixed references (merges,
  /// columns, links, validations) adjusted to the inserted and deleted rows/columns.
  String _buildXml() {
    _load();
    final doc = XmlDocument.parse(_xmlOriginal);
    final root = doc.rootElement;
    final p = root.name.prefix;
    String tag(String n) => p == null ? n : '$p:$n';
    var data = root.findElements('sheetData', namespaceUri: '*').firstOrNull;
    if (data == null) {
      data = XmlDocumentFragment.parse('<${tag('sheetData')}/>').firstElementChild!.copy();
      root.children.add(data);
    }
    const removable = {'mergeCell', 'hyperlink', 'conditionalFormatting', 'dataValidation', 'protectedRange', 'ignoredError', 'autoFilter'};
    if (_operations.isNotEmpty) {
      for (final e in root.descendantElements.toList()) {
        if (e.localName == 'sheetData' || e.localName == 'dimension') continue;
        if (e.ancestorElements.any((a) => a.localName == 'sheetData')) continue;
        if (e.localName == 'col') {
          var band = (int.tryParse(e.getAttribute('min') ?? '') ?? 1) - 1;
          var end = (int.tryParse(e.getAttribute('max') ?? '') ?? 1) - 1;
          (int, int)? r = (band, end);
          for (final op in _operations.where((o) => !o.line)) {
            r = r == null ? null : op.mapItems(r.$1, r.$2, false);
          }
          if (r == null) {
            e.remove();
          } else {
            (band, end) = r;
            e.setAttribute('min', '${band + 1}');
            e.setAttribute('max', '${end + 1}');
          }
          continue;
        }
        for (final attribute in ['ref', 'sqref', 'activeCell']) {
          final value = e.getAttribute(attribute);
          if (value == null) continue;
          String? isNew = value;
          for (final op in _operations) {
            isNew = isNew == null ? null : _mapRanges(isNew, op.mapItems);
          }
          if (isNew != null) {
            e.setAttribute(attribute, isNew);
          } else if (removable.contains(e.localName)) {
            e.remove();
          } else {
            e.setAttribute(attribute, 'A1');
          }
        }
      }
      for (final m in root.findElements('mergeCells', namespaceUri: '*').toList()) {
        final n = m.findElements('mergeCell', namespaceUri: '*').length;
        n == 0 ? m.remove() : m.setAttribute('count', '$n');
      }
    }
    final dimension = root.findElements('dimension', namespaceUri: '*').firstOrNull;
    final (ls, cs) = (lines, columns);
    dimension?.setAttribute('ref', ls == 0 || cs == 0 ? 'A1' : 'A1:${cellRef(ls - 1, cs - 1)}');

    final body = StringBuffer();
    for (var i = 0; i < _grade.length; i++) {
      final l = _grade[i];
      if (l == null) continue;
      final cells = StringBuffer();
      for (var c = 0; c < l.cells.length; c++) {
        final cel = l.cells[c];
        if (cel != null) cells.write(_cellXml(cel, cellRef(i, c), tag));
      }
      if (cells.isEmpty && l.attributes.isEmpty) continue;
      body.write('<${tag('row')} r="${i + 1}"');
      l.attributes.forEach((k, v) => body.write(' $k="${_escape(v)}"'));
      body.write(cells.isEmpty ? '/>' : '>$cells</${tag('row')}>');
    }
    data.children.clear();
    data.children.add(XmlComment('__planilha__'));
    return doc.toXmlString().replaceFirst('<!--__planilha__-->', body.toString());
  }

  String _cellXml(_Cell c, String ref, String Function(String) tag) {
    final original = c.xml;
    if (original != null) {
      final copy = original.copy()..setAttribute('r', ref);
      final f = copy.findElements('f', namespaceUri: '*').firstOrNull;
      if (f != null && c.formula != null && !c.dataTable) {
        // A shared formula becomes explicit: the master may have changed or moved.
        f.innerText = c.formula!;
        for (final a in ['si', 'ref']) {
          f.removeAttribute(a);
        }
        if (c.matrix != null) {
          f.setAttribute('ref', c.matrix);
        } else {
          f.removeAttribute('t');
        }
      }
      return copy.toXmlString();
    }
    final attributes = ' r="$ref"${c.estilo == null ? '' : ' s="${c.estilo}"'}';
    if (c.formula != null) return '<${tag('c')}$attributes><${tag('f')}>${_escape(c.formula!)}</${tag('f')}></${tag('c')}>';
    if (c.shown.isEmpty) return '<${tag('c')}$attributes/>';
    if (c.number) return '<${tag('c')}$attributes><${tag('v')}>${c.shown}</${tag('v')}></${tag('c')}>';
    return '<${tag('c')}$attributes t="inlineStr"><${tag('is')}><${tag('t')} xml:space="preserve">'
        '${_escape(c.shown)}</${tag('t')}></${tag('is')}></${tag('c')}>';
  }
}

class _Row {
  _Row(this.attributes);

  /// Attributes of `<row>` (height, hidden, style), without `r` and `spans`.
  final Map<String, String> attributes;
  final cells = <_Cell?>[];
}

class _Cell {
  _Cell({required this.shown, this.estilo, this.xml, this.formula, this.matrix, this.number = false, this.dataTable = false});

  final String shown;
  final String? estilo;

  /// Original element, rewritten as it came (only `r` and the formula adjusted); `null` = edited cell.
  final XmlElement? xml;
  String? formula;
  String? matrix;
  final bool number;
  final bool dataTable;
}

/// Insertion (`delta` 1) or deletion (`-1`) of a row or column at [index].
class _Operation {
  _Operation(this.line, this.score, this.delta);

  final bool line;
  final int score;
  final int delta;

  /// New range `[a, b]` on the affected axis; `null` when it disappears entirely.
  (int, int)? mapItems(int a, int b, bool isLine) {
    if (isLine != line) return (a, b);
    final p = score;
    if (delta > 0) return (a >= p ? a + 1 : a, b >= p ? b + 1 : b);
    if (p < a) return (a - 1, b - 1);
    if (p > b) return (a, b);
    return a == b ? null : (a, b - 1);
  }
}

typedef _MapView = (int, int)? Function(int a, int b, bool isLine);

// Text literal (ignored) | optional sheet prefix + A1 or A1:B2. A function name like LOG10(
// does not match because of the lookahead.
final _reFormula = RegExp(
  r'''("(?:[^"]|"")*")|((?:'(?:[^']|'')+'|[A-Za-z_\\][\w.\\]*)!)?(?<![\w.$])(\$?)([A-Z]{1,3})(\$?)(\d+)(?::(\$?)([A-Z]{1,3})(\$?)(\d+))?(?![\w(!])''',
);

/// Rewrites the A1 references of [formula] whose sheet prefix passes [target] (`null` = no
/// prefix). With [relative], only the parts without `$` change (shared formula copy).
String _swapRefs(String formula, bool Function(String? tab) target, _MapView mapping, {bool relative = false}) {
  return formula.replaceAllMapped(_reFormula, (m) {
    if (m[1] != null) return m[0]!;
    final prefix = m[2];
    if (!target(prefix?.substring(0, prefix.length - 1))) return m[0]!;
    final c1 = columnFromLetters(m[4]!), l1 = int.parse(m[6]!) - 1;
    final hasEnd = m[8] != null;
    final c2 = hasEnd ? columnFromLetters(m[8]!) : c1, l2 = hasEnd ? int.parse(m[10]!) - 1 : l1;
    if (c1 >= maxColumns || c2 >= maxColumns) return m[0]!;
    int? nc1 = c1, nc2 = c2, nl1 = l1, nl2 = l2;
    if (relative) {
      final dc = mapping(0, 0, false)!.$1, dl = mapping(0, 0, true)!.$1;
      if (m[3]!.isEmpty) nc1 = c1 + dc;
      if (m[5]!.isEmpty) nl1 = l1 + dl;
      if (hasEnd && m[7]!.isEmpty) nc2 = c2 + dc;
      if (hasEnd && m[9]!.isEmpty) nl2 = l2 + dl;
    } else {
      final cs = mapping(c1, c2, false), ls = mapping(l1, l2, true);
      if (cs == null || ls == null) return '${prefix ?? ''}#REF!';
      (nc1, nc2, nl1, nl2) = (cs.$1, cs.$2, ls.$1, ls.$2);
    }
    if ([nc1, nc2].any((c) => c < 0 || c >= maxColumns) || [nl1, nl2].any((l) => l < 0 || l >= maxRows)) {
      return '${prefix ?? ''}#REF!';
    }
    final start = '${m[3]}${columnLetters(nc1)}${m[5]}${nl1 + 1}';
    final end = hasEnd ? ':${m[7]}${columnLetters(nc2)}${m[9]}${nl2 + 1}' : '';
    return '${prefix ?? ''}$start$end';
  });
}

/// `A1:B2 C3` with each range mapped; those that disappear go away. `null` if none remains.
String? _mapRanges(String sqref, _MapView mapping) {
  final newItems = <String>[];
  for (final part in sqref.split(' ').where((p) => p.isNotEmpty)) {
    final tips = part.split(':');
    final a = _tryRef(tips.first), b = _tryRef(tips.last);
    if (a == null || b == null) {
      newItems.add(part);
      continue;
    }
    final ls = mapping(a.$1, b.$1, true), cs = mapping(a.$2, b.$2, false);
    if (ls == null || cs == null) continue;
    final start = cellRef(ls.$1, cs.$1);
    newItems.add(tips.length == 1 ? start : '$start:${cellRef(ls.$2, cs.$2)}');
  }
  return newItems.isEmpty ? null : newItems.join(' ');
}

(int, int)? _tryRef(String ref) {
  try {
    return readRef(ref);
  } on FormatException {
    return null;
  }
}

bool _sameName(String prefix, String name) {
  final p = prefix.startsWith("'") && prefix.endsWith("'") ? prefix.substring(1, prefix.length - 1).replaceAll("''", "'") : prefix;
  return p.toLowerCase() == name.toLowerCase();
}

final _reNumber = RegExp(r'^-?\d+([.,]\d+)?([eE][-+]?\d+)?$');

/// Number as Excel writes it in `<v>` (decimal point), accepting a comma; `null` if it is not a number.
String? _number(String value) {
  final v = value.trim();
  if (!_reNumber.hasMatch(v)) return null;
  final n = v.replaceFirst(',', '.');
  return double.tryParse(n) == null ? null : n;
}

final _reOoxmlEscape = RegExp(r'_x([0-9A-Fa-f]{4})_');

/// Text of `<si>`/`<is>`: direct `<t>` or the `<r><t>` parts of rich text, without the phonetics (`rPh`).
String _richText(XmlElement e) => e
    .findAllElements('t', namespaceUri: '*')
    .where((t) => t.parentElement?.localName != 'rPh')
    .map((t) => t.innerText)
    .join()
    .replaceAllMapped(_reOoxmlEscape, (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)));

final _reInvalidXml = RegExp('[\u0000-\u0008\u000B\u000C\u000E-\u001F]');

String _escape(String s) => s
    .replaceAll(_reInvalidXml, '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

class _Relationship {
  _Relationship(this.id, this.type, this.target);

  final String id;
  final String type;
  final String target;
}

List<_Relationship> _relationships(XmlDocument doc) => [
  for (final r in doc.findAllElements('Relationship', namespaceUri: '*'))
    if (r.getAttribute('TargetMode') != 'External')
      _Relationship(r.getAttribute('Id') ?? '', r.getAttribute('Type') ?? '', r.getAttribute('Target') ?? ''),
];

/// Path in the zip of a relationship target relative to [folder] (`xl/`); `/xl/...` is absolute.
String _resolver(String pasta, String target) {
  if (target.startsWith('/')) return target.substring(1);
  final parts = <String>[...pasta.split('/').where((p) => p.isNotEmpty)];
  for (final p in target.split('/')) {
    if (p == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else if (p.isNotEmpty && p != '.') {
      parts.add(p);
    }
  }
  return parts.join('/');
}
