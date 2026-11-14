import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../screens/util.dart';
import 'youtube_api.dart';
import 'form.dart';
import 'item_screen.dart';
import 'youtube_tab.dart';

/// One channel: "Gerência" tab (channel note + counts) and one tab per schema collection.
class ChannelScreen extends StatefulWidget {
  const ChannelScreen({super.key, required this.api, required this.slug, required this.schema});

  final ApiYoutube api;
  final String slug;
  final Doc schema;

  @override
  State<ChannelScreen> createState() => _ChannelScreenState();
}

class _ChannelScreenState extends State<ChannelScreen> {
  late Future<Doc> _channel = widget.api.channel(widget.slug);

  List<Doc> get _collections => [for (final c in widget.schema['colecoes'] as List) c as Doc];

  void _recarregar() => setState(() => _channel = widget.api.channel(widget.slug));

  Future<void> _edit(Doc channel) async {
    final r = await abrirTela<Doc>(context, (_) => NoteForm(
          titulo: 'Editar canal',
          campos: channelFields(widget.schema),
          values: {'nome': channel['nome'], 'status': channel['status'] ?? ''},
          titleNote: '${channel['titulo']}',
          tags: [for (final t in channel['tags'] as List) '$t'],
          corpo: '${channel['corpo']}',
        ));
    if (r == null || !mounted) return;
    final campos = r['campos'] as Doc;
    await actionWithWarning(context, () async {
      await widget.api.editChannel(widget.slug, {
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

  Future<void> _delete(Doc channel) async {
    if (!await confirmDeletion(context, 'O canal ${channel['nome']}') || !mounted) return;
    final nav = Navigator.of(context);
    try {
      await widget.api.deleteChannel(widget.slug);
      nav.pop();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Falhou: $e')));
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _channel,
    builder: (context, s) {
      final channel = s.data;
      return DefaultTabController(
        length: 1 + _collections.length,
        child: Scaffold(
          appBar: AppBar(
            title: Text(channel == null ? widget.slug : '${channel['nome']}'),
            actions: [
              if (channel != null) ...[
                IconButton(onPressed: () => _edit(channel), icon: const Icon(Icons.edit_outlined), tooltip: 'Editar'),
                IconButton(
                  onPressed: () => _delete(channel),
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
                for (final c in _collections) Tab(text: '${c['nome']}'),
              ],
            ),
          ),
          body: s.hasError
              ? ErroComRetry(erro: s.error!, tentar: _recarregar)
              : channel == null
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(
                  children: [
                    _Management(channel: channel, collections: _collections),
                    for (final c in _collections)
                      CollectionList(
                        api: widget.api,
                        slug: widget.slug,
                        collection: c,
                        schema: widget.schema,
                        aoMudar: _recarregar,
                      ),
                  ],
                ),
        ),
      );
    },
  );
}

class _Management extends StatelessWidget {
  const _Management({required this.channel, required this.collections});

  final Doc channel;
  final List<Doc> collections;

  @override
  Widget build(BuildContext context) {
    final counts = channel['colecoes'] as Doc;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('${channel['titulo']}', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            if (channel['status'] != null) Chip(label: Text('${channel['status']}')),
            for (final t in channel['tags'] as List) Chip(label: Text('#$t')),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in collections)
              Indicator(
                '${c['nome']}',
                '${(counts[c['id']] as Doc)['total']}',
                sub: [
                  for (final e in ((counts[c['id']] as Doc)['status'] as Doc).entries) '${e.key} ${e.value}',
                ].join(' · '),
              ),
          ],
        ),
        const Section('Nota do canal'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SelectionArea(child: VisualizadorMarkdown(texto: '${channel['corpo']}')),
          ),
        ),
      ],
    );
  }
}

/// List of one channel collection with search, status filter and creation.
class CollectionList extends StatefulWidget {
  const CollectionList({
    super.key,
    required this.api,
    required this.slug,
    required this.collection,
    required this.schema,
    required this.aoMudar,
  });

  final ApiYoutube api;
  final String slug;
  final Doc collection;
  final Doc schema;
  final VoidCallback aoMudar;

  @override
  State<CollectionList> createState() => _CollectionListState();
}

class _CollectionListState extends State<CollectionList> with AutomaticKeepAliveClientMixin {
  String _q = '';
  String _status = '';
  late Future<List<Doc>> _items = _load();

  String get _id => widget.collection['id'] as String;

  List<Doc> get _fields => [for (final c in widget.collection['campos'] as List) c as Doc];

  List<String> get _allStatus => [
    for (final c in _fields)
      if (c['nome'] == 'status') ...[for (final o in c['opcoes'] as List) '$o'],
  ];

  Future<List<Doc>> _load() => widget.api.items(widget.slug, _id, q: _q, status: _status);

  void _recarregar() => setState(() => _items = _load());

  @override
  bool get wantKeepAlive => true;

  Future<void> _new() async {
    final r = await abrirTela<Doc>(context, (_) => NoteForm(
          titulo: 'Novo ${'${widget.collection['item']}'.toLowerCase()}',
          campos: _fields,
          values: const {'status': 'rascunho'},
        ));
    if (r == null || !mounted) return;
    await actionWithWarning(context, () async {
      final campos = {
        for (final e in (r['campos'] as Doc).entries)
          if ('${e.value}'.isNotEmpty) e.key: e.value,
      };
      // empty body: the backend uses the collection template
      await widget.api.create(widget.slug, _id, {
        'titulo': r['titulo'],
        'propriedades': campos,
        'tags': r['tags'],
        'corpo': r['corpo'],
      });
      return '${widget.collection['item']} criado';
    });
    _recarregar();
    widget.aoMudar();
  }

  Future<void> _open(Doc item) async {
    await abrirTela(context, (_) => ItemScreen(
          api: widget.api,
          slug: widget.slug,
          collection: _id,
          id: item['id'] as String,
          schema: widget.schema,
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
                  for (final st in _allStatus) DropdownMenuItem(value: st, child: Text(st)),
                ],
                onChanged: (v) {
                  _status = v ?? '';
                  _recarregar();
                },
              ),
              FilledButton.icon(
                onPressed: _new,
                icon: const Icon(Icons.add),
                label: Text('Novo ${'${widget.collection['item']}'.toLowerCase()}'),
              ),
            ],
          ),
        ),
          ],
        ),
        Expanded(
          child: FutureBuilder(
            future: _items,
            builder: (context, s) {
              if (s.hasError) return ErroComRetry(erro: s.error!, tentar: _recarregar);
              final items = s.data;
              if (items == null) return const Center(child: CircularProgressIndicator());
              if (items.isEmpty) return Empty('Nada em ${widget.collection['nome']}.');
              return ListView.separated(
                itemCount: items.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) => _Line(item: items[i], abrir: () => _open(items[i])),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.item, required this.abrir});

  final Doc item;
  final VoidCallback abrir;

  @override
  Widget build(BuildContext context) {
    final ligacoes = item['ligacoes'] as Doc;
    final details = [
      for (final k in ['fio', 'formato', 'evidencia'])
        if (item[k] != null) '${item[k]}',
      if (ligacoes.isNotEmpty) 'liga: ${ligacoes.keys.join(', ')}',
    ];
    return ListTile(
      onTap: abrir,
      leading: CircleAvatar(child: Text(item['numero'] == null ? '·' : '${item['numero']}')),
      title: Text('${item['titulo']}'),
      subtitle: details.isEmpty ? null : Text(details.join(' · ')),
      trailing: item['status'] == null ? null : Chip(label: Text('${item['status']}')),
    );
  }
}
