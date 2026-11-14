import 'package:flutter/material.dart';

import '../l10n/app_text.dart';
import '../core.dart';
import '../plan.dart';
import '../theme.dart';

/// Run log: every apply done, with its final state.
class RunLogScreen extends StatefulWidget {
  const RunLogScreen({super.key, required this.core});
  final Core core;
  @override
  State<RunLogScreen> createState() => _RunLogScreenState();
}

class _RunLogScreenState extends State<RunLogScreen> {
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await widget.core.get('/registro') as Map<String, dynamic>;
    if (mounted) setState(() => _items = (r['execucoes'] as List).cast<Map<String, dynamic>>());
  }

  @override
  Widget build(BuildContext context) {
    final t = AppText.of(context);
    final colors = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(24), children: [
        Text(t.runLogTitle, style: Theme.of(context).textTheme.headlineSmall),
        if (_items.isEmpty) Padding(padding: const EdgeInsets.only(top: 16), child: Text(t.runLogEmpty)),
        for (final i in _items)
          ListTile(
            leading: Icon(switch (i['estado']) {
              'concluida' => Icons.check_circle,
              'falhou' => Icons.error,
              _ => Icons.pause_circle,
            }, color: switch (i['estado']) {
              'concluida' => colors.success,
              'falhou' => colors.error,
              _ => colors.warning,
            }),
            title: Text(i['titulo'] as String),
            subtitle: Text('${i['id']} · ${stateLabel(t, i['estado'] as String)}'),
          ),
      ]),
    );
  }
}
