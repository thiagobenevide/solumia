import 'dart:ui';

import 'package:agent_design/src/modelos.dart';
import 'package:agent_design/src/rotas.dart';
import 'package:flutter_test/flutter_test.dart';

const _cor = Color(0xFF1565C0);
NoFluxo _no(String id, Rect r, {TipoNo tipo = TipoNo.processo}) =>
    NoFluxo(id, tipo: tipo, texto: id, a: r.topLeft, b: r.bottomRight, cor: _cor);

/// Algum trecho do caminho passa por dentro de [r]?
bool _atravessa(List<Offset> c, Rect r) {
  final dentro = r.deflate(1);
  for (var i = 0; i < c.length - 1; i++) {
    for (var t = 0.0; t <= 1; t += 0.02) {
      if (dentro.contains(Offset.lerp(c[i], c[i + 1], t)!)) return true;
    }
  }
  return false;
}

void main() {
  test('a seta desvia do bloco que está no caminho e só faz curvas em ângulo reto', () {
    const a = Rect.fromLTWH(0, 0, 160, 60), b = Rect.fromLTWH(0, 400, 160, 60);
    const meio = Rect.fromLTWH(-20, 180, 200, 80);
    final rota = rotaOrtogonal(a, b, [meio])!;
    expect(_atravessa(rota, meio), isFalse);
    // começa na borda de A e termina na de B (o bloco do meio é mais largo: contorna pelo lado)
    bool naBorda(Offset p, Rect r) =>
        r.inflate(0.5).contains(p) && !r.deflate(0.5).contains(p);
    expect(naBorda(rota.first, a), isTrue);
    expect(naBorda(rota.last, b), isTrue);
    for (var i = 0; i < rota.length - 1; i++) {
      expect(rota[i].dx == rota[i + 1].dx || rota[i].dy == rota[i + 1].dy, isTrue);
    }
  });

  test('blocos de frente ligam reto, sem degrau, mesmo com centros desalinhados', () {
    const a = Rect.fromLTWH(0, 0, 160, 60), b = Rect.fromLTWH(300, 10, 160, 60);
    expect(rotaOrtogonal(a, b, const []), hasLength(2)); // uma linha só
    // losango → retângulo: o retângulo se alinha à ponta do losango
    final els = religar([
      _no('d', const Rect.fromLTWH(0, 0, 180, 90), tipo: TipoNo.decisao),
      _no('r', const Rect.fromLTWH(300, 30, 160, 48)),
      const Ligacao('l', de: 'd', para: 'r', a: Offset.zero, b: Offset.zero, cor: _cor, ortogonal: true),
    ]);
    final l = els.whereType<Ligacao>().single;
    expect(l.caminho, hasLength(2));
    expect(l.a, const Offset(180, 45)); // ponta direita do losango
  });

  test('em volta de uma fileira de blocos, nenhuma seta atravessa', () {
    final nos = [for (var i = 0; i < 6; i++) _no('n$i', Rect.fromLTWH(i * 220.0, (i % 2) * 160.0, 160, 70))];
    final setas = [
      for (var i = 0; i < 5; i++)
        Ligacao('l$i', de: 'n$i', para: 'n${5 - i}', a: Offset.zero, b: Offset.zero, cor: _cor, ortogonal: true),
    ];
    final t = Stopwatch()..start();
    final els = religar([...nos, ...setas]);
    expect(t.elapsedMilliseconds, lessThan(500));
    for (final l in els.whereType<Ligacao>()) {
      for (final n in nos) {
        if (n.id != l.de && n.id != l.para) expect(_atravessa(l.caminho, n.retangulo), isFalse, reason: '${l.id} × ${n.id}');
      }
    }
  });
}
