import 'package:flutter/material.dart';

import '../open_note.dart';
import '../models.dart';

/// Relations of the open note: outgoing links (by type), backlinks and unlinked mentions.
/// A link without a note shows in red and creates the note when tapped.
class RelationsPanel extends StatelessWidget {
  const RelationsPanel({super.key, required this.openNote});

  final OpenNote openNote;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: openNote,
    builder: (context, _) {
      final n = openNote.note;
      if (n == null) return const Center(child: Text('Nenhuma nota aberta'));
      final colors = Theme.of(context).colorScheme;
      final byType = <String, List<NoteLink>>{};
      for (final s in n.outgoing) {
        byType.putIfAbsent(s.type, () => []).add(s);
      }
      return ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _Heading('Saídas', n.outgoing.length, Icons.call_made),
          if (n.outgoing.isEmpty) const _Hint('Escreva [[ no texto ou use o botão Relação.'),
          for (final MapEntry(key: type, value: items) in byType.entries) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Text(type.replaceAll('_', ' '), style: Theme.of(context).textTheme.labelMedium),
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final s in items)
                  ActionChip(
                    avatar: Icon(s.id == null ? Icons.add : Icons.link, size: 16),
                    label: Text(s.title),
                    labelStyle: s.id == null ? TextStyle(color: colors.error) : null,
                    tooltip: s.id == null ? 'Criar nota' : null,
                    onPressed: () => s.id == null ? openNote.openOrCreate(s.title) : openNote.open(s.id!),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          _Heading('Backlinks', n.incoming.length, Icons.call_received),
          if (n.incoming.isEmpty) const _Hint('Nenhuma nota aponta para esta.'),
          for (final e in n.incoming) _item(context, e),
          if (n.mentions.isNotEmpty) ...[
            const SizedBox(height: 16),
            _Heading('Menções sem link', n.mentions.length, Icons.link_off),
            for (final m in n.mentions) _item(context, m),
          ],
        ],
      );
    },
  );

  Widget _item(BuildContext context, NoteLink l) => Card(
    margin: const EdgeInsets.only(top: 6),
    child: ListTile(
      dense: true,
      title: Text(l.title),
      subtitle: l.excerpt.isEmpty ? null : Text(l.excerpt, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: Text(l.type.replaceAll('_', ' '), style: Theme.of(context).textTheme.labelSmall),
      onTap: l.id == null ? null : () => openNote.open(l.id!),
    ),
  );
}

class _Heading extends StatelessWidget {
  const _Heading(this.text, this.n, this.icon);

  final String text;
  final int n;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Row(
    spacing: 8,
    children: [
      Icon(icon, size: 18),
      Text('$text ($n)', style: Theme.of(context).textTheme.titleSmall),
    ],
  );
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.outline)),
  );
}
