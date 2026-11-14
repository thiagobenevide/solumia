import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../modelos.dart';
import '../telas/util.dart';

/// Portão 1 · corte pelo som: cada emenda (vício, respiração, pausa que saiu) com "antes" (narração editada) e
/// "depois" (narração cortada), e a reversão; o que a conferência achou (palavras sumidas, repetições) no topo.
class CorteTela extends StatefulWidget {
  const CorteTela({super.key, required this.api, required this.ep});

  final ApiEsteira api;
  final String ep;

  @override
  State<CorteTela> createState() => _CorteTelaState();
}

class _CorteTelaState extends State<CorteTela> {
  final _player = AudioPlayer();
  String? _fonte;
  String? _tocando;
  Timer? _parar;
  String _filtro = 'todas';

  @override
  void dispose() {
    _parar?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _ouvir(String? url, num ini, num fim, String chave) async {
    if (url == null) return;
    if (_fonte != url) {
      await _player.setSourceUrl(widget.api.arquivo(url));
      _fonte = url;
    }
    final a = (ini.toDouble() - 1.5).clamp(0.0, double.infinity);
    await _player.seek(Duration(milliseconds: (a * 1000).round()));
    await _player.resume();
    setState(() => _tocando = chave);
    _parar?.cancel();
    _parar = Timer(Duration(milliseconds: ((fim.toDouble() + 1.5 - a) * 1000).round()), () {
      _player.pause();
      if (mounted) setState(() => _tocando = null);
    });
  }

  String _s(num v) => '${v.toStringAsFixed(2).replaceAll('.', ',')} s';

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Emendas · ${widget.ep}')),
    body: Sondagem<Json>(
      intervalo: const Duration(seconds: 6),
      carregar: () => widget.api.corteEstudio(widget.ep),
      construir: (context, d, recarregar) {
        final est = d['estado'] as Json;
        if (est['feito'] != true) {
          return const Vazio('Ainda sem corte pelo som. Volte e toque em "Cortar pelo som".', icone: Icons.graphic_eq);
        }
        final conf = (d['conferencia'] as Json?) ?? {};
        final todas = [for (final e in d['emendas'] as List) e as Json];
        final emendas = todas.where((e) => switch (_filtro) {
          'vicio' => e['tipo'] == 'vicio',
          'pausa' => e['tipo'] == 'pausa',
          'revertidas' => e['revertida'] == true,
          _ => true,
        }).toList();
        final alertas = [
          for (final s in conf['sumidas'] as List? ?? []) ('sumiu', s as Json),
          for (final r in conf['repeticoes'] as List? ?? []) ('repetiu', r as Json),
        ];
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: emendas.length + 1,
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
                  if (alertas.isNotEmpty) ...[
                    Text('A conferir (${alertas.length})', style: Theme.of(context).textTheme.titleSmall),
                    for (final (tipo, a) in alertas)
                      ListTile(
                        dense: true,
                        leading: Icon(tipo == 'sumiu' ? Icons.warning_amber : Icons.repeat),
                        title: Text('$tipo: "${a['texto']}"'),
                        subtitle: Text('em ${_s(a['t'] as num)} ${tipo == 'sumiu' ? '(narração editada)' : '(corte)'}'),
                        trailing: IconButton(
                          icon: const Icon(Icons.play_arrow),
                          onPressed: () => _ouvir(
                            tipo == 'sumiu' ? d['editada'] as String? : d['cortada'] as String?,
                            a['t'] as num,
                            a['t'] as num,
                            '$tipo${a['t']}',
                          ),
                        ),
                      ),
                    const Divider(),
                  ],
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final (k, r) in [('todas', 'Todas'), ('vicio', 'Vícios'), ('pausa', 'Pausas'), ('revertidas', 'Revertidas')])
                        ChoiceChip(label: Text(r), selected: _filtro == k, onSelected: (_) => setState(() => _filtro = k)),
                    ],
                  ),
                ],
              );
            }
            final e = emendas[i - 1];
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
                      icon: Icon(_tocando == 'a$id' ? Icons.volume_up : Icons.history),
                      onPressed: () => _ouvir(d['editada'] as String?, e['de'] as num, e['ate'] as num, 'a$id'),
                    ),
                    IconButton(
                      tooltip: 'Depois (corte)',
                      icon: Icon(_tocando == 'd$id' ? Icons.volume_up : Icons.play_arrow),
                      onPressed: () => _ouvir(d['cortada'] as String?, e['out'] as num, e['out'] as num, 'd$id'),
                    ),
                    Tooltip(
                      message: rev ? 'Revertida (o trecho fica)' : 'Cortada',
                      child: Switch(
                        value: !rev,
                        onChanged: (corta) => acaoComAviso(context, () async {
                          await widget.api.reverterEmenda(widget.ep, e['de'] as num, e['ate'] as num, !corta);
                          await recarregar();
                          return corta ? 'Volta a cortar; corte na fila' : 'Revertida; corte na fila';
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
