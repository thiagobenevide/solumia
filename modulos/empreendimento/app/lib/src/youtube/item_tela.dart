import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../telas/util.dart';
import 'api_youtube.dart';
import 'formulario.dart';

/// Campo de ligação → coleção onde a nota ligada mora (para abrir com um toque).
const _colecaoDoCampo = {'tema': 'temas', 'roteiro': 'roteiros', 'historia': 'historias', 'plano': 'planos'};

/// Um tema, história, roteiro, plano ou método: propriedades, ligações, corpo, edição e exclusão.
/// No tema, cria o roteiro e a história que faltam (já ligados).
class ItemTela extends StatefulWidget {
  const ItemTela({
    super.key,
    required this.api,
    required this.slug,
    required this.colecao,
    required this.id,
    required this.esquema,
  });

  final ApiYoutube api;
  final String slug;
  final String colecao;
  final String id;
  final Doc esquema;

  @override
  State<ItemTela> createState() => _ItemTelaState();
}

class _ItemTelaState extends State<ItemTela> {
  late Future<Doc> _item = _carregar();

  Future<Doc> _carregar() => widget.api.item(widget.slug, widget.colecao, widget.id);

  void _recarregar() => setState(() => _item = _carregar());

  Doc get _col => [
    for (final c in widget.esquema['colecoes'] as List)
      if (c['id'] == widget.colecao) c as Doc,
  ].first;

  List<Doc> get _campos => [for (final c in _col['campos'] as List) c as Doc];

  Future<void> _editar(Doc item) async {
    final r = await abrirTela<Doc>(context, (_) => FormularioNota(
          titulo: 'Editar ${'${_col['item']}'.toLowerCase()}',
          campos: _campos,
          valores: item['propriedades'] as Doc,
          tituloNota: '${item['titulo']}',
          tags: [for (final t in item['tags'] as List) '$t'],
          corpo: '${item['corpo']}',
        ));
    if (r == null || !mounted) return;
    await acaoComAviso(context, () async {
      await widget.api.editar(widget.slug, widget.colecao, widget.id, {
        'titulo': r['titulo'],
        'propriedades': r['campos'],
        'tags': r['tags'],
        'corpo': r['corpo'],
      });
      return 'Salvo';
    });
    _recarregar();
  }

  Future<void> _excluir(Doc item) async {
    if (!await confirmarExclusao(context, '${item['titulo']}') || !mounted) return;
    final nav = Navigator.of(context);
    try {
      await widget.api.excluir(widget.slug, widget.colecao, widget.id);
      nav.pop();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Falhou: $e')));
    }
  }

  Future<void> _derivar(String colecao) async {
    await acaoComAviso(context, () async {
      final novo = await widget.api.derivar(widget.slug, widget.id, colecao);
      return '${novo['titulo']} criado';
    });
    _recarregar();
  }

  void _abrirLigada(String campo, String id) {
    final colecao = _colecaoDoCampo[campo];
    if (colecao == null) return;
    abrirTela(context, (_) =>
            ItemTela(api: widget.api, slug: widget.slug, colecao: colecao, id: id, esquema: widget.esquema));
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
              IconButton(onPressed: () => _editar(item), icon: const Icon(Icons.edit_outlined), tooltip: 'Editar'),
              IconButton(onPressed: () => _excluir(item), icon: const Icon(Icons.delete_outline), tooltip: 'Excluir'),
            ],
          ],
        ),
        body: s.hasError
            ? ErroComRetry(erro: s.error!, tentar: _recarregar)
            : item == null
            ? const Center(child: CircularProgressIndicator())
            : _corpo(context, item),
      );
    },
  );

  Widget _corpo(BuildContext context, Doc item) {
    final props = item['propriedades'] as Doc;
    final saidas = [
      for (final x in item['saidas'] as List)
        if (_colecaoDoCampo.containsKey(x['tipo']) || x['tipo'] == 'canal') x as Doc,
    ];
    final ligados = {
      for (final x in saidas)
        if (x['id'] != null) x['tipo'],
    };
    final campos = [
      for (final c in _campos)
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
        if (saidas.isNotEmpty || widget.colecao == 'temas') ...[
          const Secao('Ligações'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final x in saidas)
                ActionChip(
                  avatar: Icon(x['id'] == null ? Icons.link_off : Icons.link, size: 16),
                  label: Text('${x['tipo']}: ${x['titulo']}'),
                  onPressed: x['id'] == null ? null : () => _abrirLigada('${x['tipo']}', '${x['id']}'),
                ),
              if (widget.colecao == 'temas' && !ligados.contains('historia'))
                OutlinedButton.icon(
                  onPressed: () => _derivar('historias'),
                  icon: const Icon(Icons.auto_stories_outlined),
                  label: const Text('Criar história'),
                ),
              if (widget.colecao == 'temas' && !ligados.contains('roteiro'))
                OutlinedButton.icon(
                  onPressed: () => _derivar('roteiros'),
                  icon: const Icon(Icons.description_outlined),
                  label: const Text('Criar roteiro'),
                ),
            ],
          ),
        ],
        if ((item['entradas'] as List).isNotEmpty) ...[
          const Secao('Citado por'),
          for (final e in item['entradas'] as List)
            ListTile(
              dense: true,
              leading: const Icon(Icons.subdirectory_arrow_left, size: 18),
              title: Text('${e['titulo']}'),
              subtitle: Text('${e['tipo']}'),
            ),
        ],
        const Secao('Conteúdo'),
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
