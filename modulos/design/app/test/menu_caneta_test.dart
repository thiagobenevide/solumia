import 'package:agent_design/src/quadro/menu_caneta.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

PointerHoverEvent _pairar(int botoes, {PointerDeviceKind tipo = PointerDeviceKind.stylus}) =>
    PointerHoverEvent(kind: tipo, buttons: botoes, position: const Offset(40, 60));

void main() {
  var agora = DateTime(2026);
  final clique = CliqueDoBotao(relogio: () => agora);

  test('clique rápido no botão pairando abre o menu onde a caneta está', () {
    expect(clique.pairar(_pairar(kPrimaryStylusButton)), isNull);
    agora = agora.add(const Duration(milliseconds: 150));
    expect(clique.pairar(_pairar(0)), const Offset(40, 60));
    expect(clique.pairar(_pairar(0)), isNull); // só uma vez por clique
  });

  test('segurar o botão não abre (é a borracha)', () {
    clique.pairar(_pairar(kPrimaryStylusButton));
    agora = agora.add(const Duration(milliseconds: 900));
    expect(clique.pairar(_pairar(0)), isNull);
  });

  test('encostar com o botão apertado cancela o clique', () {
    clique.pairar(_pairar(kPrimaryStylusButton));
    clique.cancelar();
    agora = agora.add(const Duration(milliseconds: 100));
    expect(clique.pairar(_pairar(0)), isNull);
  });

  test('levantar da borracha ainda segurando e soltar logo não abre o menu', () {
    clique.pairar(_pairar(0));
    clique.pairar(_pairar(kPrimaryStylusButton));
    clique.cancelar(); // encostou: apagando
    clique.pairar(_pairar(kPrimaryStylusButton)); // levantou ainda segurando
    agora = agora.add(const Duration(milliseconds: 100));
    expect(clique.pairar(_pairar(0)), isNull);
    // depois de soltar, um clique novo volta a abrir
    clique.pairar(_pairar(kPrimaryStylusButton));
    agora = agora.add(const Duration(milliseconds: 100));
    expect(clique.pairar(_pairar(0)), const Offset(40, 60));
  });

  test('mouse não abre o menu', () {
    clique.pairar(_pairar(kPrimaryStylusButton, tipo: PointerDeviceKind.mouse));
    expect(clique.pairar(_pairar(0, tipo: PointerDeviceKind.mouse)), isNull);
  });
}
