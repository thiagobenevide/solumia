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
  final _connectPort = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _ip.dispose();
    _pairPort.dispose();
    _code.dispose();
    _connectPort.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    final t = AppText.of(context);
    final port = int.tryParse(_pairPort.text.trim());
    if (_ip.text.trim().isEmpty || port == null) {
      notify(context, t.watchFillFields, error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.core.post('/relogio/parear', {'host': _ip.text.trim(), 'porta': port, 'codigo': _code.text.trim()});
      if (mounted) notify(context, t.watchPaired);
    } on CoreError catch (e) {
      if (mounted) notify(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _install() async {
    final t = AppText.of(context);
    final port = int.tryParse(_connectPort.text.trim());
    if (_ip.text.trim().isEmpty || port == null) {
      notify(context, t.watchFillFields, error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final plan = await widget.core.post('/relogio/plano', {'host': _ip.text.trim(), 'porta': port})
          as Map<String, dynamic>;
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
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(child: _field(_pairPort, t.watchPairPort)),
              const SizedBox(width: 12),
              Expanded(child: _field(_code, t.watchPairCode)),
              const SizedBox(width: 12),
              OutlinedButton(onPressed: _busy ? null : _pair, child: Text(t.watchPair)),
            ]),
            const SizedBox(height: 16),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(child: _field(_connectPort, t.watchConnectPort)),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _busy ? null : _install,
                icon: const Icon(Icons.install_mobile),
                label: Text(t.watchInstall),
              ),
            ]),
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
