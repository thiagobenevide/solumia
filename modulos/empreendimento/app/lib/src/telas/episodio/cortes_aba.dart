import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../api_esteira.dart';
import '../../modelos.dart';
import '../util.dart';

/// Cortes da narração: ouvir cada trecho na gravação bruta, inverter fica/sai e aplicar (roda o `limpar`).
class CortesAba extends StatefulWidget {
  const CortesAba({super.key, required this.api, required this.ep});

  final ApiEsteira api;
  final String ep;

  @override
  State<CortesAba> createState() => _CortesAbaState();
}

class _CortesAbaState extends State<CortesAba> {
  String _filtro = 'revisar';
  late Future<Json> _dados = _carregar();
  final _player = AudioPlayer();
  String? _fonte;
  int? _tocando;
  Timer? _parar;

  static const _rotulos = {
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

  Future<Json> _carregar() => widget.api.cortes(widget.ep, _filtro);

  @override
  void dispose() {
    _parar?.cancel();
    _player.dispose();
    super.dispose();
  }

  /// Toca o trecho com um respiro antes e depois, como o painel.
  Future<void> _ouvir(String bruta, Json t) async {
    final ini = (t['ini'] as num).toDouble(), fim = (t['fim'] as num).toDouble();
    if (_fonte != bruta) {
      await _player.setSourceUrl(widget.api.arquivo(bruta));
      _fonte = bruta;
    }
    await _player.seek(Duration(milliseconds: ((ini - 0.4).clamp(0, double.infinity) * 1000).round()));
    await _player.resume();
    setState(() => _tocando = t['k'] as int);
    _parar?.cancel();
    _parar = Timer(Duration(milliseconds: ((fim - ini + 0.9) * 1000).round()), () {
      _player.pause();
      if (mounted) setState(() => _tocando = null);
    });
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _dados,
    builder: (context, s) {
      if (s.hasError) return Vazio('${s.error}', icone: Icons.content_cut);
      final d = s.data;
      if (d == null) return const Center(child: CircularProgressIndicator());
      final trechos = [for (final t in d['trechos'] as List) t as Json];
      final faltando = d['faltando'] as List;
      final bruta = d['bruta'] as String?;
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
                  ? FilledButton(onPressed: _aplicar, child: const Text('Aplicar cortes'))
                  : OutlinedButton(onPressed: _aplicar, child: const Text('Aplicar cortes')),
            ],
          ),
          if (bruta == null)
            const Padding(padding: EdgeInsets.only(top: 8), child: Text('Sem gravação bruta para ouvir.')),
          if (faltando.isNotEmpty)
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
                    for (final f in faltando) Text('• $f'),
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
              selected: {_filtro},
              onSelectionChanged: (v) => setState(() {
                _filtro = v.first;
                _dados = _carregar();
              }),
            ),
          ),
          if (trechos.isEmpty) const Vazio('Nada neste filtro.'),
          for (final t in trechos) _trecho(context, t, bruta),
        ],
      );
    },
  );

  Widget _trecho(BuildContext context, Json t, String? bruta) {
    final manter = t['manter'] == true;
    final ini = (t['ini'] as num).toDouble();
    final quem = switch (t['por']) {
      'llm' => 'LLM local',
      'claude' => 'Claude',
      'painel' => 'você',
      _ => 'regra',
    };
    final motivo = '${t['motivo']}'.split(' → ').last;
    return Opacity(
      opacity: manter ? 1 : 0.6,
      child: Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: TextButton.icon(
            icon: Icon(_tocando == t['k'] ? Icons.volume_up : Icons.play_arrow, size: 18),
            label: Text('${ini ~/ 60}:${(ini % 60).toStringAsFixed(1).padLeft(4, '0')}'),
            onPressed: bruta == null ? null : () => _ouvir(bruta, t),
          ),
          title: Text(
            '${t['texto']}',
            style: manter ? null : const TextStyle(decoration: TextDecoration.lineThrough),
          ),
          subtitle: Text(
            '${_rotulos[t['tipo']] ?? t['tipo']} · decidido por $quem · '
            '${motivo.length > 140 ? motivo.substring(0, 140) : motivo}',
          ),
          trailing: FilledButton.tonal(
            style: FilledButton.styleFrom(
              backgroundColor: (manter ? Colors.green : Colors.red).withValues(alpha: 0.18),
              foregroundColor: manter ? Colors.green.shade200 : Colors.red.shade200,
            ),
            onPressed: () => _alternar(t),
            child: Text(manter ? 'Fica' : 'Sai'),
          ),
        ),
      ),
    );
  }

  Future<void> _alternar(Json t) => acaoComAviso(context, () async {
    final novo = await widget.api.alternarCorte(widget.ep, t['k'] as int);
    setState(() { _dados = _carregar(); });
    return novo['manter'] == true ? 'O trecho fica.' : 'O trecho sai.';
  });

  Future<void> _aplicar() => acaoComAviso(context, () async {
    final entrou = await widget.api.rodar(widget.ep, 'limpar');
    return entrou ? 'Cortes na fila (etapa limpar).' : 'O limpar já estava na fila.';
  });
}
