import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'jobs_api.dart';

const modalities = {'remoto': 'Remoto', 'hibrido': 'Híbrido', 'presencial': 'Presencial'};
const contracts = {'clt': 'CLT', 'pj': 'PJ', 'estagio': 'Estágio', 'outro': 'Outro'};
const _colorMixed = Color(0xFF6A1B9A);

Color modalityColor(Object? m) => switch (m) {
  'remoto' => const Color(0xFF2E7D32),
  'hibrido' => const Color(0xFFEF6C00),
  'presencial' => const Color(0xFF1565C0),
  _ => Colors.blueGrey,
};

/// Colored tag for work mode or contract type (what matters most in the job).
class Pill extends StatelessWidget {
  const Pill(this.texto, this.color, {super.key});

  final String texto;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.15),
      border: Border.all(color: color),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(texto, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
  );
}

/// Work mode and contract badges of a job (an unspecified contract does not show up).
List<Widget> slotPills(Doc v, {Color? contractColor}) => [
  if (modalities[v['modalidade']] case final String m) Pill(m, modalityColor(v['modalidade'])),
  if (contracts[v['contrato']] case final String c) Pill(c, contractColor ?? Colors.brown),
];

/// Jobs map: one pin per city (work mode color; purple if mixed), with the total and
/// the contracts. The ones without a place (remote with no headquarters given) go in a separate button.
class JobsMap extends StatefulWidget {
  const JobsMap({super.key, required this.slots, required this.card});

  final List<Doc> slots;
  final Widget Function(Doc) card;

  @override
  State<JobsMap> createState() => _JobsMapState();
}

class _JobsMapState extends State<JobsMap> {
  final _map = MapController();

  void _open(String titulo, List<Doc> slots) => showModalBottomSheet<void>(
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
          for (final v in slots) widget.card(v),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final escuro = Theme.of(context).brightness == Brightness.dark;
    final byCity = <String, List<Doc>>{};
    final withoutPlace = <Doc>[];
    for (final v in widget.slots) {
      final g = v['geo'];
      if (g is Map && g['lat'] is num) {
        byCity.putIfAbsent('${g['cidade']}/${g['uf']}', () => []).add(v);
      } else {
        withoutPlace.add(v);
      }
    }
    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
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
                for (final e in byCity.entries)
                  Marker(
                    point: LatLng(
                      (e.value.first['geo']['lat'] as num).toDouble(),
                      (e.value.first['geo']['lon'] as num).toDouble(),
                    ),
                    width: 64,
                    height: 52,
                    alignment: Alignment.topCenter,
                    child: _Pin(
                      slots: e.value,
                      onTap: () => _open(
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
        if (withoutPlace.isNotEmpty)
          Positioned(
            top: 12,
            left: 12,
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.public),
              label: Text('${withoutPlace.length} sem lugar no mapa'),
              onPressed: () => _open('Sem cidade informada (remotas, em geral)', withoutPlace),
            ),
          ),
        const Positioned(bottom: 28, right: 12, child: _Caption()),
      ],
    );
  }
}

class _Pin extends StatelessWidget {
  const _Pin({required this.slots, required this.onTap});

  final List<Doc> slots;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final modes = {for (final v in slots) v['modalidade']};
    final color = modes.length == 1 ? modalityColor(modes.first) : _colorMixed;
    final kinds = {for (final v in slots) contracts[v['contrato']]}..remove(null);
    final dica = [
      for (final v in slots.take(8))
        '${v['titulo']} · ${v['empresa']} · ${modalities[v['modalidade']] ?? '?'} · ${contracts[v['contrato']] ?? '?'}',
      if (slots.length > 8) '… e mais ${slots.length - 8}',
    ].join('\n');
    return GestureDetector(
      onTap: onTap,
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
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black38)],
              ),
              child: Text(
                '${slots.length}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
            if (kinds.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 2),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(4)),
                child: Text(
                  kinds.join('/'),
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

class _Caption extends StatelessWidget {
  const _Caption();

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          for (final (nome, color) in [
            for (final m in modalities.entries) (m.value, modalityColor(m.key)),
            ('Misturadas', _colorMixed),
          ])
            Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 6,
              children: [
                Icon(Icons.circle, size: 12, color: color),
                Text(nome, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
        ],
      ),
    ),
  );
}
