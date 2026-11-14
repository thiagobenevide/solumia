import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_eletronica.dart';
import '../cad/cad_tela.dart';
import '../cad/paineis.dart';
import '../modelos.dart';

/// Lista dos projetos: criar, abrir, renomear, duplicar e excluir.
class ProjetosTela extends StatefulWidget {
  const ProjetosTela({super.key, required this.api});

  final ApiEletronica api;

  @override
  State<ProjetosTela> createState() => _ProjetosTelaState();
}

class _ProjetosTelaState extends State<ProjetosTela> {
  late Future<List<ResumoProjeto>> _projetos = widget.api.listar();
  Future<Biblioteca>? _biblioteca;

  void _recarregar() => setState(() => _projetos = widget.api.listar());

  Future<void> _abrir(String id) async {
    final mensageiro = ScaffoldMessenger.of(context);
    try {
      final biblioteca = await (_biblioteca ??= widget.api.biblioteca());
      final projeto = await widget.api.obter(id);
      final faltam = {for (final c in projeto.componentes) c.simbolo}.where((s) => !biblioteca.porId.containsKey(s));
      if (faltam.isNotEmpty) biblioteca.adicionar(await widget.api.simbolos(faltam));
      if (!mounted) return;
      await abrirTela<void>(
        context,
        (_) => CadTela(api: widget.api, projeto: projeto, biblioteca: biblioteca),
        titulo: projeto.titulo,
        icone: Icons.memory_outlined,
      );
    } catch (e) {
      _biblioteca = null;
      mensageiro.showSnackBar(SnackBar(content: Text('Não abriu o projeto: $e')));
    }
    _recarregar();
  }

  Future<void> _novo() async {
    final titulo = await pedirTexto(context, 'Nome do projeto');
    if (titulo == null) return;
    final p = await widget.api.criar(titulo: titulo.trim());
    await _abrir(p.id);
  }

  Future<void> _acao(String acao, ResumoProjeto p) async {
    switch (acao) {
      case 'renomear':
        final titulo = await pedirTexto(context, 'Nome do projeto', inicial: p.titulo);
        if (titulo == null || titulo.trim().isEmpty) return;
        await widget.api.renomear(p.id, titulo.trim());
      case 'duplicar':
        await widget.api.duplicar(p.id);
      case 'excluir':
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('Excluir "${p.titulo}"?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Excluir')),
            ],
          ),
        );
        if (ok != true) return;
        await widget.api.excluir(p.id);
    }
    _recarregar();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Projetos de eletrônica'),
      actions: [IconButton(tooltip: 'Atualizar', onPressed: _recarregar, icon: const Icon(Icons.refresh))],
    ),
    floatingActionButton: FloatingActionButton.extended(onPressed: _novo, icon: const Icon(Icons.add), label: const Text('Novo projeto')),
    body: FutureBuilder(
      future: _projetos,
      builder: (context, s) {
        if (s.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 12,
              children: [
                Text('Não carregou os projetos: ${s.error}'),
                FilledButton(onPressed: _recarregar, child: const Text('Tentar de novo')),
              ],
            ),
          );
        }
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        final lista = s.data!;
        if (lista.isEmpty) return const Center(child: Text('Nenhum projeto ainda. Crie o primeiro circuito.'));
        return ListView.separated(
          padding: const EdgeInsets.only(bottom: 88),
          itemCount: lista.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final p = lista[i];
            final data = DateTime.tryParse(p.atualizado)?.toLocal();
            return ListTile(
              leading: const Icon(Icons.developer_board),
              title: Text(p.titulo),
              subtitle: Text([
                '${p.total} componente${p.total == 1 ? '' : 's'}',
                if (data != null) 'atualizado ${data.day.toString().padLeft(2, '0')}/${data.month.toString().padLeft(2, '0')} '
                    '${data.hour.toString().padLeft(2, '0')}:${data.minute.toString().padLeft(2, '0')}',
              ].join(' · ')),
              onTap: () => _abrir(p.id),
              trailing: PopupMenuButton<String>(
                onSelected: (a) => _acao(a, p),
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
