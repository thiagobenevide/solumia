import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../notes_api.dart';
import '../open_note.dart';
import '../models.dart';
import 'note_editor.dart';
import 'analysis_panel.dart';
import 'relations_panel.dart';

/// Screen of the Notes module.
/// - PC (≥ 1100): list | editor | relations.
/// - Tablet (≥ 700): list | editor with Escrever/Relações tabs.
/// - Phone: list; the note (and the analysis) open on their own page.
class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key, required this.api});

  final NotesApi api;

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  late final _openNote = OpenNote(widget.api);
  bool _analysis = false;
  bool _focus = false;

  @override
  void initState() {
    super.initState();
    _openNote.addListener(_updateTitle);
  }

  /// The app tab shows the title of the open note.
  void _updateTitle() {
    if (mounted) TituloAba.definir(context, _openNote.note?.title);
  }

  @override
  void dispose() {
    _openNote.removeListener(_updateTitle);
    _openNote.dispose();
    super.dispose();
  }

  Future<void> _open(String id, bool compact) async {
    setState(() => _analysis = false);
    final opening = _openNote.open(id);
    if (compact) await _notePage();
    return opening;
  }

  Future<void> _newNote(bool compact) async {
    final data = await _newNoteDialog(context, widget.api);
    if (data == null) return;
    setState(() => _analysis = false);
    final creating = _openNote.create(data);
    if (compact) await _notePage();
    return creating;
  }

  /// Phone: the note on its own page, with a thin bar (the title is already in the page).
  Future<void> _notePage() => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(toolbarHeight: 44, scrolledUnderElevation: 0),
        body: NoteEditor(openNote: _openNote, withTabs: true),
      ),
    ),
  );

  void _showAnalysis(bool compact) {
    if (!compact) return setState(() => _analysis = !_analysis);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (c) => Scaffold(
          appBar: AppBar(title: const Text('Análise das notas')),
          body: AnalysisPanel(
            api: widget.api,
            onOpen: (id) {
              Navigator.pop(c);
              _open(id, true);
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final compact = c.maxWidth < 700;
      final items = _NoteList(
        openNote: _openNote,
        analysis: _analysis,
        onOpen: (id) => _open(id, compact),
        onCreate: () => _newNote(compact),
        onAnalyze: () => _showAnalysis(compact),
      );
      if (compact) return items;
      final focus = _focus && !_analysis;
      final center = _analysis
          ? AnalysisPanel(key: ValueKey(_openNote.version), api: widget.api, onOpen: (id) => _open(id, false))
          : NoteEditor(
              openNote: _openNote,
              withTabs: c.maxWidth < 1100 && !focus,
              focused: focus,
              onFocus: () => setState(() => _focus = !_focus),
            );
      final listWidth = c.maxWidth < 1100 ? 300.0 : 340.0;
      final relations = c.maxWidth >= 1100 && !_analysis && !focus;
      return Row(
        children: [
          _SidePanel(width: focus ? 0 : listWidth, child: items),
          if (!focus) const VerticalDivider(width: 1),
          Expanded(child: center),
          if (relations) const VerticalDivider(width: 1),
          _SidePanel(width: relations ? 320 : 0, child: RelationsPanel(openNote: _openNote)),
        ],
      );
    },
  );
}

/// Side column that slides closed (focus mode) instead of disappearing at once.
class _SidePanel extends StatelessWidget {
  const _SidePanel({required this.width, required this.child});

  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 260),
    curve: Curves.easeOutCubic,
    width: width,
    child: ClipRect(
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: 0,
        maxWidth: width == 0 ? 340 : width,
        child: width == 0 ? const SizedBox() : child,
      ),
    ),
  );
}

class _NoteList extends StatefulWidget {
  const _NoteList({
    required this.openNote,
    required this.analysis,
    required this.onOpen,
    required this.onCreate,
    required this.onAnalyze,
  });

  final OpenNote openNote;
  final bool analysis;
  final void Function(String id) onOpen;
  final VoidCallback onCreate, onAnalyze;

  @override
  State<_NoteList> createState() => _NoteListState();
}

class _NoteListState extends State<_NoteList> {
  String _q = '';
  String? _type;
  bool _byType = false;
  Timer? _debounce;
  int _version = -1;
  late Future<List<NoteSummary>> _notes;
  List<NoteType> _types = [];

  NotesApi get _api => widget.openNote.api;

  @override
  void initState() {
    super.initState();
    widget.openNote.addListener(_maybeReload);
    _api.types().then((t) => mounted ? setState(() => _types = t) : null, onError: (_) {});
    _version = widget.openNote.version;
    _notes = _api.list(q: _q, type: _type);
  }

  @override
  void dispose() {
    widget.openNote.removeListener(_maybeReload);
    _debounce?.cancel();
    super.dispose();
  }

  /// Searches 300 ms after the last key, not on every key.
  void _search(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _q = q.trim();
      _maybeReload(force: true);
    });
  }

  void _maybeReload({bool force = false}) {
    if (!force && _version == widget.openNote.version) return setState(() {});
    _version = widget.openNote.version;
    setState(() {
      _notes = _api.list(q: _q, type: _type);
    });
  }

  List<Object> _recent(List<NoteSummary> notes) => _recentOrder(notes, _q.isNotEmpty);

  /// Groups by type, in chip order; header = String, note = NoteSummary.
  List<Object> _grouped(List<NoteSummary> notes, Map<String, String> names) {
    final order = [for (final t in _types) t.id];
    final groups = <String, List<NoteSummary>>{};
    for (final n in notes) {
      // vault types the app does not know (roteiro, moc...) go under Nota
      (groups[names.containsKey(n.type) ? n.type : 'nota'] ??= []).add(n);
    }
    final keys = groups.keys.toList()..sort((a, b) => (order.indexOf(a) % 999).compareTo(order.indexOf(b) % 999));
    final rows = <Object>[];
    for (final k in keys) {
      if (_type == null) rows.add(k);
      rows.addAll(groups[k]!);
    }
    _groupSizes = {for (final k in keys) k: groups[k]!.length};
    return rows;
  }

  Map<String, int> _groupSizes = {};

  Widget _groupHeader(BuildContext context, String type, Map<String, String> names) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 14, 16, 4),
    child: Row(
      spacing: 8,
      children: [
        Icon(iconForType(type), size: 16, color: Theme.of(context).colorScheme.primary),
        Text(
          '${names[type] ?? type} (${_groupSizes[type] ?? 0})',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final selectedId = widget.openNote.note?.id;
    return Column(
      children: [
        FiltrosRecolhiveis(
          chave: 'notas.lista',
          resumo: [?_types.where((t) => t.id == _type).firstOrNull?.name, if (_q.isNotEmpty) '"$_q"'].join(' · '),
          children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            spacing: 4,
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search_rounded),
                    hintText: 'Buscar no título e no texto',
                    isDense: true,
                  ),
                  onChanged: _search,
                ),
              ),
              IconButton(
                tooltip: _byType ? 'Ordenar por recentes' : 'Agrupar por tipo',
                icon: Icon(_byType ? Icons.category_rounded : Icons.schedule_rounded),
                onPressed: () => setState(() => _byType = !_byType),
              ),
              IconButton(
                tooltip: 'Análise',
                isSelected: widget.analysis,
                icon: const Icon(Icons.insights_outlined),
                onPressed: widget.onAnalyze,
              ),
              IconButton.filledTonal(tooltip: 'Nova nota', icon: const Icon(Icons.add), onPressed: widget.onCreate),
            ],
          ),
        ),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final t in [null, ..._types])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(t?.name ?? 'Todas'),
                    selected: _type == t?.id,
                    onSelected: (_) {
                      _type = t?.id;
                      _maybeReload(force: true);
                    },
                  ),
                ),
            ],
          ),
        ),
          ],
        ),
        ListenableBuilder(
          listenable: Listenable.merge([_api.offline, _api.pendingCount, _api.warnings]),
          builder: (context, _) {
            final warnings = _api.warnings.value;
            if (!_api.offline.value && _api.pendingCount.value == 0 && warnings.isEmpty) return const SizedBox();
            return MaterialBanner(
              leading: Icon(_api.offline.value ? Icons.cloud_off : Icons.cloud_sync_outlined),
              content: Text(
                [
                  if (_api.offline.value) 'Sem conexão: lendo e salvando as notas do aparelho.',
                  if (_api.pendingCount.value > 0) '${_api.pendingCount.value} alteração(ões) esperando para subir.',
                  ...warnings,
                ].join('\n'),
              ),
              actions: [
                if (warnings.isNotEmpty) TextButton(onPressed: () => _api.warnings.value = [], child: const Text('Ok')),
                TextButton(
                  onPressed: () {
                    final messenger = ScaffoldMessenger.of(context);
                    _api.sync().then(
                      (_) => _maybeReload(force: true),
                      onError: (Object e) => messenger.showSnackBar(SnackBar(content: Text('$e'))),
                    );
                  },
                  child: const Text('Sincronizar'),
                ),
              ],
            );
          },
        ),
        Expanded(
          child: FutureBuilder(
            future: _notes,
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(
                  child: Padding(padding: const EdgeInsets.all(16), child: Text('${snap.error}')),
                );
              }
              final notes = snap.data;
              if (notes == null) return const Center(child: CircularProgressIndicator());
              if (notes.isEmpty) return const Center(child: Text('Nenhuma nota'));
              final names = {for (final t in _types) t.id: t.name};
              final rows = _byType && _q.isEmpty ? _grouped(notes, names) : _recent(notes);
              return RefreshIndicator(
                onRefresh: () async => _maybeReload(force: true),
                child: ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, i) {
                    final n = rows[i];
                    if (n is String) return _groupHeader(context, n, names);
                    return _NoteRow(
                      note: n as NoteSummary,
                      typeName: names[n.type] ?? n.type,
                      query: _q,
                      selected: n.id == selectedId,
                      onTap: () => widget.onOpen(n.id),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Most recently updated first (with a search, the server's relevance order is kept).
List<Object> _recentOrder(List<NoteSummary> notes, bool searching) {
  if (searching) return [...notes];
  final sorted = [...notes]..sort((a, b) => (b.updated ?? DateTime(0)).compareTo(a.updated ?? DateTime(0)));
  return sorted;
}

/// One note in the list: type icon, title (the searched part highlighted), type, date and status.
class _NoteRow extends StatelessWidget {
  const _NoteRow({
    required this.note,
    required this.typeName,
    required this.query,
    required this.selected,
    required this.onTap,
  });

  final NoteSummary note;
  final String typeName;
  final String query;
  final bool selected;
  final VoidCallback onTap;

  List<TextSpan> _highlight(String title, TextStyle? strong) {
    final i = query.isEmpty ? -1 : title.toLowerCase().indexOf(query.toLowerCase());
    if (i < 0) return [TextSpan(text: title)];
    return [
      TextSpan(text: title.substring(0, i)),
      TextSpan(text: title.substring(i, i + query.length), style: strong),
      TextSpan(text: title.substring(i + query.length)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final n = note;
    final overdue = n.due != null && n.due!.isBefore(DateTime.now()) && n.status != null;
    final details = [
      typeName,
      if (n.updated != null) shortDate(n.updated),
      ?n.status,
      if (n.due != null) 'prazo ${shortDate(n.due)}',
      if (n.incoming > 0) '${n.incoming} ←',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected ? colors.primary.withValues(alpha: 0.14) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: colors.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(iconForType(n.type), size: 18, color: colors.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: _highlight(n.title, TextStyle(color: colors.primary, fontWeight: FontWeight.w800)),
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        details,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(color: overdue ? colors.error : colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks for the type and the title; returns the creation data (with the type's text template).
Future<Map<String, dynamic>?> _newNoteDialog(BuildContext context, NotesApi api) async {
  final types = await api.types().catchError((_) => <NoteType>[]);
  if (!context.mounted) return null;
  final title = TextEditingController();
  var type = types.isEmpty ? null : types.first;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: const Text('Nova nota'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final t in types)
                  ChoiceChip(
                    avatar: Icon(iconForType(t.id), size: 16),
                    label: Text(t.name),
                    selected: type == t,
                    onSelected: (_) => set(() => type = t),
                  ),
              ],
            ),
            TextField(
              controller: title,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Título'),
              onSubmitted: (_) => Navigator.pop(c, true),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Criar')),
        ],
      ),
    ),
  );
  final t = title.text.trim();
  title.dispose();
  if (ok != true || t.isEmpty) return null;
  return {'titulo': t, 'tipo': type?.id ?? 'nota', 'corpo': type?.template ?? ''};
}
