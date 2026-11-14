import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import 'api_youtube.dart';

/// Formulário de uma nota do YouTube (canal ou item de coleção): título, campos do esquema
/// (`texto`, `numero`, `opcoes`, `link`), tags e corpo em Markdown. Devolve, ao salvar,
/// `{titulo, tags, corpo, campos: {nome: valor}}`; campo vazio vai como `''` (apaga no backend).
class FormularioNota extends StatefulWidget {
  const FormularioNota({
    super.key,
    required this.titulo,
    required this.campos,
    this.valores = const {},
    this.tituloNota = '',
    this.tags = const [],
    this.corpo = '',
  });

  final String titulo;
  final List<Doc> campos;
  final Doc valores;
  final String tituloNota;
  final List<String> tags;
  final String corpo;

  @override
  State<FormularioNota> createState() => _FormularioNotaState();
}

class _FormularioNotaState extends State<FormularioNota> {
  final _form = GlobalKey<FormState>();
  late final _titulo = TextEditingController(text: widget.tituloNota);
  late final _tags = TextEditingController(text: widget.tags.join(', '));
  late final _corpo = ControladorMarkdown(text: widget.corpo);
  late final Map<String, TextEditingController> _textos = {
    for (final c in widget.campos)
      if (c['tipo'] != 'opcoes') c['nome'] as String: TextEditingController(text: _valor(c['nome'] as String)),
  };
  late final Map<String, String> _opcoes = {
    for (final c in widget.campos)
      if (c['tipo'] == 'opcoes') c['nome'] as String: _valor(c['nome'] as String),
  };

  /// Links chegam como `[[Título]]`; no campo fica só o título.
  String _valor(String nome) {
    final v = '${widget.valores[nome] ?? ''}';
    final m = RegExp(r'^\[\[([^\]|#]+)').firstMatch(v);
    return m?.group(1)?.trim() ?? v;
  }

  @override
  void dispose() {
    for (final c in [_titulo, _tags, _corpo, ..._textos.values]) {
      c.dispose();
    }
    super.dispose();
  }

  void _salvar() {
    if (!_form.currentState!.validate()) return;
    Navigator.pop(context, {
      'titulo': _titulo.text.trim(),
      'tags': [
        for (final t in _tags.text.split(','))
          if (t.trim().isNotEmpty) t.trim(),
      ],
      'corpo': _corpo.text,
      'campos': {for (final e in _textos.entries) e.key: e.value.text.trim(), ..._opcoes},
    });
  }

  Widget _campo(Doc c) {
    final nome = c['nome'] as String;
    final rotulo = c['rotulo'] as String;
    final tipo = c['tipo'] as String;
    if (tipo == 'opcoes') {
      final opcoes = [for (final o in c['opcoes'] as List) '$o'];
      final atual = _opcoes[nome]!;
      return DropdownButtonFormField<String>(
        initialValue: atual,
        decoration: InputDecoration(labelText: rotulo),
        items: [
          const DropdownMenuItem(value: '', child: Text('—')),
          for (final o in {...opcoes, if (atual.isNotEmpty) atual}) DropdownMenuItem(value: o, child: Text(o)),
        ],
        onChanged: (v) => _opcoes[nome] = v ?? '',
      );
    }
    return TextFormField(
      controller: _textos[nome],
      keyboardType: tipo == 'numero' ? TextInputType.number : null,
      decoration: InputDecoration(
        labelText: rotulo,
        helperText: tipo == 'link' ? 'Título exato da nota ligada' : null,
        prefixIcon: tipo == 'link' ? const Icon(Icons.link, size: 18) : null,
      ),
      validator: (v) => tipo == 'numero' && (v ?? '').trim().isNotEmpty && int.tryParse(v!.trim()) == null
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
          child: FilledButton.icon(onPressed: _salvar, icon: const Icon(Icons.save_outlined), label: const Text('Salvar')),
        ),
      ],
    ),
    body: Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextFormField(
            controller: _titulo,
            autofocus: widget.tituloNota.isEmpty,
            decoration: const InputDecoration(labelText: 'Título'),
            validator: (v) => (v ?? '').trim().isEmpty ? 'Obrigatório' : null,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [for (final c in widget.campos) SizedBox(width: 280, child: _campo(c))],
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _tags,
            decoration: const InputDecoration(labelText: 'Tags (separadas por vírgula)'),
          ),
          const SizedBox(height: 12),
          CampoMarkdown(controle: _corpo, dica: 'Conteúdo', minLinhas: 16),
        ],
      ),
    ),
  );
}

/// Pergunta antes de excluir; `true` se confirmou.
Future<bool> confirmarExclusao(BuildContext context, String oque) async =>
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
