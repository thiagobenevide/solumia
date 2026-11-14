import 'package:flutter/material.dart';

import '../models.dart';

/// Dialog to create/edit a task. Returns the fields for the API, or null if cancelled.
Future<Map<String, dynamic>?> editTask(BuildContext context, [Task? task]) =>
    showDialog<Map<String, dynamic>>(context: context, builder: (_) => _TaskEditor(task));

class _TaskEditor extends StatefulWidget {
  const _TaskEditor(this.task);

  final Task? task;

  @override
  State<_TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends State<_TaskEditor> {
  late final _title = TextEditingController(text: widget.task?.title);
  late final _description = TextEditingController(text: widget.task?.description);
  late final _tags = TextEditingController(text: widget.task?.tags.join(', '));
  late String _priority = widget.task?.priority ?? 'media';
  late DateTime? _due = widget.task?.due;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _tags.dispose();
    super.dispose();
  }

  Future<void> _pickDue() async {
    final today = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _due ?? today,
      firstDate: DateTime(today.year - 1),
      lastDate: DateTime(today.year + 5),
    );
    if (d != null) setState(() => _due = d);
  }

  void _save() {
    if (_title.text.trim().isEmpty) return;
    final p = _due;
    Navigator.pop(context, {
      'titulo': _title.text.trim(),
      'descricao': _description.text.trim(),
      'prioridade': _priority,
      'tags': [for (final t in _tags.text.split(',')) if (t.trim().isNotEmpty) t.trim()],
      // empty clears the due date on the server
      'prazo': p == null ? '' : '${p.year}-${'${p.month}'.padLeft(2, '0')}-${'${p.day}'.padLeft(2, '0')}',
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.task == null ? 'Nova tarefa' : 'Editar tarefa'),
    scrollable: true,
    content: SizedBox(
      width: 480,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          TextField(
            controller: _title,
            autofocus: widget.task == null,
            decoration: const InputDecoration(labelText: 'Título', border: OutlineInputBorder()),
            onSubmitted: (_) => _save(),
          ),
          TextField(
            controller: _description,
            minLines: 2,
            maxLines: 6,
            decoration: const InputDecoration(labelText: 'Descrição', border: OutlineInputBorder()),
          ),
          SegmentedButton<String>(
            segments: [for (final MapEntry(:key, :value) in priorities.entries) ButtonSegment(value: key, label: Text(value))],
            selected: {_priority},
            onSelectionChanged: (s) => setState(() => _priority = s.first),
          ),
          TextField(
            controller: _tags,
            decoration: const InputDecoration(labelText: 'Tags (separadas por vírgula)', border: OutlineInputBorder()),
          ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.event_outlined),
                  label: Text(_due == null ? 'Sem prazo' : 'Prazo: ${_due!.day}/${_due!.month}/${_due!.year}'),
                  onPressed: _pickDue,
                ),
              ),
              if (_due != null)
                IconButton(tooltip: 'Remover prazo', icon: const Icon(Icons.clear), onPressed: () => setState(() => _due = null)),
            ],
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(onPressed: _save, child: const Text('Salvar')),
    ],
  );
}
