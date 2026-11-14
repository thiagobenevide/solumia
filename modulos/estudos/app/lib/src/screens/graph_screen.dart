import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:agent_core/agent_core.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';

import '../studies_api.dart';
import '../graph_layout.dart';
import '../models.dart';
import 'readings_screen.dart';

const _side = 1600.0;
const _maxGroups = 10; // groups with their own color; the rest stays gray ("outros")

// Animation timeline (0..1): new nodes appear in a wave from the most linked ones, each leaving
// from the node that "pulls" it; the other links are drawn after both ends have appeared.
const _nodeDuration = 0.16, _edgeDelay = 0.05, _edgeDuration = 0.14;
const _window = 1 - _nodeDuration - _edgeDelay - _edgeDuration;
const _existingDuration = 0.5; // nodes that were already on screen slide to the new position

/// Knowledge graph: the vault notes and the links between them. The layout is computed in the background
/// and the screen only animates the result (nodes sprouting and linking). The color is the group (1st tag or title
/// prefix); hovering/tapping highlights the links and labels appear according to the zoom. Filters by
/// area, category (type), color (click on the legend) and keyword search (title, tags and type).
class GraphScreen extends StatefulWidget {
  const GraphScreen({super.key, required this.api, required this.areas});

  final StudiesApi api;
  final List<String> areas;

  @override
  State<GraphScreen> createState() => _GraphScreenState();
}

class _GraphScreenState extends State<GraphScreen> with TickerProviderStateMixin {
  List<GraphNode> _nos = const [];
  List<Edge> _edges = const [];
  Map<String, GraphNode> _byId = const {};
  Map<String, Set<String>> _neighbors = const {};
  Map<String, String> _searchText = const {}; // id → title, tags and type in lowercase
  Map<String, int> _groupOf = const {}; // id → group index (-1 = others)
  List<(String, int)> _groups = const []; // (nome, quantidade), maiores primeiro
  List<String> _types = const [];
  Set<String> _hubs = const {}; // most linked nodes: label visible at any zoom

  // scene on screen: vectors in the order of _simNodes (x, y interleaved)
  List<GraphNode> _simNodes = const [];
  List<(int, int)> _simEdges = const [];
  Float64List _de = Float64List(0), _to = Float64List(0), _pos = Float64List(0);
  Float64List _tam = Float64List(0), _start = Float64List(0);
  Int32List _parent = Int32List(0);
  List<bool> _existed = const [];
  List<int> _order = const [];
  Float32List _points = Float32List(0);
  int _pointCount = 0;
  int _generation = 0; // drops a layout computed for a filter that already changed

  String? _area, _type;
  final Set<int> _filterGroups = {};
  List<String> _terms = const [];
  Set<String> _matches = const {};
  bool _searchOnly = false;
  Timer? _wait;
  String? _selected, _hover, _lastFocus;
  String? _error;
  bool _loading = true;
  Size _size = Size.zero;
  final _visor = TransformationController();
  final _frameIndex = ValueNotifier(0);
  final _labels = <String, TextPainter>{};
  late final _anim = AnimationController(vsync: this)..addListener(_applyFrame);
  late final _focus = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  late final _camera = AnimationController(vsync: this, duration: const Duration(milliseconds: 650));
  Matrix4Tween? _cameraRoute;

  @override
  void initState() {
    super.initState();
    _camera.addListener(() {
      final r = _cameraRoute;
      if (r != null) _visor.value = r.evaluate(CurvedAnimation(parent: _camera, curve: Curves.easeInOutCubic));
    });
    _load();
  }

  @override
  void dispose() {
    _wait?.cancel();
    _anim.dispose();
    _focus.dispose();
    _camera.dispose();
    _visor.dispose();
    _frameIndex.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final (nos, edges) = await widget.api.graph();
      _nos = nos;
      _edges = edges;
      _index();
      _labels.clear();
      _error = null;
      await _redoLayout();
    } on ApiErro catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  static String _groupName(GraphNode n) {
    if (n.tags.isNotEmpty) return '#${n.tags.first}';
    if (n.type != 'nota') return n.type;
    final prefix = n.title.split(RegExp(r' [—–-] ')).first;
    final name = prefix.replaceAll(RegExp(r'[\d\s.()]+$'), '').trim();
    return name.isEmpty ? 'nota' : name;
  }

  void _index() {
    _byId = {for (final n in _nos) n.id: n};
    final viz = <String, Set<String>>{};
    for (final a in _edges) {
      (viz[a.de] ??= {}).add(a.to);
      (viz[a.to] ??= {}).add(a.de);
    }
    _neighbors = viz;
    _searchText = {for (final n in _nos) n.id: '${n.title} #${n.tags.join(' #')} ${n.type}'.toLowerCase()};
    _types = {for (final n in _nos) n.type}.toList()..sort();
    if (!_types.contains(_type)) _type = null;
    final counts = <String, int>{};
    final names = {for (final n in _nos) n.id: _groupName(n)};
    for (final g in names.values) {
      counts[g] = (counts[g] ?? 0) + 1;
    }
    final order = counts.entries.where((e) => e.value >= 3).toList()..sort((a, b) => b.value.compareTo(a.value));
    _groups = [for (final e in order.take(_maxGroups)) (e.key, e.value)];
    _filterGroups.removeWhere((g) => g >= _groups.length);
    final score = {for (final (i, g) in _groups.indexed) g.$1: i};
    _groupOf = {for (final e in names.entries) e.key: score[e.value] ?? -1};
    final byDegree = [..._nos]..sort((a, b) => b.degree.compareTo(a.degree));
    _hubs = {for (final n in byDegree.take(12)) if (n.degree > 2) n.id};
    _searchTerms();
  }

  bool _naArea(GraphNode n) =>
      _area == null ||
      n.tags.any((t) => t.toLowerCase() == _area!.toLowerCase()) ||
      n.title.toLowerCase() == _area!.toLowerCase();

  bool _passes(GraphNode n) =>
      (_type == null || n.type == _type) &&
      (_filterGroups.isEmpty || _filterGroups.contains(_groupOf[n.id] ?? -1)) &&
      (!_searchOnly || _terms.isEmpty || _matches.contains(n.id));

  bool get _filtering => _area != null || _type != null || _filterGroups.isNotEmpty || (_searchOnly && _terms.isNotEmpty);

  /// Area: its nodes and the direct neighbors; then category, color and (if on) the search.
  Set<String> get _visible {
    var base = {for (final n in _nos) if (_naArea(n)) n.id};
    if (_area != null) base = {...base, for (final id in base) ...?_neighbors[id]};
    return {for (final id in base) if (_byId[id] != null && _passes(_byId[id]!)) id};
  }

  Future<void> _redoLayout() async {
    final generation = ++_generation;
    final vis = _visible;
    final nos = [for (final n in _nos) if (vis.contains(n.id)) n];
    final currentItems = <String, Offset>{
      for (final (i, n) in _simNodes.indexed)
        if (_tam[i] > 0) n.id: Offset(_pos[2 * i], _pos[2 * i + 1]),
    };
    final ids = [for (final n in nos) n.id];
    final edges = [for (final a in _edges) if (vis.contains(a.de) && vis.contains(a.to)) (a.de, a.to)];
    // few nodes in common with the current scene: a layout from scratch looks better (the remaining ones still slide)
    final common = ids.where(currentItems.containsKey).length;
    final seed = common * 2 >= ids.length ? currentItems : const <String, Offset>{};
    final finalOnes = await compute(computeLayout, (ids, edges, _side, seed));
    if (!mounted || generation != _generation) return;
    setState(() => _buildScene(nos, finalOnes, currentItems));
  }

  void _buildScene(List<GraphNode> nos, Map<String, Offset> finalOnes, Map<String, Offset> currentItems) {
    final n = nos.length;
    final score = {for (final (i, no) in nos.indexed) no.id: i};
    final edges = <(int, int)>[
      for (final a in _edges)
        if (score[a.de] != null && score[a.to] != null && a.de != a.to) (score[a.de]!, score[a.to]!),
    ];
    final viz = List.generate(n, (_) => <int>[]);
    for (final (a, b) in edges) {
      viz[a].add(b);
      viz[b].add(a);
    }
    final de = Float64List(2 * n), to = Float64List(2 * n);
    final existed = List.filled(n, false);
    for (final (i, no) in nos.indexed) {
      final f = finalOnes[no.id] ?? Offset.zero;
      final a = currentItems[no.id];
      existed[i] = a != null;
      to[2 * i] = f.dx;
      to[2 * i + 1] = f.dy;
      de[2 * i] = (a ?? f).dx;
      de[2 * i + 1] = (a ?? f).dy;
    }
    // appearance order: breadth-first search from what is already on screen, otherwise from the most linked nodes
    final byDegree = List.generate(n, (i) => i)..sort((a, b) => viz[b].length.compareTo(viz[a].length));
    final parent = Int32List(n)..fillRange(0, n, -1);
    final seen = List.of(existed);
    final queue = [for (final i in byDegree) if (existed[i]) i];
    final order = <int>[];
    var head = 0, root = 0;
    while (order.length < n) {
      if (head == queue.length) {
        while (seen[byDegree[root]]) {
          root++;
        }
        seen[byDegree[root]] = true;
        queue.add(byDegree[root]);
      }
      final i = queue[head++];
      order.add(i);
      for (final j in viz[i]) {
        if (!seen[j]) {
          seen[j] = true;
          parent[j] = i;
          queue.add(j);
        }
      }
    }
    final newItems = existed.where((e) => !e).length;
    final start = Float64List(n);
    var k = 0;
    for (final i in order) {
      if (!existed[i]) start[i] = newItems <= 1 ? 0 : _window * k++ / (newItems - 1);
    }

    _simNodes = nos;
    _simEdges = edges;
    _de = de;
    _to = to;
    _pos = Float64List.fromList(de);
    _tam = Float64List(n);
    _start = start;
    _parent = parent;
    _existed = existed;
    _order = order;
    _points = Float32List(edges.length * 4);
    if (_selected != null && score[_selected] == null) _selected = null;
    if (_hover != null && score[_hover] == null) _hover = null;
    _updateFocus();

    final withSeconds = newItems == 0 ? 0.9 : (1.2 + newItems * 0.006).clamp(1.4, 4.5);
    _anim.duration = Duration(milliseconds: (withSeconds * 1000).round());
    _frame(animate: currentItems.isNotEmpty);
    _anim.forward(from: 0);
    _applyFrame();
  }

  /// Positions, sizes and links (already clipped by progress) of the current animation instant.
  void _applyFrame() {
    final t = _anim.value;
    for (final i in _order) {
      final double e;
      final double ox, oy;
      if (_existed[i]) {
        e = Curves.easeInOutCubic.transform((t / _existingDuration).clamp(0.0, 1.0));
        _tam[i] = 1;
        ox = _de[2 * i];
        oy = _de[2 * i + 1];
      } else {
        final u = ((t - _start[i]) / _nodeDuration).clamp(0.0, 1.0);
        e = Curves.easeOutCubic.transform(u);
        _tam[i] = u == 0 ? 0 : Curves.easeOutBack.transform(u);
        final p = _parent[i]; // the parent comes earlier in the order: its position is already this frame's
        ox = p >= 0 ? _pos[2 * p] : _de[2 * i];
        oy = p >= 0 ? _pos[2 * p + 1] : _de[2 * i + 1];
      }
      _pos[2 * i] = ox + (_to[2 * i] - ox) * e;
      _pos[2 * i + 1] = oy + (_to[2 * i + 1] - oy) * e;
    }
    var k = 0;
    for (final (a, b) in _simEdges) {
      if (_tam[a] == 0 || _tam[b] == 0) continue;
      final (o, d) = _start[a] <= _start[b] ? (a, b) : (b, a);
      var prog = 1.0;
      // the link with the pulling node is born whole (the child leaves from it); the others are drawn later
      if (!(_existed[a] && _existed[b]) && _parent[d] != o && _parent[o] != d) {
        final s = max(_start[a], _start[b]) + _nodeDuration + _edgeDelay;
        prog = Curves.easeOut.transform(((t - s) / _edgeDuration).clamp(0.0, 1.0));
        if (prog == 0) continue;
      }
      final ox = _pos[2 * o], oy = _pos[2 * o + 1];
      _points[k++] = ox;
      _points[k++] = oy;
      _points[k++] = ox + (_pos[2 * d] - ox) * prog;
      _points[k++] = oy + (_pos[2 * d + 1] - oy) * prog;
    }
    _pointCount = k;
    _frameIndex.value++;
  }

  /// Fits the camera to the final positions of the nodes [indices] (all, if null).
  void _frame({Iterable<int>? indices, bool animate = true}) {
    if (_size.isEmpty || _simNodes.isEmpty) return;
    Rect? box;
    for (final i in indices ?? Iterable<int>.generate(_simNodes.length)) {
      final p = Offset(_to[2 * i], _to[2 * i + 1]);
      box = box == null ? Rect.fromCenter(center: p, width: 0, height: 0) : box.expandToInclude(Rect.fromPoints(p, p));
    }
    if (box == null) return;
    box = Rect.fromCenter(
      center: box.center,
      width: max(box.width + 120, 300),
      height: max(box.height + 120, 300),
    );
    final s = min(_size.width / box.width, _size.height / box.height).clamp(0.1, 2.5);
    final center = box.center + const Offset(_side / 2, _side / 2);
    final target = Matrix4.diagonal3Values(s, s, 1)
      ..setTranslationRaw(_size.width / 2 - center.dx * s, _size.height / 2 - center.dy * s, 0);
    if (!animate) {
      _camera.stop();
      _visor.value = target;
      return;
    }
    _cameraRoute = Matrix4Tween(begin: _visor.value.clone(), end: target);
    _camera.forward(from: 0);
  }

  static double _radius(GraphNode n) => min(3.5 + sqrt(n.degree) * 1.4, 18);

  double get _scale => _visor.value.getMaxScaleOnAxis();

  String? _noEm(Offset local) {
    final p0 = local - const Offset(_side / 2, _side / 2);
    final slack = 6 / _scale;
    String? match;
    var best = double.infinity;
    for (var i = 0; i < _simNodes.length; i++) {
      if (_tam[i] <= 0) continue;
      final d = (Offset(_pos[2 * i], _pos[2 * i + 1]) - p0).distance;
      if (d < _radius(_simNodes[i]) + slack && d < best) {
        best = d;
        match = _simNodes[i].id;
      }
    }
    return match;
  }

  /// Focus = node under the mouse, otherwise the selected one, or the search. Animates the fading of the others.
  void _updateFocus() {
    final target = _hover ?? _selected;
    if (target != null || _terms.isNotEmpty) {
      _lastFocus = target;
      _focus.forward();
    } else {
      _focus.reverse();
    }
  }

  void _searchTerms([String? text]) {
    if (text != null) _terms = text.toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    _matches = _terms.isEmpty
        ? const {}
        : {for (final e in _searchText.entries) if (_terms.every(e.value.contains)) e.key};
  }

  void _runSearch(String text) {
    setState(() => _searchTerms(text));
    _updateFocus();
    if (_searchOnly) {
      _wait?.cancel();
      _wait = Timer(const Duration(milliseconds: 350), _redoLayout);
    }
  }

  void _frameMatches() {
    final indices = [for (final (i, n) in _simNodes.indexed) if (_matches.contains(n.id)) i];
    if (indices.isNotEmpty) _frame(indices: indices);
  }

  void _applyFilter(VoidCallback change) {
    setState(change);
    _redoLayout();
  }

  static List<Color> _palette(int n, bool dark) => [
    for (var i = 0; i < n; i++)
      HSLColor.fromAHSL(1, (205 + i * 137.508) % 360, dark ? 0.68 : 0.62, dark ? 0.64 : 0.46).toColor(),
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      _size = c.biggest;
      return _body(context);
    });
  }

  Widget _body(BuildContext context) {
    if (_loading && _simNodes.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, spacing: 12, children: [Text(_error!), FilledButton(onPressed: _load, child: const Text('Tentar de novo'))]));
    }
    if (_nos.isEmpty) {
      return const Center(child: Text('Nenhuma nota ainda. As notas de síntese das leituras aparecem aqui.'));
    }
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final palette = _palette(_groups.length, dark);
    final others = theme.colorScheme.outline;
    final sel = _selected == null ? null : _byId[_selected];
    final painter = _GraphPainter(
      nos: _simNodes,
      edges: _simEdges,
      pos: _pos,
      tam: _tam,
      points: () => Float32List.sublistView(_points, 0, _pointCount),
      color: (n) {
        final g = _groupOf[n.id] ?? -1;
        return g < 0 ? others : palette[g];
      },
      focus: _lastFocus,
      neighbors: _neighbors[_lastFocus] ?? const {},
      selected: _selected,
      matches: _matches,
      hubs: _hubs,
      t: _focus,
      visor: _visor,
      labels: _labels,
      colors: theme.colorScheme,
      textStyle: theme.textTheme.labelSmall!,
      repaint: Listenable.merge([_frameIndex, _focus, _visor]),
    );
    Widget legend(int g, Color color, String text) {
      final active = _filterGroups.isEmpty || _filterGroups.contains(g);
      return InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _applyFilter(() => _filterGroups.contains(g) ? _filterGroups.remove(g) : _filterGroups.add(g)),
        child: Opacity(
          opacity: active ? 1 : 0.35,
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2), child: _Legend(color: color, text: text)),
        ),
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: InteractiveViewer(
            transformationController: _visor,
            constrained: false,
            boundaryMargin: const EdgeInsets.all(_side),
            minScale: 0.1,
            maxScale: 6,
            onInteractionStart: (_) => _camera.stop(),
            child: MouseRegion(
              cursor: _hover != null ? SystemMouseCursors.click : MouseCursor.defer,
              onHover: (e) {
                final id = _noEm(e.localPosition);
                if (id != _hover) {
                  setState(() => _hover = id);
                  _updateFocus();
                }
              },
              onExit: (_) {
                if (_hover == null) return;
                setState(() => _hover = null);
                _updateFocus();
              },
              child: GestureDetector(
                onTapUp: (d) {
                  setState(() => _selected = _noEm(d.localPosition));
                  _updateFocus();
                },
                child: CustomPaint(size: const Size(_side, _side), painter: painter),
              ),
            ),
          ),
        ),
        if (_simNodes.isEmpty) const Center(child: Text('Nenhuma nota com esses filtros.')),
        Positioned(
          left: 8,
          right: 8,
          top: 8,
          child: LayoutBuilder(
            builder: (context, c) {
              final search = TextField(
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: theme.colorScheme.surface,
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Buscar: título, #tag, palavras',
                    suffixText: _terms.isEmpty ? null : '${_matches.length}',
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: _runSearch,
                  onSubmitted: (_) => _frameMatches(),
              );
              final filters = <Widget>[
              FilterChip(
                label: const Text('Só resultados'),
                tooltip: 'Esconde as notas que não batem com a busca',
                selected: _searchOnly,
                onSelected: (v) => _applyFilter(() => _searchOnly = v),
              ),
              ChoiceChip(
                label: const Text('Tudo'),
                selected: _area == null,
                onSelected: (_) => _applyFilter(() => _area = null),
              ),
              for (final a in widget.areas)
                ChoiceChip(label: Text(a), selected: _area == a, onSelected: (_) => _applyFilter(() => _area = a)),
              if (_types.length > 1)
                PopupMenuButton<String>(
                  tooltip: 'Categoria da nota',
                  onSelected: (v) => _applyFilter(() => _type = v.isEmpty ? null : v),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: '', child: Text('Todas as categorias')),
                    for (final t in _types) CheckedPopupMenuItem(value: t, checked: _type == t, child: Text(t)),
                  ],
                  child: Chip(
                    avatar: const Icon(Icons.category_outlined, size: 18),
                    label: Text(_type ?? 'Categoria'),
                    backgroundColor: _type == null ? null : theme.colorScheme.secondaryContainer,
                  ),
                ),
              if (_filtering)
                ActionChip(
                  avatar: const Icon(Icons.filter_alt_off_outlined, size: 18),
                  label: const Text('Limpar filtros'),
                  onPressed: () => _applyFilter(() {
                    _area = null;
                    _type = null;
                    _searchOnly = false;
                    _filterGroups.clear();
                  }),
                ),
              IconButton.filledTonal(tooltip: 'Recarregar', icon: const Icon(Icons.refresh), onPressed: _load),
              IconButton.filledTonal(
                tooltip: 'Enquadrar',
                icon: const Icon(Icons.center_focus_strong),
                onPressed: () => _frame(),
              ),
              ];
              // phone: search across the full width and filters on a single horizontally scrolling line
              if (c.maxWidth < 600) {
                return Material(
                  color: theme.colorScheme.surface.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(8),
                  clipBehavior: Clip.antiAlias,
                  child: FiltrosRecolhiveis(
                    chave: 'estudos.grafo',
                    resumo: [?_area, ?_type, ..._terms].join(' · '),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          spacing: 6,
                          children: [
                            search,
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(spacing: 6, children: filters),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }
              return Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [SizedBox(width: 260, child: search), ...filters],
              );
            },
          ),
        ),
        Positioned(
          left: 8,
          bottom: 8,
          right: sel == null ? 8 : 320,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            spacing: 6,
            children: [
              // a long legend scrolls instead of covering the graph
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 96),
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 2,
                    children: [
                      for (final (i, (name, count)) in _groups.indexed) legend(i, palette[i], '$name ($count)'),
                      if (_groupOf.values.contains(-1)) legend(-1, others, 'outros'),
                    ],
                  ),
                ),
              ),
              Text(
                '${_simNodes.length} notas · ${_simEdges.length} ligações · clique na cor para filtrar',
                style: theme.textTheme.labelSmall,
              ),
            ],
          ),
        ),
        Positioned(
          right: 8,
          bottom: 8,
          width: 300,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween(begin: const Offset(0, 0.08), end: Offset.zero).animate(anim),
                child: child,
              ),
            ),
            child: sel == null ? const SizedBox.shrink() : _card(context, sel),
          ),
        ),
      ],
    );
  }

  Widget _card(BuildContext context, GraphNode sel) {
    final theme = Theme.of(context);
    final neighbors = _neighbors[sel.id] ?? const {};
    return Card(
      key: ValueKey(sel.id),
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          spacing: 6,
          children: [
            Text(sel.title, style: theme.textTheme.titleMedium),
            Text('${sel.type} · ${sel.degree} ligações${sel.tags.isEmpty ? '' : ' · #${sel.tags.join(' #')}'}', style: theme.textTheme.bodySmall),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final id in neighbors)
                    if (_byId[id] != null)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.link, size: 18),
                        title: Text(_byId[id]!.title),
                        onTap: () {
                          setState(() => _selected = id);
                          _updateFocus();
                        },
                      ),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () {
                    setState(() => _selected = null);
                    _updateFocus();
                  },
                  child: const Text('Fechar'),
                ),
                FilledButton(
                  onPressed: () async {
                    await openNote(context, widget.api.notes, sel.id);
                    _load();
                  },
                  child: const Text('Abrir nota'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.text});

  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: 4,
    children: [
      Container(width: 9, height: 9, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      Text(text, style: Theme.of(context).textTheme.labelSmall),
    ],
  );
}

class _GraphPainter extends CustomPainter {
  _GraphPainter({
    required this.nos,
    required this.edges,
    required this.pos,
    required this.tam,
    required this.points,
    required this.color,
    required this.focus,
    required this.neighbors,
    required this.selected,
    required this.matches,
    required this.hubs,
    required this.t,
    required this.visor,
    required this.labels,
    required this.colors,
    required this.textStyle,
    super.repaint,
  });

  final List<GraphNode> nos;
  final List<(int, int)> edges;
  final Float64List pos, tam; // mutated on every frame by the animation
  final Float32List Function() points;
  final Color Function(GraphNode) color;
  final String? focus, selected;
  final Set<String> neighbors, hubs, matches;
  final Animation<double> t;
  final TransformationController visor;
  final Map<String, TextPainter> labels;
  final ColorScheme colors;
  final TextStyle textStyle;

  bool _highlight(GraphNode n) => n.id == focus || neighbors.contains(n.id) || matches.contains(n.id);

  Offset _p(int i) => Offset(pos[2 * i], pos[2 * i + 1]);

  TextPainter _label(String id, String text, double size, double alpha, bool forte) {
    final key = '$id|${size.round()}|${(alpha * 10).round()}|$forte';
    if (labels.length > 4000) labels.clear();
    return labels[key] ??= TextPainter(
      text: TextSpan(
        text: text,
        style: textStyle.copyWith(
          fontSize: size.roundToDouble(),
          fontWeight: forte ? FontWeight.w600 : FontWeight.w400,
          color: colors.onSurface.withValues(alpha: (alpha * 10).round() / 10),
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 15 * size);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.translate(size.width / 2, size.height / 2);
    final scale = visor.value.getMaxScaleOnAxis();
    final f = Curves.easeOut.transform(t.value); // 0 = sem foco, 1 = foco total
    final px = 1 / scale; // 1 pixel de tela em unidades do canvas

    // arestas comuns num só draw call (linha fina de 1 px em qualquer zoom), já no progresso da animação
    canvas.drawRawPoints(
      ui.PointMode.lines,
      points(),
      Paint()
        ..strokeWidth = 0
        ..color = colors.onSurface.withValues(alpha: ui.lerpDouble(0.09, 0.03, f)!),
    );
    // arestas do nó em foco, na cor dele
    if (focus != null && f > 0) {
      final i = nos.indexWhere((n) => n.id == focus);
      if (i >= 0) {
        final line = Paint()
          ..strokeWidth = 1.6 * px
          ..color = color(nos[i]).withValues(alpha: 0.85 * f);
        for (final (a, b) in edges) {
          if ((a == i || b == i) && tam[a] > 0 && tam[b] > 0) canvas.drawLine(_p(a), _p(b), line);
        }
      }
    }

    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2 * px
      ..color = colors.surface;
    final fills = Paint();
    final small = nos.length < 60;
    final commonLabel = ((scale - 1.0) / 0.5).clamp(0.0, 1.0); // rótulos de todos aparecem com zoom
    final textSize = (12 * px).clamp(5.0, 30.0);
    for (final (i, n) in nos.indexed) {
      final s = tam[i];
      if (s <= 0) continue;
      final p = _p(i);
      final highlight = _highlight(n);
      final alpha = highlight ? 1.0 : ui.lerpDouble(1, 0.13, f)!;
      var radius = _GraphScreenState._radius(n) * s;
      if (n.id == focus) radius *= 1 + 0.35 * f;
      canvas.drawCircle(p, radius, fills..color = color(n).withValues(alpha: alpha));
      canvas.drawCircle(p, radius, outline);
      if (n.id == selected) {
        canvas.drawCircle(p, radius + 4 * px, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 * px
          ..color = colors.onSurface);
      }
      final base = (highlight && f > 0) || hubs.contains(n.id) || small ? 1.0 : commonLabel;
      final textAlpha = base * alpha * s.clamp(0.0, 1.0);
      if (textAlpha < 0.08) continue;
      final text = _label(n.id, n.title, textSize, textAlpha, highlight && f > 0 || hubs.contains(n.id));
      text.paint(canvas, p + Offset(-text.width / 2, radius + 2 * px));
    }
  }

  @override
  bool shouldRepaint(_GraphPainter oldValue) => true;
}
