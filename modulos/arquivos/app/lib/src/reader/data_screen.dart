import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:xml/xml.dart';

import '../files_api.dart';
import '../external/external.dart';
import '../models.dart';
import '../screens/highlight_actions.dart';
import '../screens/library_screen.dart';

/// Text of the original and how it was encoded, to write it back the same way: UTF-8 (with or
/// without BOM) or, if not, Latin-1 (CSV exported by Excel in PT-BR).
class OriginalText {
  OriginalText(this.text, {this.emLatin1 = false, this.good = false});

  factory OriginalText.decode(Uint8List bytes) {
    try {
      // utf8.decode already drops the BOM; it is seen in the bytes.
      final good = bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF;
      return OriginalText(utf8.decode(bytes), good: good);
    } on FormatException {
      return OriginalText(latin1.decode(bytes), emLatin1: true);
    }
  }

  final String text;
  final bool emLatin1;
  final bool good;

  /// A character outside Latin-1 becomes `?` (the original file did not accept it anyway).
  Uint8List encode(String isNew) => emLatin1
      ? const Latin1Codec(allowInvalid: true).encode(isNew)
      : utf8.encode(good ? '\uFEFF$isNew' : isNew);
}

/// CSV lines and the separator (`;`, `,` or tab: the most frequent on the first line). Double
/// quotes protect separator and line break; `""` inside them becomes `"`.
(List<List<String>>, String) readCsv(String text) {
  final first = text.split('\n').first;
  final separator = [';', ',', '\t'].reduce((a, b) => b.allMatches(first).length > a.allMatches(first).length ? b : a);
  final lines = <List<String>>[];
  var line = <String>[];
  final field = StringBuffer();
  var quotes = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quotes) {
      if (c == '"' && i + 1 < text.length && text[i + 1] == '"') {
        field.write('"');
        i++;
      } else if (c == '"') {
        quotes = false;
      } else {
        field.write(c);
      }
    } else if (c == '"') {
      quotes = true;
    } else if (c == separator) {
      line.add(field.toString());
      field.clear();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      line.add(field.toString());
      field.clear();
      lines.add(line);
      line = [];
    } else {
      field.write(c);
    }
  }
  if (field.isNotEmpty || line.isNotEmpty) lines.add([...line, field.toString()]);
  return ([for (final l in lines) if (l.any((c) => c.isNotEmpty)) l], separator);
}

/// Inverse of [readCsv]: quotes only where the field has a separator, quotes or a line break.
String writeCsv(List<List<String>> lines, String separator, {String wrap = '\n'}) {
  String field(String c) =>
      c.contains(separator) || c.contains('"') || c.contains('\n') || c.contains('\r') ? '"${c.replaceAll('"', '""')}"' : c;
  return [for (final l in lines) l.map(field).join(separator)].join(wrap) + wrap;
}

/// Saves the edited text: uploads right away or, offline, stays on the device. `true` if it worked.
typedef SaveIntent = Future<bool> Function(String isNew);

/// Downloads the original (from the device when downloaded, otherwise from the server) and hands it to the editor.
class _OriginalScreen extends StatefulWidget {
  const _OriginalScreen({required this.api, required this.file, required this.construir});

  final FilesApi api;
  final FileItem file;
  final Widget Function(OriginalText original, SaveIntent save) construir;

  @override
  State<_OriginalScreen> createState() => _OriginalScreenState();
}

class _OriginalScreenState extends State<_OriginalScreen> {
  late final Future<OriginalText> _original = _read();

  Future<OriginalText> _read() async {
    final id = widget.file.id;
    return OriginalText.decode(await widget.api.offline.original(id) ?? await widget.api.original(id));
  }

  Future<bool> _save(String isNew) async {
    try {
      final bytes = (await _original).encode(isNew);
      final saved = await widget.api.offline.saveOriginal(widget.file, bytes);
      if (mounted) notify(context, saved == null ? 'Sem conexão: salvo no aparelho; sobe quando a conexão voltar.' : 'Salvo.');
      return true;
    } on ApiErro catch (e) {
      if (mounted) notify(context, 'Não consegui salvar: ${e.mensagem}');
      return false;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.file.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        if (editorsFor(widget.file).isNotEmpty)
          IconButton(
            tooltip: 'Abrir com…',
            icon: const Icon(Icons.open_in_new),
            onPressed: () => openWithEditor(context, widget.api, widget.file),
          ),
      ],
    ),
    body: FutureBuilder(
      future: _original,
      builder: (context, s) => s.hasError
          ? Center(child: Text('Não consegui abrir: ${s.error is ApiErro ? (s.error as ApiErro).mensagem : s.error}'))
          : s.hasData
          ? widget.construir(s.data!, _save)
          : const Center(child: CircularProgressIndicator()),
    ),
  );
}

/// Asks before leaving with unsaved changes.
class ExitGuard extends StatelessWidget {
  const ExitGuard({super.key, required this.dirty, required this.child});

  final bool dirty;
  final Widget child;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !dirty,
    onPopInvokedWithResult: (exited, _) async {
      if (exited) return;
      final leave = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Sair sem salvar?'),
          content: const Text('As alterações feitas aqui se perdem.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Continuar editando')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Sair')),
          ],
        ),
      );
      if (leave == true && context.mounted) Navigator.of(context).pop();
    },
    child: child,
  );
}

/// CSV as an editable table: tap the cell to edit; row (no.) and column (header) menus
/// to insert and delete.
class CsvScreen extends StatelessWidget {
  const CsvScreen({super.key, required this.api, required this.file});

  final FilesApi api;
  final FileItem file;

  @override
  Widget build(BuildContext context) =>
      _OriginalScreen(api: api, file: file, construir: (o, save) => _Table(original: o.text, save: save));
}

class _Table extends StatefulWidget {
  const _Table({required this.original, required this.save});

  final String original;
  final SaveIntent save;

  @override
  State<_Table> createState() => _TableState();
}

class _TableState extends State<_Table> {
  static const _width = 180.0;
  static const _numberWidth = 56.0;

  late final List<List<String>> _lines;
  late final String _separator;
  late final String _break = widget.original.contains('\r\n') ? '\r\n' : '\n';
  String _search = '';
  bool _dirty = false;
  bool _isSaving = false;
  (int, int)? _editing;
  final _input = TextEditingController();

  @override
  void initState() {
    super.initState();
    final (lines, separator) = readCsv(widget.original);
    _lines = lines.isEmpty ? [<String>['']] : lines;
    _separator = separator;
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  int get _columns => _lines.fold(0, (n, l) => l.length > n ? l.length : n);

  void _change(VoidCallback f) => setState(() {
    f();
    _dirty = true;
  });

  void _edit(int line, int column) {
    _confirmEdit();
    final l = _lines[line];
    _input.text = column < l.length ? l[column] : '';
    setState(() => _editing = (line, column));
  }

  void _confirmEdit() {
    final e = _editing;
    if (e == null) return;
    final (line, column) = e;
    final l = _lines[line];
    while (l.length <= column) {
      l.add('');
    }
    if (l[column] != _input.text) {
      l[column] = _input.text;
      _dirty = true;
    }
    setState(() => _editing = null);
  }

  Future<void> _save() async {
    _confirmEdit();
    setState(() => _isSaving = true);
    final ok = await widget.save(writeCsv(_lines, _separator, wrap: _break));
    if (!mounted) return;
    setState(() {
      _isSaving = false;
      if (ok) _dirty = false;
    });
  }

  void _rowAction(String action, int i) => _change(() {
    _editing = null;
    switch (action) {
      case 'acima':
        _lines.insert(i, List.filled(_columns, '', growable: true));
      case 'abaixo':
        _lines.insert(i + 1, List.filled(_columns, '', growable: true));
      case 'excluir':
        _lines.removeAt(i);
    }
  });

  void _columnAction(String action, int c) => _change(() {
    _editing = null;
    for (final l in _lines) {
      while (l.length < _columns) {
        l.add('');
      }
    }
    for (final l in _lines) {
      if (action == 'direita') l.insert(c + 1, '');
      if (action == 'excluir' && _lines.first.length > 1) l.removeAt(c);
    }
  });

  Widget _cell(int line, int column, {bool bold = false}) {
    final colors = Theme.of(context).colorScheme;
    final l = _lines[line];
    final editing = _editing == (line, column);
    return Container(
      width: _width,
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: colors.outlineVariant)),
        color: editing ? colors.primaryContainer : null,
      ),
      child: editing
          ? TextField(
              controller: _input,
              autofocus: true,
              style: bold ? const TextStyle(fontWeight: FontWeight.bold) : null,
              decoration: const InputDecoration(isDense: true, border: InputBorder.none),
              onSubmitted: (_) => _confirmEdit(),
              onTapOutside: (_) => _confirmEdit(),
            )
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _edit(line, column),
              child: SizedBox.expand(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    column < l.length ? l[column] : '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: bold ? const TextStyle(fontWeight: FontWeight.bold) : null,
                  ),
                ),
              ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final columns = _columns;
    final term = _search.toLowerCase();
    final indices = [
      for (var i = 1; i < _lines.length; i++)
        if (term.isEmpty || _lines[i].any((c) => c.toLowerCase().contains(term))) i,
    ];
    final colors = Theme.of(context).colorScheme;
    Widget line(int i, {Color? background}) => Container(
      color: background,
      child: Row(
        children: [
          SizedBox(
            width: _numberWidth,
            child: PopupMenuButton<String>(
              tooltip: 'Linha $i',
              onSelected: (a) => _rowAction(a, i),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'acima', child: Text('Inserir linha acima')),
                PopupMenuItem(value: 'abaixo', child: Text('Inserir linha abaixo')),
                PopupMenuItem(value: 'excluir', child: Text('Excluir linha')),
              ],
              child: Center(child: Text('$i', style: TextStyle(color: colors.outline))),
            ),
          ),
          for (var c = 0; c < columns; c++) _cell(i, c),
        ],
      ),
    );
    return ExitGuard(
      dirty: _dirty,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              spacing: 8,
              children: [
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Buscar nas linhas',
                      helperText: '${indices.length} de ${_lines.length - 1} linhas · $columns colunas',
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (v) => setState(() => _search = v),
                  ),
                ),
                IconButton(
                  tooltip: 'Nova linha no fim',
                  icon: const Icon(Icons.playlist_add),
                  onPressed: () => _rowAction('abaixo', _lines.length - 1),
                ),
                IconButton(
                  tooltip: 'Nova coluna no fim',
                  icon: const Icon(Icons.view_column_outlined),
                  onPressed: () => _columnAction('direita', columns - 1),
                ),
                FilledButton.icon(
                  onPressed: _dirty && !_isSaving ? _save : null,
                  icon: _isSaving
                      ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.save_outlined),
                  label: const Text('Salvar'),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: _numberWidth + columns * _width,
                child: Column(
                  children: [
                    Container(
                      color: colors.surfaceContainerHighest,
                      child: Row(
                        children: [
                          const SizedBox(width: _numberWidth),
                          for (var c = 0; c < columns; c++)
                            Stack(
                              children: [
                                _cell(0, c, bold: true),
                                Positioned(
                                  right: 0,
                                  top: 0,
                                  bottom: 0,
                                  child: PopupMenuButton<String>(
                                    tooltip: 'Coluna',
                                    icon: const Icon(Icons.more_vert, size: 16),
                                    padding: EdgeInsets.zero,
                                    onSelected: (a) => _columnAction(a, c),
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(value: 'direita', child: Text('Inserir coluna à direita')),
                                      PopupMenuItem(value: 'excluir', child: Text('Excluir coluna')),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: indices.length,
                        itemBuilder: (_, k) => line(indices[k], background: k.isOdd ? colors.surfaceContainerLow : null),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// XML as a collapsible tree (browse) or as editable text (the original, without reformatting).
class XmlScreen extends StatelessWidget {
  const XmlScreen({super.key, required this.api, required this.file});

  final FilesApi api;
  final FileItem file;

  @override
  Widget build(BuildContext context) =>
      _OriginalScreen(api: api, file: file, construir: (o, save) => _EditorXml(original: o.text, save: save));
}

class _EditorXml extends StatefulWidget {
  const _EditorXml({required this.original, required this.save});

  final String original;
  final SaveIntent save;

  @override
  State<_EditorXml> createState() => _EditorXmlState();
}

class _EditorXmlState extends State<_EditorXml> {
  late final _text = TextEditingController(text: widget.original);
  late String _salvo = widget.original;
  bool _textMode = false;
  bool _isSaving = false;

  bool get _dirty => _text.text != _salvo;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final isNew = _text.text;
    try {
      XmlDocument.parse(isNew);
    } on XmlException catch (e) {
      return notify(context, 'XML inválido, não salvei: $e');
    }
    setState(() => _isSaving = true);
    final ok = await widget.save(isNew);
    if (!mounted) return;
    setState(() {
      _isSaving = false;
      if (ok) _salvo = isNew;
    });
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (_textMode) {
      body = Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: TextField(
          controller: _text,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          decoration: const InputDecoration(border: OutlineInputBorder()),
          onChanged: (_) => setState(() {}),
        ),
      );
    } else {
      try {
        body = _XmlTree(key: ValueKey(_text.text), root: XmlDocument.parse(_text.text).rootElement);
      } on XmlException catch (e) {
        body = Center(child: Text('XML inválido ($e). Corrija no modo texto.'));
      }
    }
    return ExitGuard(
      dirty: _dirty,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              spacing: 8,
              children: [
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, icon: Icon(Icons.account_tree_outlined), label: Text('Árvore')),
                    ButtonSegment(value: true, icon: Icon(Icons.edit_note), label: Text('Editar texto')),
                  ],
                  selected: {_textMode},
                  onSelectionChanged: (s) => setState(() => _textMode = s.first),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _dirty && !_isSaving ? _save : null,
                  icon: _isSaving
                      ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.save_outlined),
                  label: const Text('Salvar'),
                ),
              ],
            ),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}

class _XmlTree extends StatefulWidget {
  const _XmlTree({super.key, required this.root});

  final XmlElement root;

  @override
  State<_XmlTree> createState() => _XmlTreeState();
}

class _XmlTreeState extends State<_XmlTree> {
  /// Expanded elements; starts with the root and the first level.
  late final Set<XmlElement> _openFiles = {widget.root, ...widget.root.childElements};

  /// Visible elements in order, with the depth.
  List<(XmlElement, int)> _visible() {
    final expense = <(XmlElement, int)>[];
    void visit(XmlElement e, int level) {
      expense.add((e, level));
      if (_openFiles.contains(e)) {
        for (final f in e.childElements) {
          visit(f, level + 1);
        }
      }
    }

    visit(widget.root, 0);
    return expense;
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible();
    final colors = Theme.of(context).colorScheme;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: visible.length,
      itemBuilder: (context, i) {
        final (e, level) = visible[i];
        final hasChildren = e.childElements.isNotEmpty;
        final value = hasChildren ? '' : e.innerText.trim();
        return InkWell(
          onTap: hasChildren ? () => setState(() => _openFiles.contains(e) ? _openFiles.remove(e) : _openFiles.add(e)) : null,
          child: Padding(
            padding: EdgeInsets.fromLTRB(8 + level * 18.0, 4, 16, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 24,
                  child: hasChildren
                      ? Icon(_openFiles.contains(e) ? Icons.expand_more : Icons.chevron_right, size: 20)
                      : null,
                ),
                Expanded(
                  child: SelectableText.rich(
                    TextSpan(
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                      children: [
                        TextSpan(text: e.name.qualified, style: TextStyle(color: colors.primary, fontWeight: FontWeight.bold)),
                        for (final a in e.attributes) ...[
                          TextSpan(text: ' ${a.name.qualified}=', style: TextStyle(color: colors.tertiary)),
                          TextSpan(text: '"${a.value}"'),
                        ],
                        if (hasChildren && !_openFiles.contains(e))
                          TextSpan(text: '  (${e.childElements.length})', style: TextStyle(color: colors.outline)),
                        if (value.isNotEmpty) TextSpan(text: '  $value', style: TextStyle(color: colors.onSurface)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
