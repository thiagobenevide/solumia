import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../telas/util.dart';
import 'api_youtube.dart';
import 'formulario.dart';
import 'item_tela.dart';
import 'youtube_aba.dart';

/// Um canal: aba "Gerência" (nota do canal + contagens) e uma aba por coleção do esquema.
class CanalTela extends StatefulWidget {
  const CanalTela({super.key, required this.api, required this.slug, required this.esquema});

  final ApiYoutube api;
  final String slug;
  final Doc esquema;

  @override
  State<CanalTela> createState() => _CanalTelaState();
}

class _CanalTelaState extends State<CanalTela> {
  late Future<Doc> _canal = widget.api.canal(widget.slug);

  List<Doc> get _colecoes => [for (final c in widget.esquema['colecoes'] as List) c as Doc];

  void _recarregar() => setState(() => _canal = widget.api.canal(widget.slug));

  Future<void> _editar(Doc canal) async {
    final r = await abrirTela<Doc>(context, (_) => FormularioNota(
          titulo: 'Editar canal',
          campos: camposCanal(widget.esquema),
          valores: {'nome': canal['nome'], 'status': canal['status'] ?? ''},
          tituloNota: '${canal['titulo']}',
          tags: [for (final t in canal['tags'] as List) '$t'],
          corpo: '${canal['corpo']}',
        ));
    if (r == null || !mounted) return;
    final campos = r['campos'] as Doc;
    await acaoComAviso(context, () async {
      await widget.api.editarCanal(widget.slug, {
        'titulo': r['titulo'],
        'nome': campos['nome'],
        if ('${campos['status']}'.isNotEmpty) 'status': campos['status'],
        'tags': r['tags'],
        'corpo': r['corpo'],
      });
      return 'Canal salvo';
    });
    _recarregar();
  }

  Future<void> _excluir(Doc canal) async {
    if (!await confirmarExclusao(context, 'O canal ${canal['nome']}') || !mounted) return;
    final nav = Navigator.of(context);
    try {
      await widget.api.excluirCanal(widget.slug);
      nav.pop();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Falhou: $e')));
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _canal,
    builder: (context, s) {
      final canal = s.data;
      return DefaultTabController(
        length: 1 + _colecoes.length,
        child: Scaffold(
          appBar: AppBar(
            title: Text(canal == null ? widget.slug : '${canal['nome']}'),
            actions: [
              if (canal != null) ...[
                IconButton(onPressed: () => _editar(canal), icon: const Icon(Icons.edit_outlined), tooltip: 'Editar'),
                IconButton(
                  onPressed: () => _excluir(canal),
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Excluir',
                ),
              ],
            ],
            bottom: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                const Tab(text: 'Gerência'),
                for (final c in _colecoes) Tab(text: '${c['nome']}'),
              ],
            ),
          ),
          body: s.hasError
              ? ErroComRetry(erro: s.error!, tentar: _recarregar)
              : canal == null
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(
                  children: [
                    _Gerencia(canal: canal, colecoes: _colecoes),
                    for (final c in _colecoes)
                      ColecaoLista(
                        api: widget.api,
                        slug: widget.slug,
                        colecao: c,
                        esquema: widget.esquema,
                        aoMudar: _recarregar,
                      ),
                  ],
                ),
        ),
      );
    },
  );
}

class _Gerencia extends StatelessWidget {
  const _Gerencia({required this.canal, required this.colecoes});

  final Doc canal;
  final List<Doc> colecoes;

  @override
  Widget build(BuildContext context) {
    final contagens = canal['colecoes'] as Doc;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('${canal['titulo']}', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            if (canal['status'] != null) Chip(label: Text('${canal['status']}')),
            for (final t in canal['tags'] as List) Chip(label: Text('#$t')),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in colecoes)
              Indicador(
                '${c['nome']}',
                '${(contagens[c['id']] as Doc)['total']}',
                sub: [
                  for (final e in ((contagens[c['id']] as Doc)['status'] as Doc).entries) '${e.key} ${e.value}',
                ].join(' · '),
              ),
          ],
        ),
        const Secao('Nota do canal'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SelectionArea(child: VisualizadorMarkdown(texto: '${canal['corpo']}')),
          ),
        ),
      ],
    );
  }
}

/// Lista de uma coleção do canal com busca, filtro de status e criação.
class ColecaoLista extends StatefulWidget {
  const ColecaoLista({
    super.key,
    required this.api,
    required this.slug,
    required this.colecao,
    required this.esquema,
    required this.aoMudar,
  });

  final ApiYoutube api;
  final String slug;
  final Doc colecao;
  final Doc esquema;
  final VoidCallback aoMudar;

  @override
  State<ColecaoLista> createState() => _ColecaoListaState();
}

class _ColecaoListaState extends State<ColecaoLista> with AutomaticKeepAliveClientMixin {
  String _q = '';
  String _status = '';
  late Future<List<Doc>> _itens = _carregar();

  String get _id => widget.colecao['id'] as String;

  List<Doc> get _campos => [for (final c in widget.colecao['campos'] as List) c as Doc];

  List<String> get _todosStatus => [
    for (final c in _campos)
      if (c['nome'] == 'status') ...[for (final o in c['opcoes'] as List) '$o'],
  ];

  Future<List<Doc>> _carregar() => widget.api.itens(widget.slug, _id, q: _q, status: _status);

  void _recarregar() => setState(() => _itens = _carregar());

  @override
  bool get wantKeepAlive => true;

  Future<void> _novo() async {
    final r = await abrirTela<Doc>(context, (_) => FormularioNota(
          titulo: 'Novo ${'${widget.colecao['item']}'.toLowerCase()}',
          campos: _campos,
          valores: const {'status': 'rascunho'},
        ));
    if (r == null || !mounted) return;
    await acaoComAviso(context, () async {
      final campos = {
        for (final e in (r['campos'] as Doc).entries)
          if ('${e.value}'.isNotEmpty) e.key: e.value,
      };
      // corpo vazio: o backend usa o modelo da coleção
      await widget.api.criar(widget.slug, _id, {
        'titulo': r['titulo'],
        'propriedades': campos,
        'tags': r['tags'],
        'corpo': r['corpo'],
      });
      return '${widget.colecao['item']} criado';
    });
    _recarregar();
    widget.aoMudar();
  }

  Future<void> _abrir(Doc item) async {
    await abrirTela(context, (_) => ItemTela(
          api: widget.api,
          slug: widget.slug,
          colecao: _id,
          id: item['id'] as String,
          esquema: widget.esquema,
        ));
    _recarregar();
    widget.aoMudar();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        FiltrosRecolhiveis(
          chave: 'youtube.colecao',
          resumo: [if (_status.isNotEmpty) _status, if (_q.isNotEmpty) '"$_q"'].join(' · '),
          children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 280,
                child: TextField(
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Buscar no título'),
                  onSubmitted: (v) {
                    _q = v.trim();
                    _recarregar();
                  },
                ),
              ),
              DropdownButton<String>(
                value: _status,
                items: [
                  const DropdownMenuItem(value: '', child: Text('Todos os status')),
                  for (final st in _todosStatus) DropdownMenuItem(value: st, child: Text(st)),
                ],
                onChanged: (v) {
                  _status = v ?? '';
                  _recarregar();
                },
              ),
              FilledButton.icon(
                onPressed: _novo,
                icon: const Icon(Icons.add),
                label: Text('Novo ${'${widget.colecao['item']}'.toLowerCase()}'),
              ),
            ],
          ),
        ),
          ],
        ),
        Expanded(
          child: FutureBuilder(
            future: _itens,
            builder: (context, s) {
              if (s.hasError) return ErroComRetry(erro: s.error!, tentar: _recarregar);
              final itens = s.data;
              if (itens == null) return const Center(child: CircularProgressIndicator());
              if (itens.isEmpty) return Vazio('Nada em ${widget.colecao['nome']}.');
              return ListView.separated(
                itemCount: itens.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) => _Linha(item: itens[i], abrir: () => _abrir(itens[i])),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Linha extends StatelessWidget {
  const _Linha({required this.item, required this.abrir});

  final Doc item;
  final VoidCallback abrir;

  @override
  Widget build(BuildContext context) {
    final ligacoes = item['ligacoes'] as Doc;
    final detalhes = [
      for (final k in ['fio', 'formato', 'evidencia'])
        if (item[k] != null) '${item[k]}',
      if (ligacoes.isNotEmpty) 'liga: ${ligacoes.keys.join(', ')}',
    ];
    return ListTile(
      onTap: abrir,
      leading: CircleAvatar(child: Text(item['numero'] == null ? '·' : '${item['numero']}')),
      title: Text('${item['titulo']}'),
      subtitle: detalhes.isEmpty ? null : Text(detalhes.join(' · ')),
      trailing: item['status'] == null ? null : Chip(label: Text('${item['status']}')),
    );
  }
}
