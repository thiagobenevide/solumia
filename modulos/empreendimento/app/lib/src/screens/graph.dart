import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../models.dart';
import 'util.dart';

const _grade = 20.0; // spacing of the background dots; nodes and bands align to it
const _nodeWidth = 160.0, _heightNode = 60.0, _nodeGap = 40.0, _altBand = 140.0, _margin = 40.0;

/// Operation graph in the style of the Obsidian canvas: dotted background aligned to the grid, three bands
/// (script steps, episode stages, resources) as groups, sequences as solid curves with an arrow and
/// "usa" as a dotted curve that moves slowly. Active nodes pulse and send particles along the links;
/// hovering highlights the node's links. Dragging moves, wheel/pinch zooms; tapping opens the detail.
class OperationGraph extends StatelessWidget {
  const OperationGraph({super.key, required this.api});

  final ApiEsteira api;

  @override
  Widget build(BuildContext context) => Sondagem<Json>(
    intervalo: const Duration(seconds: 3),
    carregar: api.graph,
    construir: (context, g, _) {
      final legacy = g['legado'] as List? ?? const [];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (legacy.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Processos sem rastro (anteriores ao grafo): ${legacy.length}',
                style: const TextStyle(color: Colors.amber),
              ),
            ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: _Canvas(
                defs: [for (final n in g['def_nos'] as List) n as Json],
                state: (g['nos'] as Json?) ?? const {},
                arestas: [
                  for (final s in g['seq'] as List) ('${s[0]}', '${s[1]}', false),
                  for (final u in g['usa'] as List) ('${u[0]}', '${u[1]}', true),
                ],
                onTap: (id) => _detail(context, id),
              ),
            ),
          ),
        ],
      );
    },
  );

  void _detail(BuildContext context, String id) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.85,
      child: _DetailNode(api: api, id: id),
    ),
  );
}

class _Canvas extends StatefulWidget {
  const _Canvas({required this.defs, required this.state, required this.arestas, required this.onTap});

  final List<Json> defs;
  final Json state;
  final List<(String, String, bool)> arestas;
  final void Function(String id) onTap;

  @override
  State<_Canvas> createState() => _CanvasState();
}

class _CanvasState extends State<_Canvas> with TickerProviderStateMixin {
  static const _bands = ['roteiro', 'episodio', 'estudio', 'recurso'];
  static const _bandNames = {'roteiro': 'Roteiro', 'episodio': 'Episódio', 'estudio': 'Estúdio (motion)', 'recurso': 'Recursos'};

  final _visor = TransformationController();
  late final _flow = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat();
  late final _camera = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
  Matrix4Tween? _route;
  String? _hover;
  bool _framed = false;
  Size _vista = Size.zero;
  Rect _world = Rect.zero;

  @override
  void initState() {
    super.initState();
    _camera.addListener(() {
      final r = _route;
      if (r != null) _visor.value = r.evaluate(CurvedAnimation(parent: _camera, curve: Curves.easeInOutCubic));
    });
  }

  @override
  void dispose() {
    _flow.dispose();
    _camera.dispose();
    _visor.dispose();
    super.dispose();
  }

  static double _onGrid(double v) => (v / _grade).roundToDouble() * _grade;

  /// Rectangle of each node in the world: stacked bands, nodes centered in the band, everything on the grid.
  (Map<String, Rect>, List<(String, Rect)>) _layout() {
    final byBand = {for (final f in _bands) f: widget.defs.where((n) => n['faixa'] == f).toList()};
    final maxNodes = byBand.values.map((l) => l.length).fold(1, max);
    final largura = _onGrid(maxNodes * (_nodeWidth + _nodeGap) - _nodeGap + 2 * _margin);
    final nodes = <String, Rect>{};
    final bands = <(String, Rect)>[];
    for (final (fi, f) in _bands.indexed) {
      final list = byBand[f]!;
      final top = fi * _altBand;
      bands.add((_bandNames[f]!, Rect.fromLTWH(0, top, largura, _altBand - _grade)));
      final busy = list.length * (_nodeWidth + _nodeGap) - _nodeGap;
      final start = _onGrid((largura - busy) / 2);
      for (final (i, n) in list.indexed) {
        nodes['${n['id']}'] = Rect.fromLTWH(start + i * (_nodeWidth + _nodeGap), top + 2 * _grade, _nodeWidth, _heightNode);
      }
    }
    return (nodes, bands);
  }

  void _frame({bool animate = true}) {
    if (_vista.isEmpty || _world.isEmpty) return;
    final box = _world.inflate(_grade);
    final s = min(_vista.width / box.width, _vista.height / box.height).clamp(0.3, 1.2);
    final target = Matrix4.diagonal3Values(s, s, 1)
      ..setTranslationRaw(_vista.width / 2 - box.center.dx * s, _vista.height / 2 - box.center.dy * s, 0);
    if (!animate) {
      _visor.value = target;
      return;
    }
    _route = Matrix4Tween(begin: _visor.value.clone(), end: target);
    _camera.forward(from: 0);
  }

  void _zoom(double factor) {
    final c = Offset(_vista.width / 2, _vista.height / 2);
    final current = _visor.value.clone();
    final s = current.getMaxScaleOnAxis();
    final f = (s * factor).clamp(0.3, 2.5) / s;
    final target = Matrix4.identity()
      ..setTranslationRaw(c.dx * (1 - f), c.dy * (1 - f), 0)
      ..multiply(Matrix4.diagonal3Values(f, f, 1))
      ..multiply(current);
    _route = Matrix4Tween(begin: current, end: target);
    _camera.forward(from: 0);
  }

  bool _active(String id) => (widget.state[id] as Json?)?['ativo'] == true;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (nodes, bands) = _layout();
    _world = bands.fold(Rect.zero, (r, f) => r.expandToInclude(f.$2));
    final engine = {for (final n in widget.defs) '${n['id']}': EnginePill.color('${n['motor']}')};
    return LayoutBuilder(
      builder: (context, area) {
        _vista = area.biggest;
        if (!_framed && !_vista.isEmpty) {
          _framed = true;
          _frame(animate: false);
        }
        return ColoredBox(
          color: cs.surfaceContainerLowest,
          child: Stack(
            children: [
              Positioned.fill(child: CustomPaint(painter: _Points(_visor, cs.outline))),
              Positioned.fill(
                child: InteractiveViewer(
                  transformationController: _visor,
                  constrained: false,
                  boundaryMargin: const EdgeInsets.all(600),
                  minScale: 0.3,
                  maxScale: 2.5,
                  onInteractionStart: (_) => _camera.stop(),
                  child: SizedBox(
                    width: _world.width,
                    height: _world.height,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        for (final (nome, r) in bands) Positioned.fromRect(rect: r, child: _Group(nome)),
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _Arestas(
                              arestas: widget.arestas,
                              nodes: nodes,
                              engine: engine,
                              active: {for (final id in nodes.keys) if (_active(id)) id},
                              hover: _hover,
                              cores: cs,
                              flow: _flow,
                            ),
                          ),
                        ),
                        for (final (i, n) in widget.defs.indexed)
                          if (nodes['${n['id']}'] case final r?)
                            Positioned.fromRect(
                              rect: r,
                              child: _Input(
                                delay: i,
                                child: MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  onEnter: (_) => setState(() => _hover = '${n['id']}'),
                                  onExit: (_) => setState(() => _hover = null),
                                  child: _Node(
                                    def: n,
                                    state: widget.state['${n['id']}'] as Json?,
                                    highlight: _hover == '${n['id']}',
                                    off: _hover != null && !_enabled(_hover!, '${n['id']}'),
                                    pulso: _flow,
                                    onTap: () => widget.onTap('${n['id']}'),
                                  ),
                                ),
                              ),
                            ),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 8,
                top: 8,
                child: Card(
                  margin: EdgeInsets.zero,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(tooltip: 'Afastar', icon: const Icon(Icons.remove, size: 18), onPressed: () => _zoom(1 / 1.25)),
                      IconButton(tooltip: 'Aproximar', icon: const Icon(Icons.add, size: 18), onPressed: () => _zoom(1.25)),
                      IconButton(tooltip: 'Enquadrar', icon: const Icon(Icons.center_focus_strong, size: 18), onPressed: _frame),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  bool _enabled(String a, String b) =>
      a == b || widget.arestas.any((e) => (e.$1 == a && e.$2 == b) || (e.$1 == b && e.$2 == a));
}

/// Dotted canvas background: the dots follow pan and zoom (they stay locked to the world grid).
class _Points extends CustomPainter {
  _Points(this.visor, this.color) : super(repaint: visor);

  final TransformationController visor;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final m = visor.value;
    final s = m.getMaxScaleOnAxis();
    var step = _grade * s;
    while (step < 12) {
      step *= 2; // too far: thins out so it does not turn into fog
    }
    final t = m.getTranslation();
    final x0 = t.x % step, y0 = t.y % step;
    final pts = <double>[];
    for (var y = y0; y < size.height; y += step) {
      for (var x = x0; x < size.width; x += step) {
        pts
          ..add(x)
          ..add(y);
      }
    }
    canvas.drawRawPoints(
      ui.PointMode.points,
      Float32List.fromList(pts),
      Paint()
        ..color = color.withValues(alpha: 0.35)
        ..strokeWidth = (1.6 * s).clamp(1.2, 2.4)
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_Points old) => old.color != color;
}

/// Band as a canvas group: translucent area with the name in a tag in the corner.
class _Group extends StatelessWidget {
  const _Group(this.nome);

  final String nome;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            nome.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant, letterSpacing: 1.2),
          ),
        ),
      ),
    );
  }
}

/// Node appears with a fade + slight scale, cascading by index (only the first time).
class _Input extends StatelessWidget {
  const _Input({required this.delay, required this.child});

  final int delay;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: Duration(milliseconds: 350 + delay * 40),
    curve: Curves.easeOutCubic,
    builder: (_, v, child) => Opacity(opacity: v, child: Transform.scale(scale: 0.9 + 0.1 * v, child: child)),
    child: child,
  );
}

class _Node extends StatelessWidget {
  const _Node({
    required this.def,
    required this.state,
    required this.highlight,
    required this.off,
    required this.pulso,
    required this.onTap,
  });

  final Json def;
  final Json? state;
  final bool highlight, off;
  final Animation<double> pulso;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = EnginePill.color('${def['motor']}');
    final active = state?['ativo'] == true;
    final calls = (state?['chamadas'] as num?) ?? 0;
    Widget card(double brilho) => AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: Color.alphaBlend(color.withValues(alpha: active ? 0.22 : 0.06), cs.surfaceContainerHigh),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: color.withValues(alpha: active || highlight ? 1 : 0.5),
          width: active || highlight ? 2 : 1.2,
        ),
        boxShadow: [
          if (active) BoxShadow(color: color.withValues(alpha: 0.25 + 0.35 * brilho), blurRadius: 8 + 14 * brilho),
          if (highlight) BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 16),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  spacing: 6,
                  children: [
                    Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                    Expanded(
                      child: Text(
                        '${def['rotulo']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    EnginePill.nome('${def['motor']}'),
                    if (calls > 0) '$calls cham.',
                    if (state?['tok_s'] != null) '${state!['tok_s']} tok/s',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: color.shade200),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 220),
      opacity: off ? 0.35 : 1,
      child: AnimatedScale(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutBack,
        scale: highlight ? 1.04 : 1,
        child: active
            ? AnimatedBuilder(
                animation: pulso,
                builder: (_, _) => card(0.5 + 0.5 * sin(pulso.value * 2 * pi)),
              )
            : card(0),
      ),
    );
  }
}

class _Arestas extends CustomPainter {
  _Arestas({
    required this.arestas,
    required this.nodes,
    required this.engine,
    required this.active,
    required this.hover,
    required this.cores,
    required this.flow,
  }) : super(repaint: flow);

  final List<(String, String, bool)> arestas;
  final Map<String, Rect> nodes;
  final Map<String, Color> engine;
  final Set<String> active;
  final String? hover;
  final ColorScheme cores;
  final Animation<double> flow;

  /// Smooth curve between the closest sides of the two cards, as in the Obsidian canvas.
  static Path _curve(Rect a, Rect b) {
    final Offset de, to;
    final bool vertical;
    if (b.top >= a.bottom) {
      (de, to, vertical) = (a.bottomCenter, b.topCenter, true);
    } else if (a.top >= b.bottom) {
      (de, to, vertical) = (a.topCenter, b.bottomCenter, true);
    } else if (b.left >= a.right) {
      (de, to, vertical) = (a.centerRight, b.centerLeft, false);
    } else {
      (de, to, vertical) = (a.centerLeft, b.centerRight, false);
    }
    final d = to - de;
    final puxa = vertical ? Offset(0, d.dy * 0.55) : Offset(d.dx * 0.55, 0);
    return Path()
      ..moveTo(de.dx, de.dy)
      ..cubicTo(de.dx + puxa.dx, de.dy + puxa.dy, to.dx - puxa.dx, to.dy - puxa.dy, to.dx, to.dy);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final t = flow.value;
    for (final (a, b, uses) in arestas) {
      final ra = nodes[a], rb = nodes[b];
      if (ra == null || rb == null) continue;
      final metrica = _curve(ra, rb).computeMetrics().firstOrNull;
      if (metrica == null || metrica.length < 1) continue;
      final onHover = hover != null && (a == hover || b == hover);
      final viva = active.contains(a) || active.contains(b);
      final color = engine[active.contains(b) ? b : a] ?? cores.primary;
      final factor = hover == null || onHover ? 1.0 : 0.25;
      final realce = onHover || viva;
      final base = (realce ? color : cores.onSurfaceVariant).withValues(alpha: (realce ? 0.9 : 0.45) * factor);

      if (uses) {
        // dotted line slowly walking in the link direction
        final point = Paint()..color = base.withValues(alpha: base.a * 0.85);
        const step = 8.0;
        for (var d = (t * step * 2) % step; d < metrica.length; d += step) {
          canvas.drawCircle(metrica.getTangentForOffset(d)!.position, realce ? 1.8 : 1.4, point);
        }
      } else {
        canvas.drawPath(
          metrica.extractPath(0, metrica.length - 4),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = realce ? 2.2 : 1.6
            ..strokeCap = StrokeCap.round
            ..color = base,
        );
        final end = metrica.getTangentForOffset(metrica.length)!;
        final dir = end.vector;
        final side = Offset(-dir.dy, dir.dx);
        canvas.drawPath(
          Path()
            ..moveTo(end.position.dx, end.position.dy)
            ..lineTo(end.position.dx - dir.dx * 8 + side.dx * 4, end.position.dy - dir.dy * 8 + side.dy * 4)
            ..lineTo(end.position.dx - dir.dx * 8 - side.dx * 4, end.position.dy - dir.dy * 8 - side.dy * 4)
            ..close(),
          Paint()..color = base,
        );
      }

      // particles running along the link while one of the sides is working
      if (viva) {
        final brilho = Paint()
          ..color = color.withValues(alpha: 0.5 * factor)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
        final core = Paint()..color = Color.lerp(color, Colors.white, 0.5)!.withValues(alpha: factor);
        for (var k = 0; k < 3; k++) {
          final p = metrica.getTangentForOffset(((t + k / 3) % 1) * metrica.length)!.position;
          canvas.drawCircle(p, 5, brilho);
          canvas.drawCircle(p, 2.4, core);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_Arestas old) => true;
}

class _DetailNode extends StatelessWidget {
  const _DetailNode({required this.api, required this.id});

  final ApiEsteira api;
  final String id;

  @override
  Widget build(BuildContext context) => Sondagem<Json>(
    intervalo: const Duration(seconds: 3),
    carregar: () => api.graphNode(id),
    construir: (context, d, _) {
      final t = Theme.of(context).textTheme;
      final estat = ((d['extras'] as Json?)?['estat'] as Json?) ?? const {};
      final calls = [for (final c in d['chamadas'] as List? ?? const []) c as Json];
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Row(
            spacing: 8,
            children: [
              Expanded(child: Text('${d['rotulo']}', style: t.titleLarge)),
              EnginePill('${d['motor']}'),
            ],
          ),
          const SizedBox(height: 8),
          Text('${d['como']}'),
          if ((d['usa'] as List? ?? const []).isNotEmpty)
            Text('Usa: ${(d['usa'] as List).join(', ')}', style: t.bodySmall),
          if ((d['usado_por'] as List? ?? const []).isNotEmpty)
            Text('Usado por: ${(d['usado_por'] as List).join(', ')}', style: t.bodySmall),
          if ((d['vivos'] as List? ?? const []).isNotEmpty) ...[
            const Section('Rodando agora'),
            for (final v in d['vivos'] as List) Text('• ${(v as Json)['comando'] ?? v['rotulo'] ?? v}'),
          ],
          const Section('Números'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Indicator('Chamadas', '${d['n_chamadas'] ?? 0}', sub: '${d['n_cache'] ?? 0} do cache'),
              for (final (label, chave, suffix) in const [
                ('Sucesso', 'ok_pct', '%'),
                ('Geração', 'tok_s', ' tok/s'),
                ('Prefill', 'prefill_tok_s', ' tok/s'),
                ('Latência p50', 'lat_p50', ' s'),
                ('Latência p95', 'lat_p95', ' s'),
                ('Tokens entrada', 'tokens_entrada', ''),
                ('Tokens saída', 'tokens_saida', ''),
                ('Claude', 'custo_usd', ' US\$'),
              ])
                if (estat[chave] != null) Indicator(label, '${estat[chave]}$suffix'),
            ],
          ),
          if (calls.isNotEmpty) ...[
            Section('Chamadas recentes (${calls.length})'),
            for (final c in calls.take(30)) _Call(c),
          ],
          if ((d['passos'] as List? ?? const []).isNotEmpty) ...[
            const Section('Passos'),
            for (final p in (d['passos'] as List).reversed.take(20))
              Text(
                '${_hour((p as Json)['t'] as num?)}  ${p['fluxo'] ?? ''}  ${p['detalhe'] ?? ''}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
          ],
        ],
      );
    },
  );

  static String _hour(num? t) {
    if (t == null) return '';
    final d = DateTime.fromMillisecondsSinceEpoch((t * 1000).round());
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}

/// One LLM call: engine, model, tokens, time; the prompt and the answer open on tap.
class LlmCall extends StatelessWidget {
  const LlmCall(this.c, {super.key});

  final Json c;

  @override
  Widget build(BuildContext context) => _Call(c);
}

class _Call extends StatelessWidget {
  const _Call(this.c);

  final Json c;

  @override
  Widget build(BuildContext context) {
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 12);
    final ok = c['ok'] != false;
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ExpansionTile(
        dense: true,
        leading: EnginePill('${c['engine'] ?? 'local'}'),
        title: Text('${c['name'] ?? ''} · ${c['model'] ?? ''}', overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [
            if (!ok) 'falhou',
            if (c['cache'] == true) 'do cache',
            if (c['output_tokens'] != null || c['tokens'] != null)
              '${c['output_tokens'] ?? c['tokens']} tokens',
            if (c['seconds'] != null) '${(c['seconds'] as num).toStringAsFixed(1)} s',
            if (c['tok_s'] != null) '${c['tok_s']} tok/s',
            if (c['custo'] != null) dollars(c['custo'] as num, places: 4),
          ].join(' · '),
          style: TextStyle(color: ok ? null : Theme.of(context).colorScheme.error),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (c['input'] != null) ...[const Text('Prompt'), SelectableText('${c['input']}', style: mono)],
          if (c['output'] != null || c['resposta'] != null) ...[
            const SizedBox(height: 8),
            const Text('Resposta'),
            SelectableText('${c['output'] ?? c['resposta']}', style: mono),
          ],
          if ('${c['error'] ?? ''}'.isNotEmpty)
            Text('${c['error']}', style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
      ),
    );
  }
}
