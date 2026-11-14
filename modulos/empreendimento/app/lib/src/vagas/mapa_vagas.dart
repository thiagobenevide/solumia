import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'api_vagas.dart';

const modalidades = {'remoto': 'Remoto', 'hibrido': 'Híbrido', 'presencial': 'Presencial'};
const contratos = {'clt': 'CLT', 'pj': 'PJ', 'estagio': 'Estágio', 'outro': 'Outro'};
const _corMista = Color(0xFF6A1B9A);

Color corModalidade(Object? m) => switch (m) {
  'remoto' => const Color(0xFF2E7D32),
  'hibrido' => const Color(0xFFEF6C00),
  'presencial' => const Color(0xFF1565C0),
  _ => Colors.blueGrey,
};

/// Etiqueta colorida de modalidade ou contrato (o que mais importa na vaga).
class Selo extends StatelessWidget {
  const Selo(this.texto, this.cor, {super.key});

  final String texto;
  final Color cor;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: cor.withValues(alpha: 0.15),
      border: Border.all(color: cor),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(texto, style: TextStyle(color: cor, fontSize: 12, fontWeight: FontWeight.w600)),
  );
}

/// Selos de modalidade e contrato de uma vaga (contrato não informado não aparece).
List<Widget> selosDaVaga(Doc v, {Color? corContrato}) => [
  if (modalidades[v['modalidade']] case final String m) Selo(m, corModalidade(v['modalidade'])),
  if (contratos[v['contrato']] case final String c) Selo(c, corContrato ?? Colors.brown),
];

/// Mapa das vagas: um pino por cidade (cor da modalidade; roxo se misturadas), com o total e
/// os contratos. As sem lugar (remotas sem sede informada) ficam num botão à parte.
class MapaVagas extends StatefulWidget {
  const MapaVagas({super.key, required this.vagas, required this.cartao});

  final List<Doc> vagas;
  final Widget Function(Doc) cartao;

  @override
  State<MapaVagas> createState() => _MapaVagasState();
}

class _MapaVagasState extends State<MapaVagas> {
  final _mapa = MapController();

  void _abrir(String titulo, List<Doc> vagas) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.95,
      builder: (context, rolagem) => ListView(
        controller: rolagem,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Text(titulo, style: Theme.of(context).textTheme.titleMedium),
          for (final v in vagas) widget.cartao(v),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final escuro = Theme.of(context).brightness == Brightness.dark;
    final porCidade = <String, List<Doc>>{};
    final semLugar = <Doc>[];
    for (final v in widget.vagas) {
      final g = v['geo'];
      if (g is Map && g['lat'] is num) {
        porCidade.putIfAbsent('${g['cidade']}/${g['uf']}', () => []).add(v);
      } else {
        semLugar.add(v);
      }
    }
    return Stack(
      children: [
        FlutterMap(
          mapController: _mapa,
          options: MapOptions(
            initialCenter: const LatLng(-14.2, -51.9),
            initialZoom: 4,
            minZoom: 3,
            maxZoom: 16,
            backgroundColor: escuro ? const Color(0xFF1B1F24) : const Color(0xFFE8EEF2),
            interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              tileBuilder: escuro ? darkModeTileBuilder : null,
              userAgentPackageName: 'agent.empreendimento',
            ),
            MarkerLayer(
              markers: [
                for (final e in porCidade.entries)
                  Marker(
                    point: LatLng(
                      (e.value.first['geo']['lat'] as num).toDouble(),
                      (e.value.first['geo']['lon'] as num).toDouble(),
                    ),
                    width: 64,
                    height: 52,
                    alignment: Alignment.topCenter,
                    child: _Pino(
                      vagas: e.value,
                      aoTocar: () => _abrir(
                        '${e.key}${e.value.first['geo']['aproximado'] == true ? ' (só a UF: capital)' : ''}'
                        ' · ${e.value.length} vaga(s)',
                        e.value,
                      ),
                    ),
                  ),
              ],
            ),
            const RichAttributionWidget(
              alignment: AttributionAlignment.bottomLeft,
              attributions: [TextSourceAttribution('OpenStreetMap')],
            ),
          ],
        ),
        if (semLugar.isNotEmpty)
          Positioned(
            top: 12,
            left: 12,
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.public),
              label: Text('${semLugar.length} sem lugar no mapa'),
              onPressed: () => _abrir('Sem cidade informada (remotas, em geral)', semLugar),
            ),
          ),
        const Positioned(bottom: 28, right: 12, child: _Legenda()),
      ],
    );
  }
}

class _Pino extends StatelessWidget {
  const _Pino({required this.vagas, required this.aoTocar});

  final List<Doc> vagas;
  final VoidCallback aoTocar;

  @override
  Widget build(BuildContext context) {
    final modos = {for (final v in vagas) v['modalidade']};
    final cor = modos.length == 1 ? corModalidade(modos.first) : _corMista;
    final tipos = {for (final v in vagas) contratos[v['contrato']]}..remove(null);
    final dica = [
      for (final v in vagas.take(8))
        '${v['titulo']} · ${v['empresa']} · ${modalidades[v['modalidade']] ?? '?'} · ${contratos[v['contrato']] ?? '?'}',
      if (vagas.length > 8) '… e mais ${vagas.length - 8}',
    ].join('\n');
    return GestureDetector(
      onTap: aoTocar,
      child: Tooltip(
        message: dica,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: cor,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black38)],
              ),
              child: Text(
                '${vagas.length}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
            if (tipos.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 2),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(4)),
                child: Text(
                  tipos.join('/'),
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Legenda extends StatelessWidget {
  const _Legenda();

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          for (final (nome, cor) in [
            for (final m in modalidades.entries) (m.value, corModalidade(m.key)),
            ('Misturadas', _corMista),
          ])
            Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 6,
              children: [
                Icon(Icons.circle, size: 12, color: cor),
                Text(nome, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
        ],
      ),
    ),
  );
}
