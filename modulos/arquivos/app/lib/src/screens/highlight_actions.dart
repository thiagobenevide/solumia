import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../files_api.dart';
import '../models.dart';
import 'reading_projects.dart';

void notify(BuildContext context, String mensagem) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(mensagem)));

/// Asks for a text in a dialog box. `null` when cancelled.
Future<String?> askText(
  BuildContext context, {
  required String title,
  String initial = '',
  String label = '',
  int lines = 1,
  String confirm = 'Salvar',
}) {
  final field = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: field,
          autofocus: true,
          minLines: lines,
          maxLines: lines == 1 ? 1 : 12,
          decoration: InputDecoration(labelText: label.isEmpty ? null : label),
          onSubmitted: lines == 1 ? (v) => Navigator.pop(context, v) : null,
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(context, field.text), child: Text(confirm)),
      ],
    ),
  ).whenComplete(field.dispose);
}

/// Creates a note from the highlight, asking for the title (default: start of the excerpt).
Future<void> createNoteFromHighlight(BuildContext context, FilesApi api, Reference r) async {
  final keywords = r.highlight.text.split(RegExp(r'\s+')).take(8).join(' ');
  final title = await askText(
    context,
    title: 'Nova nota com a referência',
    initial: keywords.isEmpty ? r.fileTitle : keywords,
    label: 'Título da nota',
    confirm: 'Criar',
  );
  if (title == null || title.trim().isEmpty || !context.mounted) return;
  try {
    await api.createNote(r, title: title.trim());
    if (context.mounted) notify(context, 'Nota "$title" criada no módulo Notas');
  } on ApiErro catch (e) {
    if (context.mounted) notify(context, 'Não deu para criar a nota: ${e.mensagem}');
  }
}

/// Panel of a highlight: text, comment and what can be done with it.
Future<void> showHighlight(
  BuildContext context, {
  required FilesApi api,
  required Reference reference,
  ValueChanged<String>? onComment,
  ValueChanged<String>? onTranslate,
  ValueChanged<List<String>>? onProjectsChanged,
  VoidCallback? onDelete,
  VoidCallback? onOpen,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (sheet) {
    final d = reference.highlight;
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              Text('${reference.fileTitle} · p. ${d.page + 1}', style: Theme.of(sheet).textTheme.labelLarge),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border(left: BorderSide(color: d.color.withValues(alpha: 1), width: 4)),
                  color: d.color.withValues(alpha: 0.12),
                ),
                constraints: const BoxConstraints(maxHeight: 260),
                child: SingleChildScrollView(child: SelectableText(d.text)),
              ),
              if (d.translation.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(sheet).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 8,
                    children: [
                      const Icon(Icons.translate, size: 18),
                      Expanded(child: SelectableText(d.translation)),
                    ],
                  ),
                ),
              if (d.comment.isNotEmpty)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 8,
                  children: [
                    const Icon(Icons.lightbulb_outline, size: 18),
                    Expanded(
                      child: Text(d.comment, style: const TextStyle(fontStyle: FontStyle.italic)),
                    ),
                  ],
                ),
              if (onProjectsChanged != null) ...[
                Text('Projetos de leitura', style: Theme.of(sheet).textTheme.labelLarge),
                ProjectChips(api: api, initial: d.projects, aoMudar: onProjectsChanged),
              ],
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.copy),
                    label: const Text('Copiar referência'),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: reference.citation));
                      Navigator.pop(sheet);
                      notify(context, 'Referência copiada');
                    },
                  ),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.note_add_outlined),
                    label: const Text('Criar nota'),
                    onPressed: () {
                      Navigator.pop(sheet);
                      createNoteFromHighlight(context, api, reference);
                    },
                  ),
                  if (onComment != null)
                    OutlinedButton.icon(
                      icon: const Icon(Icons.comment_outlined),
                      label: Text(d.comment.isEmpty ? 'Comentar' : 'Editar comentário'),
                      onPressed: () async {
                        Navigator.pop(sheet);
                        final c = await askText(
                          context,
                          title: 'Meu comentário (extração do conhecimento)',
                          initial: d.comment,
                          lines: 4,
                        );
                        if (c != null) onComment(c.trim());
                      },
                    ),
                  if (onTranslate != null)
                    OutlinedButton.icon(
                      icon: const Icon(Icons.translate),
                      label: Text(d.translation.isEmpty ? 'Traduzir' : 'Editar tradução'),
                      onPressed: () async {
                        Navigator.pop(sheet);
                        final t = await editTranslation(context, api, original: d.text, current: d.translation);
                        if (t != null) onTranslate(t);
                      },
                    ),
                  if (onOpen != null)
                    OutlinedButton.icon(
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Abrir no arquivo'),
                      onPressed: () {
                        Navigator.pop(sheet);
                        onOpen();
                      },
                    ),
                  if (onDelete != null)
                    TextButton.icon(
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Excluir'),
                      onPressed: () {
                        Navigator.pop(sheet);
                        onDelete();
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  },
);
