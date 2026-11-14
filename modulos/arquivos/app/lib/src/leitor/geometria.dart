import 'dart:math';
import 'dart:ui';

import '../modelos.dart';

/// Ângulos (graus) para os quais uma reta "puxa" quando passa perto: horizontal, vertical e diagonais.
const _passoAngulo = 45.0;
const _toleranciaAngulo = 5.0;

/// Transforma o traço numa reta do primeiro ao último ponto, alinhando a 0°/45°/90°… quando o
/// ângulo estiver a menos de 5° deles. A pressão vira a média, para a reta ter largura uniforme.
List<PontoTinta> retificar(List<PontoTinta> pontos) {
  if (pontos.length < 2) return pontos;
  final a = pontos.first.offset;
  var b = pontos.last.offset;
  final d = b - a;
  final graus = d.direction * 180 / pi;
  final alvo = (graus / _passoAngulo).round() * _passoAngulo;
  if ((graus - alvo).abs() < _toleranciaAngulo) {
    final rad = alvo * pi / 180;
    b = a + Offset(cos(rad), sin(rad)) * d.distance;
  }
  final p = pontos.map((e) => e.p).reduce((x, y) => x + y) / pontos.length;
  return [PontoTinta(a.dx, a.dy, p), PontoTinta(b.dx, b.dy, p)];
}

/// Distância do ponto [p] ao segmento [a]–[b].
double distanciaAoSegmento(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final comprimento2 = ab.dx * ab.dx + ab.dy * ab.dy;
  if (comprimento2 == 0) return (p - a).distance;
  final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / comprimento2).clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

/// O ponto [p], com a borracha de raio [raio], encosta no traço?
bool tocaTraco(Traco t, Offset p, double raio) {
  if (!t.limites.inflate(raio).contains(p)) return false;
  final alcance = raio + t.espessura / 2;
  if (t.pontos.length == 1) return (t.pontos.first.offset - p).distance <= alcance;
  for (var i = 1; i < t.pontos.length; i++) {
    if (distanciaAoSegmento(p, t.pontos[i - 1].offset, t.pontos[i].offset) <= alcance) return true;
  }
  return false;
}

/// Índice do caractere mais próximo de [p]: o que contém o ponto ou, se nenhum, o de menor
/// distância (dando peso maior à distância vertical, para não pular de linha).
int? caractereMaisProximo(List<Rect> caracteres, Offset p) {
  int? melhor;
  var menor = double.infinity;
  for (var i = 0; i < caracteres.length; i++) {
    final r = caracteres[i];
    if (r.isEmpty && r.width == 0) continue;
    if (r.contains(p)) return i;
    final dx = p.dx < r.left ? r.left - p.dx : (p.dx > r.right ? p.dx - r.right : 0.0);
    final dy = p.dy < r.top ? r.top - p.dy : (p.dy > r.bottom ? p.dy - r.bottom : 0.0);
    final d = dx * dx + 9 * dy * dy;
    if (d < menor) {
      menor = d;
      melhor = i;
    }
  }
  return melhor;
}

/// Retângulos do trecho [inicio]..[fim] (inclusive), um por linha: caracteres seguidos com o centro
/// vertical dentro da altura do anterior ficam na mesma linha.
List<Rect> retangulosDoTrecho(List<Rect> caracteres, int inicio, int fim) {
  final linhas = <Rect>[];
  Rect? atual;
  for (var i = inicio; i <= fim && i < caracteres.length; i++) {
    final r = caracteres[i];
    if (r.width <= 0 || r.height <= 0) continue;
    if (atual != null && (r.center.dy - atual.center.dy).abs() < atual.height * 0.6 && r.left >= atual.left - 2) {
      atual = atual.expandToInclude(r);
    } else {
      if (atual != null) linhas.add(atual);
      atual = r;
    }
  }
  if (atual != null) linhas.add(atual);
  return linhas;
}
