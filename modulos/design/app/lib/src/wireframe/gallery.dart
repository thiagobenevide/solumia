import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../design_api.dart';
import '../models.dart';
import 'wireframe_screen.dart';

/// List of wireframes: new, import what came back from another AI, rename, duplicate and delete.
class WireframeGallery extends StatefulWidget {
  const WireframeGallery({super.key, required this.api});

  final ApiDesign api;

  @override
  State<WireframeGallery> createState() => _WireframeGalleryState();
}

class _WireframeGalleryState extends State<WireframeGallery> {
  late Future<List<BoardSummary>> _list = widget.api.listWireframes();

  void _reload() => setState(() => _list = widget.api.listWireframes());

  Future<void> _open(String id) async {
    await abrirTela<void>(context, (_) => OpenWireframe(api: widget.api, id: id));
    _reload();
  }

  Future<void> _new() async => _open((await widget.api.createWireframe()).id);

  Future<void> _import() async {
    final messenger = ScaffoldMessenger.of(context);
    final a = (await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['json', 'zip', 'md', 'txt'])).firstOrNull;
    if (a == null) return;
    try {
      final w = await widget.api.importWireframe(a.name, await a.xFile.readAsBytes());
      _reload();
      await _open(w.id);
    } on ApiErro catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Não importou: ${e.mensagem}')));
    }
  }

  Future<void> _act(String action, BoardSummary w) async {
    switch (action) {
      case 'renomear':
        final controle = TextEditingController(text: w.title);
        final title = await showDialog<String>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Nome do wireframe'),
            content: TextField(controller: controle, autofocus: true, onSubmitted: (v) => Navigator.pop(c, v)),
            actions: [FilledButton(onPressed: () => Navigator.pop(c, controle.text), child: const Text('Salvar'))],
          ),
        );
        controle.dispose();
        if (title == null || title.trim().isEmpty) return;
        await widget.api.editWireframe(w.id, title: title.trim());
      case 'duplicar':
        await widget.api.duplicateWireframe(w.id);
      case 'excluir':
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('Excluir "${w.title}"?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Excluir')),
            ],
          ),
        );
        if (ok != true) return;
        await widget.api.deleteWireframe(w.id);
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Wireframes'),
      actions: [
        TextButton.icon(onPressed: _import, icon: const Icon(Icons.smart_toy_outlined), label: const Text('Importar da IA')),
        IconButton(tooltip: 'Atualizar', onPressed: _reload, icon: const Icon(Icons.refresh)),
      ],
    ),
    floatingActionButton: FloatingActionButton.extended(onPressed: _new, icon: const Icon(Icons.add), label: const Text('Novo wireframe')),
    body: FutureBuilder(
      future: _list,
      builder: (context, s) {
        if (s.hasError) return Center(child: Text('Não carregou os wireframes: ${s.error}'));
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        final items = s.data!;
        if (items.isEmpty) return const Center(child: Text('Nenhum wireframe ainda. Crie o primeiro ou importe de uma IA.'));
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            for (final w in items)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.web_outlined),
                  title: Text(w.title),
                  subtitle: Text('${w.pages.length} telas · ${w.total} componentes'),
                  onTap: () => _open(w.id),
                  trailing: PopupMenuButton<String>(
                    onSelected: (a) => _act(a, w),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'renomear', child: Text('Renomear')),
                      PopupMenuItem(value: 'duplicar', child: Text('Duplicar')),
                      PopupMenuItem(value: 'excluir', child: Text('Excluir')),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );
}
