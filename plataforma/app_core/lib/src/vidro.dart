import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Visual de vidro fosco (estilo "Liquid Glass"): um fundo com manchas de cor suaves e cartões
/// translúcidos que desfocam o que está atrás. Leve: as manchas são estáticas e o desfoque só
/// existe dentro de cada cartão.

/// Fundo com degradê e manchas de cor (primária, terciária e secundária) atrás do [child].
class FundoVidro extends StatelessWidget {
  const FundoVidro({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final escuro = Theme.of(context).brightness == Brightness.dark;
    final forca = escuro ? 0.30 : 0.22;
    return Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: c.surface)),
        _Mancha(alinhamento: const Alignment(-1.1, -1.0), cor: c.primary.withValues(alpha: forca), tamanho: 520),
        _Mancha(alinhamento: const Alignment(1.2, -0.4), cor: c.tertiary.withValues(alpha: forca * 0.8), tamanho: 460),
        _Mancha(alinhamento: const Alignment(-0.2, 1.3), cor: c.secondary.withValues(alpha: forca * 0.7), tamanho: 480),
        Positioned.fill(child: child),
      ],
    );
  }
}

class _Mancha extends StatelessWidget {
  const _Mancha({required this.alinhamento, required this.cor, required this.tamanho});

  final Alignment alinhamento;
  final Color cor;
  final double tamanho;

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: IgnorePointer(
      child: Align(
        alignment: alinhamento,
        child: Container(
          width: tamanho,
          height: tamanho,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [cor, cor.withValues(alpha: 0)]),
          ),
        ),
      ),
    ),
  );
}

/// Cartão de vidro: desfoca o fundo, tem brilho na borda e sombra suave. [cor] tinge o vidro.
class Vidro extends StatelessWidget {
  const Vidro({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.raio = 22,
    this.cor,
    this.margem = EdgeInsets.zero,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margem;
  final double raio;
  final Color? cor;

  @override
  Widget build(BuildContext context) {
    final escuro = Theme.of(context).brightness == Brightness.dark;
    final base = cor ?? Colors.white;
    final topo = base.withValues(alpha: escuro ? (cor == null ? 0.09 : 0.20) : (cor == null ? 0.72 : 0.30));
    final baixo = base.withValues(alpha: escuro ? (cor == null ? 0.04 : 0.10) : (cor == null ? 0.50 : 0.18));
    final borda = Colors.white.withValues(alpha: escuro ? 0.14 : 0.7);
    final arredondado = BorderRadius.circular(raio);
    return Padding(
      padding: margem,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: arredondado,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: escuro ? 0.28 : 0.07),
              blurRadius: 28,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: arredondado,
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            child: Container(
              padding: padding,
              decoration: BoxDecoration(
                borderRadius: arredondado,
                gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [topo, baixo]),
                border: Border.all(color: borda, width: 1),
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Título de seção dentro de um [Vidro]: ícone em pastilha colorida + texto + ação opcional.
class TituloVidro extends StatelessWidget {
  const TituloVidro({super.key, required this.icone, required this.texto, this.cor, this.acao});

  final IconData icone;
  final String texto;
  final Color? cor;
  final Widget? acao;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final tom = cor ?? c.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: tom.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(12)),
            child: Icon(icone, size: 20, color: tom),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              texto,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          ?acao,
        ],
      ),
    );
  }
}

/// Entra com fade + deslize, uma vez, em cascata pela [ordem] (recarregar não repete).
class Surgir extends StatelessWidget {
  const Surgir({super.key, required this.ordem, required this.child});

  final int ordem;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final atraso = 70 * ordem.clamp(0, 8);
    final total = 380 + atraso;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(atraso / total, 1, curve: Curves.easeOutCubic),
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 16 * (1 - t)), child: child),
      ),
    );
  }
}

/// Comemoração curta (≈1,4 s) por cima da tela: confete + selo de check com [mensagem].
/// Ex.: treino concluído, tarefa feita, plano montado.
void comemorar(BuildContext context, {String mensagem = 'Feito!'}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  late final OverlayEntry entrada;
  entrada = OverlayEntry(builder: (_) => _Comemoracao(mensagem: mensagem, aoTerminar: () => entrada.remove()));
  overlay.insert(entrada);
}

class _Comemoracao extends StatefulWidget {
  const _Comemoracao({required this.mensagem, required this.aoTerminar});

  final String mensagem;
  final VoidCallback aoTerminar;

  @override
  State<_Comemoracao> createState() => _ComemoracaoState();
}

class _ComemoracaoState extends State<_Comemoracao> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))
    ..forward().whenComplete(widget.aoTerminar);
  final _particulas = _gerarParticulas();

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final cores = [c.primary, c.tertiary, c.secondary, Colors.amber, Colors.pinkAccent];
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _anim,
        builder: (context, _) {
          final t = _anim.value;
          final selo = Curves.elasticOut.transform((t / 0.45).clamp(0, 1));
          final some = t < 0.75 ? 1.0 : 1 - (t - 0.75) / 0.25;
          return Opacity(
            opacity: some.clamp(0, 1),
            child: Stack(
              children: [
                Positioned.fill(child: CustomPaint(painter: _Confete(_particulas, t, cores))),
                Center(
                  child: Transform.scale(
                    scale: selo,
                    child: Material(
                      color: Colors.transparent,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                        decoration: BoxDecoration(
                          color: c.primary,
                          borderRadius: BorderRadius.circular(40),
                          boxShadow: [BoxShadow(color: c.primary.withValues(alpha: 0.4), blurRadius: 24)],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.check_circle_rounded, color: c.onPrimary, size: 28),
                            const SizedBox(width: 10),
                            Text(
                              widget.mensagem,
                              style: TextStyle(color: c.onPrimary, fontSize: 18, fontWeight: FontWeight.w700),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Particula {
  _Particula(this.angulo, this.velocidade, this.giro, this.cor, this.tamanho);

  final double angulo;
  final double velocidade;
  final double giro;
  final int cor;
  final double tamanho;
}

List<_Particula> _gerarParticulas() {
  final r = math.Random();
  final lista = <_Particula>[];
  for (var i = 0; i < 46; i++) {
    lista.add(_Particula(
      -math.pi / 2 + (r.nextDouble() - 0.5) * math.pi * 1.3,
      260 + r.nextDouble() * 320,
      (r.nextDouble() - 0.5) * 12,
      r.nextInt(5),
      5 + r.nextDouble() * 6,
    ));
  }
  return lista;
}

/// Confete saindo do centro em arco e caindo com gravidade.
class _Confete extends CustomPainter {
  _Confete(this.particulas, this.t, this.cores);

  final List<_Particula> particulas;
  final double t;
  final List<Color> cores;

  @override
  void paint(Canvas canvas, Size size) {
    final centro = size.center(Offset.zero);
    final tinta = Paint();
    for (final p in particulas) {
      final x = centro.dx + math.cos(p.angulo) * p.velocidade * t;
      final y = centro.dy + math.sin(p.angulo) * p.velocidade * t + 520 * t * t;
      tinta.color = cores[p.cor % cores.length];
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(p.giro * t);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: p.tamanho, height: p.tamanho * 0.55), const Radius.circular(2)),
        tinta,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_Confete old) => old.t != t;
}
