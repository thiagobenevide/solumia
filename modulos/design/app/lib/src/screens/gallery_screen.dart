import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../design_api.dart';
import '../cache.dart';
import '../models.dart';
import '../notebook/notebook_screen.dart';
import '../board/board_screen.dart';

/// List of boards with thumbnail: create, open, rename, duplicate and delete. Without network, shows the
/// boards stored on the device. With an `api.cadernos`, it is the notebooks shelf.
class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key, required this.api});

  final ApiDesign api;

  bool get notebook => api.isNotebook;

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  late final Future<BoardCache> _cache = BoardCache.open(prefix: widget.notebook ? 'design.caderno.' : 'design.quadro.');
  late Future<(List<BoardSummary>, bool)> _boards = _load();
  final Map<String, (int, Future<Uint8List>)> _thumbnails = {};

  /// (quadros, offline?)
  Future<(List<BoardSummary>, bool)> _load() async {
    final cache = await _cache;
    try {
      return (await widget.api.list(), false);
    } catch (_) {
      final localItems = cache.summaries();
      if (localItems.isEmpty) rethrow;
      return (localItems, true);
    }
  }

  void _reload() => setState(() { _boards = _load(); });

  // One fetch per board version: the grid does not download again on every rebuild.
  Future<Uint8List>? _thumbnail(BoardSummary q, bool offline) {
    if (!q.thumbnail || offline) return null;
    final current = _thumbnails[q.id];
    if (current != null && current.$1 == q.version) return current.$2;
    final nova = widget.api.thumbnail(q.id);
    _thumbnails[q.id] = (q.version, nova);
    return nova;
  }

  Future<void> _open(String id) async {
    final cache = await _cache;
    if (!mounted) return;
    await abrirTela<void>(
      context,
      (_) => widget.notebook
          ? OpenNotebook(api: widget.api, cache: cache, id: id)
          : OpenBoard(api: widget.api, cache: cache, id: id),
    );
    _reload();
  }

  /// Opens a draw.io `.drawio`/`.xml` as a new board (all pages become tabs).
  Future<void> _importDrawio() async {
    final messenger = ScaffoldMessenger.of(context);
    final a = (await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['drawio', 'xml'])).firstOrNull;
    if (a == null) return;
    try {
      final q = await widget.api.importDrawio(a.name, await a.xFile.readAsBytes());
      _reload();
      await _open(q.id);
    } on ApiErro catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Não importou: ${e.mensagem}')));
    }
  }

  Future<void> _new() async {
    final q = await widget.api.create();
    await _open(q.id);
  }

  Future<void> _act(String action, BoardSummary q) async {
    switch (action) {
      case 'renomear':
        final controle = TextEditingController(text: q.title);
        final title = await showDialog<String>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(widget.notebook ? 'Nome do caderno' : 'Nome do quadro'),
            content: TextField(controller: controle, autofocus: true, onSubmitted: (v) => Navigator.pop(c, v)),
            actions: [FilledButton(onPressed: () => Navigator.pop(c, controle.text), child: const Text('Salvar'))],
          ),
        );
        controle.dispose();
        if (title == null || title.trim().isEmpty) return;
        await widget.api.edit(q.id, title: title.trim());
      case 'duplicar':
        await widget.api.duplicate(q.id);
      case 'excluir':
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('Excluir "${q.title}"?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Excluir')),
            ],
          ),
        );
        if (ok != true) return;
        await widget.api.delete(q.id);
        await (await _cache).remover(q.id);
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.notebook ? 'Cadernos' : 'Fluxogramas'),
      actions: [
        if (!widget.notebook)
          TextButton.icon(onPressed: _importDrawio, icon: const Icon(Icons.file_open_outlined), label: const Text('Importar draw.io')),
        IconButton(tooltip: 'Atualizar', onPressed: _reload, icon: const Icon(Icons.refresh)),
      ],
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _new,
      icon: const Icon(Icons.add),
      label: Text(widget.notebook ? 'Novo caderno' : 'Novo fluxograma'),
    ),
    body: FutureBuilder(
      future: _boards,
      builder: (context, s) {
        if (s.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 12,
              children: [
                Text('Não carregou os quadros: ${s.error}'),
                FilledButton(onPressed: _reload, child: const Text('Tentar de novo')),
              ],
            ),
          );
        }
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        final (boards, offline) = s.data!;
        if (boards.isEmpty) {
          return Center(child: Text('Nenhum ${widget.notebook ? 'caderno' : 'quadro'} ainda. Crie o primeiro.'));
        }
        final grade = GridView.extent(
          maxCrossAxisExtent: 260,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.15,
          children: [
            for (final q in boards)
              _Card(
                q,
                thumbnail: _thumbnail(q, offline),
                onOpen: () => _open(q.id),
                onPick: offline ? null : (a) => _act(a, q),
              ),
          ],
        );
        if (!offline) return grade;
        return Column(
          children: [
            MaterialBanner(
              content: const Text('Sem conexão: mostrando os quadros guardados neste aparelho.'),
              actions: [TextButton(onPressed: _reload, child: const Text('Tentar de novo'))],
            ),
            Expanded(child: grade),
          ],
        );
      },
    ),
  );
}

class _Card extends StatelessWidget {
  const _Card(this.q, {required this.thumbnail, required this.onOpen, required this.onPick});

  final BoardSummary q;
  final Future<Uint8List>? thumbnail;
  final VoidCallback onOpen;
  final void Function(String)? onPick;

  static IconData _icon(Background f) => switch (f) {
    Background.liso => Icons.crop_landscape,
    Background.pontos => Icons.grain,
    Background.grade => Icons.grid_on,
    Background.linhas => Icons.format_align_justify,
  };

  @override
  Widget build(BuildContext context) {
    final data = q.updated;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: FutureBuilder(
                future: thumbnail,
                builder: (context, s) => s.hasData
                    ? Image.memory(s.data!, fit: BoxFit.cover, gaplessPlayback: true)
                    : ColoredBox(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        child: Icon(_icon(q.background), size: 40, color: Theme.of(context).colorScheme.outline),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 0, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          q.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        Text(
                          '${q.total} elementos'
                          '${data == null ? '' : ' · ${data.day.toString().padLeft(2, '0')}/${data.month.toString().padLeft(2, '0')}'}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (onPick != null)
                    PopupMenuButton<String>(
                      onSelected: onPick,
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'renomear', child: Text('Renomear')),
                        PopupMenuItem(value: 'duplicar', child: Text('Duplicar')),
                        PopupMenuItem(value: 'excluir', child: Text('Excluir')),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
