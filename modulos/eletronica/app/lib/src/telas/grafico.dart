import 'dart:math';

import 'package:flutter/material.dart';

import '../calculos.dart';

/// Ordem fixa das cores dos sinais (paleta categórica validada, modo escuro). A cor fica com o sinal
/// enquanto ele estiver visível; não passa de 8 ao mesmo tempo.
const coresSinais = [
  Color(0xFF3987E5),
  Color(0xFFD95926),
  Color(0xFF199E70),
  Color(0xFFC98500),
  Color(0xFFD55181),
  Color(0xFF008300),
  Color(0xFF9085E9),
  Color(0xFFE66767),
];

const _grade = Color(0xFF2C2C2A);
const _margem = EdgeInsets.fromLTRB(68, 10, 14, 30);

/// Passo "redondo" (1, 2 ou 5 × 10ⁿ) para cerca de [alvo] divisões em [faixa].
double passoRedondo(double faixa, [int alvo = 5]) {
  if (faixa <= 0 || !faixa.isFinite) return 1;
  final bruto = faixa / alvo;
  final dez = pow(10, (log(bruto) / ln10).floor()).toDouble();
  final m = bruto / dez;
  return (m < 1.5 ? 1 : m < 3.5 ? 2 : m < 7.5 ? 5 : 10) * dez;
}

/// Osciloscópio: [series] (todas com a mesma [unidadeY]) contra [x]; [logX] para AC. Passar o mouse ou o
/// dedo mostra a cruz e os valores no ponto mais próximo.
class GraficoCurvas extends StatefulWidget {
  const GraficoCurvas({
    super.key,
    required this.x,
    required this.series,
    required this.cores,
    required this.unidadeX,
    required this.unidadeY,
    this.logX = false,
  });

  final List<double> x;
  final Map<String, List<double>> series;
  final Map<String, Color> cores;
  final String unidadeX, unidadeY;
  final bool logX;

  @override
  State<GraficoCurvas> createState() => _GraficoCurvasState();
}

class _GraficoCurvasState extends State<GraficoCurvas> {
  int? _indice;

  void _apontar(Offset local, Size tamanho) {
    final x = widget.x;
    if (x.isEmpty) return;
    final area = _margem.deflateRect(Offset.zero & tamanho);
    final f = ((local.dx - area.left) / area.width).clamp(0.0, 1.0);
    final escala = _EscalaX(x, widget.logX);
    final alvo = escala.inverso(f);
    var lo = 0, hi = x.length - 1;
    while (hi - lo > 1) {
      final meio = (lo + hi) ~/ 2;
      x[meio] < alvo ? lo = meio : hi = meio;
    }
    final i = (alvo - x[lo]).abs() <= (x[hi] - alvo).abs() ? lo : hi;
    if (i != _indice) setState(() => _indice = i);
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final tamanho = c.biggest;
        return MouseRegion(
          onHover: (e) => _apontar(e.localPosition, tamanho),
          onExit: (_) => setState(() => _indice = null),
          child: Listener(
            onPointerDown: (e) => _apontar(e.localPosition, tamanho),
            onPointerMove: (e) => _apontar(e.localPosition, tamanho),
            child: CustomPaint(
              size: tamanho,
              painter: _PintorGrafico(
                widget,
                _indice,
                texto: tema.colorScheme.onSurface,
                textoFraco: tema.colorScheme.onSurfaceVariant,
                caixa: tema.colorScheme.surfaceContainerHighest,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Eixo x linear ou em décadas (log10), mapeado para 0–1.
class _EscalaX {
  _EscalaX(List<double> x, this.logaritmica) {
    final validos = logaritmica ? x.where((v) => v > 0) : x;
    ini = _t(validos.isEmpty ? 1 : validos.first);
    fim = _t(validos.isEmpty ? 10 : validos.last);
    if (fim == ini) fim = ini + 1;
  }

  final bool logaritmica;
  late double ini, fim;

  double _t(double v) => logaritmica ? (v > 0 ? log(v) / ln10 : double.nan) : v;

  double fracao(double v) => (_t(v) - ini) / (fim - ini);

  double inverso(double f) {
    final t = ini + f * (fim - ini);
    return logaritmica ? pow(10, t).toDouble() : t;
  }
}

class _PintorGrafico extends CustomPainter {
  _PintorGrafico(this.g, this.indice, {required this.texto, required this.textoFraco, required this.caixa});

  final GraficoCurvas g;
  final int? indice;
  final Color texto, textoFraco, caixa;

  void _rotulo(Canvas canvas, String s, Offset pos, {TextAlign alinhar = TextAlign.center, Color? cor, double tamanho = 11}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: cor ?? textoFraco, fontSize: tamanho)),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = alinhar == TextAlign.right ? -tp.width : (alinhar == TextAlign.left ? 0.0 : -tp.width / 2);
    tp.paint(canvas, pos + Offset(dx, -tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final area = _margem.deflateRect(Offset.zero & size);
    if (area.isEmpty || g.x.isEmpty) return;
    var ymin = double.infinity, ymax = -double.infinity;
    for (final s in g.series.values) {
      for (final v in s) {
        if (v.isFinite) {
          ymin = min(ymin, v);
          ymax = max(ymax, v);
        }
      }
    }
    if (!ymin.isFinite) ymin = ymax = 0;
    if (ymax - ymin < 1e-15) {
      final folga = ymax.abs() * 0.1 + 1e-12;
      ymin -= folga;
      ymax += folga;
    }
    final passoY = passoRedondo(ymax - ymin);
    ymin = (ymin / passoY).floor() * passoY;
    ymax = (ymax / passoY).ceil() * passoY;
    final ex = _EscalaX(g.x, g.logX);
    double px(double v) => area.left + ex.fracao(v) * area.width;
    double py(double v) => area.bottom - (v - ymin) / (ymax - ymin) * area.height;

    final grade = Paint()
      ..color = _grade
      ..strokeWidth = 1;
    for (var v = ymin; v <= ymax + passoY / 2; v += passoY) {
      canvas.drawLine(Offset(area.left, py(v)), Offset(area.right, py(v)), grade);
      _rotulo(canvas, formatar(v.abs() < passoY * 1e-6 ? 0 : v, g.unidadeY), Offset(area.left - 6, py(v)), alinhar: TextAlign.right);
    }
    if (g.logX) {
      for (var d = ex.ini.floor(); d <= ex.fim.ceil(); d++) {
        final v = pow(10, d).toDouble();
        if (d < ex.ini - 1e-9 || d > ex.fim + 1e-9) continue;
        canvas.drawLine(Offset(px(v), area.top), Offset(px(v), area.bottom), grade);
        _rotulo(canvas, formatar(v, g.unidadeX), Offset(px(v), area.bottom + 14));
      }
    } else {
      final passoX = passoRedondo(ex.fim - ex.ini, 6);
      for (var v = (ex.ini / passoX).ceil() * passoX; v <= ex.fim + passoX * 1e-6; v += passoX) {
        canvas.drawLine(Offset(px(v), area.top), Offset(px(v), area.bottom), grade);
        _rotulo(canvas, formatar(v.abs() < passoX * 1e-6 ? 0 : v, g.unidadeX), Offset(px(v), area.bottom + 14));
      }
    }

    canvas
      ..save()
      ..clipRect(area.inflate(2));
    for (final e in g.series.entries) {
      final caminho = Path();
      var aberto = false;
      for (var i = 0; i < min(e.value.length, g.x.length); i++) {
        final x = px(g.x[i]), y = py(e.value[i]);
        if (!x.isFinite || !y.isFinite) {
          aberto = false;
          continue;
        }
        aberto ? caminho.lineTo(x, y) : caminho.moveTo(x, y);
        aberto = true;
      }
      canvas.drawPath(
        caminho,
        Paint()
          ..color = g.cores[e.key] ?? texto
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round,
      );
    }
    canvas.restore();

    final i = indice;
    if (i == null || i >= g.x.length) return;
    final cx = px(g.x[i]);
    canvas.drawLine(Offset(cx, area.top), Offset(cx, area.bottom), Paint()..color = textoFraco.withValues(alpha: 0.6));
    final linhas = <(String, Color?)>[
      (formatar(g.x[i], g.unidadeX), null),
      for (final e in g.series.entries)
        if (i < e.value.length) ('${e.key}  ${formatar(e.value[i], g.unidadeY)}', g.cores[e.key]),
    ];
    for (final e in g.series.entries) {
      if (i >= e.value.length || !py(e.value[i]).isFinite) continue;
      final p = Offset(cx, py(e.value[i]));
      canvas
        ..drawCircle(p, 5, Paint()..color = caixa)
        ..drawCircle(p, 4, Paint()..color = g.cores[e.key] ?? texto);
    }
    const altura = 16.0;
    final largura = linhas.map((l) => l.$1.length * 6.6 + 24).reduce(max);
    var esquerda = cx + 12;
    if (esquerda + largura > size.width) esquerda = cx - 12 - largura;
    final caixaR = Rect.fromLTWH(esquerda, area.top + 4, largura, linhas.length * altura + 8);
    canvas.drawRRect(RRect.fromRectAndRadius(caixaR, const Radius.circular(6)), Paint()..color = caixa);
    for (var k = 0; k < linhas.length; k++) {
      final y = caixaR.top + 4 + altura * k + altura / 2;
      final cor = linhas[k].$2;
      if (cor != null) canvas.drawCircle(Offset(caixaR.left + 10, y), 4, Paint()..color = cor);
      _rotulo(canvas, linhas[k].$1, Offset(caixaR.left + 20, y), alinhar: TextAlign.left, cor: texto);
    }
  }

  @override
  bool shouldRepaint(_PintorGrafico old) => old.g != g || old.indice != indice;
}
