import 'package:flutter/material.dart';

import '../core.dart';
import '../l10n/app_text.dart';
import '../plan.dart';

/// Pairs with the watch over Wi-Fi debugging (first time) and installs the verified watch app.
Future<void> showWatchInstall(BuildContext context, Core core) =>
    showDialog<void>(context: context, builder: (_) => _WatchInstallDialog(core: core));

class _WatchInstallDialog extends StatefulWidget {
  const _WatchInstallDialog({required this.core});
  final Core core;
  @override
  State<_WatchInstallDialog> createState() => _WatchInstallDialogState();
}

class _WatchInstallDialogState extends State<_WatchInstallDialog> {
  final _ip = TextEditingController();
  final _pairPort = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _ip.dispose();
    _pairPort.dispose();
    _code.dispose();
    super.dispose();
  }

  /// First time: pairs with the code shown on the watch, then installs. Later: installs directly
  /// (the connection port is found by the configurator).
  Future<void> _install() async {
    final t = AppText.of(context);
    final host = _ip.text.trim();
    final pairPort = int.tryParse(_pairPort.text.trim());
    final code = _code.text.trim();
    if (host.isEmpty || (code.isNotEmpty && pairPort == null)) {
      notify(context, t.watchFillFields, error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      if (code.isNotEmpty) {
        await widget.core.post('/relogio/parear', {'host': host, 'porta': pairPort, 'codigo': code});
        if (mounted) notify(context, t.watchPaired);
      }
      final plan = await widget.core.post('/relogio/plano', {'host': host}) as Map<String, dynamic>;
      if (mounted) await showPlan(context, widget.core, plan);
    } on CoreError catch (e) {
      if (mounted) notify(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(TextEditingController c, String label, {bool number = true}) => TextField(
        controller: c,
        enabled: !_busy,
        keyboardType: number ? TextInputType.number : TextInputType.text,
        decoration: InputDecoration(labelText: label),
      );

  @override
  Widget build(BuildContext context) {
    final t = AppText.of(context);
    final theme = Theme.of(context);
    return AlertDialog(
      icon: const Icon(Icons.watch),
      title: Text(t.watchInstallTitle),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.watchSteps, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 16),
            _field(_ip, t.watchIp, number: false),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(child: _field(_pairPort, t.watchPairPort)),
              const SizedBox(width: 12),
              Expanded(child: _field(_code, t.watchPairCode)),
            ]),
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _busy ? null : _install,
                icon: const Icon(Icons.install_mobile),
                label: Text(t.watchInstall),
              ),
            ),
            if (_busy) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(MaterialLocalizations.of(context).closeButtonLabel)),
      ],
    );
  }
}
