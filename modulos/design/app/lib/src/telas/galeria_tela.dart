import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api_design.dart';
import '../cache.dart';
import '../modelos.dart';
import '../caderno/caderno_tela.dart';
import '../quadro/quadro_tela.dart';

/// Lista dos quadros com miniatura: criar, abrir, renomear, duplicar e excluir. Sem rede, mostra os
/// quadros guardados no aparelho. Com uma `api.cadernos`, é a estante dos cadernos.
class GaleriaTela extends StatefulWidget {
  const GaleriaTela({super.key, required this.api});

  final ApiDesign api;

  bool get caderno => api.ehCaderno;

  @override
  State<GaleriaTela> createState() => _GaleriaTelaState();
}

class _GaleriaTelaState extends State<GaleriaTela> {
  late final Future<CacheQuadros> _cache = CacheQuadros.abrir(prefixo: widget.caderno ? 'design.caderno.' : 'design.quadro.');
  late Future<(List<ResumoQuadro>, bool)> _quadros = _carregar();
  final Map<String, (int, Future<Uint8List>)> _miniaturas = {};

  /// (quadros, offline?)
  Future<(List<ResumoQuadro>, bool)> _carregar() async {
    final cache = await _cache;
    try {
      return (await widget.api.listar(), false);
    } catch (_) {
      final locais = cache.resumos();
      if (locais.isEmpty) rethrow;
      return (locais, true);
    }
  }

  void _recarregar() => setState(() { _quadros = _carregar(); });

  // Uma busca por versão do quadro: a grade não baixa de novo a cada rebuild.
  Future<Uint8List>? _miniatura(ResumoQuadro q, bool offline) {
    if (!q.miniatura || offline) return null;
    final atual = _miniaturas[q.id];
    if (atual != null && atual.$1 == q.versao) return atual.$2;
    final nova = widget.api.miniatura(q.id);
    _miniaturas[q.id] = (q.versao, nova);
    return nova;
  }

  Future<void> _abrir(String id) async {
    final cache = await _cache;
    if (!mounted) return;
    await abrirTela<void>(
      context,
      (_) => widget.caderno
          ? AbrirCaderno(api: widget.api, cache: cache, id: id)
          : AbrirQuadro(api: widget.api, cache: cache, id: id),
    );
    _recarregar();
  }

  /// Abre um `.drawio`/`.xml` do draw.io como quadro novo (todas as páginas viram abas).
  Future<void> _importarDrawio() async {
    final mensageiro = ScaffoldMessenger.of(context);
    final a = (await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['drawio', 'xml'])).firstOrNull;
    if (a == null) return;
    try {
      final q = await widget.api.importarDrawio(a.name, await a.xFile.readAsBytes());
      _recarregar();
      await _abrir(q.id);
    } on ApiErro catch (e) {
      mensageiro.showSnackBar(SnackBar(content: Text('Não importou: ${e.mensagem}')));
    }
  }

  Future<void> _novo() async {
    final q = await widget.api.criar();
    await _abrir(q.id);
  }

  Future<void> _acao(String acao, ResumoQuadro q) async {
    switch (acao) {
      case 'renomear':
        final controle = TextEditingController(text: q.titulo);
        final titulo = await showDialog<String>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(widget.caderno ? 'Nome do caderno' : 'Nome do quadro'),
            content: TextField(controller: controle, autofocus: true, onSubmitted: (v) => Navigator.pop(c, v)),
            actions: [FilledButton(onPressed: () => Navigator.pop(c, controle.text), child: const Text('Salvar'))],
          ),
        );
        controle.dispose();
        if (titulo == null || titulo.trim().isEmpty) return;
        await widget.api.editar(q.id, titulo: titulo.trim());
      case 'duplicar':
        await widget.api.duplicar(q.id);
      case 'excluir':
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('Excluir "${q.titulo}"?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Excluir')),
            ],
          ),
        );
        if (ok != true) return;
        await widget.api.excluir(q.id);
        await (await _cache).remover(q.id);
    }
    _recarregar();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.caderno ? 'Cadernos' : 'Fluxogramas'),
      actions: [
        if (!widget.caderno)
          TextButton.icon(onPressed: _importarDrawio, icon: const Icon(Icons.file_open_outlined), label: const Text('Importar draw.io')),
        IconButton(tooltip: 'Atualizar', onPressed: _recarregar, icon: const Icon(Icons.refresh)),
      ],
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _novo,
      icon: const Icon(Icons.add),
      label: Text(widget.caderno ? 'Novo caderno' : 'Novo fluxograma'),
    ),
    body: FutureBuilder(
      future: _quadros,
      builder: (context, s) {
        if (s.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 12,
              children: [
                Text('Não carregou os quadros: ${s.error}'),
                FilledButton(onPressed: _recarregar, child: const Text('Tentar de novo')),
              ],
            ),
          );
        }
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        final (quadros, offline) = s.data!;
        if (quadros.isEmpty) {
          return Center(child: Text('Nenhum ${widget.caderno ? 'caderno' : 'quadro'} ainda. Crie o primeiro.'));
        }
        final grade = GridView.extent(
          maxCrossAxisExtent: 260,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.15,
          children: [
            for (final q in quadros)
              _Cartao(
                q,
                miniatura: _miniatura(q, offline),
                aoAbrir: () => _abrir(q.id),
                aoEscolher: offline ? null : (a) => _acao(a, q),
              ),
          ],
        );
        if (!offline) return grade;
        return Column(
          children: [
            MaterialBanner(
              content: const Text('Sem conexão: mostrando os quadros guardados neste aparelho.'),
              actions: [TextButton(onPressed: _recarregar, child: const Text('Tentar de novo'))],
            ),
            Expanded(child: grade),
          ],
        );
      },
    ),
  );
}

class _Cartao extends StatelessWidget {
  const _Cartao(this.q, {required this.miniatura, required this.aoAbrir, required this.aoEscolher});

  final ResumoQuadro q;
  final Future<Uint8List>? miniatura;
  final VoidCallback aoAbrir;
  final void Function(String)? aoEscolher;

  static IconData _icone(Fundo f) => switch (f) {
    Fundo.liso => Icons.crop_landscape,
    Fundo.pontos => Icons.grain,
    Fundo.grade => Icons.grid_on,
    Fundo.linhas => Icons.format_align_justify,
  };

  @override
  Widget build(BuildContext context) {
    final data = q.atualizado;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: aoAbrir,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: FutureBuilder(
                future: miniatura,
                builder: (context, s) => s.hasData
                    ? Image.memory(s.data!, fit: BoxFit.cover, gaplessPlayback: true)
                    : ColoredBox(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        child: Icon(_icone(q.fundo), size: 40, color: Theme.of(context).colorScheme.outline),
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
                          q.titulo,
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
                  if (aoEscolher != null)
                    PopupMenuButton<String>(
                      onSelected: aoEscolher,
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
