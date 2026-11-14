import 'dart:math';
import 'dart:ui';

import '../modelos.dart';

/// Caneta inteligente do caderno (como no Samsung Notes): ao soltar a caneta, um traço que é
/// claramente uma reta vira reta alinhada (horizontal, vertical, 45° ou paralela a uma reta recente)
/// e um contorno fechado vira retângulo, quadrado, triângulo, elipse ou círculo certinhos.
/// Escrita não muda: só entra traço maior que ~2 linhas da pauta ([unidade]) e que se encaixa bem
/// na figura; letras, palavras e rabiscos ficam como foram escritos.
class CanetaInteligente {
  CanetaInteligente({this.ligada = true});

  bool ligada;

  /// Ângulos (radianos, 0–π) das últimas retas, para alinhar a próxima em paralelo.
  final List<double> _angulos = [];

  Elemento? ajustar(Traco t, {double unidade = 28}) {
    if (!ligada) return null;
    final r = reconhecer(t, unidade: unidade, angulos: _angulos);
    if (r != null && r.reta) {
      _angulos.add(r.angulo);
      if (_angulos.length > 12) _angulos.removeAt(0);
    }
    return r?.traco;
  }
}

/// O que a caneta reconheceu: o traço novo (mesmo id, pincel, cor e espessura) e, se for reta, o ângulo.
typedef Reconhecido = ({Traco traco, bool reta, double angulo, String figura});

const _grau = pi / 180;

Reconhecido? reconhecer(Traco t, {double unidade = 28, List<double> angulos = const []}) {
  final pts = [for (final p in t.pontos) p.offset];
  if (pts.length < 3) return null;
  var comprimento = 0.0;
  for (var i = 1; i < pts.length; i++) {
    comprimento += (pts[i] - pts[i - 1]).distance;
  }
  final caixa = _caixa(pts);
  final diagonal = caixa.size.longestSide;
  final minimo = max(44.0, unidade * 1.8);
  final pressao = _mediana([for (final p in t.pontos) p.p]);
  Traco novo(List<Offset> contorno) => Traco(
    t.id,
    grupo: t.grupo,
    pincel: t.pincel,
    cor: t.cor,
    espessura: t.espessura,
    pontos: [for (final p in _densificar(contorno)) Ponto(p.dx, p.dy, pressao)],
  );

  // Reta: as pontas longe e todo o traço colado na corda.
  final a = pts.first, b = pts.last, corda = (b - a).distance;
  if (corda >= minimo && comprimento <= corda * 1.12) {
    final desvio = pts.map((p) => _distanciaDaReta(p, a, b)).reduce(max);
    if (desvio <= max(4.0, corda * 0.05)) {
      final angulo = _alinhar((b - a).direction, angulos);
      final meio = (a + b) / 2, d = Offset.fromDirection(angulo, corda / 2);
      return (traco: novo([meio - d, meio + d]), reta: true, angulo: angulo % pi, figura: 'reta');
    }
  }

  // Figuras fechadas: as pontas se encontram (ou o traço passa da largada) e a figura é grande.
  if (diagonal < minimo || corda > max(18.0, comprimento * 0.14) || t.pincel == Pincel.marcador) return null;

  final c = caixa.center, rx = caixa.width / 2, ry = caixa.height / 2;
  if (rx > 4 && ry > 4) {
    final erro = _media([for (final p in pts) (sqrt(pow((p.dx - c.dx) / rx, 2) + pow((p.dy - c.dy) / ry, 2)) - 1).abs()]);
    if (erro < 0.09) {
      final circulo = (rx / ry - 1).abs() < 0.15;
      final raioX = circulo ? (rx + ry) / 2 : rx, raioY = circulo ? (rx + ry) / 2 : ry;
      final contorno = [
        for (var i = 0; i <= 72; i++) c + Offset(cos(i * 5 * _grau) * raioX, sin(i * 5 * _grau) * raioY),
      ];
      return (traco: novo(contorno), reta: false, angulo: 0, figura: circulo ? 'circulo' : 'elipse');
    }
  }

  final vertices = _cantos(pts, diagonal * 0.08);
  if (vertices.length != 3 && vertices.length != 4) return null;
  // O traço tem de ficar perto dos lados do polígono (senão era uma curva).
  final fechado = [...vertices, vertices.first];
  final folga = _media([for (final p in pts) _distanciaDoContorno(p, fechado)]);
  if (folga > diagonal * 0.035) return null;

  if (vertices.length == 3) {
    return (traco: novo(fechado), reta: false, angulo: 0, figura: 'triangulo');
  }
  // Quatro cantos com ângulos perto de 90°: retângulo; perto do eixo, fica reto; senão, girado.
  for (var i = 0; i < 4; i++) {
    final u = vertices[(i + 1) % 4] - vertices[i], v = vertices[(i + 3) % 4] - vertices[i];
    final ang = acos(((u.dx * v.dx + u.dy * v.dy) / (u.distance * v.distance)).clamp(-1.0, 1.0));
    if ((ang - pi / 2).abs() > 20 * _grau) return null;
  }
  final lado = vertices[1] - vertices[0];
  var giro = lado.direction;
  final reto = ((giro / (pi / 2)).round() * (pi / 2) - giro).abs() < 10 * _grau;
  if (reto) giro = 0;
  // Retângulo nas coordenadas giradas (caixa dos cantos), depois volta.
  Offset girar(Offset p, double g) => Offset(p.dx * cos(g) - p.dy * sin(g), p.dx * sin(g) + p.dy * cos(g));
  final locais = [for (final p in vertices) girar(p - c, -giro)];
  var caixaLocal = _caixa(locais);
  final quadrado = (caixaLocal.width / caixaLocal.height - 1).abs() < 0.12;
  if (quadrado) {
    final l = (caixaLocal.width + caixaLocal.height) / 2;
    caixaLocal = Rect.fromCenter(center: caixaLocal.center, width: l, height: l);
  }
  final cantos = [
    caixaLocal.topLeft,
    caixaLocal.topRight,
    caixaLocal.bottomRight,
    caixaLocal.bottomLeft,
    caixaLocal.topLeft,
  ].map((p) => girar(p, giro) + c).toList();
  return (traco: novo(cantos), reta: false, angulo: 0, figura: quadrado ? 'quadrado' : 'retangulo');
}

/// Prende em 0°/90° (8°), 45° (5°) ou paralelo a uma reta recente (5°).
double _alinhar(double angulo, List<double> recentes) {
  double perto(double alvo) {
    final d = (angulo - alvo) % pi;
    return min(d, pi - d);
  }

  for (final alvo in [0.0, pi / 2]) {
    if (perto(alvo) < 8 * _grau) return _ajustar(angulo, alvo);
  }
  for (final alvo in [pi / 4, 3 * pi / 4]) {
    if (perto(alvo) < 5 * _grau) return _ajustar(angulo, alvo);
  }
  for (final alvo in recentes.reversed) {
    if (perto(alvo) < 5 * _grau) return _ajustar(angulo, alvo);
  }
  return angulo;
}

/// O ângulo [alvo] (mod π) no sentido em que a reta foi desenhada.
double _ajustar(double angulo, double alvo) {
  final candidatos = [alvo, alvo + pi, alvo - pi, alvo - 2 * pi, alvo + 2 * pi];
  return candidatos.reduce((x, y) => (x - angulo).abs() <= (y - angulo).abs() ? x : y);
}

/// Cantos do contorno fechado: Ramer–Douglas–Peucker a partir do ponto mais longe da largada,
/// juntando cantos quase alinhados.
List<Offset> _cantos(List<Offset> pts, double eps) {
  var longe = 0;
  for (var i = 1; i < pts.length; i++) {
    if ((pts[i] - pts.first).distance > (pts[longe] - pts.first).distance) longe = i;
  }
  final ida = _rdp(pts.sublist(0, longe + 1), eps), volta = _rdp([...pts.sublist(longe), pts.first], eps);
  var v = [...ida, ...volta.sublist(1, volta.length - 1)];
  var mudou = true;
  while (mudou && v.length > 3) {
    mudou = false;
    for (var i = 0; i < v.length; i++) {
      final ant = v[(i - 1 + v.length) % v.length], prox = v[(i + 1) % v.length];
      if (_distanciaDaReta(v[i], ant, prox) < eps || (v[i] - ant).distance < eps) {
        v = [...v]..removeAt(i);
        mudou = true;
        break;
      }
    }
  }
  return v;
}

List<Offset> _rdp(List<Offset> pts, double eps) {
  if (pts.length < 3) return pts;
  var maior = 0.0, indice = 0;
  for (var i = 1; i < pts.length - 1; i++) {
    final d = _distanciaDaReta(pts[i], pts.first, pts.last);
    if (d > maior) (maior, indice) = (d, i);
  }
  if (maior <= eps) return [pts.first, pts.last];
  final esquerda = _rdp(pts.sublist(0, indice + 1), eps);
  return [...esquerda.sublist(0, esquerda.length - 1), ..._rdp(pts.sublist(indice), eps)];
}

double _distanciaDaReta(Offset p, Offset a, Offset b) {
  final ab = b - a, l = ab.distance;
  if (l == 0) return (p - a).distance;
  return ((p.dx - a.dx) * ab.dy - (p.dy - a.dy) * ab.dx).abs() / l;
}

double _distanciaDoSegmento(Offset p, Offset a, Offset b) {
  final ab = b - a, l2 = ab.distanceSquared;
  if (l2 == 0) return (p - a).distance;
  final t = (((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / l2).clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

double _distanciaDoContorno(Offset p, List<Offset> contorno) {
  var d = double.infinity;
  for (var i = 1; i < contorno.length; i++) {
    d = min(d, _distanciaDoSegmento(p, contorno[i - 1], contorno[i]));
  }
  return d;
}

/// Pontos a cada ~4 px nos lados: a borracha e o laço continuam achando o traço pelo meio.
List<Offset> _densificar(List<Offset> contorno) {
  final saida = <Offset>[contorno.first];
  for (var i = 1; i < contorno.length; i++) {
    final a = contorno[i - 1], b = contorno[i];
    final n = max(1, ((b - a).distance / 4).ceil());
    for (var k = 1; k <= n; k++) {
      saida.add(Offset.lerp(a, b, k / n)!);
    }
  }
  return saida;
}

Rect _caixa(List<Offset> pts) {
  var r = Rect.fromPoints(pts.first, pts.first);
  for (final p in pts) {
    r = r.expandToInclude(Rect.fromPoints(p, p));
  }
  return r;
}

double _media(List<double> v) => v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;

double _mediana(List<double> v) {
  final o = [...v]..sort();
  return o[o.length ~/ 2];
}
