import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import 'youtube_api.dart';

/// Form of a YouTube note (channel or collection item): title, schema fields
/// (`texto`, `numero`, `opcoes`, `link`), tags and Markdown body. On save it returns
/// `{titulo, tags, corpo, campos: {nome: valor}}`; an empty field goes as `''` (deletes it on the backend).
class NoteForm extends StatefulWidget {
  const NoteForm({
    super.key,
    required this.titulo,
    required this.campos,
    this.values = const {},
    this.titleNote = '',
    this.tags = const [],
    this.corpo = '',
  });

  final String titulo;
  final List<Doc> campos;
  final Doc values;
  final String titleNote;
  final List<String> tags;
  final String corpo;

  @override
  State<NoteForm> createState() => _NoteFormState();
}

class _NoteFormState extends State<NoteForm> {
  final _form = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.titleNote);
  late final _tags = TextEditingController(text: widget.tags.join(', '));
  late final _body = ControladorMarkdown(text: widget.corpo);
  late final Map<String, TextEditingController> _texts = {
    for (final c in widget.campos)
      if (c['tipo'] != 'opcoes') c['nome'] as String: TextEditingController(text: _value(c['nome'] as String)),
  };
  late final Map<String, String> _options = {
    for (final c in widget.campos)
      if (c['tipo'] == 'opcoes') c['nome'] as String: _value(c['nome'] as String),
  };

  /// Links arrive as `[[Título]]`; the field only keeps the title.
  String _value(String nome) {
    final v = '${widget.values[nome] ?? ''}';
    final m = RegExp(r'^\[\[([^\]|#]+)').firstMatch(v);
    return m?.group(1)?.trim() ?? v;
  }

  @override
  void dispose() {
    for (final c in [_title, _tags, _body, ..._texts.values]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    Navigator.pop(context, {
      'titulo': _title.text.trim(),
      'tags': [
        for (final t in _tags.text.split(','))
          if (t.trim().isNotEmpty) t.trim(),
      ],
      'corpo': _body.text,
      'campos': {for (final e in _texts.entries) e.key: e.value.text.trim(), ..._options},
    });
  }

  Widget _field(Doc c) {
    final nome = c['nome'] as String;
    final label = c['rotulo'] as String;
    final kind = c['tipo'] as String;
    if (kind == 'opcoes') {
      final options = [for (final o in c['opcoes'] as List) '$o'];
      final current = _options[nome]!;
      return DropdownButtonFormField<String>(
        initialValue: current,
        decoration: InputDecoration(labelText: label),
        items: [
          const DropdownMenuItem(value: '', child: Text('—')),
          for (final o in {...options, if (current.isNotEmpty) current}) DropdownMenuItem(value: o, child: Text(o)),
        ],
        onChanged: (v) => _options[nome] = v ?? '',
      );
    }
    return TextFormField(
      controller: _texts[nome],
      keyboardType: kind == 'numero' ? TextInputType.number : null,
      decoration: InputDecoration(
        labelText: label,
        helperText: kind == 'link' ? 'Título exato da nota ligada' : null,
        prefixIcon: kind == 'link' ? const Icon(Icons.link, size: 18) : null,
      ),
      validator: (v) => kind == 'numero' && (v ?? '').trim().isNotEmpty && int.tryParse(v!.trim()) == null
          ? 'Use um número inteiro'
          : null,
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.titulo),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: FilledButton.icon(onPressed: _save, icon: const Icon(Icons.save_outlined), label: const Text('Salvar')),
        ),
      ],
    ),
    body: Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextFormField(
            controller: _title,
            autofocus: widget.titleNote.isEmpty,
            decoration: const InputDecoration(labelText: 'Título'),
            validator: (v) => (v ?? '').trim().isEmpty ? 'Obrigatório' : null,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [for (final c in widget.campos) SizedBox(width: 280, child: _field(c))],
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _tags,
            decoration: const InputDecoration(labelText: 'Tags (separadas por vírgula)'),
          ),
          const SizedBox(height: 12),
          CampoMarkdown(controle: _body, dica: 'Conteúdo', minLinhas: 16),
        ],
      ),
    ),
  );
}

/// Asks before deleting; `true` if confirmed.
Future<bool> confirmDeletion(BuildContext context, String oque) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Excluir?'),
        content: Text('$oque será apagado do cofre de notas.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Excluir')),
        ],
      ),
    ) ??
    false;
