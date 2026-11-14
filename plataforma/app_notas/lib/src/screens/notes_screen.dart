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

  Future<void> _notePage() => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Nota')),
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
      final center = _analysis
          ? AnalysisPanel(key: ValueKey(_openNote.version), api: widget.api, onOpen: (id) => _open(id, false))
          : NoteEditor(openNote: _openNote, withTabs: c.maxWidth < 1100);
      return Row(
        children: [
          SizedBox(width: c.maxWidth < 1100 ? 280 : 320, child: items),
          const VerticalDivider(width: 1),
          Expanded(child: LarguraMaxima(largura: 1100, child: center)),
          if (c.maxWidth >= 1100 && !_analysis) ...[
            const VerticalDivider(width: 1),
            SizedBox(width: 340, child: RelationsPanel(openNote: _openNote)),
          ],
        ],
      );
    },
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
    super.dispose();
  }

  void _maybeReload({bool force = false}) {
    if (!force && _version == widget.openNote.version) return setState(() {});
    _version = widget.openNote.version;
    setState(() {
      _notes = _api.list(q: _q, type: _type);
    });
  }

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
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Buscar', isDense: true),
                  onChanged: (q) {
                    _q = q;
                    _maybeReload(force: true);
                  },
                ),
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
              // groups by type, in chip order (Tarefa, Meta...); header = String, note = NoteSummary
              final order = [for (final t in _types) t.id];
              final names = {for (final t in _types) t.id: t.name};
              final groups = <String, List<NoteSummary>>{};
              for (final n in notes) {
                // vault types the app does not know (roteiro, moc...) go under Nota
                (groups[names.containsKey(n.type) ? n.type : 'nota'] ??= []).add(n);
              }
              final groupKeys = groups.keys.toList()
                ..sort((a, b) => (order.indexOf(a) % 999).compareTo(order.indexOf(b) % 999));
              final rows = <Object>[
                for (final k in groupKeys) ...[
                  if (_type == null) k,
                  ...groups[k]!,
                ],
              ];
              return RefreshIndicator(
                onRefresh: () async => _maybeReload(force: true),
                child: ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, i) {
                    final n = rows[i];
                    if (n is String) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Row(
                          spacing: 8,
                          children: [
                            Icon(iconForType(n), size: 16, color: Theme.of(context).colorScheme.primary),
                            Text(
                              '${names[n] ?? n} (${groups[n]!.length})',
                              style: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(color: Theme.of(context).colorScheme.primary),
                            ),
                          ],
                        ),
                      );
                    }
                    n as NoteSummary;
                    final isOverdue = n.due != null && n.due!.isBefore(DateTime.now()) && n.status != null;
                    return ListTile(
                      selected: n.id == selectedId,
                      leading: Icon(iconForType(n.type)),
                      title: Text(n.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        [n.status, if (n.due != null) shortDate(n.due), if (n.incoming > 0) '${n.incoming} ←']
                            .nonNulls
                            .join(' · '),
                        style: isOverdue ? TextStyle(color: Theme.of(context).colorScheme.error) : null,
                      ),
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
