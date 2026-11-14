import 'package:flutter/material.dart';

import '../l10n/app_text.dart';
import '../core.dart';

/// Chat with the Claude Code of this PC. The core sends Claude only a sanitized state (shown in
/// "What Claude receives"); Claude has no tools and the conversation is not saved to disk.
class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key, required this.core, required this.openScreen});
  final Core core;
  final void Function(String screenId) openScreen;
  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<Map<String, dynamic>> _turns = [];
  bool? _available;
  String _context = '';
  String _lastScreen = '';
  bool _waiting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final r = await widget.core.get('/assistente') as Map<String, dynamic>;
    if (!mounted) return;
    setState(() {
      _available = r['disponivel'] as bool;
      _context = r['contexto'] as String;
      _turns
        ..clear()
        ..addAll((r['historico'] as List).cast<Map<String, dynamic>>());
    });
  }

  Future<void> _send() async {
    final question = _input.text.trim();
    if (question.isEmpty || _waiting) return;
    setState(() {
      _waiting = true;
      _error = null;
    });
    try {
      final r = await widget.core.post('/assistente/perguntar', {'pergunta': question}) as Map<String, dynamic>;
      _input.clear();
      setState(() {
        _turns.add(r);
        _lastScreen = r['tela'] as String;
      });
    } on CoreError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _waiting = false);
    }
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _clear() async {
    await widget.core.post('/assistente/limpar');
    setState(() => _lastScreen = '');
    await _load();
  }

  void _showContext() {
    final t = AppText.of(context);
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t.assistantContext),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(child: SelectableText(_context, style: const TextStyle(fontFamily: 'monospace'))),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(t.close))],
      ),
    );
  }

  Widget _bubble(String text, bool mine) {
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 640),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: mine ? colors.primaryContainer : colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: SelectableText(text),
      ),
    );
  }

  List<Widget> _conversation() {
    final items = <Widget>[];
    for (final turn in _turns) {
      items.add(_bubble('${turn['pergunta']}', true));
      items.add(_bubble('${turn['resposta']}', false));
    }
    return items;
  }

  Widget _header(AppText t) {
    return Row(children: [
      Expanded(child: Text(t.navAssistant, style: Theme.of(context).textTheme.headlineSmall)),
      TextButton.icon(onPressed: _showContext, icon: const Icon(Icons.visibility_outlined), label: Text(t.assistantContext)),
      IconButton(tooltip: t.assistantClear, onPressed: _waiting ? null : _clear, icon: const Icon(Icons.delete_sweep_outlined)),
    ]);
  }

  Widget _composer(AppText t) {
    return Row(children: [
      Expanded(
        child: TextField(
          controller: _input,
          enabled: !_waiting,
          minLines: 1,
          maxLines: 5,
          maxLength: 4000,
          decoration: InputDecoration(hintText: t.assistantHint, helperText: t.assistantNoSecrets),
          onSubmitted: (_) => _send(),
        ),
      ),
      const SizedBox(width: 8),
      FilledButton.icon(onPressed: _waiting ? null : _send, icon: const Icon(Icons.send), label: Text(t.assistantSend)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppText.of(context);
    final available = _available;
    if (available == null) return const Center(child: CircularProgressIndicator());
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _header(t),
        const SizedBox(height: 8),
        Text(t.assistantIntro, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),
        if (!available) Text(t.assistantUnavailable, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        Expanded(child: ListView(controller: _scroll, children: _conversation())),
        if (_waiting)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 8),
              Text(t.assistantThinking),
            ]),
          ),
        if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        if (_lastScreen.isNotEmpty)
          TextButton.icon(
            onPressed: () => widget.openScreen(_lastScreen),
            icon: const Icon(Icons.arrow_forward),
            label: Text(t.assistantOpenScreen),
          ),
        if (available) _composer(t),
      ]),
    );
  }
}
