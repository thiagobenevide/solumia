import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../models.dart';
import '../screens/util.dart';

/// Timeline of the per-block direction: each block (script paragraph) with the moments that got a piece; the chosen
/// piece and the other candidates the code found — one click swaps (the local AI fills the new one and the swap teaches
/// the bench) — and the render of the changed block only.
class Timeline extends StatelessWidget {
  const Timeline({
    super.key,
    required this.api,
    required this.ep,
    required this.blocks,
    required this.scenes,
    required this.hasRender,
    required this.recarregar,
  });

  final ApiEsteira api;
  final String ep;
  final List<Json> blocks;
  final List<Json> scenes;
  final bool hasRender;
  final Future<void> Function() recarregar;

  static String _time(num s) => '${s ~/ 60}:${(s % 60).floor().toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final pequeno = Theme.of(context).textTheme.bodySmall;
    final withoutBlock = [for (final c in scenes) if (c['bloco'] == null) c];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final b in blocks)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 6,
                children: [
                  Row(
                    children: [
                      Text('Bloco ${(b['i'] as num) + 1} · ${_time(b['ini'] as num)}–${_time(b['fim'] as num)}',
                          style: Theme.of(context).textTheme.titleSmall),
                      const Spacer(),
                      if (hasRender)
                        TextButton.icon(
                          icon: const Icon(Icons.movie_edit, size: 18),
                          label: const Text('Renderizar só este bloco'),
                          onPressed: () => actionWithWarning(context, () async {
                            await api.renderBlock(ep, (b['i'] as num).toInt());
                            return 'Bloco na fila: trecho → emenda no vídeo → loudness e prévia';
                          }),
                        ),
                    ],
                  ),
                  Text('${b['texto']}', style: pequeno, maxLines: 2, overflow: TextOverflow.ellipsis),
                  for (final c in scenes.where((c) => c['bloco'] == b['i']))
                    _Moment(api: api, ep: ep, c: c, recarregar: recarregar),
                  if (!scenes.any((c) => c['bloco'] == b['i'])) Text('Só mídia neste bloco.', style: pequeno),
                ],
              ),
            ),
          ),
        for (final c in withoutBlock) _Moment(api: api, ep: ep, c: c, recarregar: recarregar),
      ],
    );
  }
}

class _Moment extends StatelessWidget {
  const _Moment({required this.api, required this.ep, required this.c, required this.recarregar});

  final ApiEsteira api;
  final String ep;
  final Json c;
  final Future<void> Function() recarregar;

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final pequeno = Theme.of(context).textTheme.bodySmall;
    final current = '${c['cena']}';
    final cands = [for (final x in (c['candidatas'] as List?) ?? const []) '$x'];
    final enc = (c['encaixes'] as Json?) ?? const {};
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cores.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          Text(
            '${Timeline._time(c['t'] as num)}–${Timeline._time(c['ate'] as num)} · ${c['tratamento'] ?? ''}'
            '${c['intencao'] != null ? ' · ${c['intencao']}' : ''} · ${c['manual'] == true ? 'manual' : c['por']}',
            style: pequeno,
          ),
          Text('"${c['frase']}"', maxLines: 2, overflow: TextOverflow.ellipsis),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final id in {current, ...cands})
                id == current
                    ? Chip(
                        avatar: const Icon(Icons.check, size: 16),
                        label: Text(id),
                        backgroundColor: cores.primaryContainer,
                      )
                    : ActionChip(
                        label: Text(id),
                        tooltip: 'Trocar por $id (a IA local preenche)',
                        onPressed: () => actionWithWarning(context, () async {
                          await api.swapPiece(ep, (c['id'] as num).toInt(), id);
                          await recarregar();
                          return 'Trocada por $id; a troca ensina a bancada';
                        }),
                      ),
            ],
          ),
          if (enc.isNotEmpty)
            Text(
              enc.entries.map((e) => '${e.key}: ${e.value is List ? '${(e.value as List).length} item(ns)' : e.value}').join(' · '),
              style: pequeno,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          if ('${c['motivo'] ?? ''}'.isNotEmpty) Text('Motivo: ${c['motivo']}', style: pequeno),
        ],
      ),
    );
  }
}
