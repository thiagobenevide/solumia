import 'package:agent_core/agent_core.dart';
import 'package:agent_notas/agent_notas.dart';
import 'package:flutter/material.dart';

import '../studies_api.dart';
import '../models.dart';

/// Opens note [id] in the notes editor, on a page over the module.
Future<void> openNote(BuildContext context, NotesApi api, String id) {
  final isOpen = OpenNote(api)..open(id);
  return abrirTela(context, (_) => Scaffold(
        appBar: AppBar(title: const Text('Nota')),
        body: NoteEditor(openNote: isOpen),
      ));
}

/// Books and articles by area and status; each one has its synthesis note (Markdown in the vault),
/// which links to the area note and goes into the knowledge graph.
class ReadingsScreen extends StatefulWidget {
  const ReadingsScreen({super.key, required this.api, required this.options});

  final StudiesApi api;
  final StudyOptions options;

  @override
  State<ReadingsScreen> createState() => _ReadingsScreenState();
}

class _ReadingsScreenState extends State<ReadingsScreen> {
  StudiesApi get api => widget.api;
  List<Reading>? _readings;
  String? _area;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _retry(Future<void> Function() action) async {
    try {
      await action();
    } on ApiErro catch (e) {
      if (!mounted) return;
      if (_readings == null) {
        setState(() => _error = '$e');
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _load() => _retry(() async {
    final l = await api.readings();
    if (mounted) {
      setState(() {
        _readings = l;
        _error = null;
      });
    }
  });

  Future<void> _form([Reading? current]) async {
    final data = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _ReadingForm(options: widget.options, current: current, initialArea: _area),
    );
    if (data == null) return;
    await _retry(() async {
      current == null ? await api.createReading(data) : await api.editReading(current.id, data);
      await _load();
    });
  }

  Future<void> _synthesis(Reading l) => _retry(() async {
    var id = l.noteId;
    if (id == null) {
      final note = await api.notes.create({
        'titulo': l.title,
        'tags': ['estudos', l.area.toLowerCase()],
        'propriedades': {'autor': l.author, 'tipo_leitura': l.type},
        'corpo':
            '## Ideias principais\n\n## Citações\n\n## Como aplico\n\n## Ligações\n- Área: [[${l.area}]]\n',
      });
      id = note.id;
      await api.editReading(l.id, {'nota_id': id});
      await _load();
    }
    if (mounted) await openNote(context, api.notes, id);
  });

  Future<void> _progress(Reading l) async {
    final c = TextEditingController(text: '${l.currentPage}');
    final page = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.title),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: 'Página atual', suffixText: l.pages == null ? null : 'de ${l.pages}'),
          onSubmitted: (v) => Navigator.pop(context, int.tryParse(v)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, int.tryParse(c.text)), child: const Text('Salvar')),
        ],
      ),
    );
    if (page == null) return;
    final end = l.pages != null && page >= l.pages!;
    await _retry(() async {
      await api.editReading(l.id, {
        'pagina_atual': page,
        if (end) 'status': 'lido' else if (l.status == 'quero ler' && page > 0) 'status': 'lendo',
      });
      await _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, spacing: 12, children: [Text(_error!), FilledButton(onPressed: _load, child: const Text('Tentar de novo'))]));
    }
    final all = _readings;
    if (all == null) return const Center(child: CircularProgressIndicator());
    final items = [for (final l in all) if (_area == null || l.area == _area) l];
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _form,
        icon: const Icon(Icons.add),
        label: const Text('Leitura'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(8),
            child: Row(
              spacing: 6,
              children: [
                ChoiceChip(label: Text('Todas (${all.length})'), selected: _area == null, onSelected: (_) => setState(() => _area = null)),
                for (final a in widget.options.areas)
                  ChoiceChip(
                    label: Text('$a (${all.where((l) => l.area == a).length})'),
                    selected: _area == a,
                    onSelected: (_) => setState(() => _area = a),
                  ),
              ],
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? const Center(child: Text('Nenhuma leitura. Adicione um livro ou artigo.'))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 88),
                      children: [
                        for (final status in const ['lendo', 'quero ler', 'lido'])
                          if (items.any((l) => l.status == status)) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
                              child: Text(status.toUpperCase(), style: Theme.of(context).textTheme.labelLarge),
                            ),
                            for (final l in items.where((l) => l.status == status)) _card(l),
                          ],
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _card(Reading l) {
    final theme = Theme.of(context);
    return Card(
      child: InkWell(
        onTap: () => _progress(l),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            children: [
              Icon(l.type == 'artigo' ? Icons.article_outlined : Icons.menu_book_outlined, size: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    Text(l.title, style: theme.textTheme.titleSmall),
                    Text([l.author, l.area].where((t) => t.isNotEmpty).join(' · '), style: theme.textTheme.bodySmall),
                    if (l.progress != null) ...[
                      const SizedBox(height: 4),
                      LinearProgressIndicator(value: l.progress),
                      Text('${l.currentPage} de ${l.pages} páginas', style: theme.textTheme.labelSmall),
                    ],
                  ],
                ),
              ),
              IconButton(
                tooltip: l.noteId == null ? 'Criar nota de síntese' : 'Abrir nota de síntese',
                icon: Icon(l.noteId == null ? Icons.note_add_outlined : Icons.sticky_note_2_outlined),
                onPressed: () => _synthesis(l),
              ),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'editar') return _form(l);
                  if (v.startsWith('status:')) {
                    return _retry(() async {
                      await api.editReading(l.id, {'status': v.substring(7)});
                      await _load();
                    });
                  }
                  await _retry(() async {
                    await api.deleteReading(l.id);
                    await _load();
                  });
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'editar', child: Text('Editar')),
                  for (final s in widget.options.status)
                    if (s != l.status) PopupMenuItem(value: 'status:$s', child: Text('Marcar "$s"')),
                  const PopupMenuItem(value: 'excluir', child: Text('Excluir (a nota fica)')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReadingForm extends StatefulWidget {
  const _ReadingForm({required this.options, this.current, this.initialArea});

  final StudyOptions options;
  final Reading? current;
  final String? initialArea;

  @override
  State<_ReadingForm> createState() => _ReadingFormState();
}

class _ReadingFormState extends State<_ReadingForm> {
  late final _title = TextEditingController(text: widget.current?.title);
  late final _author = TextEditingController(text: widget.current?.author);
  late final _pages = TextEditingController(text: widget.current?.pages?.toString() ?? '');
  late final _url = TextEditingController(text: widget.current?.url);
  late String _type = widget.current?.type ?? 'livro';
  late String _area = widget.current?.area ?? widget.initialArea ?? widget.options.areas.first;
  late String _status = widget.current?.status ?? 'quero ler';

  @override
  void dispose() {
    for (final c in [_title, _author, _pages, _url]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.current == null ? 'Nova leitura' : 'Editar leitura'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 10,
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'livro', icon: Icon(Icons.menu_book_outlined), label: Text('Livro')),
                ButtonSegment(value: 'artigo', icon: Icon(Icons.article_outlined), label: Text('Artigo')),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() => _type = s.first),
            ),
            TextField(controller: _title, autofocus: true, decoration: const InputDecoration(labelText: 'Título')),
            TextField(controller: _author, decoration: const InputDecoration(labelText: 'Autor')),
            DropdownButtonFormField<String>(
              initialValue: _area,
              decoration: const InputDecoration(labelText: 'Área'),
              items: [for (final a in widget.options.areas) DropdownMenuItem(value: a, child: Text(a))],
              onChanged: (v) => setState(() => _area = v!),
            ),
            DropdownButtonFormField<String>(
              initialValue: _status,
              decoration: const InputDecoration(labelText: 'Status'),
              items: [for (final s in widget.options.status) DropdownMenuItem(value: s, child: Text(s))],
              onChanged: (v) => setState(() => _status = v!),
            ),
            TextField(
              controller: _pages,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Páginas (opcional)'),
            ),
            TextField(controller: _url, decoration: const InputDecoration(labelText: 'Link (opcional)')),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(
        onPressed: () {
          if (_title.text.trim().isEmpty) return;
          Navigator.pop(context, {
            'titulo': _title.text.trim(),
            'autor': _author.text.trim(),
            'tipo': _type,
            'area': _area,
            'status': _status,
            'paginas': int.tryParse(_pages.text),
            'url': _url.text.trim(),
          });
        },
        child: const Text('Salvar'),
      ),
    ],
  );
}
