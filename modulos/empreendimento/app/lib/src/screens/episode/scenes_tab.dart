import 'package:flutter/material.dart';

import '../../api_esteira.dart';
import '../../models.dart';
import '../util.dart';

/// Timeline: each scene with the media frame, the vision model score, the mood and the search; swap
/// a scene's media with another term (queues the search for that scene only).
class ScenesTab extends StatefulWidget {
  const ScenesTab({super.key, required this.api, required this.ep});

  final ApiEsteira api;
  final String ep;

  @override
  State<ScenesTab> createState() => _ScenesTabState();
}

class _ScenesTabState extends State<ScenesTab> {
  late Future<Json> _dados = widget.api.scenes(widget.ep);

  static const _moods = <String, MaterialColor>{
    'tensao': Colors.red,
    'revelacao': Colors.purple,
    'dado': Colors.lightBlue,
    'respiro': Colors.green,
  };

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _dados,
    builder: (context, s) {
      if (s.hasError) return Empty('${s.error}', icone: Icons.view_timeline_outlined);
      final d = s.data;
      if (d == null) return const Center(child: CircularProgressIndicator());
      final scenes = [for (final c in d['cenas'] as List) c as Json];
      final graphics = [for (final g in d['graficos'] as List) g as Json];
      return RefreshIndicator(
        onRefresh: () async => setState(() { _dados = widget.api.scenes(widget.ep); }),
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverList.list(
                children: [
                  Text(
                    '${scenes.length} cenas · ${graphics.length} gráficos. Nota da mídia pelo modelo de visão (1–5); '
                    'troque a mídia de uma cena com outro termo de busca.',
                  ),
                  const SizedBox(height: 6),
                  const Wrap(
                    spacing: 6,
                    children: [
                      EnginePill('py', label: 'Python + APIs dos bancos'),
                      EnginePill('local', label: 'visão local'),
                    ],
                  ),
                  if (graphics.isNotEmpty) ...[
                    const Section('Gráficos animados'),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final g in graphics)
                          Chip(label: Text('${_time(g['inicio'] as num)}  ${g['modelo']}  ${g['rotulo']}')),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 340,
                  mainAxisExtent: 390,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: scenes.length,
                itemBuilder: (context, i) => _scene(context, scenes[i]),
              ),
            ),
          ],
        ),
      );
    },
  );

  static String _time(num s) => '${s ~/ 60}:${(s % 60).floor().toString().padLeft(2, '0')}';

  Widget _scene(BuildContext context, Json c) {
    final note = c['nota_midia'] as num?;
    final color = _moods[c['clima']] ?? Colors.blueGrey;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(
                  color: Colors.black,
                  child: c['quadro'] == null
                      ? null
                      : Image.network(widget.api.arquivo('${c['quadro']}'), fit: BoxFit.cover),
                ),
                Positioned(top: 6, left: 6, child: _tag('${c['id']} · ${_time(c['inicio'] as num)}')),
                if (note != null)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: _tag('★ $note', background: note < 3 ? Colors.red.shade700 : Colors.black87),
                  ),
                if (c['midia_tipo'] == 'video') Positioned(bottom: 6, right: 6, child: _tag('vídeo')),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 6,
                children: [
                  Text('${c['texto']}', maxLines: 3, overflow: TextOverflow.ellipsis),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      if (c['clima'] != null) EnginePill('', label: '${c['clima']}', fixedColor: color),
                      EnginePill('py', label: '${c['busca_en'] ?? c['busca'] ?? ''}'),
                    ],
                  ),
                  if ('${c['problema_midia'] ?? ''}'.isNotEmpty)
                    Text(
                      '${c['problema_midia']}',
                      style: const TextStyle(color: Colors.amber, fontSize: 12),
                      maxLines: 2,
                    ),
                  const Spacer(),
                  _Swap(onSwap: (search) => _swap(c['id'] as int, search)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _tag(String texto, {Color background = Colors.black87}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(4)),
    child: Text(
      texto,
      style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.white),
    ),
  );

  Future<void> _swap(int scene, String search) => actionWithWarning(context, () async {
    final entrou = await widget.api.swapMedia(widget.ep, scene, search);
    return entrou ? 'Nova busca da cena $scene na fila.' : 'A busca já estava na fila.';
  });
}

class _Swap extends StatefulWidget {
  const _Swap({required this.onSwap});

  final void Function(String search) onSwap;

  @override
  State<_Swap> createState() => _SwapState();
}

class _SwapState extends State<_Swap> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Row(
    spacing: 6,
    children: [
      Expanded(
        child: TextField(
          controller: _c,
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(
            isDense: true,
            hintText: 'outra busca (inglês)',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _send(),
        ),
      ),
      FilledButton.tonal(onPressed: _send, child: const Text('Trocar')),
    ],
  );

  void _send() {
    widget.onSwap(_c.text.trim());
    _c.clear();
  }
}
