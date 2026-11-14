import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api_design.dart';
import '../modelos.dart';
import 'wireframe_tela.dart';

/// Lista dos wireframes: novo, importar o que voltou de outra IA, renomear, duplicar e excluir.
class GaleriaWireframes extends StatefulWidget {
  const GaleriaWireframes({super.key, required this.api});

  final ApiDesign api;

  @override
  State<GaleriaWireframes> createState() => _GaleriaWireframesState();
}

class _GaleriaWireframesState extends State<GaleriaWireframes> {
  late Future<List<ResumoQuadro>> _lista = widget.api.listarWireframes();

  void _recarregar() => setState(() => _lista = widget.api.listarWireframes());

  Future<void> _abrir(String id) async {
    await abrirTela<void>(context, (_) => AbrirWireframe(api: widget.api, id: id));
    _recarregar();
  }

  Future<void> _novo() async => _abrir((await widget.api.criarWireframe()).id);

  Future<void> _importar() async {
    final mensageiro = ScaffoldMessenger.of(context);
    final a = (await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['json', 'zip', 'md', 'txt'])).firstOrNull;
    if (a == null) return;
    try {
      final w = await widget.api.importarWireframe(a.name, await a.xFile.readAsBytes());
      _recarregar();
      await _abrir(w.id);
    } on ApiErro catch (e) {
      mensageiro.showSnackBar(SnackBar(content: Text('Não importou: ${e.mensagem}')));
    }
  }

  Future<void> _acao(String acao, ResumoQuadro w) async {
    switch (acao) {
      case 'renomear':
        final controle = TextEditingController(text: w.titulo);
        final titulo = await showDialog<String>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Nome do wireframe'),
            content: TextField(controller: controle, autofocus: true, onSubmitted: (v) => Navigator.pop(c, v)),
            actions: [FilledButton(onPressed: () => Navigator.pop(c, controle.text), child: const Text('Salvar'))],
          ),
        );
        controle.dispose();
        if (titulo == null || titulo.trim().isEmpty) return;
        await widget.api.editarWireframe(w.id, titulo: titulo.trim());
      case 'duplicar':
        await widget.api.duplicarWireframe(w.id);
      case 'excluir':
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('Excluir "${w.titulo}"?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Excluir')),
            ],
          ),
        );
        if (ok != true) return;
        await widget.api.excluirWireframe(w.id);
    }
    _recarregar();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Wireframes'),
      actions: [
        TextButton.icon(onPressed: _importar, icon: const Icon(Icons.smart_toy_outlined), label: const Text('Importar da IA')),
        IconButton(tooltip: 'Atualizar', onPressed: _recarregar, icon: const Icon(Icons.refresh)),
      ],
    ),
    floatingActionButton: FloatingActionButton.extended(onPressed: _novo, icon: const Icon(Icons.add), label: const Text('Novo wireframe')),
    body: FutureBuilder(
      future: _lista,
      builder: (context, s) {
        if (s.hasError) return Center(child: Text('Não carregou os wireframes: ${s.error}'));
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        final lista = s.data!;
        if (lista.isEmpty) return const Center(child: Text('Nenhum wireframe ainda. Crie o primeiro ou importe de uma IA.'));
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            for (final w in lista)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.web_outlined),
                  title: Text(w.titulo),
                  subtitle: Text('${w.paginas.length} telas · ${w.total} componentes'),
                  onTap: () => _abrir(w.id),
                  trailing: PopupMenuButton<String>(
                    onSelected: (a) => _acao(a, w),
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
