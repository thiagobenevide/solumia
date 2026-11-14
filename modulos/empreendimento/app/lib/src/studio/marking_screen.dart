import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../models.dart';
import '../screens/util.dart';

const _auto = 'auto';
const _none = 'nenhuma';

/// Marking on the script: each span of the cut narration gets its scene (or "auto", the local AI picks; or
/// "nenhuma", media only). In the marked ones the local AI only fills title and values. Confirming releases the director and
/// queues the production with the style, formats and intensity chosen on the production screen.
class MarkingScreen extends StatefulWidget {
  const MarkingScreen({super.key, required this.api, required this.ep, required this.produce});

  final ApiEsteira api;
  final String ep;
  final Json produce; // {estilo, formatos, intensidade}

  @override
  State<MarkingScreen> createState() => _MarkingScreenState();
}

class _MarkingScreenState extends State<MarkingScreen> {
  late final Future<Json> _dados = widget.api.marking(widget.ep, estilo: '${widget.produce['estilo'] ?? ''}');
  Map<int, String>? _marks; // span index → scene
  List<Json> _spans = [];

  static String _nome(String c) => switch (c) {
    _auto => 'auto (IA local)',
    _none => 'nenhuma (só mídia)',
    _ => c.replaceAll('_', ' '),
  };

  static String _time(num s) => '${s ~/ 60}:${(s % 60).floor().toString().padLeft(2, '0')}';

  List<Json> get _list => [
    for (final t in _spans) {'texto': t['texto'], 'cena': _marks![t['i'] as int] ?? _auto},
  ];

  Future<void> _save({required bool confirm}) => actionWithWarning(context, () async {
    await widget.api.saveMarking(widget.ep, _list, confirm: confirm, produce: confirm ? widget.produce : null);
    if (confirm && mounted) Navigator.pop(context);
    return confirm ? 'Apontamento confirmado; produção na fila' : 'Apontamento salvo';
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('Apontamento · ${widget.ep}'),
      actions: [
        TextButton(onPressed: _marks == null ? null : () => _save(confirm: false), child: const Text('Salvar')),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: FilledButton.icon(
            icon: const Icon(Icons.play_arrow),
            label: const Text('Confirmar e produzir'),
            onPressed: _marks == null ? null : () => _save(confirm: true),
          ),
        ),
      ],
    ),
    body: FutureBuilder<Json>(
      future: _dados,
      builder: (context, snap) {
        if (snap.hasError) return Empty('${snap.error}', icone: Icons.error_outline);
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final d = snap.data!;
        _spans = [for (final t in d['trechos'] as List) t as Json];
        _marks ??= {for (final t in _spans) if (t['cena'] != _auto) t['i'] as int: t['cena'] as String};
        final options = [_auto, _none, for (final c in d['cenas'] as List) c as String];
        final marcadas = _marks!.length;
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: _spans.length + 1,
          itemBuilder: (context, i) {
            if (i == 0) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Estilo ${d['estilo']} · ${_spans.length} trechos · $marcadas marcados'
                  '${d['confirmado'] == true ? ' · confirmado' : ''}. Marque a cena onde você já sabe o que quer; '
                  'o resto fica com a IA local.',
                ),
              );
            }
            final t = _spans[i - 1];
            final idx = t['i'] as int;
            final scene = _marks![idx] ?? _auto;
            return Card(
              color: scene == _auto ? null : Theme.of(context).colorScheme.secondaryContainer,
              child: ListTile(
                leading: Text(_time(t['ini'] as num)),
                title: Text('${t['texto']}'),
                trailing: DropdownButton<String>(
                  value: options.contains(scene) ? scene : _auto,
                  items: [for (final c in options) DropdownMenuItem(value: c, child: Text(_nome(c)))],
                  onChanged: (v) => setState(() => v == null || v == _auto ? _marks!.remove(idx) : _marks![idx] = v),
                ),
              ),
            );
          },
        );
      },
    ),
  );
}
