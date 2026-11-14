import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../studies_api.dart';
import '../knowledge_models.dart';
import 'readings_screen.dart' show openNote;
import 'projects_screen.dart' show OpenInFile;

/// Trilhas section: the career track (Software Architect) in phases and steps, each with the
/// chapters to read, the practice and the step note. The fronts (Back-end, Dados, IA…) filter the same
/// track. Reading and highlighting happen in the Arquivos reader, through the book linked in the Leituras tab.
class TracksScreen extends StatefulWidget {
  const TracksScreen({super.key, required this.api, this.openInFile});

  final StudiesApi api;
  final OpenInFile? openInFile;

  @override
  State<TracksScreen> createState() => _TracksScreenState();
}

class _TracksScreenState extends State<TracksScreen> {
  StudiesApi get api => widget.api;
  List<KnowledgeTrack>? _tracks;
  KnowledgeTrack? _track;
  List<TrackBook>? _shelf;
  String? _front;
  bool _showShelf = false;
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
      if (_track == null) {
        setState(() => _error = '$e');
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _load() => _retry(() async {
    final tracks = _tracks ?? await api.knowledgeTracks();
    if (tracks.isEmpty) return;
    final id = _track?.id ?? tracks.first.id;
    final t = await api.knowledgeTrack(id, front: _front);
    final shelf = _showShelf ? await api.shelf() : _shelf;
    if (mounted) {
      setState(() {
        _tracks = tracks;
        _track = t;
        _shelf = shelf;
        _error = null;
      });
    }
  });

  Future<void> _mark(TrackStep e, Map<String, dynamic> data) => _retry(() async {
    await api.markStep(_track!.id, e.id, data);
    await _load();
  });

  Future<void> _link(TrackBook l) => _retry(() async {
    await api.linkReading(l.id);
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('“${l.title}” está em Leituras: anexe o PDF lá para ler e grifar.')),
      );
    }
  });

  Future<void> _openPdf(LinkedReading l) async {
    final open = widget.openInFile;
    if (open == null || l.fileId == null) return;
    await open(context, l.fileId!, l.currentPage < 1 ? 1 : l.currentPage);
  }

  Future<void> _note(TrackStep e) => _retry(() async {
    var id = e.noteId;
    if (id == null) {
      final t = _track!;
      final readings = [for (final i in e.readings) '- ${i.book.title} — ${i.chapters}'].join('\n');
      final note = await api.notes.create({
        'titulo': '${t.title} — ${e.title}',
        'pasta': 'Notas/Estudos/${t.area}/${t.title}',
        'tags': ['estudos', 'trilha', for (final f in e.fronts) f.toLowerCase().replaceAll(' ', '-')],
        'propriedades': {'trilha': t.title, 'fase': e.phase},
        'corpo':
            '## Objetivo\n${e.goal}\n\n## Leituras\n$readings\n\n## Conceitos\n'
            '${[for (final c in e.concepts) '- $c'].join('\n')}\n\n## Grifos e ideias\n\n'
            '## Prática\n${e.practice}\n\n## Entregável\n${e.deliverable}\n\n'
            '## Ligações\n- Área: [[${t.area}]]\n- Trilha: [[${t.title}]]\n',
      });
      id = note.id;
      await api.markStep(t.id, e.id, {'nota_id': id});
      await _load();
    }
    if (mounted) await openNote(context, api.notes, id);
  });

  @override
  Widget build(BuildContext context) {
    final t = _track;
    if (_error != null && t == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            Text(_error!),
            FilledButton(onPressed: _load, child: const Text('Tentar de novo')),
          ],
        ),
      );
    }
    if (t == null) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Header(track: t, tracks: _tracks ?? const [], onSwitch: (id) {
            _track = _tracks!.firstWhere((x) => x.id == id);
            _load();
          }),
          const SizedBox(height: 12),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Trilha'), icon: Icon(Icons.route_outlined)),
              ButtonSegment(value: true, label: Text('Estante'), icon: Icon(Icons.shelves)),
            ],
            selected: {_showShelf},
            onSelectionChanged: (s) {
              setState(() => _showShelf = s.first);
              _load();
            },
          ),
          const SizedBox(height: 12),
          if (_showShelf)
            ..._books()
          else ...[
            if (t.next != null) _NextUpCard(next: t.next!),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ChoiceChip(
                  label: const Text('Todas as frentes'),
                  selected: _front == null,
                  onSelected: (_) {
                    _front = null;
                    _load();
                  },
                ),
                for (final f in t.fronts)
                  ChoiceChip(
                    label: Text(f),
                    selected: _front == f,
                    onSelected: (_) {
                      _front = f;
                      _load();
                    },
                  ),
              ],
            ),
            const SizedBox(height: 8),
            ..._steps(t),
          ],
        ],
      ),
    );
  }

  List<Widget> _steps(KnowledgeTrack t) {
    final itens = <Widget>[];
    String? phase;
    for (final e in t.steps) {
      if (e.phase != phase) {
        phase = e.phase;
        itens.add(
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 4),
            child: Text(phase, style: Theme.of(context).textTheme.titleMedium),
          ),
        );
      }
      itens.add(
        _StepCard(
          step: e,
          onMarkReading: (i, done) => _mark(e, {'leitura': i, 'feita': done}),
          onMarkPractice: (done) => _mark(e, {'pratica': done}),
          onNote: () => _note(e),
          onLink: _link,
          onOpenPdf: widget.openInFile == null ? null : _openPdf,
        ),
      );
    }
    return itens;
  }

  List<Widget> _books() {
    final shelf = _shelf;
    if (shelf == null) return const [Center(child: CircularProgressIndicator())];
    return [
      for (final l in shelf)
        Card(
          child: ListTile(
            leading: Icon(l.type == 'doc' ? Icons.public : Icons.menu_book_outlined),
            title: Text(l.title),
            subtitle: Text(
              [
                l.author,
                if (l.original != l.title) l.original,
                l.edition,
                '${l.hints} indicações na trilha',
                if (l.reading != null) 'em Leituras: ${l.reading!.status}${l.reading!.fileId != null ? ' · PDF' : ''}',
                if (l.url.isNotEmpty) l.url,
              ].join(' · '),
            ),
            isThreeLine: true,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (l.reading == null && l.type == 'livro')
                  IconButton(
                    tooltip: 'Ligar às Leituras (para anexar o PDF e grifar)',
                    icon: const Icon(Icons.link),
                    onPressed: () => _link(l),
                  ),
                Tooltip(
                  message: l.owned ? 'Na estante' : 'Ainda não tenho',
                  child: Switch(
                    value: l.owned,
                    onChanged: (v) => _retry(() async {
                      await api.markBook(l.id, v);
                      await _load();
                    }),
                  ),
                ),
              ],
            ),
          ),
        ),
    ];
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.track, required this.tracks, required this.onSwitch});

  final KnowledgeTrack track;
  final List<KnowledgeTrack> tracks;
  final ValueChanged<String> onSwitch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 6,
      children: [
        if (tracks.length > 1)
          DropdownButton<String>(
            value: track.id,
            items: [for (final t in tracks) DropdownMenuItem(value: t.id, child: Text('${t.area} · ${t.title}'))],
            onChanged: (id) => id == null ? null : onSwitch(id),
          )
        else
          Text('${track.area} · ${track.title}', style: theme.headlineSmall),
        Text(track.descricao),
        LinearProgressIndicator(value: track.progress),
        Text(
          '${track.completedSteps} de ${track.totalSteps} etapas concluídas'
          '${track.front == null ? '' : ' em ${track.front}'} · ${(track.progress * 100).round()}%',
          style: theme.bodySmall,
        ),
      ],
    );
  }
}

class _NextUpCard extends StatelessWidget {
  const _NextUpCard({required this.next});

  final NextUp next;

  @override
  Widget build(BuildContext context) {
    final p = next;
    final i = p.hint;
    final (icone, title, text) = switch (p.type) {
      'leitura' => (Icons.auto_stories, 'Leia agora', '${i!.book.title} — ${i.chapters}\n${i.focus}'),
      'conseguir' => (
        Icons.shopping_bag_outlined,
        'Próxima leitura (livro que falta na estante)',
        '${i!.book.title} — ${i.chapters}\n${i.focus}',
      ),
      _ => (Icons.build_outlined, 'Hora da prática', p.practice),
    };
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: ListTile(
        leading: Icon(icone),
        title: Text('$title · ${p.step}'),
        subtitle: Text('${p.phase}\n$text'),
        isThreeLine: true,
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.step,
    required this.onMarkReading,
    required this.onMarkPractice,
    required this.onNote,
    required this.onLink,
    this.onOpenPdf,
  });

  final TrackStep step;
  final void Function(int score, bool done) onMarkReading;
  final ValueChanged<bool> onMarkPractice;
  final VoidCallback onNote;
  final ValueChanged<TrackBook> onLink;
  final ValueChanged<LinkedReading>? onOpenPdf;

  @override
  Widget build(BuildContext context) {
    final e = step;
    final theme = Theme.of(context);
    return Card(
      child: ExpansionTile(
        leading: e.completed
            ? Icon(Icons.check_circle, color: theme.colorScheme.primary)
            : SizedBox.square(dimension: 28, child: CircularProgressIndicator(value: e.progress, strokeWidth: 3)),
        title: Text(e.title),
        subtitle: Text(e.fronts.join(' · ')),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(e.goal),
          const SizedBox(height: 8),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [for (final c in e.concepts) Chip(label: Text(c), visualDensity: VisualDensity.compact)],
          ),
          const SizedBox(height: 8),
          Text('Leituras', style: theme.textTheme.titleSmall),
          for (final i in e.readings)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Checkbox(value: i.done != null, onChanged: (v) => onMarkReading(i.score, v ?? false)),
              title: Text('${i.book.title} — ${i.chapters}'),
              subtitle: Text(
                [
                  i.focus,
                  if (!i.book.owned) 'Ainda não está na sua estante',
                  if (i.book.url.isNotEmpty) i.book.url,
                  if (i.done != null) 'Lido em ${i.done}',
                ].join('\n'),
              ),
              trailing: switch (i.book.reading) {
                final LinkedReading l when l.fileId != null && onOpenPdf != null => IconButton(
                  tooltip: 'Abrir o PDF para ler e grifar',
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  onPressed: () => onOpenPdf!(l),
                ),
                null when i.book.type == 'livro' => IconButton(
                  tooltip: 'Ligar às Leituras (para anexar o PDF e grifar)',
                  icon: const Icon(Icons.link),
                  onPressed: () => onLink(i.book),
                ),
                _ => null,
              },
            ),
          const SizedBox(height: 4),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: e.practiceDone != null,
            onChanged: (v) => onMarkPractice(v ?? false),
            title: const Text('Prática'),
            subtitle: Text('${e.practice}\nEntregável: ${e.deliverable}'),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: onNote,
              icon: Icon(e.noteId == null ? Icons.note_add_outlined : Icons.sticky_note_2_outlined),
              label: Text(e.noteId == null ? 'Criar nota da etapa' : 'Abrir nota da etapa'),
            ),
          ),
        ],
      ),
    );
  }
}
