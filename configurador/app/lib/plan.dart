// Plan dialog: shows the steps BEFORE any change, applies only after confirmation and
// follows the run with a live log.
import 'dart:async';

import 'package:flutter/material.dart';

import 'l10n/app_text.dart';
import 'core.dart';
import 'theme.dart';

Future<bool> showPlan(BuildContext context, Core core, Map<String, dynamic> plan) async {
  final r = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PlanDialog(core: core, plan: plan),
  );
  return r ?? false;
}

class _PlanDialog extends StatefulWidget {
  const _PlanDialog({required this.core, required this.plan});
  final Core core;
  final Map<String, dynamic> plan;
  @override
  State<_PlanDialog> createState() => _PlanDialogState();
}

class _PlanDialogState extends State<_PlanDialog> {
  final _totp = TextEditingController();
  final _scroll = ScrollController();
  String? _execId;
  String _state = 'plano'; // plano | rodando | concluida | falhou | cancelada
  final Map<String, String> _steps = {};
  final List<Map<String, dynamic>> _log = [];
  int _since = 0;
  Timer? _timer;
  String? _error;

  List<Map<String, dynamic>> get _list =>
      (widget.plan['passos'] as List).cast<Map<String, dynamic>>();

  @override
  void dispose() {
    _timer?.cancel();
    _totp.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    setState(() => _error = null);
    try {
      final r = await widget.core.post('/planos/${widget.plan['id']}/aplicar', {
        'hash': widget.plan['hash'],
        if (widget.plan['destrutivo'] == true) 'totp': _totp.text.trim(),
      });
      _execId = r['id'] as String;
      setState(() => _state = 'rodando');
      _timer = Timer.periodic(const Duration(milliseconds: 700), (_) => _query());
    } on CoreError catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _query() async {
    if (_execId == null) return;
    try {
      final r = await widget.core.get('/execucoes/$_execId', {'desde': '$_since'});
      final newEvents = (r['novos'] as List).cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        for (final ev in newEvents) {
          _since = (ev['n'] as int) + 1;
          final step = ev['passo'] as String?;
          switch (ev['tipo']) {
            case 'passo':
              _steps[step!] = 'rodando';
            case 'ok':
              if (_steps[step] != 'pulado') _steps[step!] = 'ok';
            case 'pulado':
              _steps[step!] = 'pulado';
            case 'falha':
              if (step != null) _steps[step] = 'falha';
              _log.add(ev);
            default:
              if ((ev['texto'] as String).isNotEmpty) _log.add(ev);
          }
        }
        final state = r['estado'] as String;
        if (state != 'rodando' && state != 'pendente') {
          _state = state;
          _timer?.cancel();
        }
      });
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    } on CoreError catch (e) {
      setState(() => _error = e.message);
    }
  }

  Widget _icon(String? s, ColorScheme c) => switch (s) {
        'rodando' => const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        'ok' => Icon(Icons.check_circle, color: c.success, size: 20),
        'pulado' => Icon(Icons.skip_next, color: c.outline, size: 20),
        'falha' => Icon(Icons.error, color: c.error, size: 20),
        _ => const Icon(Icons.radio_button_unchecked, size: 20),
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = AppText.of(context);
    final didRun = _state != 'plano';
    return AlertDialog(
      title: Text(widget.plan['titulo'] as String),
      content: SizedBox(
        width: 760,
        height: 560,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(didRun ? t.planRun(stateLabel(t, _state)) : t.planNothingChanged,
              style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Expanded(
            flex: didRun ? 2 : 5,
            child: ListView(children: [
              for (final p in _list)
                ListTile(
                  dense: true,
                  leading: _icon(_steps[p['id']], theme.colorScheme),
                  title: Text(p['titulo'] as String),
                  subtitle: (p['detalhe'] as String).isEmpty ? null : Text(p['detalhe'] as String),
                ),
            ]),
          ),
          if (didRun) ...[
            const Divider(),
            Expanded(
              flex: 3,
              child: Container(
                padding: const EdgeInsets.all(8),
                color: theme.colorScheme.surfaceContainerHighest,
                child: ListView.builder(
                  controller: _scroll,
                  itemCount: _log.length,
                  itemBuilder: (_, i) {
                    final ev = _log[i];
                    return SelectableText(ev['texto'] as String,
                        style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: ev['tipo'] == 'falha' ? theme.colorScheme.error : null));
                  },
                ),
              ),
            ),
          ],
          if (!didRun && widget.plan['destrutivo'] == true)
            TextField(
              controller: _totp,
              decoration: InputDecoration(labelText: t.destructiveCode),
              keyboardType: TextInputType.number,
              maxLength: 6,
            ),
          if (_error != null) Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ]),
      ),
      actions: [
        if (_state == 'plano') ...[
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.cancel)),
          FilledButton.icon(onPressed: _apply, icon: const Icon(Icons.play_arrow), label: Text(t.apply)),
        ],
        if (_state == 'rodando')
          TextButton(
            onPressed: () => widget.core.post('/execucoes/$_execId/cancelar'),
            child: Text(t.stopAfterStep),
          ),
        if (_state != 'plano' && _state != 'rodando')
          FilledButton(onPressed: () => Navigator.pop(context, _state == 'concluida'), child: Text(t.close)),
      ],
    );
  }
}

String stateLabel(AppText t, String s) => switch (s) {
      'rodando' => t.stateRunning,
      'concluida' => t.stateFinished,
      'falhou' => t.stateFailed,
      'cancelada' => t.stateCancelled,
      _ => s,
    };

void notify(BuildContext context, String text, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(text),
    backgroundColor: error ? Theme.of(context).colorScheme.error : null,
  ));
}
