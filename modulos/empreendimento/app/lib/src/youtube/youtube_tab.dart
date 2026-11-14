import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../screens/util.dart';
import 'youtube_api.dart';
import 'channel_screen.dart';
import 'form.dart';

/// Channel management: one card per channel with the total and the status of each collection. The data comes from the
/// notes vault (`/api/youtube`); "Importar do Obsidian" brings the Obsidian vault notes into the platform vault.
class YoutubeTab extends StatefulWidget {
  const YoutubeTab({super.key, required this.api});

  final ApiYoutube api;

  @override
  State<YoutubeTab> createState() => _YoutubeTabState();
}

class _YoutubeTabState extends State<YoutubeTab> {
  late Future<(Doc, List<Doc>)> _dados = _load();

  Future<(Doc, List<Doc>)> _load() async => (await widget.api.schema(), await widget.api.channels());

  void _recarregar() => setState(() { _dados = _load(); });

  Future<void> _import() async {
    var replace = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Importar do Obsidian'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Copia Notas/Empreendimento/YouTube do vault para o cofre de notas, no padrão das notas.'),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: replace,
                onChanged: (v) => set(() => replace = v ?? false),
                title: const Text('Regravar notas que já existem no cofre'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Importar')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    await actionWithWarning(context, () async {
      final r = await widget.api.runImport(replace: replace);
      return '${r['importadas']} notas importadas, ${r['puladas']} já existiam';
    });
    _recarregar();
  }

  Future<void> _newChannel(Doc schema) async {
    final r = await abrirTela<Doc>(context, (_) => NoteForm(titulo: 'Novo canal', campos: channelFields(schema, newItem: true)));
    if (r == null || !mounted) return;
    final campos = r['campos'] as Doc;
    await actionWithWarning(context, () async {
      await widget.api.createChannel({
        'slug': campos['slug'],
        'titulo': r['titulo'],
        'nome': campos['nome'],
        if ('${campos['status']}'.isNotEmpty) 'status': campos['status'],
        'tags': r['tags'],
        'corpo': r['corpo'],
      });
      return 'Canal criado';
    });
    _recarregar();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _dados,
    builder: (context, s) {
      if (s.hasError) return ErroComRetry(erro: s.error!, tentar: _recarregar);
      final dados = s.data;
      if (dados == null) return const Center(child: CircularProgressIndicator());
      final (schema, channels) = dados;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => _newChannel(schema),
                icon: const Icon(Icons.add),
                label: const Text('Novo canal'),
              ),
              OutlinedButton.icon(
                onPressed: _import,
                icon: const Icon(Icons.download_outlined),
                label: const Text('Importar do Obsidian'),
              ),
              IconButton(onPressed: _recarregar, icon: const Icon(Icons.refresh), tooltip: 'Recarregar'),
            ],
          ),
          const SizedBox(height: 12),
          if (channels.isEmpty)
            const Empty('Nenhum canal no cofre. Importe do Obsidian ou crie um.', icone: Icons.smart_display_outlined)
          else
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final c in channels)
                  _ChannelCard(
                    channel: c,
                    schema: schema,
                    abrir: () async {
                      await abrirTela(context, (_) => ChannelScreen(api: widget.api, slug: c['slug'] as String, schema: schema));
                      _recarregar();
                    },
                  ),
              ],
            ),
        ],
      );
    },
  );
}

/// Channel form fields; the identifier (folder) can only be chosen when creating.
List<Doc> channelFields(Doc schema, {bool newItem = false}) => [
  if (newItem) {'nome': 'slug', 'rotulo': 'Identificador (pasta, ex.: finlumia)', 'tipo': 'texto', 'opcoes': []},
  {'nome': 'nome', 'rotulo': 'Nome do canal', 'tipo': 'texto', 'opcoes': []},
  {'nome': 'status', 'rotulo': 'Status', 'tipo': 'opcoes', 'opcoes': schema['status_canal']},
];

class _ChannelCard extends StatelessWidget {
  const _ChannelCard({required this.channel, required this.schema, required this.abrir});

  final Doc channel;
  final Doc schema;
  final VoidCallback abrir;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final collections = channel['colecoes'] as Doc;
    return SizedBox(
      width: 340,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: abrir,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 6,
              children: [
                Row(
                  children: [
                    Expanded(child: Text('${channel['nome']}', style: t.titleLarge)),
                    if (channel['status'] != null) Chip(label: Text('${channel['status']}')),
                  ],
                ),
                Text('${channel['titulo']}', style: t.bodySmall),
                const Divider(),
                for (final col in schema['colecoes'] as List)
                  _CollectionLine(nome: '${col['nome']}', dados: collections[col['id']] as Doc),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CollectionLine extends StatelessWidget {
  const _CollectionLine({required this.nome, required this.dados});

  final String nome;
  final Doc dados;

  @override
  Widget build(BuildContext context) {
    final status = dados['status'] as Doc;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 90, child: Text(nome)),
        SizedBox(width: 36, child: Text('${dados['total']}', style: const TextStyle(fontWeight: FontWeight.w600))),
        Expanded(
          child: Text(
            [for (final e in status.entries) '${e.key} ${e.value}'].join(' · '),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
