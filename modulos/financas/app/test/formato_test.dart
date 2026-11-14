import 'package:agent_financas/src/formato.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('número e moeda no formato brasileiro', () {
    expect(numero(1234567.891), '1.234.567,89');
    expect(numero(-0.5), '-0,50');
    expect(moeda(10), r'R$ 10,00');
    expect(pct(12.34), '12,3%');
    expect(numero(null), '—');
  });

  test('lê números digitados', () {
    expect(lerNumero('1.234,56'), 1234.56);
    expect(lerNumero(r'R$ 10'), 10);
    expect(lerNumero('-12.5'), -12.5);
    expect(lerNumero(''), isNull);
    expect(lerNumero('abc'), isNull);
  });

  test('datas e meses', () {
    expect(iso(DateTime(2026, 3, 5)), '2026-03-05');
    expect(dataBr('2026-03-05'), '05/03/2026');
    expect(mesBr('2026-10'), 'out/2026');
    expect(mesIso(somarMeses(DateTime(2026, 12), 1)), '2027-01');
  });
}
