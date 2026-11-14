import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../notes_api.dart';
import '../open_note.dart';
import '../models.dart';
import 'relations_panel.dart';

/// Editor of the open note: title, type, the type's fields (form), tags and text with `[[link]]`
/// autocomplete. Saves on its own 1.5 s after the last change (and with Ctrl+S).
/// [withTabs]: tablet/phone, with the relations in a second tab.
class NoteEditor extends StatefulWidget {
  const NoteEditor({super.key, required this.openNote, this.withTabs = false});

  final OpenNote openNote;
  final bool withTabs;

  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> {
  final _title = TextEditingController();
  final _body = ControladorMarkdown();
  final _tags = TextEditingController();
  Map<String, dynamic> _props = {};
  String _type = 'nota';
  String? _id;
  bool _dirty = false;
  Timer? _autoSave, _debounce;
  List<String> _suggestions = [];
  List<NoteType> _types = [];

  OpenNote get _openNote => widget.openNote;
  NotesApi get _api => _openNote.api;

  @override
  void initState() {
    super.initState();
    _openNote.addListener(_reload);
    _openNote.pending = _savePending;
    _body.addListener(_searchLink);
    _api.types().then((t) => mounted ? setState(() => _types = t) : null, onError: (_) {});
    _reload();
  }

  @override
  void dispose() {
    _openNote.removeListener(_reload);
    if (_openNote.pending == _savePending) _openNote.pending = null;
    _savePending();
    _autoSave?.cancel();
    _debounce?.cancel();
    _title.dispose();
    _body.dispose();
    _tags.dispose();
    super.dispose();
  }

  /// Only resets the fields when the note changes: saving must not move the cursor of whoever is typing.
  void _reload() {
    final n = _openNote.note;
    if (n?.id == _id) return setState(() {});
    _id = n?.id;
    _dirty = false;
    _suggestions = [];
    if (n != null) {
      _title.text = n.title;
      _body.text = n.body;
      _tags.text = n.tags.join(', ');
      _props = Map.of(n.properties);
      _type = n.type;
    }
    setState(() {});
  }

  void _changed() {
    _dirty = true;
    _autoSave?.cancel();
    _autoSave = Timer(const Duration(milliseconds: 1500), _savePending);
    setState(() {});
  }

  Future<void> _savePending() async {
    _autoSave?.cancel();
    if (!_dirty || _openNote.note == null || _title.text.trim().isEmpty) return;
    _dirty = false;
    await _openNote.save({
      'titulo': _title.text.trim(),
      'tipo': _type,
      'tags': [for (final t in _tags.text.split(',')) if (t.trim().isNotEmpty) t.trim()],
      'propriedades': _props,
      'corpo': _body.text,
    });
  }

  // ---------- [[ autocomplete ----------

  /// Position of the open `[[` before the cursor, or -1.
  int _linkStart() {
    final pos = _body.selection.baseOffset;
    if (pos < 2) return -1;
    final before = _body.text.substring(0, pos);
    final i = before.lastIndexOf('[[');
    if (i < 0) return -1;
    final inside = before.substring(i + 2);
    return inside.contains(']') || inside.contains('\n') ? -1 : i;
  }

  void _searchLink() {
    final i = _linkStart();
    _debounce?.cancel();
    if (i < 0) {
      if (_suggestions.isNotEmpty) setState(() => _suggestions = []);
      return;
    }
    final q = _body.text.substring(i + 2, _body.selection.baseOffset);
    _debounce = Timer(const Duration(milliseconds: 200), () async {
      final s = await _api.suggestions(q).catchError((_) => <String>[]);
      if (mounted) setState(() => _suggestions = [...s, if (q.trim().isNotEmpty && !s.contains(q.trim())) q.trim()]);
    });
  }

  void _completeLink(String title) {
    final i = _linkStart();
    if (i < 0) return;
    final pos = _body.selection.baseOffset;
    final after = _body.text.substring(pos).startsWith(']]') ? pos + 2 : pos;
    _body.value = TextEditingValue(
      text: _body.text.replaceRange(i, after, '[[$title]]'),
      selection: TextSelection.collapsed(offset: i + title.length + 4),
    );
    setState(() => _suggestions = []);
  }

  void _insert(String text) {
    final sel = _body.selection.isValid ? _body.selection : TextSelection.collapsed(offset: _body.text.length);
    _body.value = TextEditingValue(
      text: _body.text.replaceRange(sel.start, sel.end, text),
      selection: TextSelection.collapsed(offset: sel.start + text.length),
    );
    _changed();
  }

  // ---------- typed relations ----------

  Future<void> _newRelation() async {
    final type = _types.where((t) => t.id == _type).firstOrNull;
    final options = {...?type?.relations, 'relacionada'}.toList();
    final rel = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Tipo de relação'),
        children: [
          for (final o in options)
            SimpleDialogOption(onPressed: () => Navigator.pop(c, o), child: Text(o.replaceAll('_', ' '))),
        ],
      ),
    );
    if (rel == null || !mounted) return;
    final target = await pickNote(context, _api);
    if (target == null) return;
    final existing = _props[rel];
    _props[rel] = [...(existing is List ? existing : [?existing]), '[[$target]]'];
    _changed();
    await _savePending();
  }

  @override
  Widget build(BuildContext context) {
    final n = _openNote.note;
    if (n == null) {
      return Center(
        child: _openNote.loading
            ? const CircularProgressIndicator()
            : Text(_openNote.error ?? 'Escolha uma nota ou crie uma nova', textAlign: TextAlign.center),
      );
    }
    final editor = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _savePending,
      },
      child: _editor(context),
    );
    if (!widget.withTabs) return editor;
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          TabBar(
            tabs: [
              const Tab(text: 'Escrever'),
              Tab(text: 'Relações (${n.outgoing.length + n.incoming.length})'),
            ],
          ),
          Expanded(
            child: TabBarView(children: [editor, RelationsPanel(openNote: _openNote)]),
          ),
        ],
      ),
    );
  }

  Widget _editor(BuildContext context) {
    final theme = Theme.of(context);
    final type = _types.where((t) => t.id == _type).firstOrNull;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Row(
          children: [
            PopupMenuButton<String>(
              tooltip: 'Tipo da nota',
              icon: Icon(iconForType(_type)),
              initialValue: _type,
              onSelected: (t) {
                _type = t;
                _changed();
              },
              itemBuilder: (_) => [
                for (final t in _types)
                  PopupMenuItem(value: t.id, child: ListTile(leading: Icon(iconForType(t.id)), title: Text(t.name))),
              ],
            ),
            Expanded(
              child: TextField(
                controller: _title,
                style: theme.textTheme.headlineSmall,
                decoration: const InputDecoration(border: InputBorder.none, hintText: 'Título'),
                onChanged: (_) => _changed(),
              ),
            ),
            _status(theme),
            PopupMenuButton<String>(
              onSelected: (_) => _excluir(),
              itemBuilder: (_) => const [PopupMenuItem(value: 'excluir', child: Text('Excluir nota'))],
            ),
          ],
        ),
        if (type != null && type.fields.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [for (final c in type.fields) SizedBox(width: 200, child: _field(c))],
            ),
          ),
        TextField(
          controller: _tags,
          decoration: const InputDecoration(prefixIcon: Icon(Icons.sell_outlined), hintText: 'tags, separadas por vírgula'),
          onChanged: (_) => _changed(),
        ),
        const SizedBox(height: 8),
        if (_suggestions.isNotEmpty)
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final s in _suggestions)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(avatar: const Icon(Icons.link, size: 16), label: Text(s), onPressed: () => _completeLink(s)),
                  ),
              ],
            ),
          ),
        CampoMarkdown(
          controle: _body,
          aoMudar: _changed,
          dica: 'Escreva… [[ cria um link',
          extras: [
            _button(Icons.link, 'Link', () => _insert('[[')),
            _button(Icons.hub_outlined, 'Relação', _newRelation),
          ],
        ),
      ],
    );
  }

  Widget _status(ThemeData theme) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: _openNote.loading
        ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
        : Tooltip(
            message: _openNote.error ?? (_dirty ? 'Salvando…' : 'Salvo'),
            child: Icon(
              _openNote.error != null ? Icons.error_outline : (_dirty ? Icons.edit_outlined : Icons.cloud_done_outlined),
              size: 18,
              color: _openNote.error != null ? theme.colorScheme.error : theme.colorScheme.outline,
            ),
          ),
  );

  Widget _button(IconData icon, String text, VoidCallback action) =>
      TextButton.icon(onPressed: action, icon: Icon(icon, size: 18), label: Text(text));

  Widget _field(NoteField c) {
    final value = _props[c.name];
    final fieldKey = ValueKey('$_id-${c.name}');
    void setValue(Object? v) {
      if (v == null || v == '') {
        _props.remove(c.name);
      } else {
        _props[c.name] = v;
      }
      _changed();
    }

    final deco = InputDecoration(labelText: c.label, isDense: true, border: const OutlineInputBorder());
    switch (c.type) {
      case 'opcoes':
        return DropdownButtonFormField<String>(
          key: fieldKey,
          initialValue: c.options.contains('$value') ? '$value' : null,
          decoration: deco,
          items: [for (final o in c.options) DropdownMenuItem(value: o, child: Text(o))],
          onChanged: setValue,
        );
      case 'data':
        final date = DateTime.tryParse('${value ?? ''}');
        return InputDecorator(
          decoration: deco,
          child: InkWell(
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: date ?? DateTime.now(),
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
              );
              if (d != null) setValue(d.toIso8601String().substring(0, 10));
            },
            child: Text(date == null ? 'definir' : shortDate(date)),
          ),
        );
      case 'link':
        final target = linkRe.firstMatch('${value ?? ''}')?.group(1);
        return InputDecorator(
          decoration: deco,
          child: InkWell(
            onTap: () async {
              final t = await pickNote(context, _api);
              if (t != null) setValue('[[$t]]');
            },
            onLongPress: target == null ? null : () => _openNote.openOrCreate(target),
            child: Text(target ?? 'escolher nota'),
          ),
        );
      default:
        return TextFormField(
          key: fieldKey,
          initialValue: value == null ? '' : '$value',
          decoration: deco,
          keyboardType: c.type == 'numero' ? TextInputType.number : null,
          onChanged: (v) => setValue(c.type == 'numero' ? num.tryParse(v.replaceAll(',', '.')) : v),
        );
    }
  }

  Future<void> _excluir() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Excluir "${_title.text}"?'),
        content: const Text('O arquivo Markdown é apagado. Links para ela viram links quebrados.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Excluir')),
        ],
      ),
    );
    if (ok != true) return;
    _dirty = false;
    await _openNote.delete();
  }
}

/// Dialog to search a note by title. Returns the chosen title (or the typed one, to create it).
Future<String?> pickNote(BuildContext context, NotesApi api) => showDialog<String>(
  context: context,
  builder: (_) => _NotePicker(api),
);

class _NotePicker extends StatefulWidget {
  const _NotePicker(this.api);

  final NotesApi api;

  @override
  State<_NotePicker> createState() => _NotePickerState();
}

class _NotePickerState extends State<_NotePicker> {
  String _q = '';
  late Future<List<String>> _found = widget.api.suggestions('');

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: TextField(
      autofocus: true,
      decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Buscar nota'),
      onChanged: (q) => setState(() {
        _q = q.trim();
        _found = widget.api.suggestions(_q);
      }),
      onSubmitted: (q) => Navigator.pop(context, q.trim().isEmpty ? null : q.trim()),
    ),
    content: SizedBox(
      width: 360,
      height: 320,
      child: FutureBuilder(
        future: _found,
        builder: (context, snap) {
          final items = snap.data ?? const <String>[];
          return ListView(
            children: [
              for (final t in items) ListTile(title: Text(t), onTap: () => Navigator.pop(context, t)),
              if (_q.isNotEmpty && !items.contains(_q))
                ListTile(
                  leading: const Icon(Icons.add),
                  title: Text('Nova: $_q'),
                  onTap: () => Navigator.pop(context, _q),
                ),
            ],
          );
        },
      ),
    ),
  );
}
