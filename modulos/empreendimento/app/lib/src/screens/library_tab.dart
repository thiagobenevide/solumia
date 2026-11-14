import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../models.dart';
import 'util.dart';

/// Library: every media downloaded from the banks, with credit, terms, the vision model description and where it was
/// already used. The media search queries the library before the APIs.
class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key, required this.api});

  final ApiEsteira api;

  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {
  final _q = TextEditingController();
  String _kind = '';
  late Future<Json> _dados = widget.api.mediaLibrary();

  void _fetch() => setState(() { _dados = widget.api.mediaLibrary(q: _q.text.trim(), kind: _kind); });

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomScrollView(
    slivers: [
      SliverPadding(
        padding: const EdgeInsets.all(16),
        sliver: SliverList.list(
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 340,
                  child: TextField(
                    controller: _q,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      hintText: 'buscar (inglês): credit card, debt, city night…',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onSubmitted: (_) => _fetch(),
                  ),
                ),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: '', label: Text('Tudo')),
                    ButtonSegment(value: 'video', label: Text('Vídeos')),
                    ButtonSegment(value: 'imagem', label: Text('Imagens')),
                  ],
                  selected: {_kind},
                  onSelectionChanged: (v) {
                    _kind = v.first;
                    _fetch();
                  },
                ),
                FilledButton(onPressed: _fetch, child: const Text('Buscar')),
              ],
            ),
            const SizedBox(height: 6),
            const Wrap(
              spacing: 6,
              children: [
                EnginePill('py', label: 'busca: Python (SQLite)'),
                EnginePill('local', label: 'descrições: visão local'),
              ],
            ),
          ],
        ),
      ),
      FutureBuilder(
        future: _dados,
        builder: (context, s) {
          if (s.hasError) return SliverToBoxAdapter(child: Empty('${s.error}'));
          final d = s.data;
          if (d == null) return const SliverToBoxAdapter(child: Center(child: CircularProgressIndicator()));
          final e = d['estatisticas'] as Json;
          final items = [for (final it in d['itens'] as List) it as Json];
          return SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            sliver: SliverMainAxisGroup(
              slivers: [
                SliverToBoxAdapter(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Indicator('Itens', '${e['itens']}', sub: '${e['gb']} GB em disco'),
                      Indicator('Vídeos', '${e['videos']}', sub: 'clipes guardados'),
                      Indicator('Imagens', '${e['imagens']}', sub: 'fotos guardadas'),
                      Indicator('Descritos', '${e['descritos']}', sub: 'pelo modelo de visão local'),
                      Indicator('Usos', '${e['usos']}', sub: '${e['reusados']} mídias já usadas'),
                    ],
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
                if (items.isEmpty)
                  SliverToBoxAdapter(
                    child: Empty(
                      _q.text.isEmpty
                          ? 'Acervo vazio: rode ./dark library import ou produza um episódio.'
                          : 'Nada encontrado para "${_q.text}".',
                    ),
                  ),
                SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 320,
                    mainAxisExtent: 320,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, i) => _item(context, items[i]),
                ),
              ],
            ),
          );
        },
      ),
    ],
  );

  Widget _item(BuildContext context, Json it) {
    final uses = it['usos'] as List? ?? const [];
    final video = it['tipo'] == 'video';
    final pequeno = Theme.of(context).textTheme.bodySmall;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.network(
                  widget.api.arquivo('${it['mini']}'),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black26),
                ),
                Positioned(top: 6, left: 6, child: _tag('${it['provedor']}')),
                Positioned(
                  top: 6,
                  right: 6,
                  child: _tag(video ? '▶ ${(it['duracao'] as num? ?? 0).round()}s' : 'foto'),
                ),
                if (uses.isNotEmpty)
                  Positioned(
                    bottom: 6,
                    right: 6,
                    child: _tag('${uses.length} uso${uses.length > 1 ? 's' : ''}'),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  if ('${it['descricao'] ?? ''}'.isNotEmpty)
                    Text('${it['descricao']}', maxLines: 2, overflow: TextOverflow.ellipsis),
                  Text(
                    'termos: ${(it['termos'] as List? ?? const []).join(' · ')}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: pequeno,
                  ),
                  Text('${it['largura']}×${it['altura']} · ${it['orientacao']}', style: pequeno),
                  if (uses.isNotEmpty)
                    Text(
                      'usado em: ${uses.take(3).map((u) => (u as Json)['ep']).join(', ')}',
                      overflow: TextOverflow.ellipsis,
                      style: pequeno,
                    ),
                  if (it['pagina'] != null)
                    InkWell(
                      onTap: () => openUrl(context, '${it['pagina']}'),
                      child: Text(
                        '${it['licenca'] ?? 'fonte'} ↗',
                        style: pequeno?.copyWith(color: Theme.of(context).colorScheme.primary),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _tag(String t) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(4)),
    child: Text(t, style: const TextStyle(fontSize: 10, color: Colors.white)),
  );
}
