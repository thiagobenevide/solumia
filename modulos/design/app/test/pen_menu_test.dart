import 'package:agent_design/src/board/pen_menu.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

PointerHoverEvent _hover(int buttons, {PointerDeviceKind type = PointerDeviceKind.stylus}) =>
    PointerHoverEvent(kind: type, buttons: buttons, position: const Offset(40, 60));

void main() {
  var now = DateTime(2026);
  final clique = ButtonClick(clock: () => now);

  test('clique rápido no botão pairando abre o menu onde a caneta está', () {
    expect(clique.hover(_hover(kPrimaryStylusButton)), isNull);
    now = now.add(const Duration(milliseconds: 150));
    expect(clique.hover(_hover(0)), const Offset(40, 60));
    expect(clique.hover(_hover(0)), isNull); // only once per click
  });

  test('segurar o botão não abre (é a borracha)', () {
    clique.hover(_hover(kPrimaryStylusButton));
    now = now.add(const Duration(milliseconds: 900));
    expect(clique.hover(_hover(0)), isNull);
  });

  test('encostar com o botão apertado cancela o clique', () {
    clique.hover(_hover(kPrimaryStylusButton));
    clique.cancel();
    now = now.add(const Duration(milliseconds: 100));
    expect(clique.hover(_hover(0)), isNull);
  });

  test('levantar da borracha ainda segurando e soltar logo não abre o menu', () {
    clique.hover(_hover(0));
    clique.hover(_hover(kPrimaryStylusButton));
    clique.cancel(); // encostou: apagando
    clique.hover(_hover(kPrimaryStylusButton)); // levantou ainda segurando
    now = now.add(const Duration(milliseconds: 100));
    expect(clique.hover(_hover(0)), isNull);
    // after releasing, a new click opens it again
    clique.hover(_hover(kPrimaryStylusButton));
    now = now.add(const Duration(milliseconds: 100));
    expect(clique.hover(_hover(0)), const Offset(40, 60));
  });

  test('mouse não abre o menu', () {
    clique.hover(_hover(kPrimaryStylusButton, type: PointerDeviceKind.mouse));
    expect(clique.hover(_hover(0, type: PointerDeviceKind.mouse)), isNull);
  });
}
