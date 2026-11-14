import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';

import '../files_api.dart';
import '../reader/data_screen.dart';
import '../models.dart';
import 'docx.dart';
import 'export.dart';
import '../screens/highlight_actions.dart';
import 'rewrite.dart';

/// Author of the spelling/grammar suggestions requested from Claude.
const claudeReviewerAuthor = 'Revisor (Claude)';

const _fonts = {
  'Padrão': 'Clear',
  'Times New Roman': 'Times New Roman',
  'Arial': 'Arial',
  'Calibri': 'Calibri',
  'Cambria': 'Cambria',
  'Georgia': 'Georgia',
  'Garamond': 'Garamond',
  'Liberation Serif': 'Liberation Serif',
  'Liberation Sans': 'Liberation Sans',
  'Courier New': 'Courier New',
};

const _sizes = {
  'Padrão': '0', '8': '8', '9': '9', '10': '10', '10.5': '10.5', '11': '11', '12': '12', '14': '14', '16': '16',
  '18': '18', '20': '20', '24': '24', '28': '28', '32': '32', '36': '36', '48': '48', '72': '72',
};

const _cores = [Color(0xFF1E88E5), Color(0xFFD81B60), Color(0xFF43A047), Color(0xFF8E24AA), Color(0xFFF4511E), Color(0xFF00897B)];

/// Fixed color per author (the same on every device).
Color authorColor(String author) => _cores[author.codeUnits.fold(0, (a, b) => (a * 31 + b) & 0x7fffffff) % _cores.length];

/// Excerpt with a revision (insertion or deletion) by an author, in document positions.
class Revision {
  Revision(this.insertion, this.mark, this.start, this.end, this.text);

  final bool insertion;
  final String mark;
  final int start;
  final int end;
  final String text;

  String get author => readMark(mark).author;
  DateTime? get data => readMark(mark).data;
}

/// Revisions of the delta, joining neighboring excerpts of the same author and type.
List<Revision> revisionsOf(List<Operation> ops) {
  final r = <Revision>[];
  var pos = 0;
  for (final op in ops) {
    final n = op.length ?? 0;
    final text = op.data is String ? op.data as String : '';
    for (final (key, insertion) in [(insertionAttribute, true), (deletionAttribute, false)]) {
      final mark = op.attributes?[key];
      if (mark is! String) continue;
      final last = r.lastOrNull;
      if (last != null && last.insertion == insertion && last.mark == mark && last.end == pos) {
        r[r.length - 1] = Revision(insertion, mark, last.start, pos + n, last.text + text);
      } else {
        r.add(Revision(insertion, mark, pos, pos + n, text));
      }
    }
    pos += n;
  }
  return r;
}

/// Word-style DOCX editor: font, size, color, highlight, headings, lists, alignment,
/// indent, links; "Controlar alterações" (what I write/erase stays marked with my name, as the
/// advisor did in the original), revisions panel (accept/reject by author) and comments panel,
/// spelling and rewrite by Claude Code (they become tracked suggestions) and export.
class DocumentScreen extends StatefulWidget {
  const DocumentScreen({super.key, required this.api, required this.file});

  final FilesApi api;
  final FileItem file;

  @override
  State<DocumentScreen> createState() => _DocumentScreenState();
}

enum _Panel { revisions, comments }

class _DocumentScreenState extends State<DocumentScreen> {
  late final Future<void> _load = _read();
  DocxDocument? _docx;
  QuillController? _c;
  StreamSubscription<dynamic>? _changes;
  List<Comment> _comments = [];
  bool _reviewer = false;
  bool _dirty = false;
  bool _isSaving = false;
  bool _acceptedWarnings = false;
  bool _applying = false;
  String _author = 'Eu';
  String? _authorFilter;
  _Panel? _panel;
  final _scaffold = GlobalKey<ScaffoldState>();
  final _focus = FocusNode(debugLabel: 'documento');
  final _scroll = ScrollController();

  QuillController get c => _c!;

  @override
  void dispose() {
    _changes?.cancel();
    _c?.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _read() async {
    final arm = await Armazem.abrir('preferencias');
    final saved = await arm.lerJson('editor/autor.json');
    if (saved is String && saved.trim().isNotEmpty) _author = saved;
    final id = widget.file.id;
    final bytes = await widget.api.offline.original(id) ?? await widget.api.original(id);
    final docx = DocxDocument.read(bytes);
    final controle = QuillController(
      document: Document.fromJson(docx.delta),
      selection: const TextSelection.collapsed(offset: 0),
    );
    controle.onReplaceText = _replace;
    _changes = controle.document.changes.listen((_) {
      if (mounted) setState(() => _dirty = true);
    });
    _docx = docx;
    _c = controle;
    _comments = [...docx.comments];
    _reviewer = docx.tracking;
    // Revisions and comments that came in the file (from the advisor) open the panel.
    if (revisionsOf(controle.document.toDelta().toList()).isNotEmpty) {
      _panel = _Panel.revisions;
    } else if (_comments.isNotEmpty) {
      _panel = _Panel.comments;
    }
  }

  // ---------------------------------------------------------------- revision (track changes)

  String _mark([String? author]) => revisionMark(author ?? _author, DateTime.now());

  Attribute<String?> _attr(String key, String? value) => Attribute(key, AttributeScope.inline, value);

  void _withoutMarks(int start, int n) {
    c.formatText(start, n, _attr(insertionAttribute, null));
    c.formatText(start, n, _attr(deletionAttribute, null));
  }

  void _apply(void Function() edition) {
    _applying = true;
    try {
      edition();
    } finally {
      _applying = false;
    }
  }

  /// Every typing/paste passes here. With the reviewer on, the new text stays marked with my
  /// name and the erased one becomes a tracked deletion (strikethrough) instead of disappearing.
  bool _replace(int index, int len, Object? data) {
    if (_applying || data is! String) return true;
    _apply(() {
      if (!_reviewer) {
        c.replaceText(index, len, data, TextSelection.collapsed(offset: index + data.length));
        // New text does not inherit the neighbor's revision mark.
        if (data.isNotEmpty) _withoutMarks(index, data.length);
        return;
      }
      _editTracked(index, len, data, _mark());
      c.updateSelection(TextSelection.collapsed(offset: index + data.length), ChangeSource.local);
    });
    return false;
  }

  /// Replaces [len] characters at [index] with [text] as a revision of [mark] (without touching the selection).
  void _editTracked(int index, int len, String text, String mark) {
    if (text.isNotEmpty) {
      c.replaceText(index, 0, text, null);
      _withoutMarks(index, text.length);
      c.formatText(index, text.length, _attr(insertionAttribute, mark));
    }
    if (len > 0) _markDeletion(index + text.length, len, mark);
  }

  void _markDeletion(int start, int len, String mark) {
    final author = readMark(mark).author;
    final ops = c.document.toDelta().slice(start, start + len).toList();
    // Backspace at the start of the line joins the paragraphs (the break is not tracked).
    if (len == 1 && ops.length == 1 && ops.first.data == '\n') {
      c.replaceText(start, 1, '', null);
      return;
    }
    // Back to front: really erasing does not shift what is still left.
    var end = start + len;
    for (final op in ops.reversed) {
      final n = op.length ?? 0;
      final start = end - n;
      end = start;
      final dado = op.data;
      if (dado is! String) continue;
      final ins = op.attributes?[insertionAttribute];
      final alreadyDeleted = op.attributes?[deletionAttribute] != null;
      // Parts without a line break: the breaks stay (Quill does not mark line formatting on '\n').
      var p = n;
      for (final chunk in dado.split('\n').reversed) {
        final a = p - chunk.length;
        if (chunk.isNotEmpty) {
          if (ins is String && readMark(ins).author == author) {
            c.replaceText(start + a, chunk.length, '', null); // erasing what I inserted myself leaves no trace
          } else if (!alreadyDeleted) {
            c.formatText(start + a, chunk.length, _attr(deletionAttribute, mark));
          }
        }
        p = a - 1;
      }
    }
  }

  void _resolver(Iterable<Revision> revisions, {required bool accept}) {
    _apply(() {
      // Back to front, so the positions stay valid.
      for (final r in revisions.toList().reversed) {
        final remover = r.insertion != accept;
        if (remover) {
          c.replaceText(r.start, r.end - r.start, '', null);
        } else {
          c.formatText(r.start, r.end - r.start, _attr(r.insertion ? insertionAttribute : deletionAttribute, null));
        }
      }
    });
    setState(() {});
  }

  void _goTo(int start, int end) {
    c.updateSelection(TextSelection(baseOffset: start, extentOffset: end), ChangeSource.local);
    _focus.requestFocus();
  }

  // ---------------------------------------------------------------- comments

  /// (start, end) of each excerpt marked with comment [id].
  List<(int, int)> _excerptsOf(String id) {
    final r = <(int, int)>[];
    var pos = 0;
    for (final op in c.document.toDelta().toList()) {
      final n = op.length ?? 0;
      if (commentIds(op.attributes?[commentAttribute]).contains(id)) {
        if (r.isNotEmpty && r.last.$2 == pos) {
          r[r.length - 1] = (r.last.$1, pos + n);
        } else {
          r.add((pos, pos + n));
        }
      }
      pos += n;
    }
    return r;
  }

  /// Adds/removes [id] in the comment list of each piece between [start] and [end].
  void _markComment(int start, int end, String id, {required bool include}) {
    _apply(() {
      var pos = start;
      for (final op in c.document.toDelta().slice(start, end).toList()) {
        final n = op.length ?? 0;
        final ids = commentIds(op.attributes?[commentAttribute]).toSet();
        include ? ids.add(id) : ids.remove(id);
        c.formatText(pos, n, _attr(commentAttribute, ids.isEmpty ? null : (ids.toList()..sort()).join(',')));
        pos += n;
      }
    });
  }

  String _newId() =>
      '${_comments.map((c) => int.tryParse(c.id) ?? 0).fold(-1, (a, b) => a > b ? a : b) + 1}';

  Future<String?> _askText(String title, {String initial = ''}) {
    final field = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: TextField(controller: field, autofocus: true, minLines: 3, maxLines: 8),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, field.text.trim()), child: const Text('OK')),
        ],
      ),
    ).whenComplete(field.dispose);
  }

  Future<void> _comment({String? replyTo}) async {
    final sel = c.selection;
    final excerpts = replyTo == null ? [(sel.start, sel.end)] : _excerptsOf(replyTo);
    if (excerpts.isEmpty || excerpts.first.$1 == excerpts.first.$2) {
      return notify(context, 'Selecione o trecho a comentar.');
    }
    final text = await _askText(replyTo == null ? 'Novo comentário' : 'Responder');
    if (text == null || text.isEmpty) return;
    final id = _newId();
    final anterior = replyTo == null ? null : _comments.firstWhere((x) => x.id == replyTo);
    setState(() {
      _comments.add(Comment(id: id, author: _author, text: anterior == null ? text : '↳ ${anterior.author}: $text'));
      _panel = _Panel.comments;
      _dirty = true;
    });
    for (final (i, f) in excerpts) {
      _markComment(i, f, id, include: true);
    }
  }

  void _deleteComment(Comment x) {
    for (final (i, f) in _excerptsOf(x.id).reversed) {
      _markComment(i, f, x.id, include: false);
    }
    setState(() {
      _comments.remove(x);
      _dirty = true;
    });
  }

  Future<void> _editComment(Comment x) async {
    final text = await _askText('Editar comentário', initial: x.text);
    if (text == null || text.isEmpty) return;
    setState(() {
      _comments[_comments.indexOf(x)] = x.withText(text);
      _dirty = true;
    });
  }

  // ---------------------------------------------------------------- Claude

  /// Spelling and grammar by Claude Code: each accepted suggestion goes in as a revision of the
  /// "Revisor (Claude)", to accept/reject in the panel like the advisor's.
  Future<void> _spelling() async {
    final sel = c.selection;
    final start = sel.isCollapsed ? 0 : sel.start;
    final text = c.document.toPlainText().substring(start, sel.isCollapsed ? null : sel.end);
    if (text.trim().isEmpty) return;
    if (text.length > 60000) {
      return notify(context, 'Texto grande demais para uma revisão: selecione uma parte (até 60 mil caracteres).');
    }
    final Map<String, dynamic> r;
    try {
      r = await _withWait(
        'Revisando ortografia e gramática pelo Claude…',
        widget.api.rewrite(excerpt: text, goal: 'gramatica', fileId: widget.file.id),
      );
    } on ApiErro catch (e) {
      if (mounted) notify(context, 'Não consegui revisar: ${e.mensagem}');
      return;
    }
    final changes = [
      for (final m in (r['mudancas'] as List? ?? const []).cast<Map<String, dynamic>>())
        if ((m['antes'] as String? ?? '').isNotEmpty && m['antes'] != m['depois']) m,
    ];
    if (!mounted) return;
    if (changes.isEmpty) return notify(context, 'Nenhum erro encontrado.');
    final chosenItems = await _pickSuggestions(changes);
    if (chosenItems == null || chosenItems.isEmpty) return;
    var applied = 0;
    _apply(() {
      // From the end to the start, looking for each "antes" from the revised excerpt.
      final plan = c.document.toPlainText();
      final positions = <(int, Map<String, dynamic>)>[];
      var search = start;
      for (final m in chosenItems) {
        final i = plan.indexOf(m['antes'] as String, search);
        if (i < 0) continue;
        positions.add((i, m));
        search = i + (m['antes'] as String).length;
      }
      for (final (i, m) in positions.reversed) {
        _editTracked(i, (m['antes'] as String).length, m['depois'] as String? ?? '', _mark(claudeReviewerAuthor));
        applied++;
      }
    });
    setState(() => _panel = _Panel.revisions);
    if (mounted) notify(context, '$applied sugestões entraram como revisões do $claudeReviewerAuthor.');
  }

  /// Waits for [task] with a modal notice in front (the review takes a few seconds).
  Future<T> _withWait<T>(String mensagem, Future<T> task) async {
    final browser = Navigator.of(context);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 16),
              Expanded(child: Text(mensagem)),
            ],
          ),
        ),
      ),
    );
    try {
      return await task;
    } finally {
      browser.pop();
    }
  }

  Future<List<Map<String, dynamic>>?> _pickSuggestions(List<Map<String, dynamic>> changes) {
    final marked = List.filled(changes.length, true);
    return showDialog<List<Map<String, dynamic>>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text('${changes.length} sugestões'),
          content: SizedBox(
            width: 560,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (var i = 0; i < changes.length; i++)
                  CheckboxListTile(
                    value: marked[i],
                    onChanged: (v) => set(() => marked[i] = v ?? false),
                    title: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: changes[i]['antes'] as String,
                            style: const TextStyle(decoration: TextDecoration.lineThrough, color: Colors.redAccent),
                          ),
                          const TextSpan(text: '  →  '),
                          TextSpan(text: changes[i]['depois'] as String? ?? '', style: const TextStyle(color: Colors.green)),
                        ],
                      ),
                    ),
                    subtitle: Text(changes[i]['motivo'] as String? ?? ''),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, [
                for (var i = 0; i < changes.length; i++)
                  if (marked[i]) changes[i],
              ]),
              child: const Text('Aplicar como revisões'),
            ),
          ],
        ),
      ),
    );
  }

  /// Rewrites the selection with Claude; the accepted text replaces the excerpt as a tracked revision.
  Future<void> _rewrite() async {
    final sel = c.selection;
    if (sel.isCollapsed) return notify(context, 'Selecione o trecho a reescrever.');
    final excerpt = c.document.toPlainText().substring(sel.start, sel.end);
    final isNew = await rewriteWithClaude(
      context,
      widget.api,
      excerpt: excerpt,
      fileId: widget.file.id,
      title: widget.file.title,
    );
    if (isNew == null || isNew == excerpt) return;
    _apply(() => _editTracked(sel.start, sel.end - sel.start, isNew, _mark('Claude')));
    setState(() => _panel = _Panel.revisions);
  }

  // ---------------------------------------------------------------- save and export

  List<Map<String, dynamic>> get _delta => [...c.document.toDelta().toJson().cast<Map<String, dynamic>>()];

  Future<bool> _save() async {
    final docx = _docx!;
    if (docx.warnings.isNotEmpty && !_acceptedWarnings) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Salvar daqui perde partes do arquivo'),
          content: Text(
            'Este editor não preserva: ${docx.warnings.join(', ')}.\n\n'
            'Para manter tudo, use "Editar no Collabora" ou "Abrir com…" (LibreOffice/WordCraft).',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Salvar assim')),
          ],
        ),
      );
      if (ok != true) return false;
      _acceptedWarnings = true;
    }
    setState(() => _isSaving = true);
    try {
      final bytes = docx.save(_delta, comments: _comments, track: _reviewer);
      final isNew = await widget.api.offline.saveOriginal(widget.file, bytes);
      if (mounted) {
        setState(() => _dirty = false);
        notify(context, isNew == null ? 'Sem conexão: salvo no aparelho; sobe quando a conexão voltar.' : 'Salvo.');
      }
      return true;
    } on ApiErro catch (e) {
      if (mounted) notify(context, 'Não consegui salvar: ${e.mensagem}');
      return false;
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _export() async {
    if (_dirty && !await _save()) return;
    if (mounted) await exportFile(context, widget.api, widget.file, markdown: deltaToMarkdown(_delta));
  }

  Future<void> _switchAuthor() async {
    final name = await _askText('Seu nome nas revisões e comentários', initial: _author);
    if (name == null || name.isEmpty) return;
    setState(() => _author = name);
    await (await Armazem.abrir('preferencias')).gravarJson('editor/autor.json', name);
  }

  // ---------------------------------------------------------------- telas

  TextStyle _revisionStyle(Attribute<dynamic> a) {
    final v = a.value;
    if (v is! String) return const TextStyle();
    switch (a.key) {
      case insertionAttribute:
        final color = authorColor(readMark(v).author);
        return TextStyle(color: color, decoration: TextDecoration.underline, decorationColor: color);
      case deletionAttribute:
        final color = authorColor(readMark(v).author);
        return TextStyle(color: color.withValues(alpha: 0.75), decoration: TextDecoration.lineThrough, decorationColor: color);
      case commentAttribute:
        return TextStyle(backgroundColor: Colors.amber.withValues(alpha: 0.35));
    }
    return const TextStyle();
  }

  @override
  Widget build(BuildContext context) => ExitGuard(
    dirty: _dirty,
    // Quill brings its own toolbar texts; the app does not register its delegates.
    child: Localizations.override(
      context: context,
      delegates: const [FlutterQuillLocalizations.delegate],
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
            if (_dirty && !_isSaving) _save();
          },
        },
        child: Scaffold(
          key: _scaffold,
          appBar: AppBar(
            title: Text(widget.file.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: [
              if (_c != null) ..._actions(),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: FilledButton.icon(
                  onPressed: _dirty && !_isSaving ? _save : null,
                  icon: _isSaving
                      ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.save_outlined),
                  label: const Text('Salvar'),
                ),
              ),
            ],
          ),
          endDrawer: _c != null && !_largo(context) ? Drawer(width: 360, child: SafeArea(child: _panelContent())) : null,
          body: FutureBuilder(
            future: _load,
            builder: (context, s) {
              if (s.hasError) {
                final e = s.error;
                final msg = e is ApiErro ? e.mensagem : (e is InvalidDocx ? e.mensagem : '$e');
                return Center(child: Text('Não consegui abrir: $msg'));
              }
              if (s.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
              return _body(context);
            },
          ),
        ),
      ),
    ),
  );

  bool _largo(BuildContext context) => MediaQuery.sizeOf(context).width >= 1000;

  List<Widget> _actions() {
    final revisions = revisionsOf(c.document.toDelta().toList());
    return [
      Tooltip(
        message: 'Controlar alterações: o que você escreve/apaga fica marcado com "$_author"',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.track_changes, size: 18),
            const SizedBox(width: 4),
            const Text('Revisor'),
            Switch(value: _reviewer, onChanged: (v) => setState(() {
              _reviewer = v;
              _dirty = true;
            })),
          ],
        ),
      ),
      IconButton(
        tooltip: 'Revisões (${revisions.length})',
        onPressed: () => _openPanel(_Panel.revisions),
        icon: Badge.count(count: revisions.length, isLabelVisible: revisions.isNotEmpty, child: const Icon(Icons.rule)),
      ),
      IconButton(
        tooltip: 'Comentários (${_comments.length})',
        onPressed: () => _openPanel(_Panel.comments),
        icon: Badge.count(
          count: _comments.length,
          isLabelVisible: _comments.isNotEmpty,
          child: const Icon(Icons.comment_outlined),
        ),
      ),
      IconButton(tooltip: 'Comentar a seleção', onPressed: _comment, icon: const Icon(Icons.add_comment_outlined)),
      IconButton(tooltip: 'Ortografia e gramática (Claude)', onPressed: _spelling, icon: const Icon(Icons.spellcheck)),
      IconButton(tooltip: 'Reescrever a seleção (Claude)', onPressed: _rewrite, icon: const Icon(Icons.auto_fix_high)),
      IconButton(tooltip: 'Exportar', onPressed: _export, icon: const Icon(Icons.ios_share)),
      IconButton(tooltip: 'Seu nome: $_author', onPressed: _switchAuthor, icon: const Icon(Icons.badge_outlined)),
    ];
  }

  void _openPanel(_Panel p) {
    if (_largo(context)) {
      setState(() => _panel = _panel == p ? null : p);
    } else {
      setState(() => _panel = p);
      _scaffold.currentState?.openEndDrawer();
    }
  }

  Widget _body(BuildContext context) {
    final docx = _docx!;
    final largo = _largo(context);
    final plan = c.document.toPlainText();
    final keywords = RegExp(r'\S+').allMatches(plan).length;
    return Column(
      children: [
        QuillSimpleToolbar(
          controller: c,
          config: const QuillSimpleToolbarConfig(
            multiRowsDisplay: false,
            showFontFamily: true,
            showFontSize: true,
            showSubscript: true,
            showSuperscript: true,
            showCodeBlock: false,
            showInlineCode: false,
            showSearchButton: true,
            buttonOptions: QuillSimpleToolbarButtonOptions(
              fontFamily: QuillToolbarFontFamilyButtonOptions(items: _fonts),
              fontSize: QuillToolbarFontSizeButtonOptions(items: _sizes),
            ),
          ),
        ),
        if (docx.warnings.isNotEmpty)
          Material(
            color: Theme.of(context).colorScheme.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                'Não editável aqui (some ao salvar): ${docx.warnings.join(', ')}. Para isso, "Editar no Collabora".',
                style: TextStyle(color: Theme.of(context).colorScheme.onTertiaryContainer),
              ),
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _page(context)),
              if (largo && _panel != null) ...[
                const VerticalDivider(width: 1),
                SizedBox(width: 360, child: _panelContent()),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              Text('$keywords palavras · ${plan.length - 1} caracteres', style: Theme.of(context).textTheme.bodySmall),
              const Spacer(),
              if (_reviewer)
                Text(
                  'Controlar alterações ligado ($_author)',
                  style: TextStyle(color: authorColor(_author), fontSize: 12),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Centered light sheet, like a text editor page.
  Widget _page(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerLowest,
    child: Theme(
      data: ThemeData(brightness: Brightness.light, colorSchemeSeed: Colors.blue),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Card(
            margin: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
            color: Colors.white,
            elevation: 2,
            child: QuillEditor(
              controller: c,
              focusNode: _focus,
              scrollController: _scroll,
              config: QuillEditorConfig(
                padding: const EdgeInsets.fromLTRB(72, 56, 72, 56),
                placeholder: 'Escreva aqui…',
                customStyleBuilder: _revisionStyle,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _panelContent() => switch (_panel ?? _Panel.revisions) {
    _Panel.revisions => _revisionsPanel(),
    _Panel.comments => _commentsPanel(),
  };

  Widget _header(String title, List<Widget> actions) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
    child: Row(
      children: [
        Expanded(child: Text(title, style: Theme.of(context).textTheme.titleSmall)),
        ...actions,
      ],
    ),
  );

  Widget _revisionsPanel() {
    final all = revisionsOf(c.document.toDelta().toList());
    final authors = {for (final r in all) r.author}.toList()..sort();
    final filter = authors.contains(_authorFilter) ? _authorFilter : null;
    final items = filter == null ? all : all.where((r) => r.author == filter).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header('Revisões (${items.length})', [
          TextButton(onPressed: items.isEmpty ? null : () => _resolver(items, accept: true), child: const Text('Aceitar todas')),
          TextButton(onPressed: items.isEmpty ? null : () => _resolver(items, accept: false), child: const Text('Rejeitar todas')),
        ]),
        if (authors.length > 1)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 6,
              children: [
                ChoiceChip(label: const Text('Todos'), selected: filter == null, onSelected: (_) => setState(() => _authorFilter = null)),
                for (final a in authors)
                  ChoiceChip(
                    avatar: CircleAvatar(backgroundColor: authorColor(a), radius: 6),
                    label: Text(a),
                    selected: filter == a,
                    onSelected: (_) => setState(() => _authorFilter = a),
                  ),
              ],
            ),
          ),
        if (items.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Sem revisões. Ligue "Revisor" para marcar o que você mudar.'),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, i) {
              final r = items[i];
              final data = r.data;
              return ListTile(
                dense: true,
                onTap: () => _goTo(r.start, r.end),
                leading: Icon(r.insertion ? Icons.add_circle_outline : Icons.remove_circle_outline, color: authorColor(r.author)),
                title: Text(
                  r.text.trim().isEmpty ? '(quebra/espaço)' : r.text.trim(),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(decoration: r.insertion ? null : TextDecoration.lineThrough),
                ),
                subtitle: Text(
                  '${r.insertion ? 'Inseriu' : 'Excluiu'} · ${r.author}${data == null ? '' : ' · ${_shortDate(data)}'}',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(tooltip: 'Aceitar', onPressed: () => _resolver([r], accept: true), icon: const Icon(Icons.check)),
                    IconButton(tooltip: 'Rejeitar', onPressed: () => _resolver([r], accept: false), icon: const Icon(Icons.close)),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _commentsPanel() {
    final plan = c.document.toPlainText();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header('Comentários (${_comments.length})', [
          TextButton.icon(onPressed: _comment, icon: const Icon(Icons.add_comment_outlined), label: const Text('Novo')),
        ]),
        if (_comments.isEmpty)
          const Padding(padding: EdgeInsets.all(16), child: Text('Selecione um trecho e toque em "Novo".')),
        Expanded(
          child: ListView.builder(
            itemCount: _comments.length,
            itemBuilder: (context, i) {
              final x = _comments[i];
              final excerpts = _excerptsOf(x.id);
              final cited = excerpts.map((t) => plan.substring(t.$1, t.$2.clamp(t.$1, plan.length))).join(' … ').trim();
              return Card(
                margin: const EdgeInsets.fromLTRB(10, 4, 10, 4),
                child: InkWell(
                  onTap: excerpts.isEmpty ? null : () => _goTo(excerpts.first.$1, excerpts.last.$2),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              radius: 12,
                              backgroundColor: authorColor(x.author),
                              child: Text(x.initial, style: const TextStyle(fontSize: 10, color: Colors.white)),
                            ),
                            const SizedBox(width: 8),
                            Expanded(child: Text('${x.author} · ${_shortDate(x.data)}', style: Theme.of(context).textTheme.labelMedium)),
                          ],
                        ),
                        if (cited.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              '"$cited"',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontStyle: FontStyle.italic),
                            ),
                          ),
                        Padding(padding: const EdgeInsets.only(top: 6), child: Text(x.text)),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (excerpts.isNotEmpty)
                              TextButton(onPressed: () => _comment(replyTo: x.id), child: const Text('Responder')),
                            IconButton(tooltip: 'Editar', onPressed: () => _editComment(x), icon: const Icon(Icons.edit_outlined, size: 18)),
                            IconButton(
                              tooltip: 'Resolver (excluir)',
                              onPressed: () => _deleteComment(x),
                              icon: const Icon(Icons.done_all, size: 18),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

String _shortDate(DateTime d) {
  final l = d.toLocal();
  String z(int n) => n.toString().padLeft(2, '0');
  return '${z(l.day)}/${z(l.month)}/${l.year} ${z(l.hour)}:${z(l.minute)}';
}
