import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../modelos.dart';
import '../telas/util.dart';

/// Linha do tempo da direção por bloco: cada bloco (parágrafo do roteiro) com os momentos que ganharam peça; a peça
/// escolhida e as outras candidatas que o código achou — um clique troca (a IA local preenche a nova e a troca ensina
/// a bancada) — e o render só do bloco alterado.
class LinhaDoTempo extends StatelessWidget {
  const LinhaDoTempo({
    super.key,
    required this.api,
    required this.ep,
    required this.blocos,
    required this.cenas,
    required this.temRender,
    required this.recarregar,
  });

  final ApiEsteira api;
  final String ep;
  final List<Json> blocos;
  final List<Json> cenas;
  final bool temRender;
  final Future<void> Function() recarregar;

  static String _tempo(num s) => '${s ~/ 60}:${(s % 60).floor().toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final pequeno = Theme.of(context).textTheme.bodySmall;
    final semBloco = [for (final c in cenas) if (c['bloco'] == null) c];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final b in blocos)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 6,
                children: [
                  Row(
                    children: [
                      Text('Bloco ${(b['i'] as num) + 1} · ${_tempo(b['ini'] as num)}–${_tempo(b['fim'] as num)}',
                          style: Theme.of(context).textTheme.titleSmall),
                      const Spacer(),
                      if (temRender)
                        TextButton.icon(
                          icon: const Icon(Icons.movie_edit, size: 18),
                          label: const Text('Renderizar só este bloco'),
                          onPressed: () => acaoComAviso(context, () async {
                            await api.renderBloco(ep, (b['i'] as num).toInt());
                            return 'Bloco na fila: trecho → emenda no vídeo → loudness e prévia';
                          }),
                        ),
                    ],
                  ),
                  Text('${b['texto']}', style: pequeno, maxLines: 2, overflow: TextOverflow.ellipsis),
                  for (final c in cenas.where((c) => c['bloco'] == b['i']))
                    _Momento(api: api, ep: ep, c: c, recarregar: recarregar),
                  if (!cenas.any((c) => c['bloco'] == b['i'])) Text('Só mídia neste bloco.', style: pequeno),
                ],
              ),
            ),
          ),
        for (final c in semBloco) _Momento(api: api, ep: ep, c: c, recarregar: recarregar),
      ],
    );
  }
}

class _Momento extends StatelessWidget {
  const _Momento({required this.api, required this.ep, required this.c, required this.recarregar});

  final ApiEsteira api;
  final String ep;
  final Json c;
  final Future<void> Function() recarregar;

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final pequeno = Theme.of(context).textTheme.bodySmall;
    final atual = '${c['cena']}';
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
            '${LinhaDoTempo._tempo(c['t'] as num)}–${LinhaDoTempo._tempo(c['ate'] as num)} · ${c['tratamento'] ?? ''}'
            '${c['intencao'] != null ? ' · ${c['intencao']}' : ''} · ${c['manual'] == true ? 'manual' : c['por']}',
            style: pequeno,
          ),
          Text('"${c['frase']}"', maxLines: 2, overflow: TextOverflow.ellipsis),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final id in {atual, ...cands})
                id == atual
                    ? Chip(
                        avatar: const Icon(Icons.check, size: 16),
                        label: Text(id),
                        backgroundColor: cores.primaryContainer,
                      )
                    : ActionChip(
                        label: Text(id),
                        tooltip: 'Trocar por $id (a IA local preenche)',
                        onPressed: () => acaoComAviso(context, () async {
                          await api.trocarPeca(ep, (c['id'] as num).toInt(), id);
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
