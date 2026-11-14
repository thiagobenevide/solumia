import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'code_api.dart';
import 'models.dart';
import 'highlight.dart';

/// Code browser (read only): the PC repository tree at a commit (default: the latest) with what that
/// commit brought highlighted — new/changed files in the tree and new lines in the file.
class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key, required this.api});

  final CodeApi api;

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  CodeTree? _tree;
  Object? _error;
  bool _loading = false;
  String _commit = '';
  final _openTabs = <String>{};
  String? _expanded;
  bool _onlyChanges = false;
  String _filter = '';

  /// What the search box looks for: file name, text in the code or notes (comments).
  _Mode _mode = _Mode.files;

  /// Line and term for the viewer to jump to and highlight when opening a search result.
  int? _line;
  String _highlight = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load([String commit = '']) async {
    setState(() => _loading = true);
    try {
      final tree = await widget.api.tree(commit);
      if (!mounted) return;
      setState(() {
        _tree = tree;
        _commit = commit;
        _error = null;
        // Opens the folders of what changed and the first new/changed file, if nothing was open.
        for (final c in tree.changes.keys) {
          final parts = c.split('/');
          for (var i = 1; i < parts.length; i++) {
            _openTabs.add(parts.take(i).join('/'));
          }
        }
        if (_expanded == null || !tree.files.contains(_expanded)) {
          _expanded = [
            for (final e in tree.changes.entries)
              if (e.value != 'D') e.key,
          ].firstOrNull;
        }
      });
    } catch (e) {
      // 404 here = VPS backend older than the browser (the /arvore and /arquivo routes do not exist there yet).
      final error = e is ApiErro && e.status == 404
          ? 'O backend da VPS está desatualizado e ainda não tem o navegador de código. '
                'Atualize a VPS (peça aqui no Código "atualizar a VPS" ou rode infra/scripts/atualizar_vps) e tente de novo.'
          : e;
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tree = _tree;
    if (tree == null) {
      return _error != null
          ? ErroComRetry(erro: _error!, tentar: _load)
          : const Center(child: CircularProgressIndicator());
    }
    return LayoutBuilder(
      builder: (context, c) {
        final largo = c.maxWidth >= 820;
        final items = _ItemList(
          api: widget.api,
          compact: !largo,
          mode: _mode,
          onMode: (m) => setState(() => _mode = m),
          onOpenLine: (a, l) => setState(() {
            _expanded = a;
            _line = l;
            _highlight = _mode == _Mode.notes && _filter.trim().isEmpty ? '' : _filter.trim();
          }),
          tree: tree,
          openTabs: _openTabs,
          expanded: _expanded,
          onlyChanges: _onlyChanges,
          filter: _filter,
          onToggleFolder: (p) => setState(() => _openTabs.contains(p) ? _openTabs.remove(p) : _openTabs.add(p)),
          onOpen: (a) => setState(() {
            _expanded = a;
            _line = null;
            _highlight = '';
          }),
          onFilter: (f) => setState(() => _filter = f),
          onOnlyChanges: (v) => setState(() => _onlyChanges = v),
        );
        final expanded = _expanded;
        final visor = expanded == null
            ? const Center(child: Text('Escolha um arquivo à esquerda.'))
            : _Visor(
                key: ValueKey('${tree.commit}:$expanded'),
                api: widget.api,
                path: expanded,
                commit: tree.commit,
                status: tree.changes[expanded],
                line: _line,
                highlight: _highlight,
                onBack: largo ? null : () => setState(() => _expanded = null),
              );
        // On the phone the open file takes the whole screen; the system "back" returns to the list.
        final soVisor = !largo && expanded != null;
        return PopScope(
          canPop: !soVisor,
          onPopInvokedWithResult: (exited, _) {
            if (!exited && soVisor) setState(() => _expanded = null);
          },
          child: Column(
            children: [
              if (!soVisor)
                _Header(
                  tree: tree,
                  commit: _commit,
                  loading: _loading,
                  compact: !largo,
                  onPick: _load,
                ),
              if (_error != null)
                MaterialBanner(
                  content: Text('$_error'),
                  leading: const Icon(Icons.error_outline),
                  actions: [TextButton(onPressed: () => _load(_commit), child: const Text('Tentar de novo'))],
                ),
              if (!soVisor) const Divider(height: 1),
              Expanded(
                child: largo
                    ? Row(
                        children: [
                          SizedBox(width: 340, child: items),
                          const VerticalDivider(width: 1),
                          Expanded(child: visor),
                        ],
                      )
                    : (expanded == null ? items : visor),
              ),
            ],
          ),
        );
      },
    );
  }
}

enum _Mode { files, text, notes }

/// Color and label of each git status.
(Color, String) _status(String status, ColorScheme scheme) => switch (status) {
  'A' => (Colors.green, 'novo'),
  'M' => (Colors.orange, 'alterado'),
  'D' => (scheme.error, 'removido'),
  'R' => (Colors.blue, 'renomeado'),
  _ => (scheme.outline, status),
};

String _data(DateTime? d) {
  if (d == null) return '';
  final l = d.toLocal();
  String twoDigits(int n) => n.toString().padLeft(2, '0');
  return '${twoDigits(l.day)}/${twoDigits(l.month)} ${twoDigits(l.hour)}:${twoDigits(l.minute)}';
}

/// Shown commit (list of the latest to pick from) and the summary of what it changed.
class _Header extends StatelessWidget {
  const _Header({
    required this.tree,
    required this.commit,
    required this.loading,
    required this.compact,
    required this.onPick,
  });

  final CodeTree tree;
  final String commit;
  final bool loading;

  /// Phone: a single line (title and author stacked, count in letters) to leave room for the code.
  final bool compact;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = [
      for (final c in tree.commits)
        if (c.hash == tree.commit) c,
    ].firstOrNull;
    final counts = <String, int>{};
    for (final s in tree.changes.values) {
      counts[s] = (counts[s] ?? 0) + 1;
    }
    final title = current == null
        ? tree.commit.substring(0, 7)
        : '${commit.isEmpty ? 'Última atualização' : current.short} · ${current.subject}';
    final refresh = IconButton(
      tooltip: 'Atualizar',
      onPressed: loading ? null : () => onPick(commit),
      icon: loading
          ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.refresh),
    );
    PopupMenuButton<String> menu(Widget child) => PopupMenuButton<String>(
      tooltip: 'Ver outra atualização',
      onSelected: (h) => onPick(h == tree.commits.firstOrNull?.hash ? '' : h),
      itemBuilder: (_) => [
        for (final (i, c) in tree.commits.indexed)
          PopupMenuItem(
            value: c.hash,
            child: Text(
              '${c.short}  ${_data(c.data)}  ${c.subject}${i == 0 ? '  (última)' : ''}',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: c.hash == tree.commit ? FontWeight.bold : null),
            ),
          ),
      ],
      child: child,
    );
    if (compact) {
      return Material(
        color: scheme.surfaceContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 0, 2),
          child: Row(
            children: [
              Expanded(
                child: menu(
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall,
                            ),
                            Text.rich(
                              TextSpan(
                                children: [
                                  if (current != null) TextSpan(text: '${current.author} · ${_data(current.data)}'),
                                  for (final s in ['A', 'M', 'R', 'D'])
                                    if (counts[s] != null)
                                      TextSpan(
                                        text: '  ● ${counts[s]} ${_status(s, scheme).$2}',
                                        style: TextStyle(color: _status(s, scheme).$1),
                                      ),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.arrow_drop_down),
                    ],
                  ),
                ),
              ),
              if (commit.isNotEmpty)
                IconButton(tooltip: 'Última', onPressed: () => onPick(''), icon: const Icon(Icons.update)),
              refresh,
            ],
          ),
        ),
      );
    }
    return Material(
      color: scheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Icon(Icons.history, size: 18, color: scheme.onSurfaceVariant),
            menu(
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(title, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                    ),
                    const Icon(Icons.arrow_drop_down),
                  ],
                ),
              ),
            ),
            if (current != null) Text('${current.author} · ${_data(current.data)}', style: theme.textTheme.bodySmall),
            for (final s in ['A', 'M', 'R', 'D'])
              if (counts[s] != null)
                Chip(
                  visualDensity: VisualDensity.compact,
                  avatar: Icon(Icons.circle, size: 10, color: _status(s, scheme).$1),
                  label: Text('${counts[s]} ${_status(s, scheme).$2}${counts[s]! > 1 ? 's' : ''}'),
                ),
            if (commit.isNotEmpty)
              TextButton.icon(
                onPressed: () => onPick(''),
                icon: const Icon(Icons.update),
                label: const Text('Última'),
              ),
            refresh,
          ],
        ),
      ),
    );
  }
}

/// Row of the list on the left: folder (with level) or file.
typedef _Item = ({String path, String name, int level, bool pasta});

/// File tree with search and the "only what changed" filter (which turn into a flat list of paths); in
/// text/notes modes the search goes to the repository and shows the matching lines.
class _ItemList extends StatelessWidget {
  const _ItemList({
    required this.api,
    required this.compact,
    required this.mode,
    required this.onMode,
    required this.onOpenLine,
    required this.tree,
    required this.openTabs,
    required this.expanded,
    required this.onlyChanges,
    required this.filter,
    required this.onToggleFolder,
    required this.onOpen,
    required this.onFilter,
    required this.onOnlyChanges,
  });

  final CodeApi api;
  final bool compact;
  final _Mode mode;
  final ValueChanged<_Mode> onMode;
  final void Function(String path, int line) onOpenLine;
  final CodeTree tree;
  final Set<String> openTabs;
  final String? expanded;
  final bool onlyChanges;
  final String filter;
  final ValueChanged<String> onToggleFolder;
  final ValueChanged<String> onOpen;
  final ValueChanged<String> onFilter;
  final ValueChanged<bool> onOnlyChanges;

  /// Flattened tree with only what is visible (folders before files, in alphabetical order).
  List<_Item> _items() {
    final search = filter.trim().toLowerCase();
    if (search.isNotEmpty || onlyChanges) {
      final fontSize = onlyChanges ? tree.changes.keys : tree.files;
      return [
        for (final c in fontSize.toList()..sort())
          if (c.toLowerCase().contains(search)) (path: c, name: c, level: 0, pasta: false),
      ];
    }
    final pastas = <String, Set<String>>{'': {}};
    final files = <String, List<String>>{};
    for (final c in tree.files) {
      final parts = c.split('/');
      for (var i = 0; i < parts.length - 1; i++) {
        final parent = parts.take(i).join('/');
        final pasta = parts.take(i + 1).join('/');
        (pastas[parent] ??= {}).add(pasta);
        pastas[pasta] ??= {};
      }
      (files[parts.take(parts.length - 1).join('/')] ??= []).add(c);
    }
    final itens = <_Item>[];
    void scrollDown(String pasta, int level) {
      for (final p in pastas[pasta]!.toList()..sort()) {
        itens.add((path: p, name: p.split('/').last, level: level, pasta: true));
        if (openTabs.contains(p)) scrollDown(p, level + 1);
      }
      for (final a in [...?files[pasta]]..sort()) {
        itens.add((path: a, name: a.split('/').last, level: level, pasta: false));
      }
    }

    scrollDown('', 0);
    return itens;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final itens = mode == _Mode.files ? _items() : const <_Item>[];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: SegmentedButton<_Mode>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(
                value: _Mode.files,
                icon: Icon(Icons.description_outlined, size: 18),
                label: Text('Arquivos'),
              ),
              ButtonSegment(value: _Mode.text, icon: Icon(Icons.text_fields, size: 18), label: Text('Palavras')),
              ButtonSegment(
                value: _Mode.notes,
                icon: Icon(Icons.comment_outlined, size: 18),
                label: Text('Observações'),
              ),
            ],
            selected: {mode},
            onSelectionChanged: (m) => onMode(m.first),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: TextFormField(
            initialValue: filter,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 18),
              hintText: switch (mode) {
                _Mode.files => 'Buscar arquivo pelo nome ou pasta',
                _Mode.text => 'Buscar palavra no código',
                _Mode.notes => 'Buscar nos comentários (vazio: TODO/FIXME)',
              },
              border: const OutlineInputBorder(),
            ),
            onChanged: onFilter,
          ),
        ),
        if (mode == _Mode.files)
          SwitchListTile(
            dense: true,
            title: Text('Só o que mudou (${tree.changes.length})'),
            value: onlyChanges,
            onChanged: onOnlyChanges,
          )
        else
          const SizedBox(height: 8),
        const Divider(height: 1),
        if (mode != _Mode.files)
          Expanded(
            child: _Results(
              api: api,
              commit: tree.commit,
              term: filter.trim(),
              notes: mode == _Mode.notes,
              expanded: expanded,
              compact: compact,
              onOpen: onOpenLine,
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              itemCount: itens.length,
              itemExtent: compact ? 40 : 30,
              itemBuilder: (context, i) {
                final item = itens[i];
                final status = tree.changes[item.path];
                final changed = item.pasta ? tree.folderChanged(item.path) : status != null;
                final color = status == null ? null : _status(status, scheme).$1;
                return InkWell(
                  onTap: () {
                    if (item.pasta) {
                      onToggleFolder(item.path);
                    } else if (status != 'D') {
                      onOpen(item.path);
                    }
                  },
                  child: Container(
                    color: item.path == expanded ? scheme.secondaryContainer : null,
                    padding: EdgeInsets.only(left: 8 + item.level * 14.0, right: 8),
                    child: Row(
                      children: [
                        if (item.pasta)
                          Icon(
                            openTabs.contains(item.path) ? Icons.folder_open : Icons.folder,
                            size: 16,
                            color: scheme.primary,
                          )
                        else
                          fileIcon(item.name, scheme.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            item.name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: compact ? 14 : 13,
                              color: color,
                              fontWeight: changed ? FontWeight.w600 : null,
                              decoration: status == 'D' ? TextDecoration.lineThrough : null,
                            ),
                          ),
                        ),
                        if (status != null)
                          Text(
                            status,
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color),
                          )
                        else if (item.pasta && changed)
                          const Icon(Icons.circle, size: 7, color: Colors.orange),
                      ],
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

/// Lines found in the repository, grouped by file; tapping opens the file at that line.
class _Results extends StatefulWidget {
  const _Results({
    required this.api,
    required this.commit,
    required this.term,
    required this.notes,
    required this.expanded,
    required this.compact,
    required this.onOpen,
  });

  final CodeApi api;
  final String commit;
  final String term;
  final bool notes;
  final String? expanded;
  final bool compact;
  final void Function(String path, int line) onOpen;

  @override
  State<_Results> createState() => _ResultsState();
}

class _ResultsState extends State<_Results> {
  Timer? _waiting;
  Map<String, dynamic>? _match;
  Object? _error;
  bool _loading = false;
  int _request = 0;

  /// Last search made: going back from the open file (phone) shows the result without asking the PC again.
  static (String, Map<String, dynamic>)? _last;

  String get _key => '${widget.commit}|${widget.notes}|${widget.term}';

  @override
  void initState() {
    super.initState();
    _runSearch();
  }

  @override
  void didUpdateWidget(_Results old) {
    super.didUpdateWidget(old);
    if (old.term != widget.term || old.notes != widget.notes || old.commit != widget.commit) {
      // Waits for typing to stop so it does not send a search to the PC on every letter.
      _waiting?.cancel();
      _waiting = Timer(const Duration(milliseconds: 450), _runSearch);
    }
  }

  @override
  void dispose() {
    _waiting?.cancel();
    super.dispose();
  }

  Future<void> _runSearch() async {
    final request = ++_request;
    if (widget.term.length < 2 && !(widget.notes && widget.term.isEmpty)) {
      setState(() {
        _match = null;
        _error = null;
        _loading = false;
      });
      return;
    }
    if (_last?.$1 == _key) {
      setState(() {
        _match = _last!.$2;
        _error = null;
      });
      return;
    }
    final key = _key;
    setState(() => _loading = true);
    try {
      final r = await widget.api.search(widget.term, widget.commit, notes: widget.notes);
      _last = (key, r);
      if (mounted && request == _request) {
        setState(() {
          _match = r;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && request == _request) setState(() => _error = e);
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  /// Text of the line with the term (or the TODO/FIXME markers) highlighted.
  TextSpan _marked(String text, TextStyle base, Color background) {
    final term = widget.term.toLowerCase();
    final pattern = term.isEmpty
        ? RegExp(r'\b(TODO|FIXME|XXX|HACK|NOTE|OBS)\b')
        : RegExp(RegExp.escape(term), caseSensitive: false);
    final parts = <TextSpan>[];
    var pos = 0;
    for (final m in pattern.allMatches(text)) {
      if (m.start > pos) parts.add(TextSpan(text: text.substring(pos, m.start)));
      parts.add(
        TextSpan(
          text: m.group(0),
          style: TextStyle(backgroundColor: background, fontWeight: FontWeight.bold),
        ),
      );
      pos = m.end;
    }
    if (pos < text.length) parts.add(TextSpan(text: text.substring(pos)));
    return TextSpan(children: parts, style: base);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final match = _match;
    final Widget body;
    if (_error != null) {
      body = ErroComRetry(erro: _error!, tentar: _runSearch);
    } else if (match == null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _loading ? 'Buscando…' : 'Digite ao menos 2 letras para buscar em todos os arquivos.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      );
    } else {
      final results = [for (final r in match['resultados'] as List) r as Map<String, dynamic>];
      final files = <String>{for (final r in results) r['caminho'] as String};
      // Flat list: file header followed by its lines.
      final itens = <Object>[];
      String? last;
      for (final r in results) {
        if (r['caminho'] != last) itens.add(last = r['caminho'] as String);
        itens.add(r);
      }
      const mono = TextStyle(fontFamily: 'monospace', fontSize: 12.5);
      final background = Colors.amber.withValues(alpha: 0.45);
      body = Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    results.isEmpty
                        ? 'Nada encontrado.'
                        : '${results.length}${match['cortado'] == true ? '+' : ''} linha${results.length > 1 ? 's' : ''} '
                              'em ${files.length} arquivo${files.length > 1 ? 's' : ''}',
                    style: theme.textTheme.labelMedium,
                  ),
                ),
                if (_loading) const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: itens.length,
              itemBuilder: (context, i) {
                final item = itens[i];
                if (item is String) {
                  final parts = item.split('/');
                  return Container(
                    color: scheme.surfaceContainerHigh,
                    padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                    child: Row(
                      children: [
                        fileIcon(parts.last, scheme.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: parts.last,
                                  style: const TextStyle(fontWeight: FontWeight.w600),
                                ),
                                if (parts.length > 1)
                                  TextSpan(
                                    text: '  ${parts.take(parts.length - 1).join('/')}',
                                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
                                  ),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  );
                }
                final r = item as Map<String, dynamic>;
                final path = r['caminho'] as String;
                final line = r['linha'] as int;
                return InkWell(
                  onTap: () => widget.onOpen(path, line),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: widget.compact ? 8 : 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 40,
                          child: Text(
                            '$line',
                            textAlign: TextAlign.right,
                            style: mono.copyWith(color: scheme.outline),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text.rich(
                            _marked(r['texto'] as String, mono, background),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      );
    }
    return body;
  }
}

/// Open file: line numbers, new lines of the commit in green, a button to jump between them,
/// search inside the file and adjustable font size (for reading on the phone).
class _Visor extends StatefulWidget {
  const _Visor({
    super.key,
    required this.api,
    required this.path,
    required this.commit,
    required this.status,
    this.line,
    this.highlight = '',
    this.onBack,
  });

  final CodeApi api;
  final String path;
  final String commit;
  final String? status;

  /// Line (1 = first) to open already scrolled to and the term to highlight (coming from the search).
  final int? line;
  final String highlight;
  final VoidCallback? onBack;

  @override
  State<_Visor> createState() => _VisorState();
}

class _VisorState extends State<_Visor> {
  /// Font size kept across opened files.
  static double _fontSize = 13;
  late final Future<CodeFile> _file = widget.api.file(widget.path, widget.commit);
  final _scroll = ScrollController();
  final _search = TextEditingController();
  final _focus = FocusNode();
  (CodeFile, Brightness)? _highlightKey;
  List<List<TextSpan>>? _highlighting;
  List<String> _lines = const [];
  bool _searching = false;

  /// Lines (index 0) with the search term in the file and which one is focused.
  List<int> _matches = const [];
  int _current = -1;

  /// Line already scrolled to (so it is not repeated on every rebuild).
  int? _scrolled;

  double get _height => (_fontSize * 1.3 + 2).roundToDouble();

  @override
  void initState() {
    super.initState();
    if (widget.highlight.isNotEmpty) {
      _searching = true;
      _search.text = widget.highlight;
    }
  }

  @override
  void didUpdateWidget(_Visor old) {
    super.didUpdateWidget(old);
    if (widget.highlight != old.highlight && widget.highlight.isNotEmpty) {
      _searching = true;
      _search.text = widget.highlight;
      _find();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _goTo(int line, {bool animate = true}) {
    if (!_scroll.hasClients) return;
    final target = ((line - 4) * _height).clamp(0.0, _scroll.position.maxScrollExtent);
    animate
        ? _scroll.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeOut)
        : _scroll.jumpTo(target);
  }

  /// Scrolls to the next block of new lines after the one at the top (back to the first at the end).
  void _nextChange(List<int> novas) {
    if (novas.isEmpty || !_scroll.hasClients) return;
    final top = (_scroll.offset / _height).floor() + 1;
    var target = novas.first;
    for (var i = 0; i < novas.length; i++) {
      final blockStart = i == 0 || novas[i - 1] != novas[i] - 1;
      if (blockStart && novas[i] > top + 4) {
        target = novas[i];
        break;
      }
    }
    _goTo(target + 1);
  }

  /// Recomputes the lines with the term; focuses the first one from the visible top.
  void _find() {
    final term = _search.text.toLowerCase();
    final matches = term.isEmpty
        ? const <int>[]
        : [
            for (final (i, l) in _lines.indexed)
              if (l.toLowerCase().contains(term)) i,
          ];
    final top = _scroll.hasClients ? (_scroll.offset / _height).floor() : 0;
    setState(() {
      _matches = matches;
      _current = matches.isEmpty ? -1 : matches.indexWhere((i) => i >= top).clamp(0, matches.length - 1);
    });
    if (_current >= 0) _goTo(matches[_current] + 1);
  }

  void _step(int delta) {
    if (_matches.isEmpty) return;
    setState(() => _current = (_current + delta) % _matches.length);
    _goTo(_matches[_current] + 1);
  }

  void _closeSearch() => setState(() {
    _searching = false;
    _search.clear();
    _matches = const [];
    _current = -1;
  });

  void _changeFontSize(double delta) => setState(() => _fontSize = (_fontSize + delta).clamp(9, 24));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return FutureBuilder<CodeFile>(
      future: _file,
      builder: (context, s) {
        final file = s.data;
        final novas = file == null ? const <int>[] : (file.novas.toList()..sort());
        final status = widget.status;
        final parts = widget.path.split('/');
        final pasta = parts.take(parts.length - 1).join('/');
        final header = Material(
          color: scheme.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              children: [
                if (widget.onBack != null)
                  IconButton(onPressed: widget.onBack, icon: const Icon(Icons.arrow_back), tooltip: 'Arquivos')
                else
                  const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          if (status != null) ...[
                            Icon(Icons.circle, size: 9, color: _status(status, scheme).$1),
                            const SizedBox(width: 5),
                          ],
                          Flexible(
                            child: Text(
                              parts.last,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(fontFamily: 'monospace'),
                            ),
                          ),
                          if (status != null)
                            Text(
                              '  ${_status(status, scheme).$2}',
                              style: theme.textTheme.labelSmall?.copyWith(color: _status(status, scheme).$1),
                            ),
                        ],
                      ),
                      if (pasta.isNotEmpty)
                        Text(
                          pasta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
                if (novas.isNotEmpty)
                  TextButton.icon(
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact, foregroundColor: Colors.green),
                    onPressed: () => _nextChange(novas),
                    icon: const Icon(Icons.keyboard_double_arrow_down, size: 18),
                    label: Text('${novas.length}'),
                  ),
                IconButton(
                  tooltip: 'Buscar no arquivo',
                  isSelected: _searching,
                  onPressed: () {
                    if (_searching) {
                      _closeSearch();
                    } else {
                      setState(() => _searching = true);
                      _focus.requestFocus();
                    }
                  },
                  icon: const Icon(Icons.search),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Mais',
                  onSelected: (o) => switch (o) {
                    'maior' => _changeFontSize(1),
                    'menor' => _changeFontSize(-1),
                    'inicio' => _goTo(1),
                    'fim' => _goTo(_lines.length + 4),
                    _ => Clipboard.setData(ClipboardData(text: widget.path)),
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'maior',
                      child: ListTile(leading: Icon(Icons.text_increase), title: Text('Letra maior')),
                    ),
                    const PopupMenuItem(
                      value: 'menor',
                      child: ListTile(leading: Icon(Icons.text_decrease), title: Text('Letra menor')),
                    ),
                    const PopupMenuItem(
                      value: 'inicio',
                      child: ListTile(leading: Icon(Icons.vertical_align_top), title: Text('Ir ao início')),
                    ),
                    const PopupMenuItem(
                      value: 'fim',
                      child: ListTile(leading: Icon(Icons.vertical_align_bottom), title: Text('Ir ao fim')),
                    ),
                    const PopupMenuItem(
                      value: 'copiar',
                      child: ListTile(leading: Icon(Icons.copy), title: Text('Copiar caminho')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
        final searchBar = Material(
          color: scheme.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 4, 6),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _search,
                    focusNode: _focus,
                    textInputAction: TextInputAction.search,
                    decoration: const InputDecoration(
                      isDense: true,
                      prefixIcon: Icon(Icons.search, size: 18),
                      hintText: 'Buscar neste arquivo',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => _find(),
                    onSubmitted: (_) => _step(1),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _search.text.isEmpty ? '' : (_matches.isEmpty ? '0' : '${_current + 1}/${_matches.length}'),
                  style: theme.textTheme.labelMedium,
                ),
                IconButton(
                  tooltip: 'Anterior',
                  onPressed: _matches.isEmpty ? null : () => _step(-1),
                  icon: const Icon(Icons.keyboard_arrow_up),
                ),
                IconButton(
                  tooltip: 'Próxima',
                  onPressed: _matches.isEmpty ? null : () => _step(1),
                  icon: const Icon(Icons.keyboard_arrow_down),
                ),
                IconButton(tooltip: 'Fechar busca', onPressed: _closeSearch, icon: const Icon(Icons.close)),
              ],
            ),
          ),
        );
        final Widget body;
        if (s.hasError) {
          body = Center(child: Text('${s.error}'));
        } else if (file == null) {
          body = const Center(child: CircularProgressIndicator());
        } else if (file.binary) {
          body = Center(
            child: Text('Arquivo binário (${(file.size / 1024).toStringAsFixed(1)} KB): sem visualização.'),
          );
        } else {
          body = _string(context, file);
        }
        return Column(
          children: [
            header,
            if (_searching) searchBar,
            const Divider(height: 1),
            Expanded(child: body),
          ],
        );
      },
    );
  }

  Widget _string(BuildContext context, CodeFile file) {
    final scheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    final estilo = TextStyle(fontFamily: 'monospace', fontSize: _fontSize, height: 1.3);
    if (_highlightKey?.$1 != file || _highlightKey?.$2 != brightness) {
      final lines = file.text.replaceAll('\t', '    ').split('\n');
      if (lines.length > 1 && lines.last.isEmpty) lines.removeLast();
      _lines = lines;
      _highlightKey = (file, brightness);
      // No font size in the highlighting: the spans inherit the one from Text.rich, and changing the size does not redo it.
      _highlighting = highlight(lines.join('\n'), widget.path, const TextStyle(fontFamily: 'monospace'), brightness);
      // First time with the text: applies the search coming from the list and scrolls to the requested line.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_search.text.isNotEmpty) _find();
      });
    }
    final target = widget.line;
    if (target != null && _scrolled != target) {
      _scrolled = target;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final i = _matches.indexOf(target - 1);
        if (i >= 0) setState(() => _current = i);
        _goTo(target, animate: false);
      });
    }
    final lines = _lines;
    final size = TextPainter(
      text: TextSpan(text: 'M', style: estilo),
      textDirection: TextDirection.ltr,
    )..layout();
    final larger = lines.fold<int>(0, (m, l) => l.length > m ? l.length : m);
    final numberWidth = '${lines.length}'.length * size.width + 16;
    final verde = Colors.green.withValues(alpha: 0.16);
    final match = Colors.amber.withValues(alpha: 0.22);
    final focused = Colors.amber.withValues(alpha: 0.5);
    final matches = _matches.toSet();
    final focus = _current >= 0 && _current < _matches.length ? _matches[_current] : -1;
    final highlighting = _highlighting;
    final height = _height;
    return Column(
      children: [
        if (file.truncated)
          MaterialBanner(
            content: Text('Arquivo grande: mostrando só os primeiros ${(file.text.length / 1024).round()} KB.'),
            actions: const [SizedBox.shrink()],
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) {
              final width = (numberWidth + 12 + larger * size.width + 24).clamp(c.maxWidth, double.infinity);
              return Scrollbar(
                controller: _scroll,
                interactive: true,
                thickness: 8,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: width,
                    child: SelectionArea(
                      child: ListView.builder(
                        controller: _scroll,
                        itemCount: lines.length,
                        itemExtent: height,
                        itemBuilder: (context, i) {
                          final nova = file.novas.contains(i + 1);
                          final background = i == focus ? focused : (matches.contains(i) ? match : (nova ? verde : null));
                          return Container(
                            decoration: background == null
                                ? null
                                : BoxDecoration(
                                    color: background,
                                    border: nova ? const Border(left: BorderSide(color: Colors.green, width: 3)) : null,
                                  ),
                            child: Row(
                              children: [
                                SelectionContainer.disabled(
                                  child: SizedBox(
                                    width: numberWidth,
                                    child: Text(
                                      '${i + 1}',
                                      textAlign: TextAlign.right,
                                      style: estilo.copyWith(color: nova ? Colors.green : scheme.outline),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                highlighting != null && i < highlighting.length
                                    ? Text.rich(TextSpan(children: highlighting[i]), style: estilo, softWrap: false)
                                    : Text(lines[i], style: estilo, softWrap: false),
                              ],
                            ),
                          );
                        },
                      ),
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
