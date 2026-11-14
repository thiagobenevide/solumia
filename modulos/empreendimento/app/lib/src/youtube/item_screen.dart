import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../screens/util.dart';
import 'youtube_api.dart';
import 'form.dart';

/// Link field → collection where the linked note lives (to open it with one tap).
const _collectionField = {'tema': 'temas', 'roteiro': 'roteiros', 'historia': 'historias', 'plano': 'planos'};

/// One theme, story, script, plan or method: properties, links, body, editing and deletion.
/// On a theme, creates the missing script and story (already linked).
class ItemScreen extends StatefulWidget {
  const ItemScreen({
    super.key,
    required this.api,
    required this.slug,
    required this.collection,
    required this.id,
    required this.schema,
  });

  final ApiYoutube api;
  final String slug;
  final String collection;
  final String id;
  final Doc schema;

  @override
  State<ItemScreen> createState() => _ItemScreenState();
}

class _ItemScreenState extends State<ItemScreen> {
  late Future<Doc> _item = _load();

  Future<Doc> _load() => widget.api.item(widget.slug, widget.collection, widget.id);

  void _recarregar() => setState(() => _item = _load());

  Doc get _col => [
    for (final c in widget.schema['colecoes'] as List)
      if (c['id'] == widget.collection) c as Doc,
  ].first;

  List<Doc> get _fields => [for (final c in _col['campos'] as List) c as Doc];

  Future<void> _edit(Doc item) async {
    final r = await abrirTela<Doc>(context, (_) => NoteForm(
          titulo: 'Editar ${'${_col['item']}'.toLowerCase()}',
          campos: _fields,
          values: item['propriedades'] as Doc,
          titleNote: '${item['titulo']}',
          tags: [for (final t in item['tags'] as List) '$t'],
          corpo: '${item['corpo']}',
        ));
    if (r == null || !mounted) return;
    await actionWithWarning(context, () async {
      await widget.api.edit(widget.slug, widget.collection, widget.id, {
        'titulo': r['titulo'],
        'propriedades': r['campos'],
        'tags': r['tags'],
        'corpo': r['corpo'],
      });
      return 'Salvo';
    });
    _recarregar();
  }

  Future<void> _delete(Doc item) async {
    if (!await confirmDeletion(context, '${item['titulo']}') || !mounted) return;
    final nav = Navigator.of(context);
    try {
      await widget.api.delete(widget.slug, widget.collection, widget.id);
      nav.pop();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Falhou: $e')));
    }
  }

  Future<void> _derive(String collection) async {
    await actionWithWarning(context, () async {
      final newItem = await widget.api.derive(widget.slug, widget.id, collection);
      return '${newItem['titulo']} criado';
    });
    _recarregar();
  }

  void _openOn(String campo, String id) {
    final collection = _collectionField[campo];
    if (collection == null) return;
    abrirTela(context, (_) =>
            ItemScreen(api: widget.api, slug: widget.slug, collection: collection, id: id, schema: widget.schema));
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _item,
    builder: (context, s) {
      final item = s.data;
      return Scaffold(
        appBar: AppBar(
          title: Text(item == null ? '${_col['item']}' : '${item['titulo']}'),
          actions: [
            if (item != null) ...[
              IconButton(onPressed: () => _edit(item), icon: const Icon(Icons.edit_outlined), tooltip: 'Editar'),
              IconButton(onPressed: () => _delete(item), icon: const Icon(Icons.delete_outline), tooltip: 'Excluir'),
            ],
          ],
        ),
        body: s.hasError
            ? ErroComRetry(erro: s.error!, tentar: _recarregar)
            : item == null
            ? const Center(child: CircularProgressIndicator())
            : _body(context, item),
      );
    },
  );

  Widget _body(BuildContext context, Doc item) {
    final props = item['propriedades'] as Doc;
    final outputs = [
      for (final x in item['saidas'] as List)
        if (_collectionField.containsKey(x['tipo']) || x['tipo'] == 'canal') x as Doc,
    ];
    final ligados = {
      for (final x in outputs)
        if (x['id'] != null) x['tipo'],
    };
    final campos = [
      for (final c in _fields)
        if (c['tipo'] != 'link' && props[c['nome']] != null) '${c['rotulo']}: ${props[c['nome']]}',
    ];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in campos) Chip(label: Text(c)),
            for (final t in item['tags'] as List) Chip(label: Text('#$t')),
          ],
        ),
        if (outputs.isNotEmpty || widget.collection == 'temas') ...[
          const Section('Ligações'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final x in outputs)
                ActionChip(
                  avatar: Icon(x['id'] == null ? Icons.link_off : Icons.link, size: 16),
                  label: Text('${x['tipo']}: ${x['titulo']}'),
                  onPressed: x['id'] == null ? null : () => _openOn('${x['tipo']}', '${x['id']}'),
                ),
              if (widget.collection == 'temas' && !ligados.contains('historia'))
                OutlinedButton.icon(
                  onPressed: () => _derive('historias'),
                  icon: const Icon(Icons.auto_stories_outlined),
                  label: const Text('Criar história'),
                ),
              if (widget.collection == 'temas' && !ligados.contains('roteiro'))
                OutlinedButton.icon(
                  onPressed: () => _derive('roteiros'),
                  icon: const Icon(Icons.description_outlined),
                  label: const Text('Criar roteiro'),
                ),
            ],
          ),
        ],
        if ((item['entradas'] as List).isNotEmpty) ...[
          const Section('Citado por'),
          for (final e in item['entradas'] as List)
            ListTile(
              dense: true,
              leading: const Icon(Icons.subdirectory_arrow_left, size: 18),
              title: Text('${e['titulo']}'),
              subtitle: Text('${e['tipo']}'),
            ),
        ],
        const Section('Conteúdo'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SelectionArea(child: VisualizadorMarkdown(texto: '${item['corpo']}')),
          ),
        ),
      ],
    );
  }
}
