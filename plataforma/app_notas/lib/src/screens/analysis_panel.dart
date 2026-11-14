import 'package:flutter/material.dart';

import '../notes_api.dart';
import '../models.dart';

/// Vault analysis: what is overdue/stale (the basis for follow-ups) and the health of the links.
/// Reusable: the Painel module embeds this widget with its own [onOpen].
class AnalysisPanel extends StatefulWidget {
  const AnalysisPanel({super.key, required this.api, required this.onOpen});

  final NotesApi api;
  final void Function(String id) onOpen;

  @override
  State<AnalysisPanel> createState() => _AnalysisPanelState();
}

class _AnalysisPanelState extends State<AnalysisPanel> {
  late Future<NoteAnalysis> _analysis = widget.api.analysis();

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _analysis,
    builder: (context, snap) {
      if (snap.hasError) return Center(child: Text('${snap.error}'));
      final a = snap.data;
      if (a == null) return const Center(child: CircularProgressIndicator());
      final colors = Theme.of(context).colorScheme;
      final sections = [
        _section('Vencidas: cobrar', Icons.alarm, colors.error, a.overdue, showDue: true),
        _section('Vencem em 7 dias', Icons.event, colors.tertiary, a.dueSoon, showDue: true),
        _section('Paradas há 14+ dias', Icons.hourglass_bottom, colors.secondary, a.stale),
        _section('Mais citadas', Icons.hub_outlined, colors.primary, a.hubs),
        _Block(
          title: 'Links quebrados (${a.broken.length})',
          icon: Icons.link_off,
          color: colors.error,
          children: [
            for (final q in a.broken.take(30))
              ListTile(
                dense: true,
                title: Text(q.title),
                subtitle: Text('${q.type} → [[${q.excerpt}]]'),
                onTap: () => widget.onOpen(q.id!),
              ),
          ],
        ),
        _section('Órfãs (sem nenhum link)', Icons.scatter_plot_outlined, colors.outline, a.orphans),
        _Block(
          title: 'Por tipo',
          icon: Icons.category_outlined,
          color: colors.primary,
          children: [
            for (final MapEntry(key: t, value: n) in a.byType.entries)
              ListTile(
                dense: true,
                leading: Icon(iconForType(t)),
                title: Text(t),
                subtitle: LinearProgressIndicator(value: n / a.total),
                trailing: Text('$n'),
              ),
          ],
        ),
      ];
      return RefreshIndicator(
        onRefresh: () async => setState(() => _analysis = widget.api.analysis()),
        child: LayoutBuilder(
          builder: (context, c) {
            // two columns on PC/landscape tablet, one on the phone
            final width = c.maxWidth >= 900 ? (c.maxWidth - 36) / 2 : c.maxWidth - 24;
            return ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _Stat('Notas', a.total, colors.primary),
                    _Stat('Abertas', a.openCount, colors.secondary),
                    _Stat('Vencidas', a.overdue.length, colors.error),
                    _Stat('Paradas', a.stale.length, colors.tertiary),
                    _Stat('Links quebrados', a.broken.length, colors.error),
                    _Stat('Órfãs', a.orphans.length, colors.outline),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [for (final s in sections) SizedBox(width: width, child: s)],
                ),
              ],
            );
          },
        ),
      );
    },
  );

  Widget _section(String title, IconData icon, Color color, List<NoteSummary> items, {bool showDue = false}) =>
      _Block(
        title: '$title (${items.length})',
        icon: icon,
        color: color,
        children: [
          for (final r in items.take(30))
            ListTile(
              dense: true,
              leading: Icon(iconForType(r.type)),
              title: Text(r.title),
              subtitle: Text(
                [r.status, showDue ? shortDate(r.due) : null, '${r.incoming} backlinks'].nonNulls.join(' · '),
              ),
              onTap: () => widget.onOpen(r.id),
            ),
        ],
      );
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, this.color);

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 150,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$value', style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: color)),
            Text(label),
          ],
        ),
      ),
    ),
  );
}

class _Block extends StatelessWidget {
  const _Block({required this.title, required this.icon, required this.color, required this.children});

  final String title;
  final IconData icon;
  final Color color;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: Icon(icon, color: color),
          title: Text(title, style: Theme.of(context).textTheme.titleSmall),
        ),
        if (children.isEmpty)
          const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 16), child: Text('Nada aqui.'))
        else
          ...children,
      ],
    ),
  );
}
