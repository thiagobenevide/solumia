import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Live preview of a Studio kit piece (approximation drawn in the app, no render): same palette, fonts and
/// layout as the style, in a loop. The real video comes out of the kit (`esteira/studio/kit/estudio.js`).
class PiecePreview extends StatefulWidget {
  const PiecePreview({
    super.key,
    required this.piece,
    required this.paleta,
    this.sources = const {},
    this.layout = 'split',
    this.format = '16:9',
    this.color = 'destaque',
    this.sidePresenter = 'esquerda',
    this.largura = 0.45,
    this.caption = '',
    this.playing = true,
  });

  /// Kit scene (`anel_percentual`, `contador`…); empty = layout only.
  final String piece;
  final Map<String, Color> paleta;

  /// role (`fonte_destaque`…) → family registered in the app (`Estudio-<nome>`).
  final Map<String, String> sources;

  /// camera · split · peca · capitulo · tipografia · broll · midia_overlay
  final String layout;
  final String format;
  final String color;
  final String sidePresenter;
  final double largura;
  final String caption;
  final bool playing;

  @override
  State<PiecePreview> createState() => _PiecePreviewState();
}

class _PiecePreviewState extends State<PiecePreview> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 3600));

  @override
  void initState() {
    super.initState();
    if (widget.playing) _c.repeat();
  }

  @override
  void didUpdateWidget(PiecePreview old) {
    super.didUpdateWidget(old);
    if (old.piece != widget.piece && widget.playing) _c.forward(from: 0).then((_) => _c.repeat());
    if (!widget.playing) _c.value = 1;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: widget.format == '9:16' ? 9 / 16 : 16 / 9,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => CustomPaint(
          painter: _Painter(
            w: widget,
            // the loop shows the entrance (0–0.75) and holds the finished piece at the end
            t: widget.playing ? (_c.value / 0.75).clamp(0.0, 1.0) : 1,
          ),
        ),
      ),
    ),
  );
}

/// Sample data of each piece (the same in the app previews).
const pieceExamples = {
  'anel_percentual': '81,7% · das famílias estão endividadas',
  'grade_proporcao': '8 em cada 10 · sem reserva',
  'contador': 'R\$ 1.412 · salário mínimo',
  'equacao': '200 × 60 = 12 mil',
  'grafico_linha': '2019 63% → 2025 78%',
  'ranking': 'cartão 60 · cheque 20 · consignado 12',
  'barras_comparacao': 'poupança 12% · rotativo 400%',
  'versus': '400% vs 12%',
  'linha_do_tempo': '2019 · 2022 · 2025',
  'passo_a_passo': 'Listar → negociar → cortar',
  'lista_itens': 'Reserva · Dívidas · Investir',
  'citacao_estudo': 'CNC · 2026',
  'termo_tecnico': 'Rotativo',
  'alerta': 'Cuidado com o mínimo',
  'lettering': 'ISSO MUDA TUDO',
  'frase_destaque': 'ISSO MUDA TUDO',
  'pergunta_destaque': 'Qual é o maior vilão?',
  'titulo_capitulo': 'Capítulo 2',
  'conceito_icone': 'Juros compostos',
  'cta': 'Comenta RESERVA',
  'riscado': 'Pagar o mínimo',
  'carimbo': 'Quitado',
  'midia': 'mídia',
};

class _Painter extends CustomPainter {
  _Painter({required this.w, required this.t});

  final PiecePreview w;
  final double t;

  Color get background => w.paleta['fundo'] ?? const Color(0xFF0A1628);
  Color get background2 => w.paleta['fundo2'] ?? const Color(0xFF14284A);
  Color get texto => w.paleta['texto'] ?? Colors.white;
  Color get accent => w.paleta['acento'] ?? Colors.redAccent;
  Color get dest => w.paleta[w.color] ?? w.paleta['destaque'] ?? Colors.amber;

  String? f(String role) => w.sources[role];

  /// Entrance of an element: 0→1 between `de` and `de + d` of the piece time, with a smooth curve.
  double e(double de, [double d = 0.25]) => Curves.easeOutCubic.transform(((t - de) / d).clamp(0.0, 1.0));

  void txt(
    Canvas c,
    String s,
    Offset o,
    double size, {
    Color? color,
    String role = 'fonte_texto',
    FontWeight weight = FontWeight.w600,
    double opac = 1,
    TextAlign al = TextAlign.left,
    double? maxW,
    bool italico = false,
    double espaco = 0,
  }) {
    if (opac <= 0) return;
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          fontSize: size,
          fontWeight: weight,
          color: (color ?? texto).withValues(alpha: opac.clamp(0.0, 1.0) * ((color ?? texto).a)),
          fontFamily: f(role),
          fontStyle: italico ? FontStyle.italic : FontStyle.normal,
          letterSpacing: espaco,
          height: 1.05,
        ),
      ),
      textAlign: al,
      textDirection: TextDirection.ltr,
      maxLines: 3,
    )..layout(maxWidth: maxW ?? 9999);
    final dx = al == TextAlign.center ? -tp.width / 2 : (al == TextAlign.right ? -tp.width : 0.0);
    tp.paint(c, o + Offset(dx, 0));
  }

  @override
  void paint(Canvas c, Size s) {
    c.drawRect(Offset.zero & s, Paint()..color = background);
    final v = s.height > s.width;
    final u = math.min(s.width, s.height) / 100;
    Rect area = Offset.zero & s;
    switch (w.layout) {
      case 'camera':
        _presenter(c, Offset.zero & s, u);
        if (w.piece == 'lettering' || w.piece == 'frase_destaque' || w.piece == 'cta' || w.piece == 'carimbo') {
          area = Rect.fromLTWH(0, s.height * (v ? .55 : .5), s.width, s.height * (v ? .3 : .45));
        } else {
          area = Rect.zero;
        }
      case 'split':
        if (v) {
          final cam = Rect.fromLTWH(s.width * .06, s.height * .58, s.width * .88, s.height * .32);
          area = Rect.fromLTWH(0, 0, s.width, s.height * .56);
          _presenter(c, cam, u, cantos: 3 * u);
        } else {
          final lw = s.width * w.largura;
          final esq = w.sidePresenter != 'direita';
          final cam = esq ? Rect.fromLTWH(0, 0, lw, s.height) : Rect.fromLTWH(s.width - lw, 0, lw, s.height);
          area = esq ? Rect.fromLTWH(lw, 0, s.width - lw, s.height) : Rect.fromLTWH(0, 0, s.width - lw, s.height);
          _presenter(c, cam, u);
        }
      case 'lateral':
      case 'flutuante':
      case 'solido':
        // data on the free side: over the image (side/floating) or in a card over a solid background
        final esq = w.sidePresenter != 'esquerda';
        if (w.layout == 'solido') {
          c.drawRect(Offset.zero & s, Paint()..color = Color.lerp(background, dest, .12)!);
        } else {
          _presenter(c, Offset.zero & s, u);
        }
        area = v
            ? Rect.fromLTWH(s.width * .06, s.height * .06, s.width * .88, s.height * .44)
            : Rect.fromLTWH(esq ? s.width * .05 : s.width * .51, s.height * .14, s.width * .44, s.height * .66);
        if (w.layout == 'lateral') {
          final band = v
              ? Rect.fromLTWH(0, 0, s.width, s.height * .52)
              : (esq ? Rect.fromLTWH(0, 0, s.width * .54, s.height) : Rect.fromLTWH(s.width * .46, 0, s.width * .54, s.height));
          c.drawRect(band, Paint()..color = const Color(0x99000000));
        } else {
          final r = RRect.fromRectAndRadius(area, Radius.circular(2.4 * u));
          c.drawRRect(r, Paint()..color = (w.layout == 'solido' ? background : const Color(0x8C0C0C12)));
          c.drawRRect(r, Paint()
            ..color = dest.withValues(alpha: .55)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6 * u
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2 * u));
          c.drawRRect(r, Paint()
            ..color = const Color(0xD9FFFFFF)
            ..style = PaintingStyle.stroke
            ..strokeWidth = .4 * u);
        }
      case 'galeria':
        _presenter(c, Offset.zero & s, u);
        for (final (l, t, gw, gh) in v
            ? const [(.06, .05, .40, .22), (.54, .07, .40, .2), (.2, .3, .3, .17)]
            : const [(.06, .09, .17, .33), (.25, .11, .13, .28), (.62, .3, .17, .38), (.79, .09, .13, .27)]) {
          final r = RRect.fromRectAndRadius(
            Rect.fromLTWH(s.width * l, s.height * t, s.width * gw, s.height * gh),
            Radius.circular(1.8 * u),
          );
          c.drawRRect(r, Paint()..color = const Color(0xFF1E3326));
          c.drawRRect(r, Paint()
            ..color = const Color(0xD9FFFFFF)
            ..style = PaintingStyle.stroke
            ..strokeWidth = .4 * u);
        }
        area = Rect.zero;
      case 'broll':
      case 'midia_overlay':
        c.drawRect(Offset.zero & s, Paint()..color = const Color(0xFF1E3326));
        txt(c, 'mídia', s.center(Offset(0, -2 * u)), 4 * u, color: const Color(0xFF8FD4A6), al: TextAlign.center);
        area = w.layout == 'midia_overlay' ? Offset.zero & s : Rect.zero;
      default:
        _grade(c, s, u);
    }
    if (area != Rect.zero && w.piece.isNotEmpty && w.piece != 'midia') {
      c.save();
      c.clipRect(area);
      _piece(c, area.deflate(area.shortestSide * .08), u, v);
      c.restore();
    }
    if (w.caption.isNotEmpty) {
      final y = s.height * (v ? .72 : .84);
      final parts = w.caption.split('*');
      // *word* in the highlight color
      final tp = TextPainter(
        text: TextSpan(
          children: [
            for (final (i, p) in parts.indexed)
              TextSpan(
                text: p,
                style: TextStyle(color: i.isOdd ? dest : Colors.white),
              ),
          ],
          style: TextStyle(
            fontSize: (v ? 5.2 : 4.4) * u,
            fontWeight: FontWeight.w800,
            fontFamily: f('fonte_legenda'),
            shadows: const [Shadow(blurRadius: 6)],
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: s.width * .9);
      tp.paint(c, Offset((s.width - tp.width) / 2, y));
    }
  }

  void _grade(Canvas c, Size s, double u) {
    final p = Paint()
      ..color = texto.withValues(alpha: .04)
      ..strokeWidth = 1;
    for (double x = 0; x < s.width; x += 8 * u) {
      c.drawLine(Offset(x, 0), Offset(x, s.height), p);
    }
    for (double y = 0; y < s.height; y += 8 * u) {
      c.drawLine(Offset(0, y), Offset(s.width, y), p);
    }
  }

  void _presenter(Canvas c, Rect r, double u, {double cantos = 0}) {
    c.save();
    c.clipRRect(RRect.fromRectAndRadius(r, Radius.circular(cantos)));
    c.drawRect(r, Paint()..color = Color.lerp(background2, Colors.white, .08)!);
    final cx = r.center.dx, h = r.height;
    final head = Paint()..color = Color.lerp(background2, Colors.white, .22)!;
    c.drawCircle(Offset(cx, r.top + h * .42), h * .12, head);
    c.drawOval(Rect.fromCenter(center: Offset(cx, r.bottom + h * .12), width: h * .62, height: h * .55), head);
    c.restore();
  }

  void _piece(Canvas c, Rect a, double u, bool v) {
    final k = math.min(a.width, a.height) / 100; // unit of the piece area
    final cx = a.center.dx;
    switch (w.piece) {
      case 'anel_percentual':
        final r = math.min(a.height * .38, a.width * .2);
        final center = Offset(a.left + r + 2 * k, a.center.dy);
        final p = .817 * e(.15, .5);
        for (var i = 0; i < 60; i++) {
          final ang = i / 60 * 2 * math.pi - math.pi / 2;
          final on = i / 60 < p;
          c.drawLine(
            center + Offset(math.cos(ang), math.sin(ang)) * (r * 1.16),
            center + Offset(math.cos(ang), math.sin(ang)) * (r * 1.24),
            Paint()
              ..color = texto.withValues(alpha: on ? .9 : .12)
              ..strokeWidth = .8 * k,
          );
        }
        final arc = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * .18
          ..strokeCap = StrokeCap.round;
        c.drawCircle(center, r, arc..color = background2);
        c.drawArc(Rect.fromCircle(center: center, radius: r), -math.pi / 2, 2 * math.pi * p, false, arc..color = dest);
        final x = center.dx + r * 1.5;
        txt(c, 'CNC · 2026', Offset(x, a.center.dy - 26 * k), 4 * k, color: accent, role: 'fonte_tecnica', opac: e(.1));
        txt(
          c,
          '${(81.7 * e(.15, .5)).toStringAsFixed(1).replaceAll('.', ',')}%',
          Offset(x, a.center.dy - 20 * k),
          22 * k,
          color: dest,
          role: 'fonte_destaque',
          weight: FontWeight.w800,
          opac: e(.15),
        );
        final bw = a.right - x;
        c.drawRect(Rect.fromLTWH(x, a.center.dy + 6 * k, bw * .9, 1.6 * k), Paint()..color = background2);
        c.drawRect(Rect.fromLTWH(x, a.center.dy + 6 * k, bw * .9 * p, 1.6 * k), Paint()..color = dest);
        txt(c, 'das famílias estão endividadas', Offset(x, a.center.dy + 11 * k), 5 * k, opac: e(.4), maxW: bw);
      case 'grade_proporcao':
        txt(c, '8 em cada 10', Offset(cx, a.top + 2 * k), 12 * k, color: dest, role: 'fonte_destaque', weight: FontWeight.w800, al: TextAlign.center, opac: e(.05));
        final side = math.min(a.width * .6, a.height * .62);
        final cel = side / 10;
        final top = a.bottom - side;
        final lit = (80 * e(.3, .5)).round();
        var n = 0;
        for (var lin = 9; lin >= 0; lin--) {
          for (var col = 0; col < 10; col++) {
            final on = n++ < lit;
            c.drawRRect(
              RRect.fromRectAndRadius(
                Rect.fromLTWH(cx - side / 2 + col * cel + cel * .1, top + lin * cel + cel * .1, cel * .8, cel * .8),
                Radius.circular(cel * .15),
              ),
              Paint()..color = on ? dest : texto.withValues(alpha: .1 * e(.0, .3)),
            );
          }
        }
      case 'contador':
        txt(c, 'SALÁRIO MÍNIMO', Offset(cx, a.top + a.height * .18), 4 * k, color: dest, role: 'fonte_tecnica', al: TextAlign.center, opac: e(0), espaco: 2);
        txt(c, 'R\$ ${(1412 * e(.1, .5)).round()}', Offset(cx, a.top + a.height * .3), 24 * k, role: 'fonte_destaque', weight: FontWeight.w800, al: TextAlign.center, opac: e(.1));
        final lw = a.width * .5 * e(.45);
        c.drawRect(Rect.fromCenter(center: Offset(cx, a.top + a.height * .74), width: lw, height: 1.2 * k), Paint()..color = dest);
      case 'equacao':
        final items = ['200', '×', '60', '=', '12 mil'];
        final step = a.width / items.length;
        for (final (i, s) in items.indexed) {
          final res = i == 4;
          final op = s == '×' || s == '=';
          txt(
            c,
            s,
            Offset(a.left + step * (i + .5), a.center.dy - (op ? 5 : 8) * k),
            (op ? 9 : (res ? 13 : 12)) * k,
            color: res ? dest : (op ? accent : texto),
            role: op ? 'fonte_texto' : 'fonte_destaque',
            weight: op ? FontWeight.w300 : FontWeight.w800,
            al: TextAlign.center,
            opac: e(.1 + i * .12),
          );
        }
      case 'grafico_linha':
        final pts = [.63, .66, .7, .74, .78];
        final path = Path();
        final prog = e(.15, .6);
        for (final (i, p) in pts.indexed) {
          final o = Offset(a.left + a.width * i / (pts.length - 1), a.bottom - a.height * (p - .5) * 2.2);
          i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
        }
        for (final m in path.computeMetrics()) {
          c.drawPath(
            m.extractPath(0, m.length * prog),
            Paint()
              ..color = dest
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.4 * k
              ..strokeCap = StrokeCap.round,
          );
        }
        txt(c, '78%', Offset(a.right, a.top), 14 * k, color: dest, role: 'fonte_destaque', weight: FontWeight.w800, al: TextAlign.right, opac: e(.6));
        txt(c, '2019', Offset(a.left, a.bottom - 4 * k), 4 * k, color: accent, role: 'fonte_tecnica', opac: e(.1));
        txt(c, '2025', Offset(a.right, a.bottom - 4 * k), 4 * k, color: accent, role: 'fonte_tecnica', al: TextAlign.right, opac: e(.7));
      case 'ranking':
      case 'barras_comparacao':
        final dados = w.piece == 'ranking'
            ? [('Cartão', .6), ('Cheque especial', .2), ('Consignado', .12)]
            : [('Poupança', .03), ('Rotativo', 1.0)];
        final alt = a.height / (dados.length + 1);
        for (final (i, (rot, val)) in dados.indexed) {
          final y = a.top + alt * (i + .5);
          final top = w.piece == 'ranking' ? i == 0 : i == dados.length - 1;
          final op = w.piece == 'ranking' && i > 0 && t > .9 ? .4 : 1.0;
          txt(c, rot, Offset(a.left, y), 4.6 * k, opac: e(.1 + i * .12) * op);
          final width = (a.width * .8) * val / (w.piece == 'ranking' ? .6 : 1) * e(.2 + i * .12, .45);
          c.drawRRect(
            RRect.fromRectAndRadius(Rect.fromLTWH(a.left, y + 6 * k, width, 2.4 * k), Radius.circular(k)),
            Paint()..color = (top ? dest : texto.withValues(alpha: .5)).withValues(alpha: op),
          );
        }
      case 'versus':
        txt(c, '400%', Offset(a.left + a.width * .25, a.center.dy - 8 * k), 14 * k, color: dest, role: 'fonte_destaque', weight: FontWeight.w800, al: TextAlign.center, opac: e(.1));
        txt(c, 'vs', Offset(cx, a.center.dy - 4 * k), 7 * k, color: accent, role: 'fonte_editorial', italico: true, al: TextAlign.center, opac: e(.3));
        txt(c, '12%', Offset(a.left + a.width * .75, a.center.dy - 8 * k), 14 * k, role: 'fonte_destaque', weight: FontWeight.w800, al: TextAlign.center, opac: e(.4));
      case 'linha_do_tempo':
        final y = a.center.dy;
        c.drawLine(Offset(a.left, y), Offset(a.left + a.width * e(.05, .5), y), Paint()
          ..color = dest
          ..strokeWidth = .6 * k);
        for (final (i, year) in ['2019', '2022', '2025'].indexed) {
          final x = a.left + a.width * (.1 + i * .4);
          c.drawCircle(Offset(x, y), 2 * k * e(.2 + i * .15), Paint()..color = dest);
          txt(c, year, Offset(x, y - 12 * k), 7 * k, role: 'fonte_destaque', weight: FontWeight.w800, al: TextAlign.center, opac: e(.2 + i * .15));
        }
      case 'passo_a_passo':
      case 'lista_itens':
        final items = w.piece == 'lista_itens' ? ['Reserva', 'Dívidas', 'Investir'] : ['Listar', 'Negociar', 'Cortar'];
        for (final (i, s) in items.indexed) {
          final y = a.top + a.height * (.2 + i * .25);
          final active = i == ((t * 3).floor().clamp(0, 2));
          txt(c, '${i + 1}', Offset(a.left, y), 7 * k, color: dest, role: 'fonte_tecnica', opac: e(i * .15));
          txt(c, s, Offset(a.left + 10 * k, y), 7 * k, role: 'fonte_destaque', weight: FontWeight.w800, opac: e(i * .15) * (active || t >= 1 ? 1 : .4));
        }
      case 'citacao_estudo':
        final r = RRect.fromRectAndRadius(
          Rect.fromLTWH(a.left, a.center.dy - 16 * k, a.width, 32 * k),
          Radius.circular(2 * k),
        );
        c.drawRRect(r, Paint()..color = background2.withValues(alpha: e(0)));
        c.drawRect(Rect.fromLTWH(a.left, r.top, 1 * k, r.height), Paint()..color = dest.withValues(alpha: e(0)));
        txt(c, 'ESTUDO · CNC 2026', Offset(a.left + 5 * k, r.top + 4 * k), 4 * k, color: dest, role: 'fonte_tecnica', opac: e(.1), espaco: 1.5);
        txt(c, 'Pesquisa de Endividamento', Offset(a.left + 5 * k, r.top + 11 * k), 7 * k, role: 'fonte_editorial', italico: true, opac: e(.2), maxW: a.width * .9);
      case 'termo_tecnico':
        const term = 'Rotativo';
        final n = (term.length * e(.1, .5)).round();
        txt(c, 'TERMO', Offset(a.left, a.center.dy - 16 * k), 4 * k, color: accent, role: 'fonte_tecnica', espaco: 2, opac: e(0));
        txt(c, term.substring(0, n) + (t < .8 && (t * 8).floor().isEven ? '|' : ''), Offset(a.left, a.center.dy - 10 * k), 14 * k, color: dest, role: 'fonte_destaque', weight: FontWeight.w800);
        c.drawRect(Rect.fromLTWH(a.left, a.center.dy + 7 * k, a.width * .6 * e(.6), .8 * k), Paint()..color = dest);
        txt(c, 'os juros mais caros do país', Offset(a.left, a.center.dy + 11 * k), 5 * k, opac: e(.7));
      case 'alerta':
        final ic = Offset(a.left + 9 * k, a.center.dy);
        c.drawCircle(ic, 9 * k * e(0), Paint()..color = dest.withValues(alpha: .15));
        c.drawCircle(ic, 9 * k * (1 + .6 * (t % .5) * 2), Paint()
          ..color = dest.withValues(alpha: (1 - (t % .5) * 2) * .6)
          ..style = PaintingStyle.stroke);
        txt(c, '!', ic - Offset(0, 7 * k), 12 * k, color: dest, weight: FontWeight.w900, al: TextAlign.center, opac: e(.1));
        txt(c, 'ATENÇÃO', Offset(a.left + 22 * k, a.center.dy - 9 * k), 4 * k, color: dest, role: 'fonte_tecnica', espaco: 2, opac: e(.15));
        txt(c, 'Cuidado com o mínimo', Offset(a.left + 22 * k, a.center.dy - 3 * k), 7 * k, role: 'fonte_destaque', weight: FontWeight.w800, opac: e(.25), maxW: a.width - 22 * k);
      case 'lettering':
      case 'frase_destaque':
        final lines = ['ISSO', 'MUDA', 'TUDO'];
        final alt = a.height / 3.4;
        for (final (i, s) in lines.indexed) {
          final p = e(.05 + i * .14, .3);
          c.save();
          c.clipRect(Rect.fromLTWH(a.left, a.top + alt * i, a.width, alt));
          txt(c, s, Offset(cx, a.top + alt * i + alt * (1 - p)), alt * .85, color: i == 2 ? dest : texto, role: 'fonte_destaque', weight: FontWeight.w900, al: TextAlign.center);
          c.restore();
        }
      case 'pergunta_destaque':
        txt(c, '?', Offset(cx, a.top - 10 * k), a.height * .9, color: dest.withValues(alpha: .15), role: 'fonte_editorial', italico: true, al: TextAlign.center, opac: e(0));
        txt(c, 'Qual é o maior vilão?', Offset(cx, a.center.dy - 6 * k), 10 * k, role: 'fonte_destaque', weight: FontWeight.w800, al: TextAlign.center, opac: e(.15), maxW: a.width);
      case 'titulo_capitulo':
        txt(c, 'PARTE 2', Offset(a.left, a.center.dy - 14 * k), 4 * k, color: dest, role: 'fonte_tecnica', espaco: 3, opac: e(0));
        final s = 'O cartão de crédito';
        txt(c, s.substring(0, (s.length * e(.15, .5)).round()), Offset(a.left, a.center.dy - 7 * k), 12 * k, role: 'fonte_editorial', italico: true, weight: FontWeight.w700, maxW: a.width);
      case 'conceito_icone':
        c.drawCircle(Offset(cx, a.center.dy - 8 * k), 10 * k * e(0), Paint()
          ..color = dest
          ..style = PaintingStyle.stroke
          ..strokeWidth = .8 * k);
        txt(c, 'JUROS COMPOSTOS', Offset(cx, a.center.dy + 6 * k), 8 * k, role: 'fonte_destaque', weight: FontWeight.w800, al: TextAlign.center, opac: e(.2));
      case 'cta':
        final r = RRect.fromRectAndRadius(Rect.fromCenter(center: a.center, width: a.width * .7 * (.7 + .3 * e(0)), height: 14 * k), const Radius.circular(99));
        c.drawRRect(r, Paint()..color = dest.withValues(alpha: e(0)));
        txt(c, 'COMENTA RESERVA →', a.center - Offset(0, 4 * k), 6 * k, color: background, role: 'fonte_destaque', weight: FontWeight.w800, al: TextAlign.center, opac: e(.1));
      case 'riscado':
        txt(c, 'PAGAR O MÍNIMO', a.center - Offset(0, 5 * k), 9 * k, role: 'fonte_destaque', weight: FontWeight.w800, al: TextAlign.center, opac: e(0) * (t > .7 ? .4 : 1));
        c.drawLine(a.center - Offset(a.width * .4, 0), a.center - Offset(a.width * .4, 0) + Offset(a.width * .8 * e(.35, .2), 0), Paint()
          ..color = accent
          ..strokeWidth = 1.2 * k);
      case 'carimbo':
        c.save();
        c.translate(a.center.dx, a.center.dy);
        final s = 2.4 - 1.4 * e(0, .15);
        c.scale(s);
        c.rotate(-.12);
        c.drawRRect(
          RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: 50 * k, height: 16 * k), Radius.circular(2 * k)),
          Paint()
            ..color = dest.withValues(alpha: e(0, .15))
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4 * k,
        );
        txt(c, 'QUITADO', Offset(0, -6 * k), 10 * k, color: dest, role: 'fonte_destaque', weight: FontWeight.w900, al: TextAlign.center, opac: e(0, .15));
        c.restore();
    }
  }

  @override
  bool shouldRepaint(_Painter old) => true;
}
