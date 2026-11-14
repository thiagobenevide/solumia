import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../modelos.dart';
import 'util.dart';

const _grade = 20.0; // espaçamento dos pontos do fundo; nós e faixas ficam alinhados a ele
const _larguraNo = 160.0, _alturaNo = 60.0, _vaoNo = 40.0, _altFaixa = 140.0, _margem = 40.0;

/// Grafo da operação no estilo do canvas do Obsidian: fundo pontilhado alinhado à grade, três faixas
/// (passos do roteiro, etapas do episódio, recursos) como grupos, sequências em curva cheia com seta e
/// "usa" em curva pontilhada que anda devagar. Nós ativos pulsam e soltam partículas pelas ligações;
/// passar o mouse destaca as ligações do nó. Arrastar move, roda/pinça dá zoom; tocar abre o detalhe.
class GrafoOperacao extends StatelessWidget {
  const GrafoOperacao({super.key, required this.api});

  final ApiEsteira api;

  @override
  Widget build(BuildContext context) => Sondagem<Json>(
    intervalo: const Duration(seconds: 3),
    carregar: api.grafo,
    construir: (context, g, _) {
      final legado = g['legado'] as List? ?? const [];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (legado.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Processos sem rastro (anteriores ao grafo): ${legado.length}',
                style: const TextStyle(color: Colors.amber),
              ),
            ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: _Canvas(
                defs: [for (final n in g['def_nos'] as List) n as Json],
                estado: (g['nos'] as Json?) ?? const {},
                arestas: [
                  for (final s in g['seq'] as List) ('${s[0]}', '${s[1]}', false),
                  for (final u in g['usa'] as List) ('${u[0]}', '${u[1]}', true),
                ],
                aoTocar: (id) => _detalhe(context, id),
              ),
            ),
          ),
        ],
      );
    },
  );

  void _detalhe(BuildContext context, String id) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.85,
      child: _DetalheNo(api: api, id: id),
    ),
  );
}

class _Canvas extends StatefulWidget {
  const _Canvas({required this.defs, required this.estado, required this.arestas, required this.aoTocar});

  final List<Json> defs;
  final Json estado;
  final List<(String, String, bool)> arestas;
  final void Function(String id) aoTocar;

  @override
  State<_Canvas> createState() => _CanvasState();
}

class _CanvasState extends State<_Canvas> with TickerProviderStateMixin {
  static const _faixas = ['roteiro', 'episodio', 'estudio', 'recurso'];
  static const _nomesFaixa = {'roteiro': 'Roteiro', 'episodio': 'Episódio', 'estudio': 'Estúdio (motion)', 'recurso': 'Recursos'};

  final _visor = TransformationController();
  late final _fluxo = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat();
  late final _camera = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
  Matrix4Tween? _rota;
  String? _hover;
  bool _enquadrado = false;
  Size _vista = Size.zero;
  Rect _mundo = Rect.zero;

  @override
  void initState() {
    super.initState();
    _camera.addListener(() {
      final r = _rota;
      if (r != null) _visor.value = r.evaluate(CurvedAnimation(parent: _camera, curve: Curves.easeInOutCubic));
    });
  }

  @override
  void dispose() {
    _fluxo.dispose();
    _camera.dispose();
    _visor.dispose();
    super.dispose();
  }

  static double _naGrade(double v) => (v / _grade).roundToDouble() * _grade;

  /// Retângulo de cada nó no mundo: faixas empilhadas, nós centralizados na faixa, tudo na grade.
  (Map<String, Rect>, List<(String, Rect)>) _layout() {
    final porFaixa = {for (final f in _faixas) f: widget.defs.where((n) => n['faixa'] == f).toList()};
    final maxNos = porFaixa.values.map((l) => l.length).fold(1, max);
    final largura = _naGrade(maxNos * (_larguraNo + _vaoNo) - _vaoNo + 2 * _margem);
    final nos = <String, Rect>{};
    final faixas = <(String, Rect)>[];
    for (final (fi, f) in _faixas.indexed) {
      final lista = porFaixa[f]!;
      final topo = fi * _altFaixa;
      faixas.add((_nomesFaixa[f]!, Rect.fromLTWH(0, topo, largura, _altFaixa - _grade)));
      final ocupado = lista.length * (_larguraNo + _vaoNo) - _vaoNo;
      final inicio = _naGrade((largura - ocupado) / 2);
      for (final (i, n) in lista.indexed) {
        nos['${n['id']}'] = Rect.fromLTWH(inicio + i * (_larguraNo + _vaoNo), topo + 2 * _grade, _larguraNo, _alturaNo);
      }
    }
    return (nos, faixas);
  }

  void _enquadrar({bool animar = true}) {
    if (_vista.isEmpty || _mundo.isEmpty) return;
    final caixa = _mundo.inflate(_grade);
    final s = min(_vista.width / caixa.width, _vista.height / caixa.height).clamp(0.3, 1.2);
    final alvo = Matrix4.diagonal3Values(s, s, 1)
      ..setTranslationRaw(_vista.width / 2 - caixa.center.dx * s, _vista.height / 2 - caixa.center.dy * s, 0);
    if (!animar) {
      _visor.value = alvo;
      return;
    }
    _rota = Matrix4Tween(begin: _visor.value.clone(), end: alvo);
    _camera.forward(from: 0);
  }

  void _zoom(double fator) {
    final c = Offset(_vista.width / 2, _vista.height / 2);
    final atual = _visor.value.clone();
    final s = atual.getMaxScaleOnAxis();
    final f = (s * fator).clamp(0.3, 2.5) / s;
    final alvo = Matrix4.identity()
      ..setTranslationRaw(c.dx * (1 - f), c.dy * (1 - f), 0)
      ..multiply(Matrix4.diagonal3Values(f, f, 1))
      ..multiply(atual);
    _rota = Matrix4Tween(begin: atual, end: alvo);
    _camera.forward(from: 0);
  }

  bool _ativo(String id) => (widget.estado[id] as Json?)?['ativo'] == true;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (nos, faixas) = _layout();
    _mundo = faixas.fold(Rect.zero, (r, f) => r.expandToInclude(f.$2));
    final motor = {for (final n in widget.defs) '${n['id']}': SeloMotor.cor('${n['motor']}')};
    return LayoutBuilder(
      builder: (context, area) {
        _vista = area.biggest;
        if (!_enquadrado && !_vista.isEmpty) {
          _enquadrado = true;
          _enquadrar(animar: false);
        }
        return ColoredBox(
          color: cs.surfaceContainerLowest,
          child: Stack(
            children: [
              Positioned.fill(child: CustomPaint(painter: _Pontos(_visor, cs.outline))),
              Positioned.fill(
                child: InteractiveViewer(
                  transformationController: _visor,
                  constrained: false,
                  boundaryMargin: const EdgeInsets.all(600),
                  minScale: 0.3,
                  maxScale: 2.5,
                  onInteractionStart: (_) => _camera.stop(),
                  child: SizedBox(
                    width: _mundo.width,
                    height: _mundo.height,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        for (final (nome, r) in faixas) Positioned.fromRect(rect: r, child: _Grupo(nome)),
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _Arestas(
                              arestas: widget.arestas,
                              nos: nos,
                              motor: motor,
                              ativos: {for (final id in nos.keys) if (_ativo(id)) id},
                              hover: _hover,
                              cores: cs,
                              fluxo: _fluxo,
                            ),
                          ),
                        ),
                        for (final (i, n) in widget.defs.indexed)
                          if (nos['${n['id']}'] case final r?)
                            Positioned.fromRect(
                              rect: r,
                              child: _Entrada(
                                atraso: i,
                                child: MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  onEnter: (_) => setState(() => _hover = '${n['id']}'),
                                  onExit: (_) => setState(() => _hover = null),
                                  child: _No(
                                    def: n,
                                    estado: widget.estado['${n['id']}'] as Json?,
                                    destaque: _hover == '${n['id']}',
                                    apagado: _hover != null && !_ligado(_hover!, '${n['id']}'),
                                    pulso: _fluxo,
                                    onTap: () => widget.aoTocar('${n['id']}'),
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
                      IconButton(tooltip: 'Enquadrar', icon: const Icon(Icons.center_focus_strong, size: 18), onPressed: _enquadrar),
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

  bool _ligado(String a, String b) =>
      a == b || widget.arestas.any((e) => (e.$1 == a && e.$2 == b) || (e.$1 == b && e.$2 == a));
}

/// Fundo pontilhado do canvas: os pontos acompanham pan e zoom (ficam presos à grade do mundo).
class _Pontos extends CustomPainter {
  _Pontos(this.visor, this.cor) : super(repaint: visor);

  final TransformationController visor;
  final Color cor;

  @override
  void paint(Canvas canvas, Size size) {
    final m = visor.value;
    final s = m.getMaxScaleOnAxis();
    var passo = _grade * s;
    while (passo < 12) {
      passo *= 2; // longe demais: rarefaz para não virar névoa
    }
    final t = m.getTranslation();
    final x0 = t.x % passo, y0 = t.y % passo;
    final pts = <double>[];
    for (var y = y0; y < size.height; y += passo) {
      for (var x = x0; x < size.width; x += passo) {
        pts
          ..add(x)
          ..add(y);
      }
    }
    canvas.drawRawPoints(
      ui.PointMode.points,
      Float32List.fromList(pts),
      Paint()
        ..color = cor.withValues(alpha: 0.35)
        ..strokeWidth = (1.6 * s).clamp(1.2, 2.4)
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_Pontos antigo) => antigo.cor != cor;
}

/// Faixa como grupo do canvas: área translúcida com o nome numa etiqueta no canto.
class _Grupo extends StatelessWidget {
  const _Grupo(this.nome);

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

/// Nó surge com fade + leve escala, em cascata pelo índice (só na primeira vez).
class _Entrada extends StatelessWidget {
  const _Entrada({required this.atraso, required this.child});

  final int atraso;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: Duration(milliseconds: 350 + atraso * 40),
    curve: Curves.easeOutCubic,
    builder: (_, v, filho) => Opacity(opacity: v, child: Transform.scale(scale: 0.9 + 0.1 * v, child: filho)),
    child: child,
  );
}

class _No extends StatelessWidget {
  const _No({
    required this.def,
    required this.estado,
    required this.destaque,
    required this.apagado,
    required this.pulso,
    required this.onTap,
  });

  final Json def;
  final Json? estado;
  final bool destaque, apagado;
  final Animation<double> pulso;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final cor = SeloMotor.cor('${def['motor']}');
    final ativo = estado?['ativo'] == true;
    final chamadas = (estado?['chamadas'] as num?) ?? 0;
    Widget cartao(double brilho) => AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: Color.alphaBlend(cor.withValues(alpha: ativo ? 0.22 : 0.06), cs.surfaceContainerHigh),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: cor.withValues(alpha: ativo || destaque ? 1 : 0.5),
          width: ativo || destaque ? 2 : 1.2,
        ),
        boxShadow: [
          if (ativo) BoxShadow(color: cor.withValues(alpha: 0.25 + 0.35 * brilho), blurRadius: 8 + 14 * brilho),
          if (destaque) BoxShadow(color: cor.withValues(alpha: 0.4), blurRadius: 16),
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
                    Container(width: 7, height: 7, decoration: BoxDecoration(color: cor, shape: BoxShape.circle)),
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
                    SeloMotor.nome('${def['motor']}'),
                    if (chamadas > 0) '$chamadas cham.',
                    if (estado?['tok_s'] != null) '${estado!['tok_s']} tok/s',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: cor.shade200),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 220),
      opacity: apagado ? 0.35 : 1,
      child: AnimatedScale(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutBack,
        scale: destaque ? 1.04 : 1,
        child: ativo
            ? AnimatedBuilder(
                animation: pulso,
                builder: (_, _) => cartao(0.5 + 0.5 * sin(pulso.value * 2 * pi)),
              )
            : cartao(0),
      ),
    );
  }
}

class _Arestas extends CustomPainter {
  _Arestas({
    required this.arestas,
    required this.nos,
    required this.motor,
    required this.ativos,
    required this.hover,
    required this.cores,
    required this.fluxo,
  }) : super(repaint: fluxo);

  final List<(String, String, bool)> arestas;
  final Map<String, Rect> nos;
  final Map<String, Color> motor;
  final Set<String> ativos;
  final String? hover;
  final ColorScheme cores;
  final Animation<double> fluxo;

  /// Curva suave entre os lados mais próximos dos dois cartões, como no canvas do Obsidian.
  static Path _curva(Rect a, Rect b) {
    final Offset de, para;
    final bool vertical;
    if (b.top >= a.bottom) {
      (de, para, vertical) = (a.bottomCenter, b.topCenter, true);
    } else if (a.top >= b.bottom) {
      (de, para, vertical) = (a.topCenter, b.bottomCenter, true);
    } else if (b.left >= a.right) {
      (de, para, vertical) = (a.centerRight, b.centerLeft, false);
    } else {
      (de, para, vertical) = (a.centerLeft, b.centerRight, false);
    }
    final d = para - de;
    final puxa = vertical ? Offset(0, d.dy * 0.55) : Offset(d.dx * 0.55, 0);
    return Path()
      ..moveTo(de.dx, de.dy)
      ..cubicTo(de.dx + puxa.dx, de.dy + puxa.dy, para.dx - puxa.dx, para.dy - puxa.dy, para.dx, para.dy);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final t = fluxo.value;
    for (final (a, b, usa) in arestas) {
      final ra = nos[a], rb = nos[b];
      if (ra == null || rb == null) continue;
      final metrica = _curva(ra, rb).computeMetrics().firstOrNull;
      if (metrica == null || metrica.length < 1) continue;
      final ligadaHover = hover != null && (a == hover || b == hover);
      final viva = ativos.contains(a) || ativos.contains(b);
      final cor = motor[ativos.contains(b) ? b : a] ?? cores.primary;
      final fator = hover == null || ligadaHover ? 1.0 : 0.25;
      final realce = ligadaHover || viva;
      final base = (realce ? cor : cores.onSurfaceVariant).withValues(alpha: (realce ? 0.9 : 0.45) * fator);

      if (usa) {
        // pontilhado que caminha devagar na direção da ligação
        final ponto = Paint()..color = base.withValues(alpha: base.a * 0.85);
        const passo = 8.0;
        for (var d = (t * passo * 2) % passo; d < metrica.length; d += passo) {
          canvas.drawCircle(metrica.getTangentForOffset(d)!.position, realce ? 1.8 : 1.4, ponto);
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
        final fim = metrica.getTangentForOffset(metrica.length)!;
        final dir = fim.vector;
        final lado = Offset(-dir.dy, dir.dx);
        canvas.drawPath(
          Path()
            ..moveTo(fim.position.dx, fim.position.dy)
            ..lineTo(fim.position.dx - dir.dx * 8 + lado.dx * 4, fim.position.dy - dir.dy * 8 + lado.dy * 4)
            ..lineTo(fim.position.dx - dir.dx * 8 - lado.dx * 4, fim.position.dy - dir.dy * 8 - lado.dy * 4)
            ..close(),
          Paint()..color = base,
        );
      }

      // partículas correndo pela ligação enquanto um dos lados trabalha
      if (viva) {
        final brilho = Paint()
          ..color = cor.withValues(alpha: 0.5 * fator)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
        final nucleo = Paint()..color = Color.lerp(cor, Colors.white, 0.5)!.withValues(alpha: fator);
        for (var k = 0; k < 3; k++) {
          final p = metrica.getTangentForOffset(((t + k / 3) % 1) * metrica.length)!.position;
          canvas.drawCircle(p, 5, brilho);
          canvas.drawCircle(p, 2.4, nucleo);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_Arestas antigo) => true;
}

class _DetalheNo extends StatelessWidget {
  const _DetalheNo({required this.api, required this.id});

  final ApiEsteira api;
  final String id;

  @override
  Widget build(BuildContext context) => Sondagem<Json>(
    intervalo: const Duration(seconds: 3),
    carregar: () => api.noDoGrafo(id),
    construir: (context, d, _) {
      final t = Theme.of(context).textTheme;
      final estat = ((d['extras'] as Json?)?['estat'] as Json?) ?? const {};
      final chamadas = [for (final c in d['chamadas'] as List? ?? const []) c as Json];
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Row(
            spacing: 8,
            children: [
              Expanded(child: Text('${d['rotulo']}', style: t.titleLarge)),
              SeloMotor('${d['motor']}'),
            ],
          ),
          const SizedBox(height: 8),
          Text('${d['como']}'),
          if ((d['usa'] as List? ?? const []).isNotEmpty)
            Text('Usa: ${(d['usa'] as List).join(', ')}', style: t.bodySmall),
          if ((d['usado_por'] as List? ?? const []).isNotEmpty)
            Text('Usado por: ${(d['usado_por'] as List).join(', ')}', style: t.bodySmall),
          if ((d['vivos'] as List? ?? const []).isNotEmpty) ...[
            const Secao('Rodando agora'),
            for (final v in d['vivos'] as List) Text('• ${(v as Json)['comando'] ?? v['rotulo'] ?? v}'),
          ],
          const Secao('Números'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Indicador('Chamadas', '${d['n_chamadas'] ?? 0}', sub: '${d['n_cache'] ?? 0} do cache'),
              for (final (rotulo, chave, sufixo) in const [
                ('Sucesso', 'ok_pct', '%'),
                ('Geração', 'tok_s', ' tok/s'),
                ('Prefill', 'prefill_tok_s', ' tok/s'),
                ('Latência p50', 'lat_p50', ' s'),
                ('Latência p95', 'lat_p95', ' s'),
                ('Tokens entrada', 'tokens_entrada', ''),
                ('Tokens saída', 'tokens_saida', ''),
                ('Claude', 'custo_usd', ' US\$'),
              ])
                if (estat[chave] != null) Indicador(rotulo, '${estat[chave]}$sufixo'),
            ],
          ),
          if (chamadas.isNotEmpty) ...[
            Secao('Chamadas recentes (${chamadas.length})'),
            for (final c in chamadas.take(30)) _Chamada(c),
          ],
          if ((d['passos'] as List? ?? const []).isNotEmpty) ...[
            const Secao('Passos'),
            for (final p in (d['passos'] as List).reversed.take(20))
              Text(
                '${_hora((p as Json)['t'] as num?)}  ${p['fluxo'] ?? ''}  ${p['detalhe'] ?? ''}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
          ],
        ],
      );
    },
  );

  static String _hora(num? t) {
    if (t == null) return '';
    final d = DateTime.fromMillisecondsSinceEpoch((t * 1000).round());
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}

/// Uma chamada de LLM: motor, modelo, tokens, tempo; o prompt e a resposta abrem ao tocar.
class ChamadaLlm extends StatelessWidget {
  const ChamadaLlm(this.c, {super.key});

  final Json c;

  @override
  Widget build(BuildContext context) => _Chamada(c);
}

class _Chamada extends StatelessWidget {
  const _Chamada(this.c);

  final Json c;

  @override
  Widget build(BuildContext context) {
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 12);
    final ok = c['ok'] != false;
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ExpansionTile(
        dense: true,
        leading: SeloMotor('${c['engine'] ?? 'local'}'),
        title: Text('${c['name'] ?? ''} · ${c['model'] ?? ''}', overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [
            if (!ok) 'falhou',
            if (c['cache'] == true) 'do cache',
            if (c['output_tokens'] != null || c['tokens'] != null)
              '${c['output_tokens'] ?? c['tokens']} tokens',
            if (c['seconds'] != null) '${(c['seconds'] as num).toStringAsFixed(1)} s',
            if (c['tok_s'] != null) '${c['tok_s']} tok/s',
            if (c['custo'] != null) dolares(c['custo'] as num, casas: 4),
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
