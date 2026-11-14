import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../exams_api.dart';
import '../models.dart';

/// Color of the exam location by driving distance from the origin.
Color distanceColor(int? km) => km == null
    ? Colors.blueGrey
    : km <= 300
    ? const Color(0xFF2E7D32)
    : km <= 800
    ? const Color(0xFFEF6C00)
    : const Color(0xFFC62828);

LatLng _ll(Local l) => LatLng(l.lat, l.lon);

/// Radar of open IT exams in Brazil: map with your city, the nearest exam location of each
/// exam and the driving route to it; list/detail beside it with openings, salaries, registration,
/// exam and links, and the button that starts following it (study flow by Claude).
class RadarScreen extends StatefulWidget {
  const RadarScreen({super.key, required this.api, required this.onFollow, this.baseMap = true});

  final ExamsApi api;

  /// Called with the id of the created exam (the list screen opens the exam).
  final void Function(String id) onFollow;

  /// Map tiles (the tests turn them off: no network).
  final bool baseMap;

  @override
  State<RadarScreen> createState() => _RadarScreenState();
}

class _RadarScreenState extends State<RadarScreen> {
  final _map = MapController();
  final _routes = <String, TravelRoute>{};
  String? _selected;
  bool _pronto = false;
  // On the phone the list is hidden so the map takes the screen; it opens from the button or on tapping a pin.
  bool _listOpen = false;
  final _spheres = <String>{};

  ExamsApi get api => widget.api;

  Future<void> _select(ItemRadar? item, Local? origin) async {
    setState(() => _selected = item?.id);
    if (item == null || origin == null) {
      if (_pronto) _map.move(const LatLng(-14.2, -51.9), 4);
      return;
    }
    final destination = item.nearest ?? item.headquarters;
    if (destination == null) return;
    var points = [_ll(origin), _ll(destination)];
    if (item.nearest != null && !_routes.containsKey(item.id)) {
      try {
        final r = await api.route(item.id);
        if (mounted) setState(() => _routes[item.id] = r);
      } catch (_) {
        // no route: the straight line stays
      }
    }
    final route = _routes[item.id];
    if (route != null && route.points.length > 1) points = [for (final (la, lo) in route.points) LatLng(la, lo)];
    if (_pronto && mounted) {
      _map.fitCamera(CameraFit.bounds(
        bounds: LatLngBounds.fromPoints([...points, if (item.headquarters != null) _ll(item.headquarters!)]),
        padding: const EdgeInsets.fromLTRB(60, 110, 60, 60),
        maxZoom: 9,
      ));
    }
  }

  Future<void> _follow(ItemRadar item) async {
    final cargo = await showDialog<String>(context: context, builder: (_) => _PickPosition(item: item));
    if (cargo == null || !mounted) return;
    try {
      final id = await api.follow(item.id, cargo);
      widget.onFollow(id);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) => Sondagem<Radar>(
    intervalo: const Duration(seconds: 20),
    carregar: api.radar,
    construir: (context, allItems, reload) {
      final radar = allItems.onlySpheres(_spheres);
      final item = radar.itens.where((i) => i.id == _selected).firstOrNull;
      final mapView = _MapView(
        controle: _map,
        radar: radar,
        selected: item,
        route: item == null ? null : _routes[item.id],
        baseMap: widget.baseMap,
        aoPronto: () => _pronto = true,
        filter: _SphereFilter(
          allItems: allItems,
          spheres: _spheres,
          aoMudar: (e, sim) => setState(() => sim ? _spheres.add(e) : _spheres.remove(e)),
        ),
        onItemTap: (i) => _select(i, radar.origin),
        refresh: () async {
          await api.refreshRadar();
          await reload();
        },
        researchClaude: () async {
          try {
            await api.researchRadarClaude();
          } catch (e) {
            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
          }
          await reload();
        },
      );
      final panel = item == null
          ? _ItemList(radar: radar, onItemTap: (i) => _select(i, radar.origin))
          : _Detail(
              item: item,
              origin: radar.origin,
              route: _routes[item.id],
              back: () => _select(null, null),
              follow: () => _follow(item),
            );
      return LayoutBuilder(builder: (context, c) {
        if (c.maxWidth >= 1000) {
          return Row(children: [
            Expanded(child: mapView),
            SizedBox(width: c.maxWidth >= 1500 ? 480 : 420, child: Material(elevation: 2, child: panel)),
          ]);
        }
        if (item == null && !_listOpen) {
          return Stack(children: [
            Positioned.fill(child: mapView),
            Positioned(
              left: 0,
              right: 0,
              bottom: 16,
              child: Center(
                child: FloatingActionButton.extended(
                  heroTag: null,
                  onPressed: () => setState(() => _listOpen = true),
                  icon: const Icon(Icons.list),
                  label: Text('Lista · ${radar.itens.length}'),
                ),
              ),
            ),
          ]);
        }
        return Column(children: [
          SizedBox(height: c.maxHeight * (item == null ? .5 : .42), child: mapView),
          if (item == null)
            Material(
              elevation: 2,
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.expand_more),
                title: const Text('Ocultar lista'),
                onTap: () => setState(() => _listOpen = false),
              ),
            ),
          Expanded(child: Material(elevation: 2, child: panel)),
        ]);
      });
    },
  );
}

class _MapView extends StatelessWidget {
  const _MapView({
    required this.controle,
    required this.radar,
    required this.selected,
    required this.route,
    required this.baseMap,
    required this.aoPronto,
    required this.filter,
    required this.onItemTap,
    required this.refresh,
    required this.researchClaude,
  });

  final Future<void> Function() researchClaude;
  final MapController controle;
  final Radar radar;
  final ItemRadar? selected;
  final TravelRoute? route;
  final bool baseMap;
  final VoidCallback aoPronto;
  final Widget filter;
  final void Function(ItemRadar?) onItemTap;
  final Future<void> Function() refresh;

  @override
  Widget build(BuildContext context) {
    final topicName = Theme.of(context);
    final dark = topicName.brightness == Brightness.dark;
    final origin = radar.origin;
    final sel = selected;
    final selectedDestination = sel?.nearest ?? sel?.headquarters;
    final line = route != null && route!.points.length > 1
        ? [for (final (la, lo) in route!.points) LatLng(la, lo)]
        : (origin != null && selectedDestination != null ? [_ll(origin), _ll(selectedDestination)] : <LatLng>[]);
    return Stack(
      children: [
        FlutterMap(
          mapController: controle,
          options: MapOptions(
            initialCenter: const LatLng(-14.2, -51.9),
            initialZoom: 4,
            minZoom: 3,
            maxZoom: 16,
            backgroundColor: dark ? const Color(0xFF1B1F24) : const Color(0xFFE8EEF2),
            onMapReady: aoPronto,
            onTap: (_, _) => onItemTap(null),
            interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
          ),
          children: [
            if (baseMap)
              TileLayer(
                // CARTO started requiring a key; OSM does not (in the dark theme, the colors are inverted)
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                tileBuilder: dark ? darkModeTileBuilder : null,
                userAgentPackageName: 'agent.concursos',
              ),
            if (line.length > 1)
              PolylineLayer(polylines: [
                Polyline(
                  points: line,
                  strokeWidth: 5,
                  color: topicName.colorScheme.primary,
                  borderStrokeWidth: 3,
                  borderColor: dark ? Colors.black87 : Colors.white,
                  pattern: route == null || route!.estimated
                      ? StrokePattern.dashed(segments: const [12, 8])
                      : const StrokePattern.solid(),
                ),
              ]),
            MarkerLayer(markers: [
              // other exam locations of the selected one (smaller)
              if (sel != null)
                for (final l in sel.places.where((l) => l.name != selectedDestination?.name))
                  Marker(
                    point: _ll(l),
                    width: 14,
                    height: 14,
                    child: Tooltip(
                      message: '${l.name} · ${l.km ?? l.straightKm} km',
                      child: _Dot(color: distanceColor(l.km ?? l.straightKm), size: 12),
                    ),
                  ),
              // agency headquarters, when it is not the exam location
              if (sel?.headquarters != null && sel!.headquarters!.name != selectedDestination?.name)
                Marker(
                  point: _ll(sel.headquarters!),
                  width: 300,
                  height: 76,
                  alignment: Alignment.topCenter,
                  child: _Labeled(
                    icone: Icons.account_balance,
                    color: const Color(0xFF6A1B9A),
                    text: 'Sede · ${sel.headquarters!.name}',
                  ),
                ),
              // one pin per exam (nearest exam location or headquarters)
              for (final i in radar.itens)
                if ((i.nearest ?? i.headquarters) case final Local l)
                  Marker(
                    point: _ll(l),
                    width: i.id == sel?.id ? 300 : 44,
                    height: i.id == sel?.id ? 82 : 44,
                    alignment: Alignment.topCenter,
                    child: GestureDetector(
                      onTap: () => onItemTap(i),
                      child: i.id == sel?.id
                          ? _Labeled(
                              icone: Icons.place,
                              color: distanceColor(l.km),
                              text: 'Prova · ${l.name}',
                              large: true,
                            )
                          : Tooltip(
                              message: '${i.agency}\n${i.totalOpenings} vaga(s) de TI · ${l.name} · ${l.km ?? '?'} km',
                              child: _Pin(color: distanceColor(l.km), openings: i.totalOpenings),
                            ),
                    ),
                  ),
              // you
              if (origin != null)
                Marker(
                  point: _ll(origin),
                  width: 300,
                  height: 82,
                  alignment: Alignment.topCenter,
                  child: _Labeled(icone: Icons.home, color: const Color(0xFF1565C0), text: 'Você · ${origin.name}', large: true),
                ),
              // distance in the middle of the way
              if (sel != null && line.length > 1 && route != null)
                Marker(
                  point: line[line.length ~/ 2],
                  width: 150,
                  height: 34,
                  child: _Badge(text: '${route!.estimated ? '≈ ' : ''}${route!.km} km · ${duration(route!.hours)}'),
                ),
            ]),
            if (baseMap)
              const RichAttributionWidget(
                alignment: AttributionAlignment.bottomLeft,
                attributions: [TextSourceAttribution('OpenStreetMap'), TextSourceAttribution('OSRM')],
              ),
          ],
        ),
        Positioned(top: 12, left: 12, right: 12, child: _TopBar(radar: radar, filter: filter, refresh: refresh, researchClaude: researchClaude)),
        const Positioned(bottom: 28, right: 12, child: _Legend()),
      ],
    );
  }
}

/// Card at the top of the map: title and filter always; the status (LLM, errors, Claude) only when open, so it does not cover the map.
class _TopBar extends StatefulWidget {
  const _TopBar({required this.radar, required this.filter, required this.refresh, required this.researchClaude});

  final Radar radar;
  final Widget filter;
  final Future<void> Function() refresh;
  final Future<void> Function() researchClaude;

  @override
  State<_TopBar> createState() => _TopBarState();
}

class _TopBarState extends State<_TopBar> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final _TopBar(:radar, :filter, :refresh, :researchClaude) = widget;
    final topicName = Theme.of(context);
    final hasError = radar.error.isNotEmpty || radar.claudeError.isNotEmpty;
    Text line(String t, {bool error = false}) => Text(
      t,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: error ? TextStyle(color: topicName.colorScheme.error, fontSize: 12) : topicName.textTheme.bodySmall,
    );
    final when = radar.updated == null
        ? 'ainda não coletado'
        : 'atualizado ${dataBr(radar.updated, short: true)} ${radar.updated!.substring(11, 16)} UTC';
    return Align(
      alignment: Alignment.topLeft,
      child: Card(
        elevation: 3,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.radar, color: topicName.colorScheme.primary),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    InkWell(
                      onTap: () => setState(() => _expanded = !_expanded),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(child: Text('Concursos de TI abertos · ${radar.itens.length}', style: topicName.textTheme.titleSmall)),
                          if (hasError && !_expanded) ...[
                            const SizedBox(width: 4),
                            Icon(Icons.error_outline, size: 16, color: topicName.colorScheme.error),
                          ],
                          Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 20),
                        ],
                      ),
                    ),
                    if (_expanded) ...[
                      line(
                        radar.collecting
                            ? 'A LLM local está lendo os editais…${radar.pending > 0 ? ' (${radar.pending} na fila)' : ''}'
                            : '$when${radar.pending > 0 ? ' · ${radar.pending} na fila' : ''}',
                      ),
                      if (radar.error.isNotEmpty) line(radar.error, error: true),
                      if (radar.researchingClaude)
                        line('O Claude está pesquisando na internet (alguns minutos)…')
                      else if (radar.claudeError.isNotEmpty)
                        line('Claude: ${radar.claudeError}', error: true)
                      else if (radar.claudeEm != null)
                        line('Claude: ${radar.claudeFound} achado(s) em ${dataBr(radar.claudeEm, short: true)}'),
                    ],
                    // On a narrow screen the filter only shows with the card open, so it does not cover the map.
                    if (_expanded || MediaQuery.sizeOf(context).width >= 700) filter,
                  ],
                ),
              ),
              radar.collecting
                  ? const Padding(padding: EdgeInsets.all(12), child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                  : IconButton(tooltip: 'Buscar agora (PCI + LLM local)', icon: const Icon(Icons.refresh), onPressed: refresh),
              radar.researchingClaude
                  ? const Padding(padding: EdgeInsets.all(12), child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                  : IconButton(tooltip: 'Pesquisar com o Claude (internet: abertos e previstos)', icon: const Icon(Icons.travel_explore), onPressed: researchClaude),
            ],
          ),
        ),
      ),
    );
  }
}

/// Federal / Estadual / Municipal chips (none checked = all), with the count of each.
class _SphereFilter extends StatelessWidget {
  const _SphereFilter({required this.allItems, required this.spheres, required this.aoMudar});

  final Radar allItems;
  final Set<String> spheres;
  final void Function(String sphere, bool marked) aoMudar;

  static const _labels = {'federal': 'Federais', 'estadual': 'Estaduais', 'municipal': 'Municipais'};

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          for (final MapEntry(key: e, value: label) in _labels.entries)
            FilterChip(
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              label: Text('$label · ${allItems.itens.where((i) => i.sphere == e).length}'),
              selected: spheres.contains(e),
              onSelected: (sim) => aoMudar(e, sim),
            ),
        ],
      ),
    ),
  );
}

/// Collapsible legend: on a narrow screen it starts closed (only the button), so it does not cover the map.
class _Legend extends StatefulWidget {
  const _Legend();

  @override
  State<_Legend> createState() => _LegendState();
}

class _LegendState extends State<_Legend> {
  bool? _isOpen;

  @override
  Widget build(BuildContext context) {
    final isOpen = _isOpen ?? MediaQuery.sizeOf(context).width >= 700;
    if (!isOpen) {
      return FloatingActionButton.small(
        heroTag: null,
        tooltip: 'Legenda',
        onPressed: () => setState(() => _isOpen = true),
        child: const Icon(Icons.info_outline),
      );
    }
    Widget item(Color c, String t) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(mainAxisSize: MainAxisSize.min, children: [_Dot(color: c, size: 10), const SizedBox(width: 6), Text(t, style: const TextStyle(fontSize: 12))]),
    );
    return Card(
      elevation: 2,
      child: InkWell(
        onTap: () => setState(() => _isOpen = false),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              item(const Color(0xFF1565C0), 'Você'),
              item(distanceColor(1), 'Prova até 300 km'),
              item(distanceColor(500), '300–800 km'),
              item(distanceColor(900), 'Mais de 800 km'),
              item(const Color(0xFF6A1B9A), 'Sede do órgão'),
            ],
          ),
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
  );
}

/// Pin with the number of IT openings.
class _Pin extends StatelessWidget {
  const _Pin({required this.color, required this.openings});

  final Color color;
  final int openings;

  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.topCenter,
    children: [
      Icon(Icons.location_on, size: 44, color: color, shadows: const [Shadow(blurRadius: 6, color: Colors.black38)]),
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
          child: Text('$openings', style: TextStyle(fontSize: openings > 99 ? 8 : 11, fontWeight: FontWeight.bold, color: color)),
        ),
      ),
    ],
  );
}

/// Icon with a pill label below (you, headquarters, selected exam location).
class _Labeled extends StatelessWidget {
  const _Labeled({required this.icone, required this.color, required this.text, this.large = false});

  final IconData icone;
  final Color color;
  final String text;
  final bool large;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        padding: EdgeInsets.all(large ? 7 : 5),
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2.5),
          boxShadow: const [BoxShadow(blurRadius: 8, color: Colors.black38)],
        ),
        child: Icon(icone, size: large ? 22 : 16, color: Colors.white),
      ),
      const SizedBox(height: 3),
      Flexible(child: _Badge(text: text, color: color)),
    ],
  );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final topicName = Theme.of(context);
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: topicName.colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color ?? topicName.colorScheme.primary, width: 1.5),
          boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
        ),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color ?? topicName.colorScheme.primary),
        ),
      ),
    );
  }
}

class _ItemList extends StatelessWidget {
  const _ItemList({required this.radar, required this.onItemTap});

  final Radar radar;
  final void Function(ItemRadar) onItemTap;

  @override
  Widget build(BuildContext context) {
    final topicName = Theme.of(context);
    if (radar.itens.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            radar.collecting
                ? 'Buscando concursos de TI… a LLM local lê cada edital (alguns minutos).'
                : 'Nenhum concurso de TI com inscrição aberta encontrado ainda. Toque em ↻ no mapa para buscar agora '
                      'ou na lupa de globo para o Claude pesquisar na internet (abertos e previstos); '
                      'a busca do PCI também roda sozinha a cada 6 horas.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: radar.itens.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, n) {
        final i = radar.itens[n];
        final l = i.nearest;
        return ListTile(
          onTap: () => onItemTap(i),
          leading: CircleAvatar(
            backgroundColor: distanceColor(l?.km).withValues(alpha: .15),
            child: Text('${i.totalOpenings}', style: TextStyle(color: distanceColor(l?.km), fontWeight: FontWeight.bold)),
          ),
          title: Text(i.agency, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [
              [if (i.board.isNotEmpty) i.board, if (i.maxSalary > 0) 'até ${real(i.maxSalary)}'].join(' · '),
              'Inscrições até ${dataBr(i.registrationEnd)}${i.examDate.isEmpty ? '' : ' · prova ${dataBr(i.examDate)}'}',
            ].where((s) => s.isNotEmpty).join('\n'),
          ),
          isThreeLine: true,
          trailing: l == null
              ? null
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('${l.km ?? l.straightKm} km', style: topicName.textTheme.titleSmall?.copyWith(color: distanceColor(l.km))),
                    Text(l.name, style: topicName.textTheme.bodySmall),
                  ],
                ),
        );
      },
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({required this.item, required this.origin, required this.route, required this.back, required this.follow});

  final ItemRadar item;
  final Local? origin;
  final TravelRoute? route;
  final VoidCallback back;
  final VoidCallback follow;

  @override
  Widget build(BuildContext context) {
    final topicName = Theme.of(context);
    final l = item.nearest;
    final km = route?.km ?? l?.km;
    final hours = route?.hours ?? l?.hours;
    Widget section(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Text(t.toUpperCase(), style: topicName.textTheme.labelMedium?.copyWith(color: topicName.colorScheme.primary, letterSpacing: 1)),
    );
    Widget line(IconData i, String t, [String? s]) => ListTile(dense: true, leading: Icon(i, size: 20), title: Text(t), subtitle: s == null ? null : Text(s));
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        ListTile(
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: back),
          title: Text(item.agency, style: topicName.textTheme.titleMedium),
          subtitle: Text([
            if (item.status == 'previsto') 'Previsto',
            if (item.board.isNotEmpty) 'Banca ${item.board}',
            item.uf,
            if (item.level.isNotEmpty) item.level,
            if (item.source == 'claude') 'achado pelo Claude',
          ].join(' · ')),
        ),
        if (item.summary.isNotEmpty) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(item.summary)),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Kpi(label: 'Vagas de TI', value: '${item.totalOpenings}', icone: Icons.groups),
              if (item.maxSalary > 0) _Kpi(label: 'Salário até', value: real(item.maxSalary), icone: Icons.payments),
              if (km != null) _Kpi(label: 'Distância', value: '${route?.estimated ?? false ? '≈' : ''}$km km', icone: Icons.route, color: distanceColor(km)),
              if (hours != null) _Kpi(label: 'De carro', value: duration(hours), icone: Icons.directions_car),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: follow,
            icon: const Icon(Icons.auto_awesome),
            label: const Text('Acompanhar e montar o fluxo de estudo'),
          ),
        ),
        section('Inscrições'),
        line(Icons.event_available, item.registrationStart.isEmpty ? 'Até ${dataBr(item.registrationEnd)}' : '${dataBr(item.registrationStart)} a ${dataBr(item.registrationEnd)}',
            item.fee.isEmpty ? null : 'Taxa: ${item.fee}'),
        section('Prova'),
        line(Icons.edit_calendar, item.examDate.isEmpty ? 'Data ainda não divulgada' : dataBr(item.examDate),
            item.examTime.isEmpty ? null : 'Horário: ${item.examTime}'),
        if (l != null)
          line(
            Icons.place,
            'Mais perto de você: ${l.name}${l.supposed ? ' (sede; o edital não lista cidades)' : ''}',
            '${origin?.name ?? 'Origem'} → ${l.name}: ${km ?? '?'} km${hours == null ? '' : ' · ${duration(hours)} de carro'}',
          ),
        if (item.places.length > 1)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final x in item.places)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: CircleAvatar(backgroundColor: distanceColor(x.km ?? x.straightKm), radius: 6),
                    label: Text('${x.name} · ${x.km ?? '~${x.straightKm}'} km'),
                  ),
              ],
            ),
          ),
        section('Vagas de TI'),
        for (final v in item.openings)
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: ListTile(
              title: Text(v.cargo),
              subtitle: v.requirements.isEmpty ? null : Text(v.requirements),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(v.salary > 0 ? real(v.salary) : '—', style: topicName.textTheme.titleSmall),
                  Text('${v.openings} vaga(s)${v.reserveList ? ' + CR' : ''}', style: topicName.textTheme.bodySmall),
                ],
              ),
            ),
          ),
        section('Links'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (item.noticeUrl.isNotEmpty)
                OutlinedButton.icon(onPressed: () => abrirLink(context, item.noticeUrl), icon: const Icon(Icons.picture_as_pdf), label: const Text('Edital')),
              OutlinedButton.icon(onPressed: () => abrirLink(context, item.url), icon: const Icon(Icons.article_outlined), label: const Text('Notícia')),
              if (item.registrationLink.isNotEmpty)
                OutlinedButton.icon(onPressed: () => abrirLink(context, item.registrationLink), icon: const Icon(Icons.how_to_reg), label: const Text('Inscrição')),
              if (l != null && origin != null)
                OutlinedButton.icon(
                  onPressed: () => abrirLink(
                    context,
                    'https://www.google.com/maps/dir/?api=1&origin=${origin!.lat},${origin!.lon}&destination=${l.lat},${l.lon}&travelmode=driving',
                  ),
                  icon: const Icon(Icons.map_outlined),
                  label: const Text('Rota no Google Maps'),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi({required this.label, required this.value, required this.icone, this.color});

  final String label, value;
  final IconData icone;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final topicName = Theme.of(context);
    final c = color ?? topicName.colorScheme.primary;
    return Container(
      width: 140,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: c.withValues(alpha: .08), borderRadius: BorderRadius.circular(12), border: Border.all(color: c.withValues(alpha: .3))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icone, size: 18, color: c),
          const SizedBox(height: 4),
          Text(value, style: topicName.textTheme.titleMedium?.copyWith(color: c, fontWeight: FontWeight.bold)),
          Text(label, style: topicName.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _PickPosition extends StatefulWidget {
  const _PickPosition({required this.item});

  final ItemRadar item;

  @override
  State<_PickPosition> createState() => _PickPositionState();
}

class _PickPositionState extends State<_PickPosition> {
  late String? _cargo = widget.item.openings.firstOrNull?.cargo;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Qual vaga você vai disputar?'),
    content: SizedBox(
      width: 480,
      child: RadioGroup<String>(
        groupValue: _cargo,
        onChanged: (v) => setState(() => _cargo = v),
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final v in widget.item.openings)
              RadioListTile<String>(
                value: v.cargo,
                title: Text(v.cargo),
                subtitle: Text('${v.openings} vaga(s)${v.reserveList ? ' + CR' : ''}${v.salary > 0 ? ' · ${real(v.salary)}' : ''}'),
              ),
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text('O app baixa o edital, o Claude monta o fluxo de estudo até 1 semana antes da prova e os prazos viram alertas.'),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(onPressed: _cargo == null ? null : () => Navigator.pop(context, _cargo), child: const Text('Acompanhar')),
    ],
  );
}
