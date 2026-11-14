import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../models.dart';
import '../screens/util.dart';

/// Gate 1 · cut by sound: each splice (filler, breath, removed pause) with "before" (edited narration) and
/// "after" (cut narration), and the revert; what the check found (missing words, repetitions) at the top.
class CutScreen extends StatefulWidget {
  const CutScreen({super.key, required this.api, required this.ep});

  final ApiEsteira api;
  final String ep;

  @override
  State<CutScreen> createState() => _CutScreenState();
}

class _CutScreenState extends State<CutScreen> {
  final _player = AudioPlayer();
  String? _source;
  String? _playing;
  Timer? _stop;
  String _filter = 'todas';

  @override
  void dispose() {
    _stop?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _listen(String? url, num startAt, num end, String chave) async {
    if (url == null) return;
    if (_source != url) {
      await _player.setSourceUrl(widget.api.arquivo(url));
      _source = url;
    }
    final a = (startAt.toDouble() - 1.5).clamp(0.0, double.infinity);
    await _player.seek(Duration(milliseconds: (a * 1000).round()));
    await _player.resume();
    setState(() => _playing = chave);
    _stop?.cancel();
    _stop = Timer(Duration(milliseconds: ((end.toDouble() + 1.5 - a) * 1000).round()), () {
      _player.pause();
      if (mounted) setState(() => _playing = null);
    });
  }

  String _s(num v) => '${v.toStringAsFixed(2).replaceAll('.', ',')} s';

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Emendas · ${widget.ep}')),
    body: Sondagem<Json>(
      intervalo: const Duration(seconds: 6),
      carregar: () => widget.api.studioCut(widget.ep),
      construir: (context, d, recarregar) {
        final est = d['estado'] as Json;
        if (est['feito'] != true) {
          return const Empty('Ainda sem corte pelo som. Volte e toque em "Cortar pelo som".', icone: Icons.graphic_eq);
        }
        final conf = (d['conferencia'] as Json?) ?? {};
        final all = [for (final e in d['emendas'] as List) e as Json];
        final joins = all.where((e) => switch (_filter) {
          'vicio' => e['tipo'] == 'vicio',
          'pausa' => e['tipo'] == 'pausa',
          'revertidas' => e['revertida'] == true,
          _ => true,
        }).toList();
        final alerts = [
          for (final s in conf['sumidas'] as List? ?? []) ('sumiu', s as Json),
          for (final r in conf['repeticoes'] as List? ?? []) ('repetiu', r as Json),
        ];
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: joins.length + 1,
          itemBuilder: (context, i) {
            if (i == 0) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (est['atualizado'] != true)
                    const Card(
                      child: ListTile(
                        leading: Icon(Icons.hourglass_top),
                        title: Text('Refazendo o corte com as reversões (ou a narração mudou). Aguarde a fila.'),
                      ),
                    ),
                  Text(
                    '${_s(est['duracao_antes'] as num)} → ${_s(est['duracao'] as num)} · ${est['emendas']} emendas · '
                    '${est['vicios']} vícios · ${est['protegidas']} palavras protegidas · ${est['revertidas']} revertidas · '
                    'texto igual ${(((est['nota'] as num?) ?? 0) * 100).round()}%',
                  ),
                  const SizedBox(height: 8),
                  if (alerts.isNotEmpty) ...[
                    Text('A conferir (${alerts.length})', style: Theme.of(context).textTheme.titleSmall),
                    for (final (kind, a) in alerts)
                      ListTile(
                        dense: true,
                        leading: Icon(kind == 'sumiu' ? Icons.warning_amber : Icons.repeat),
                        title: Text('$kind: "${a['texto']}"'),
                        subtitle: Text('em ${_s(a['t'] as num)} ${kind == 'sumiu' ? '(narração editada)' : '(corte)'}'),
                        trailing: IconButton(
                          icon: const Icon(Icons.play_arrow),
                          onPressed: () => _listen(
                            kind == 'sumiu' ? d['editada'] as String? : d['cortada'] as String?,
                            a['t'] as num,
                            a['t'] as num,
                            '$kind${a['t']}',
                          ),
                        ),
                      ),
                    const Divider(),
                  ],
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final (k, r) in [('todas', 'Todas'), ('vicio', 'Vícios'), ('pausa', 'Pausas'), ('revertidas', 'Revertidas')])
                        ChoiceChip(label: Text(r), selected: _filter == k, onSelected: (_) => setState(() => _filter = k)),
                    ],
                  ),
                ],
              );
            }
            final e = joins[i - 1];
            final id = '${e['id']}';
            final rev = e['revertida'] == true;
            return Card(
              child: ListTile(
                leading: Icon(e['tipo'] == 'vicio' ? Icons.record_voice_over : Icons.space_bar),
                title: Text(
                  '${_s(e['de'] as num)} · −${_s(e['dur'] as num)}'
                  '${(e['texto'] as String? ?? '').isNotEmpty ? ' · "${e['texto']}"' : ''}',
                ),
                subtitle: Text('${e['janela'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    IconButton(
                      tooltip: 'Antes (narração editada)',
                      icon: Icon(_playing == 'a$id' ? Icons.volume_up : Icons.history),
                      onPressed: () => _listen(d['editada'] as String?, e['de'] as num, e['ate'] as num, 'a$id'),
                    ),
                    IconButton(
                      tooltip: 'Depois (corte)',
                      icon: Icon(_playing == 'd$id' ? Icons.volume_up : Icons.play_arrow),
                      onPressed: () => _listen(d['cortada'] as String?, e['out'] as num, e['out'] as num, 'd$id'),
                    ),
                    Tooltip(
                      message: rev ? 'Revertida (o trecho fica)' : 'Cortada',
                      child: Switch(
                        value: !rev,
                        onChanged: (cuts) => actionWithWarning(context, () async {
                          await widget.api.revertSplice(widget.ep, e['de'] as num, e['ate'] as num, !cuts);
                          await recarregar();
                          return cuts ? 'Volta a cortar; corte na fila' : 'Revertida; corte na fila';
                        }),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ),
  );
}
