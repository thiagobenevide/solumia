import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../models.dart';
import 'episode/episode_screen.dart';
import 'util.dart';

/// Episodes of every channel (or of one), with live progress.
class ProductionTab extends StatefulWidget {
  const ProductionTab({super.key, required this.api});

  final ApiEsteira api;

  @override
  State<ProductionTab> createState() => _ProductionTabState();
}

class _ProductionTabState extends State<ProductionTab> {
  late final Future<List<Channel>> _channels = widget.api.channels();
  String _channel = '';

  @override
  Widget build(BuildContext context) => Column(
    children: [
      FutureBuilder(
        future: _channels,
        builder: (context, s) => Align(
          alignment: Alignment.centerLeft,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Todos'),
                  selected: _channel.isEmpty,
                  onSelected: (_) => _choose(''),
                ),
                for (final c in s.data ?? const <Channel>[])
                  ChoiceChip(
                    label: Text('${c.id} · ${c.episodes}'),
                    selected: _channel == c.id,
                    onSelected: (_) => _choose(c.id),
                  ),
              ],
            ),
          ),
        ),
      ),
      Expanded(
        child: Sondagem<List<EpisodeSummary>>(
          key: ValueKey(_channel),
          intervalo: const Duration(seconds: 5),
          carregar: () => widget.api.episodes(channel: _channel),
          construir: (context, eps, _) => eps.isEmpty
              ? const Empty('Nenhum episódio ainda.\nEscolha roteiros na aba Roteiros e mande produzir.')
              : LayoutBuilder(
                  builder: (context, area) {
                    // Card height follows the column width: 16:9 thumbnail + the text block.
                    const margin = 16.0, espaco = 12.0;
                    final columns = ((area.maxWidth - 2 * margin + espaco) / (380 + espaco)).ceil().clamp(
                      1,
                      8,
                    );
                    final largura = (area.maxWidth - 2 * margin - espaco * (columns - 1)) / columns;
                    return GridView.builder(
                      padding: const EdgeInsets.all(margin),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisExtent: largura * 9 / 16 + 130,
                        crossAxisSpacing: espaco,
                        mainAxisSpacing: espaco,
                      ),
                      itemCount: eps.length,
                      itemBuilder: (context, i) => _EpisodeCard(api: widget.api, ep: eps[i]),
                    );
                  },
                ),
        ),
      ),
    ],
  );

  void _choose(String channel) => setState(() => _channel = channel);
}

class _EpisodeCard extends StatelessWidget {
  const _EpisodeCard({required this.api, required this.ep});

  final ApiEsteira api;
  final EpisodeSummary ep;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final p = ep.prog;
    return Card(
      child: InkWell(
        onTap: () => abrirTela(context, (_) => EpisodeScreen(api: api, ep: ep.id, titulo: ep.titulo)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ep.thumbs.isEmpty
                  ? ColoredBox(
                      color: tema.colorScheme.surfaceContainerHighest,
                      child: Icon(Icons.image_outlined, size: 40, color: tema.colorScheme.outline),
                    )
                  : Image.network(api.arquivo(ep.thumbs.first.url), fit: BoxFit.cover),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 6,
                children: [
                  Text(
                    ep.titulo,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: tema.textTheme.titleSmall,
                  ),
                  Text('${ep.channel} · ${ep.numero}', style: tema.textTheme.bodySmall),
                  LinearProgressIndicator(value: p.fraction, color: corDoEstado(tema.colorScheme, p.state)),
                  Text(
                    p.rodando != null
                        ? 'Rodando: ${p.rodando} · ${p.doneSteps}/${p.total}'
                        : p.erro != null
                        ? 'Erro em ${p.erro} · ${p.doneSteps}/${p.total}'
                        : p.finalReady
                        ? (p.outdated ? 'Pronto, mas o vídeo está desatualizado' : 'Vídeo pronto')
                        : '${p.doneSteps}/${p.total} etapas',
                    style: tema.textTheme.bodySmall,
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
