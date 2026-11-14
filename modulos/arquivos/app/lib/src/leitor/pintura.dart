import 'dart:math';

import 'package:flutter/material.dart';

import '../modelos.dart';

/// Desenha os elementos de uma página. Tudo está em pontos PDF; [escala] converte para a tela.
void pintarTraco(Canvas canvas, Traco t, double escala) {
  if (t.pontos.isEmpty) return;
  final pontos = [for (final p in t.pontos) p.offset * escala];
  final base = t.espessura * escala;
  switch (t.pincel) {
    case Pincel.marcador:
      // Traço chapado, translúcido e multiplicado: o texto embaixo continua legível.
      canvas.drawPath(
        _caminhoSuave(pontos),
        Paint()
          ..color = t.cor.withValues(alpha: 0.38)
          ..blendMode = BlendMode.multiply
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.square
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = base,
      );
    case Pincel.caneta || Pincel.lapis || Pincel.caligrafia:
      final larguras = _suavizar([for (var i = 0; i < pontos.length; i++) _largura(t, i, base)]);
      if (pontos.length == 1) {
        canvas.drawCircle(pontos.first, larguras.first / 2, Paint()..color = t.cor);
        return;
      }
      // Lápis translúcido numa camada: as junções sobrepostas não escurecem em bolinhas.
      final lapis = t.pincel == Pincel.lapis;
      if (lapis) {
        final media = t.pontos.fold(0.0, (s, p) => s + p.p) / t.pontos.length;
        canvas.saveLayer(null, Paint()..color = Colors.black.withValues(alpha: 0.35 + 0.55 * media));
      }
      final tinta = Paint()
        ..color = lapis ? t.cor.withValues(alpha: 1) : t.cor
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      final (curva, ls) = _curvaDensa(pontos, larguras);
      for (var i = 1; i < curva.length; i++) {
        tinta.strokeWidth = ls[i];
        canvas.drawLine(curva[i - 1], curva[i], tinta);
      }
      if (lapis) canvas.restore();
  }
}

/// Média móvel das larguras: tira o serrilhado de pressão e direção ponto a ponto.
List<double> _suavizar(List<double> v, {int raio = 2}) => [
  for (var i = 0; i < v.length; i++)
    () {
      final de = max(0, i - raio), ate = min(v.length - 1, i + raio);
      var s = 0.0;
      for (var j = de; j <= ate; j++) {
        s += v[j];
      }
      return s / (ate - de + 1);
    }(),
];

/// Catmull-Rom pelos pontos, com um passo a cada ~1,5 px: a curva passa por todos os pontos
/// sem os cantos das retas, e a largura varia aos poucos entre eles.
(List<Offset>, List<double>) _curvaDensa(List<Offset> p, List<double> l) {
  final curva = <Offset>[p.first], ls = <double>[l.first];
  for (var i = 0; i < p.length - 1; i++) {
    final p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.length - 1)];
    final passos = ((p2 - p1).distance / 1.5).ceil().clamp(1, 32);
    for (var s = 1; s <= passos; s++) {
      final u = s / passos, u2 = u * u, u3 = u2 * u;
      curva.add(
        (p1 * 2 + (p2 - p0) * u + (p0 * 2 - p1 * 5 + p2 * 4 - p3) * u2 + (p1 * 3 - p0 - p2 * 3 + p3) * u3) * 0.5,
      );
      ls.add(l[i] + (l[i + 1] - l[i]) * u);
    }
  }
  return (curva, ls);
}

/// Largura do segmento que termina no ponto [i]: a pressão engrossa; no pincel de caligrafia a
/// direção também conta (ponta chata a 45°).
double _largura(Traco t, int i, double base) {
  final p = t.pontos[i].p;
  switch (t.pincel) {
    case Pincel.caneta:
      return base * (0.35 + 0.95 * p);
    case Pincel.lapis:
      return base * (0.6 + 0.5 * p);
    case Pincel.caligrafia:
      if (i == 0) return base * 0.5;
      final d = t.pontos[i].offset - t.pontos[i - 1].offset;
      final angulo = (d.direction - pi / 4).abs();
      return base * (0.2 + 0.8 * sin(angulo).abs()) * (0.6 + 0.6 * p);
    case Pincel.marcador:
      return base;
  }
}

Path _caminhoSuave(List<Offset> pontos) {
  final caminho = Path()..moveTo(pontos.first.dx, pontos.first.dy);
  if (pontos.length == 1) return caminho..lineTo(pontos.first.dx + 0.01, pontos.first.dy);
  for (var i = 1; i < pontos.length - 1; i++) {
    final meio = (pontos[i] + pontos[i + 1]) / 2;
    caminho.quadraticBezierTo(pontos[i].dx, pontos[i].dy, meio.dx, meio.dy);
  }
  return caminho..lineTo(pontos.last.dx, pontos.last.dy);
}

void pintarDestaque(Canvas canvas, Destaque d, double escala, {bool selecionado = false}) {
  final tinta = Paint()
    ..color = d.cor.withValues(alpha: 0.4)
    ..blendMode = BlendMode.multiply;
  for (final r in d.retangulos) {
    final tela = Rect.fromLTRB(r.left * escala, r.top * escala, r.right * escala, r.bottom * escala);
    canvas.drawRRect(RRect.fromRectAndRadius(tela.inflate(1), const Radius.circular(2)), tinta);
  }
  if (selecionado || d.comentario.isNotEmpty) {
    final r = d.retangulos.firstOrNull;
    if (r == null) return;
    // Marquinha no canto: o destaque tem comentário.
    canvas.drawCircle(Offset(r.left * escala - 4, r.top * escala), 3, Paint()..color = d.cor.withValues(alpha: 1));
  }
}

TextPainter pintorDeTexto(TextoAnotado t, double escala) => TextPainter(
  text: TextSpan(
    text: t.texto,
    style: TextStyle(color: t.cor, fontSize: t.tamanho * escala, height: 1.2),
  ),
  textDirection: TextDirection.ltr,
)..layout();

void pintarTexto(Canvas canvas, TextoAnotado t, double escala) =>
    pintorDeTexto(t, escala).paint(canvas, t.posicao * escala);

/// Retângulo do texto em pontos PDF (para tocar e editar/apagar).
Rect limitesDoTexto(TextoAnotado t) {
  final tp = pintorDeTexto(t, 1);
  return t.posicao & tp.size;
}
