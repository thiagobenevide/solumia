import 'package:flutter/material.dart';

import '../l10n/app_text.dart';
import '../core.dart';
import '../plan.dart';
import '../theme.dart';

/// Worker on this PC (`solumia-worker`), side by side with the older `agent-worker`.
class WorkerScreen extends StatefulWidget {
  const WorkerScreen({super.key, required this.core});
  final Core core;
  @override
  State<WorkerScreen> createState() => _WorkerScreenState();
}

class _WorkerScreenState extends State<WorkerScreen> {
  Map<String, dynamic>? _status;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await widget.core.get('/worker') as Map<String, dynamic>;
    if (mounted) setState(() => _status = r);
  }

  Future<void> _install() async {
    setState(() => _error = null);
    try {
      final plan = await widget.core.post('/worker/plano') as Map<String, dynamic>;
      if (mounted) await showPlan(context, widget.core, plan);
    } on CoreError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
    await _load();
  }

  Widget _stateTile(String unit, String state) {
    final colors = Theme.of(context).colorScheme;
    final active = state == 'active';
    return Card(
      child: ListTile(
        leading: Icon(active ? Icons.check_circle : Icons.radio_button_unchecked,
            color: active ? colors.success : null),
        title: Text(AppText.of(context).workerState(unit, state)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppText.of(context);
    final s = _status;
    if (s == null) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(24), children: [
        Text(t.itemWorker, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(t.workerIntro),
        const SizedBox(height: 16),
        _stateTile('${s['unidade']}', '${s['estado']}'),
        _stateTile('${s['antigo']}', '${s['estado_antigo']}'),
        const SizedBox(height: 8),
        Text(t.workerLlama('${s['porta_llama']}'), style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 16),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(onPressed: _install, icon: const Icon(Icons.play_arrow), label: Text(t.workerInstall)),
        ),
      ]),
    );
  }
}
