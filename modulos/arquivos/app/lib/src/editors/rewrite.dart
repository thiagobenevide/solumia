import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../files_api.dart';
import '../screens/highlight_actions.dart';

/// Rewrite goals (keys of `shared/claude_code.py` → label).
const rewriteGoals = {
  'orientador': 'Revisar para o orientador',
  'feedback': 'Aplicar comentários do orientador',
  'formal': 'Linguagem acadêmica formal',
  'conciso': 'Mais conciso',
  'expandir': 'Desenvolver argumentação',
  'gramatica': 'Só gramática e ortografia',
};

/// Rewrite of an excerpt by Claude Code (on the PC, through the subscription). Returns the accepted text, or
/// `null`. [fileId] sends the whole document as context (coherence with the rest of the thesis);
/// without [excerpt], the field starts empty for pasting.
Future<String?> rewriteWithClaude(
  BuildContext context,
  FilesApi api, {
  String excerpt = '',
  String? fileId,
  String? title,
}) => abrirTela<String>(
  context,
  (_) => _RewriteScreen(api: api, excerpt: excerpt, fileId: fileId, title: title),
  titulo: 'Reescrever com Claude',
  icone: Icons.auto_fix_high,
);

class _RewriteScreen extends StatefulWidget {
  const _RewriteScreen({required this.api, required this.excerpt, this.fileId, this.title});

  final FilesApi api;
  final String excerpt;
  final String? fileId;
  final String? title;

  @override
  State<_RewriteScreen> createState() => _RewriteScreenState();
}

class _RewriteScreenState extends State<_RewriteScreen> {
  late final _excerpt = TextEditingController(text: widget.excerpt);
  final _feedback = TextEditingController();
  final _instruction = TextEditingController();
  final _suggestion = TextEditingController();
  String _goal = 'orientador';
  bool _working = false;
  Map<String, dynamic>? _result;

  @override
  void dispose() {
    for (final c in [_excerpt, _feedback, _instruction, _suggestion]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _rewrite() async {
    if (_excerpt.text.trim().isEmpty) return notify(context, 'Cole ou selecione o trecho a reescrever.');
    if (_goal == 'feedback' && _feedback.text.trim().isEmpty) {
      return notify(context, 'Cole os comentários do orientador.');
    }
    setState(() => _working = true);
    try {
      final r = await widget.api.rewrite(
        excerpt: _excerpt.text,
        goal: _goal,
        instruction: _instruction.text,
        feedback: _feedback.text,
        fileId: widget.fileId,
      );
      if (!mounted) return;
      _suggestion.text = r['texto'] as String? ?? '';
      setState(() => _result = r);
    } on ApiErro catch (e) {
      if (mounted) notify(context, 'Não consegui reescrever: ${e.mensagem}');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Widget _input(TextEditingController c, String label, {int lines = 3, String? hint}) => TextField(
    controller: c,
    minLines: lines,
    maxLines: lines + 8,
    decoration: InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder()),
  );

  @override
  Widget build(BuildContext context) {
    final r = _result;
    final changes = [...(r?['mudancas'] as List? ?? const []).cast<Map<String, dynamic>>()];
    final notes = (r?['observacoes'] as String? ?? '').trim();
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title == null ? 'Reescrever com Claude' : 'Reescrever · ${widget.title}'),
        actions: [
          if (r != null) ...[
            IconButton(
              tooltip: 'Copiar sugestão',
              icon: const Icon(Icons.copy),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _suggestion.text));
                if (context.mounted) notify(context, 'Sugestão copiada.');
              },
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.icon(
                onPressed: () => Navigator.pop(context, _suggestion.text),
                icon: const Icon(Icons.check),
                label: const Text('Aplicar'),
              ),
            ),
          ],
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final MapEntry(:key, :value) in rewriteGoals.entries)
                ChoiceChip(
                  label: Text(value),
                  selected: _goal == key,
                  onSelected: (_) => setState(() => _goal = key),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (_goal == 'feedback') ...[
            _input(_feedback, 'Comentários do orientador', hint: 'Cole aqui o que o orientador pediu.'),
            const SizedBox(height: 12),
          ],
          _input(_excerpt, 'Trecho', lines: 6),
          const SizedBox(height: 12),
          _input(_instruction, 'Pedido adicional (opcional)', lines: 1, hint: 'ex.: manter em até 150 palavras'),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: _working ? null : _rewrite,
                icon: _working
                    ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.auto_fix_high),
                label: Text(_working ? 'Claude está reescrevendo…' : (r == null ? 'Reescrever' : 'Refazer')),
              ),
              const SizedBox(width: 12),
              if (widget.fileId != null)
                Expanded(
                  child: Text(
                    'O documento inteiro vai como contexto, para manter a coerência.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ],
          ),
          if (r != null) ...[
            const Divider(height: 32),
            _input(_suggestion, 'Sugestão (pode ajustar antes de aplicar)', lines: 6),
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Card(
                color: theme.colorScheme.tertiaryContainer,
                child: ListTile(
                  leading: const Icon(Icons.flag_outlined),
                  title: const Text('Para você resolver'),
                  subtitle: Text(notes),
                ),
              ),
            ],
            if (changes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('O que mudou e por quê', style: theme.textTheme.titleSmall),
              for (final m in changes)
                ListTile(
                  dense: true,
                  title: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: m['antes'] as String? ?? '',
                          style: TextStyle(
                            decoration: TextDecoration.lineThrough,
                            color: theme.colorScheme.error,
                          ),
                        ),
                        const TextSpan(text: '  →  '),
                        TextSpan(
                          text: m['depois'] as String? ?? '',
                          style: TextStyle(color: theme.colorScheme.primary),
                        ),
                      ],
                    ),
                  ),
                  subtitle: Text(m['motivo'] as String? ?? ''),
                ),
            ],
          ],
        ],
      ),
    );
  }
}
