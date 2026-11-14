import 'package:flutter/material.dart';

import '../modelos.dart';

/// Diálogo de criar/editar tarefa. Devolve os campos para a API, ou null se cancelado.
Future<Map<String, dynamic>?> editarTarefa(BuildContext context, [Tarefa? tarefa]) =>
    showDialog<Map<String, dynamic>>(context: context, builder: (_) => _EditorTarefa(tarefa));

class _EditorTarefa extends StatefulWidget {
  const _EditorTarefa(this.tarefa);

  final Tarefa? tarefa;

  @override
  State<_EditorTarefa> createState() => _EditorTarefaState();
}

class _EditorTarefaState extends State<_EditorTarefa> {
  late final _titulo = TextEditingController(text: widget.tarefa?.titulo);
  late final _descricao = TextEditingController(text: widget.tarefa?.descricao);
  late final _tags = TextEditingController(text: widget.tarefa?.tags.join(', '));
  late String _prioridade = widget.tarefa?.prioridade ?? 'media';
  late DateTime? _prazo = widget.tarefa?.prazo;

  @override
  void dispose() {
    _titulo.dispose();
    _descricao.dispose();
    _tags.dispose();
    super.dispose();
  }

  Future<void> _escolherPrazo() async {
    final hoje = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _prazo ?? hoje,
      firstDate: DateTime(hoje.year - 1),
      lastDate: DateTime(hoje.year + 5),
    );
    if (d != null) setState(() => _prazo = d);
  }

  void _salvar() {
    if (_titulo.text.trim().isEmpty) return;
    final p = _prazo;
    Navigator.pop(context, {
      'titulo': _titulo.text.trim(),
      'descricao': _descricao.text.trim(),
      'prioridade': _prioridade,
      'tags': [for (final t in _tags.text.split(',')) if (t.trim().isNotEmpty) t.trim()],
      // vazio limpa o prazo no servidor
      'prazo': p == null ? '' : '${p.year}-${'${p.month}'.padLeft(2, '0')}-${'${p.day}'.padLeft(2, '0')}',
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.tarefa == null ? 'Nova tarefa' : 'Editar tarefa'),
    scrollable: true,
    content: SizedBox(
      width: 480,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          TextField(
            controller: _titulo,
            autofocus: widget.tarefa == null,
            decoration: const InputDecoration(labelText: 'Título', border: OutlineInputBorder()),
            onSubmitted: (_) => _salvar(),
          ),
          TextField(
            controller: _descricao,
            minLines: 2,
            maxLines: 6,
            decoration: const InputDecoration(labelText: 'Descrição', border: OutlineInputBorder()),
          ),
          SegmentedButton<String>(
            segments: [for (final MapEntry(:key, :value) in prioridades.entries) ButtonSegment(value: key, label: Text(value))],
            selected: {_prioridade},
            onSelectionChanged: (s) => setState(() => _prioridade = s.first),
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
                  label: Text(_prazo == null ? 'Sem prazo' : 'Prazo: ${_prazo!.day}/${_prazo!.month}/${_prazo!.year}'),
                  onPressed: _escolherPrazo,
                ),
              ),
              if (_prazo != null)
                IconButton(tooltip: 'Remover prazo', icon: const Icon(Icons.clear), onPressed: () => setState(() => _prazo = null)),
            ],
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(onPressed: _salvar, child: const Text('Salvar')),
    ],
  );
}
