import 'package:flutter/material.dart';

import '../../api_esteira.dart';
import '../../modelos.dart';
import '../util.dart';

/// Linha do tempo: cada cena com o quadro da mídia, a nota do modelo de visão, o clima e a busca; trocar
/// a mídia de uma cena com outro termo (põe a busca só dessa cena na fila).
class CenasAba extends StatefulWidget {
  const CenasAba({super.key, required this.api, required this.ep});

  final ApiEsteira api;
  final String ep;

  @override
  State<CenasAba> createState() => _CenasAbaState();
}

class _CenasAbaState extends State<CenasAba> {
  late Future<Json> _dados = widget.api.cenas(widget.ep);

  static const _climas = <String, MaterialColor>{
    'tensao': Colors.red,
    'revelacao': Colors.purple,
    'dado': Colors.lightBlue,
    'respiro': Colors.green,
  };

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _dados,
    builder: (context, s) {
      if (s.hasError) return Vazio('${s.error}', icone: Icons.view_timeline_outlined);
      final d = s.data;
      if (d == null) return const Center(child: CircularProgressIndicator());
      final cenas = [for (final c in d['cenas'] as List) c as Json];
      final graficos = [for (final g in d['graficos'] as List) g as Json];
      return RefreshIndicator(
        onRefresh: () async => setState(() { _dados = widget.api.cenas(widget.ep); }),
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverList.list(
                children: [
                  Text(
                    '${cenas.length} cenas · ${graficos.length} gráficos. Nota da mídia pelo modelo de visão (1–5); '
                    'troque a mídia de uma cena com outro termo de busca.',
                  ),
                  const SizedBox(height: 6),
                  const Wrap(
                    spacing: 6,
                    children: [
                      SeloMotor('py', rotulo: 'Python + APIs dos bancos'),
                      SeloMotor('local', rotulo: 'visão local'),
                    ],
                  ),
                  if (graficos.isNotEmpty) ...[
                    const Secao('Gráficos animados'),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final g in graficos)
                          Chip(label: Text('${_tempo(g['inicio'] as num)}  ${g['modelo']}  ${g['rotulo']}')),
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
                itemCount: cenas.length,
                itemBuilder: (context, i) => _cena(context, cenas[i]),
              ),
            ),
          ],
        ),
      );
    },
  );

  static String _tempo(num s) => '${s ~/ 60}:${(s % 60).floor().toString().padLeft(2, '0')}';

  Widget _cena(BuildContext context, Json c) {
    final nota = c['nota_midia'] as num?;
    final cor = _climas[c['clima']] ?? Colors.blueGrey;
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
                Positioned(top: 6, left: 6, child: _etiqueta('${c['id']} · ${_tempo(c['inicio'] as num)}')),
                if (nota != null)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: _etiqueta('★ $nota', fundo: nota < 3 ? Colors.red.shade700 : Colors.black87),
                  ),
                if (c['midia_tipo'] == 'video') Positioned(bottom: 6, right: 6, child: _etiqueta('vídeo')),
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
                      if (c['clima'] != null) SeloMotor('', rotulo: '${c['clima']}', corFixa: cor),
                      SeloMotor('py', rotulo: '${c['busca_en'] ?? c['busca'] ?? ''}'),
                    ],
                  ),
                  if ('${c['problema_midia'] ?? ''}'.isNotEmpty)
                    Text(
                      '${c['problema_midia']}',
                      style: const TextStyle(color: Colors.amber, fontSize: 12),
                      maxLines: 2,
                    ),
                  const Spacer(),
                  _Trocar(onTrocar: (busca) => _trocar(c['id'] as int, busca)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _etiqueta(String texto, {Color fundo = Colors.black87}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(color: fundo, borderRadius: BorderRadius.circular(4)),
    child: Text(
      texto,
      style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.white),
    ),
  );

  Future<void> _trocar(int cena, String busca) => acaoComAviso(context, () async {
    final entrou = await widget.api.trocarMidia(widget.ep, cena, busca);
    return entrou ? 'Nova busca da cena $cena na fila.' : 'A busca já estava na fila.';
  });
}

class _Trocar extends StatefulWidget {
  const _Trocar({required this.onTrocar});

  final void Function(String busca) onTrocar;

  @override
  State<_Trocar> createState() => _TrocarState();
}

class _TrocarState extends State<_Trocar> {
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
          onSubmitted: (_) => _enviar(),
        ),
      ),
      FilledButton.tonal(onPressed: _enviar, child: const Text('Trocar')),
    ],
  );

  void _enviar() {
    widget.onTrocar(_c.text.trim());
    _c.clear();
  }
}
