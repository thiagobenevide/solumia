import 'dart:math';
import 'dart:ui';

import 'package:agent_design/src/notebook/pen.dart';
import 'package:agent_design/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

Traco _stroke(List<Offset> pts, {Pincel brush = Pincel.caneta}) => Traco(
  't',
  brush: brush,
  color: const Color(0xFF000000),
  thickness: 3,
  pontos: [for (final p in pts) StrokePoint(p.dx, p.dy, 0.5)],
);

/// Outline through the [corners] with a hand jitter (±[noise]).
List<Offset> _jitter(List<Offset> cantos, {double noise = 2}) {
  final r = Random(7), exit = <Offset>[];
  for (var i = 1; i < cantos.length; i++) {
    for (var k = 0; k < 25; k++) {
      final p = Offset.lerp(cantos[i - 1], cantos[i], k / 25)!;
      exit.add(p + Offset((r.nextDouble() - 0.5) * noise, (r.nextDouble() - 0.5) * noise));
    }
  }
  return exit..add(cantos.last);
}

void main() {
  test('reta quase horizontal fica horizontal, com o mesmo id e cor', () {
    final r = recognize(_stroke(_jitter([const Offset(10, 100), const Offset(300, 108)])))!;
    expect(r.figure, 'reta');
    final ys = r.stroke.pontos.map((p) => p.y.toStringAsFixed(1)).toSet();
    expect(ys.length, 1);
    expect(r.stroke.id, 't');
  });

  test('reta nova paralela a uma recente pega o mesmo ângulo', () {
    const recent = 0.5; // ~28,6°
    final fim = Offset(10 + cos(0.53) * 300, 10 + sin(0.53) * 300);
    final r = recognize(_stroke([const Offset(10, 10), (const Offset(10, 10) + fim) / 2, fim]), angles: [recent])!;
    expect(r.angle, closeTo(recent, 1e-9));
  });

  test('retângulo, quadrado, triângulo e círculo tortos ficam certinhos', () {
    expect(
      recognize(_stroke(_jitter([const Offset(0, 0), const Offset(200, 3), const Offset(198, 100), const Offset(2, 98), const Offset(1, 2)])))!
          .figure,
      'retangulo',
    );
    expect(
      recognize(_stroke(_jitter([const Offset(0, 0), const Offset(150, 2), const Offset(148, 147), const Offset(1, 150), const Offset(0, 3)])))!
          .figure,
      'quadrado',
    );
    expect(
      recognize(_stroke(_jitter([const Offset(0, 150), const Offset(80, 0), const Offset(160, 150), const Offset(2, 148)])))!.figure,
      'triangulo',
    );
    final circulo = [for (var i = 0; i <= 60; i++) Offset(100 + cos(i * pi / 30) * 80, 100 + sin(i * pi / 30) * 78)];
    expect(recognize(_stroke(circulo))!.figure, 'circulo');
  });

  test('escrita não muda: letra pequena e palavra cursiva ficam como estão', () {
    final o = [for (var i = 0; i <= 30; i++) Offset(10 + cos(i * pi / 15) * 8, 10 + sin(i * pi / 15) * 10)];
    expect(recognize(_stroke(o)), isNull);
    final word = [for (var x = 0.0; x < 160; x += 2) Offset(x, 20 + sin(x / 6) * 9)];
    expect(recognize(_stroke(word)), isNull);
  });

  test('desligada não mexe em nada', () {
    final caneta = SmartPen(connected: false);
    expect(caneta.fit(_stroke([const Offset(0, 0), const Offset(150, 1), const Offset(300, 2)])), isNull);
  });
}
