import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../electronics_api.dart';
import '../cad/cad_screen.dart';
import '../cad/panels.dart';
import '../models.dart';

/// Project list: create, open, rename, duplicate and delete.
class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({super.key, required this.api});

  final ElectronicsApi api;

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  late Future<List<ProjectSummary>> _projects = widget.api.list();
  Future<Library>? _library;

  void _reload() => setState(() => _projects = widget.api.list());

  Future<void> _open(String id) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final library = await (_library ??= widget.api.library());
      final project = await widget.api.fetch(id);
      final missingCount = {for (final c in project.components) c.symbol}.where((s) => !library.byId.containsKey(s));
      if (missingCount.isNotEmpty) library.adicionar(await widget.api.symbols(missingCount));
      if (!mounted) return;
      await abrirTela<void>(
        context,
        (_) => CadScreen(api: widget.api, project: project, library: library),
        titulo: project.title,
        icone: Icons.memory_outlined,
      );
    } catch (e) {
      _library = null;
      messenger.showSnackBar(SnackBar(content: Text('Não abriu o projeto: $e')));
    }
    _reload();
  }

  Future<void> _new() async {
    final title = await askText(context, 'Nome do projeto');
    if (title == null) return;
    final p = await widget.api.create(title: title.trim());
    await _open(p.id);
  }

  Future<void> _act(String action, ProjectSummary p) async {
    switch (action) {
      case 'renomear':
        final title = await askText(context, 'Nome do projeto', initial: p.title);
        if (title == null || title.trim().isEmpty) return;
        await widget.api.rename(p.id, title.trim());
      case 'duplicar':
        await widget.api.duplicate(p.id);
      case 'excluir':
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('Excluir "${p.title}"?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Excluir')),
            ],
          ),
        );
        if (ok != true) return;
        await widget.api.delete(p.id);
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Projetos de eletrônica'),
      actions: [IconButton(tooltip: 'Atualizar', onPressed: _reload, icon: const Icon(Icons.refresh))],
    ),
    floatingActionButton: FloatingActionButton.extended(onPressed: _new, icon: const Icon(Icons.add), label: const Text('Novo projeto')),
    body: FutureBuilder(
      future: _projects,
      builder: (context, s) {
        if (s.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 12,
              children: [
                Text('Não carregou os projetos: ${s.error}'),
                FilledButton(onPressed: _reload, child: const Text('Tentar de novo')),
              ],
            ),
          );
        }
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        final items = s.data!;
        if (items.isEmpty) return const Center(child: Text('Nenhum projeto ainda. Crie o primeiro circuito.'));
        return ListView.separated(
          padding: const EdgeInsets.only(bottom: 88),
          itemCount: items.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final p = items[i];
            final data = DateTime.tryParse(p.updated)?.toLocal();
            return ListTile(
              leading: const Icon(Icons.developer_board),
              title: Text(p.title),
              subtitle: Text([
                '${p.total} componente${p.total == 1 ? '' : 's'}',
                if (data != null) 'atualizado ${data.day.toString().padLeft(2, '0')}/${data.month.toString().padLeft(2, '0')} '
                    '${data.hour.toString().padLeft(2, '0')}:${data.minute.toString().padLeft(2, '0')}',
              ].join(' · ')),
              onTap: () => _open(p.id),
              trailing: PopupMenuButton<String>(
                onSelected: (a) => _act(a, p),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'renomear', child: Text('Renomear')),
                  PopupMenuItem(value: 'duplicar', child: Text('Duplicar')),
                  PopupMenuItem(value: 'excluir', child: Text('Excluir')),
                ],
              ),
            );
          },
        );
      },
    ),
  );
}
