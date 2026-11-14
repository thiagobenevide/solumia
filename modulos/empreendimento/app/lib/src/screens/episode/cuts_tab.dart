import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../api_esteira.dart';
import '../../models.dart';
import '../util.dart';

/// Narration cuts: listen to each span in the raw recording, flip keep/drop and apply (runs `limpar`).
class CutsTab extends StatefulWidget {
  const CutsTab({super.key, required this.api, required this.ep});

  final ApiEsteira api;
  final String ep;

  @override
  State<CutsTab> createState() => _CutsTabState();
}

class _CutsTabState extends State<CutsTab> {
  String _filter = 'revisar';
  late Future<Json> _dados = _load();
  final _player = AudioPlayer();
  String? _source;
  int? _playing;
  Timer? _stop;

  static const _labels = {
    'tomada': 'tomada',
    'reformulada': 'reformulada',
    'continuacao': 'continuação',
    'improviso': 'improviso',
    'retake': 'retake',
    'bastidor': 'bastidor',
    'fora': 'fora do roteiro',
    'descartado': 'leitura descartada',
    'marcador': 'marcador falado',
  };

  Future<Json> _load() => widget.api.cuts(widget.ep, _filter);

  @override
  void dispose() {
    _stop?.cancel();
    _player.dispose();
    super.dispose();
  }

  /// Plays the span with a breath before and after, like the panel.
  Future<void> _listen(String raw, Json t) async {
    final startAt = (t['ini'] as num).toDouble(), end = (t['fim'] as num).toDouble();
    if (_source != raw) {
      await _player.setSourceUrl(widget.api.arquivo(raw));
      _source = raw;
    }
    await _player.seek(Duration(milliseconds: ((startAt - 0.4).clamp(0, double.infinity) * 1000).round()));
    await _player.resume();
    setState(() => _playing = t['k'] as int);
    _stop?.cancel();
    _stop = Timer(Duration(milliseconds: ((end - startAt + 0.9) * 1000).round()), () {
      _player.pause();
      if (mounted) setState(() => _playing = null);
    });
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _dados,
    builder: (context, s) {
      if (s.hasError) return Empty('${s.error}', icone: Icons.content_cut);
      final d = s.data;
      if (d == null) return const Center(child: CircularProgressIndicator());
      final spans = [for (final t in d['trechos'] as List) t as Json];
      final stillMissing = d['faltando'] as List;
      final raw = d['bruta'] as String?;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text(
                'Toque no tempo para ouvir o trecho na gravação bruta. Fica/Sai inverte a decisão; '
                'depois, Aplicar refaz o áudio com as suas escolhas.',
              ),
              d['editado'] == true
                  ? FilledButton(onPressed: _apply, child: const Text('Aplicar cortes'))
                  : OutlinedButton(onPressed: _apply, child: const Text('Aplicar cortes')),
            ],
          ),
          if (raw == null)
            const Padding(padding: EdgeInsets.only(top: 8), child: Text('Sem gravação bruta para ouvir.')),
          if (stillMissing.isNotEmpty)
            Card(
              margin: const EdgeInsets.only(top: 16),
              color: Colors.amber.withValues(alpha: 0.08),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 4,
                  children: [
                    const Text(
                      'Frases do roteiro sem tomada na gravação',
                      style: TextStyle(color: Colors.amber),
                    ),
                    for (final f in stillMissing) Text('• $f'),
                  ],
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'revisar', label: Text('Para revisar')),
                ButtonSegment(value: 'cortados', label: Text('Só cortados')),
                ButtonSegment(value: 'todos', label: Text('Tudo')),
              ],
              selected: {_filter},
              onSelectionChanged: (v) => setState(() {
                _filter = v.first;
                _dados = _load();
              }),
            ),
          ),
          if (spans.isEmpty) const Empty('Nada neste filtro.'),
          for (final t in spans) _span(context, t, raw),
        ],
      );
    },
  );

  Widget _span(BuildContext context, Json t, String? raw) {
    final keep = t['manter'] == true;
    final startAt = (t['ini'] as num).toDouble();
    final who = switch (t['por']) {
      'llm' => 'LLM local',
      'claude' => 'Claude',
      'painel' => 'você',
      _ => 'regra',
    };
    final reason = '${t['motivo']}'.split(' → ').last;
    return Opacity(
      opacity: keep ? 1 : 0.6,
      child: Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: TextButton.icon(
            icon: Icon(_playing == t['k'] ? Icons.volume_up : Icons.play_arrow, size: 18),
            label: Text('${startAt ~/ 60}:${(startAt % 60).toStringAsFixed(1).padLeft(4, '0')}'),
            onPressed: raw == null ? null : () => _listen(raw, t),
          ),
          title: Text(
            '${t['texto']}',
            style: keep ? null : const TextStyle(decoration: TextDecoration.lineThrough),
          ),
          subtitle: Text(
            '${_labels[t['tipo']] ?? t['tipo']} · decidido por $who · '
            '${reason.length > 140 ? reason.substring(0, 140) : reason}',
          ),
          trailing: FilledButton.tonal(
            style: FilledButton.styleFrom(
              backgroundColor: (keep ? Colors.green : Colors.red).withValues(alpha: 0.18),
              foregroundColor: keep ? Colors.green.shade200 : Colors.red.shade200,
            ),
            onPressed: () => _toggle(t),
            child: Text(keep ? 'Fica' : 'Sai'),
          ),
        ),
      ),
    );
  }

  Future<void> _toggle(Json t) => actionWithWarning(context, () async {
    final newItem = await widget.api.toggleCut(widget.ep, t['k'] as int);
    setState(() { _dados = _load(); });
    return newItem['manter'] == true ? 'O trecho fica.' : 'O trecho sai.';
  });

  Future<void> _apply() => actionWithWarning(context, () async {
    final entrou = await widget.api.run(widget.ep, 'clean');
    return entrou ? 'Cortes na fila (etapa limpar).' : 'O limpar já estava na fila.';
  });
}
