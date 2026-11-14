import 'dart:math';
import 'dart:ui';

import 'package:agent_design/src/caderno/caneta.dart';
import 'package:agent_design/src/modelos.dart';
import 'package:flutter_test/flutter_test.dart';

Traco _traco(List<Offset> pts, {Pincel pincel = Pincel.caneta}) => Traco(
  't',
  pincel: pincel,
  cor: const Color(0xFF000000),
  espessura: 3,
  pontos: [for (final p in pts) Ponto(p.dx, p.dy, 0.5)],
);

/// Contorno pelos [cantos] com um tremido de mão (±[ruido]).
List<Offset> _tremido(List<Offset> cantos, {double ruido = 2}) {
  final r = Random(7), saida = <Offset>[];
  for (var i = 1; i < cantos.length; i++) {
    for (var k = 0; k < 25; k++) {
      final p = Offset.lerp(cantos[i - 1], cantos[i], k / 25)!;
      saida.add(p + Offset((r.nextDouble() - 0.5) * ruido, (r.nextDouble() - 0.5) * ruido));
    }
  }
  return saida..add(cantos.last);
}

void main() {
  test('reta quase horizontal fica horizontal, com o mesmo id e cor', () {
    final r = reconhecer(_traco(_tremido([const Offset(10, 100), const Offset(300, 108)])))!;
    expect(r.figura, 'reta');
    final ys = r.traco.pontos.map((p) => p.y.toStringAsFixed(1)).toSet();
    expect(ys.length, 1);
    expect(r.traco.id, 't');
  });

  test('reta nova paralela a uma recente pega o mesmo ângulo', () {
    const recente = 0.5; // ~28,6°
    final fim = Offset(10 + cos(0.53) * 300, 10 + sin(0.53) * 300);
    final r = reconhecer(_traco([const Offset(10, 10), (const Offset(10, 10) + fim) / 2, fim]), angulos: [recente])!;
    expect(r.angulo, closeTo(recente, 1e-9));
  });

  test('retângulo, quadrado, triângulo e círculo tortos ficam certinhos', () {
    expect(
      reconhecer(_traco(_tremido([const Offset(0, 0), const Offset(200, 3), const Offset(198, 100), const Offset(2, 98), const Offset(1, 2)])))!
          .figura,
      'retangulo',
    );
    expect(
      reconhecer(_traco(_tremido([const Offset(0, 0), const Offset(150, 2), const Offset(148, 147), const Offset(1, 150), const Offset(0, 3)])))!
          .figura,
      'quadrado',
    );
    expect(
      reconhecer(_traco(_tremido([const Offset(0, 150), const Offset(80, 0), const Offset(160, 150), const Offset(2, 148)])))!.figura,
      'triangulo',
    );
    final circulo = [for (var i = 0; i <= 60; i++) Offset(100 + cos(i * pi / 30) * 80, 100 + sin(i * pi / 30) * 78)];
    expect(reconhecer(_traco(circulo))!.figura, 'circulo');
  });

  test('escrita não muda: letra pequena e palavra cursiva ficam como estão', () {
    final o = [for (var i = 0; i <= 30; i++) Offset(10 + cos(i * pi / 15) * 8, 10 + sin(i * pi / 15) * 10)];
    expect(reconhecer(_traco(o)), isNull);
    final palavra = [for (var x = 0.0; x < 160; x += 2) Offset(x, 20 + sin(x / 6) * 9)];
    expect(reconhecer(_traco(palavra)), isNull);
  });

  test('desligada não mexe em nada', () {
    final caneta = CanetaInteligente(ligada: false);
    expect(caneta.ajustar(_traco([const Offset(0, 0), const Offset(150, 1), const Offset(300, 2)])), isNull);
  });
}
