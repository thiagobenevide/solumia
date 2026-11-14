import 'package:agent_eletronica/src/calculos.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lerValor entende prefixos, vírgula e o estilo 4k7', () {
    expect(lerValor('4k7'), closeTo(4700, 1e-9));
    expect(lerValor('4,7k'), closeTo(4700, 1e-9));
    expect(lerValor('100n'), closeTo(100e-9, 1e-18));
    expect(lerValor('10 mH'), closeTo(0.01, 1e-12));
    expect(lerValor('1MHz'), 1e6);
    expect(lerValor('5V'), 5);
    expect(lerValor('2e-3'), 0.002);
    expect(lerValor(''), isNull);
    expect(lerValor('abc'), isNull);
  });

  test('formatar usa prefixo de engenharia e vírgula', () {
    expect(formatar(4700, 'Ω'), '4,7 kΩ');
    expect(formatar(100e-9, 'F'), '100 nF');
    expect(formatar(1.25, 'V'), '1,25 V');
    expect(formatar(0.02, 'A'), '20 mA');
  });

  test('lei de Ohm a partir de qualquer par', () {
    final a = leiDeOhm(v: 12, r: 4)!;
    expect((a.i, a.p), (3, 36));
    final b = leiDeOhm(r: 4, p: 36)!;
    expect(b.v, closeTo(12, 1e-9));
    expect(b.i, closeTo(3, 1e-9));
    final c = leiDeOhm(i: 2, p: 10)!;
    expect((c.v, c.r), (5, 2.5));
    expect(leiDeOhm(v: 5), isNull);
    expect(leiDeOhm(v: 5, i: 0), isNull);
  });

  test('divisor de tensão nos dois sentidos', () {
    expect(divisorVout(12, 10000, 10000), 6);
    expect(divisorR2(12, 3, 9000), closeTo(3000, 1e-9));
    expect(divisorR2(5, 6, 1000).isNaN, isTrue);
  });

  test('E24 acima e resistor de LED', () {
    expect(e24Acima(150), 150);
    expect(e24Acima(151), 160);
    expect(e24Acima(9500), 10000);
    expect(e24Acima(0.33), 0.33);
    final led = resistorLed(5, 2, 0.02)!;
    expect(led.r, closeTo(150, 1e-9));
    expect(led.p, closeTo(0.06, 1e-12));
    expect(led.rComercial, 150);
    final led2 = resistorLed(12, 3.2, 0.02)!; // 440 Ω → 470 Ω
    expect(led2.rComercial, 470);
    expect(led2.pComercial, closeTo(8.8 * 8.8 / 470, 1e-12));
    expect(resistorLed(2, 3, 0.02), isNull);
  });

  test('filtro RC: fc, R e C', () {
    final fc = rcFrequencia(10000, 100e-9);
    expect(fc, closeTo(159.15, 0.01));
    expect(rcResistor(fc, 100e-9), closeTo(10000, 1e-6));
    expect(rcCapacitor(fc, 10000), closeTo(100e-9, 1e-15));
  });

  test('código de cores de ida e volta', () {
    expect(valorDasCores([4, 7], 2), 4700);
    expect(valorDasCores([4, 7], -2), 0.47);
    expect(valorDasCores([1, 0, 0], 1), 1000);
    expect(corMultiplicador(-1), 'ouro');
    final quatro = coresDoValor(4700, 4)!;
    expect(quatro.digitos, [4, 7]);
    expect(quatro.expoente, 2);
    final cinco = coresDoValor(4700, 5)!;
    expect(cinco.digitos, [4, 7, 0]);
    expect(cinco.expoente, 1);
    final cem = coresDoValor(100, 4)!;
    expect(cem.digitos, [1, 0]);
    expect(cem.expoente, 1);
    final arredonda = coresDoValor(9990, 4)!; // 9,99k → 10k
    expect(arredonda.digitos, [1, 0]);
    expect(arredonda.expoente, 3);
    expect(coresDoValor(0.001, 4), isNull);
  });

  test('crossover de 1ª e 2ª ordem', () {
    final p1 = crossover(8, 3000, TipoCrossover.primeiraOrdem);
    expect(p1.l, closeTo(424.4e-6, 0.1e-6));
    expect(p1.c, closeTo(6.63e-6, 0.01e-6));
    final bw = crossover(8, 3000, TipoCrossover.butterworth);
    expect(bw.l, closeTo(0.2251 * 8 / 3000, 1e-7));
    expect(bw.c, closeTo(0.1125 / (8 * 3000), 1e-8));
    final lr = crossover(8, 3000, TipoCrossover.linkwitzRiley);
    expect(lr.l, closeTo(0.3183 * 8 / 3000, 1e-7));
    expect(lr.c, closeTo(0.0796 / (8 * 3000), 1e-8));
  });

  test('dissipador e LM317', () {
    expect(rthDissipador(potencia: 10, tjMax: 150, tAmb: 40, rthJc: 1.5, rthCs: 0.5), closeTo(9, 1e-9));
    expect(rthDissipador(potencia: 100, tjMax: 150, tAmb: 40, rthJc: 1.5, rthCs: 0.5), lessThan(0));
    expect(lm317Vout(240, 720, iAdj: 0), closeTo(5, 1e-9));
    expect(lm317Vout(240, 720), closeTo(5.036, 1e-9));
    expect(lm317Vout(240, lm317R2(5, 240)), closeTo(5, 1e-9));
    expect(lm317R2(1, 240).isNaN, isTrue);
  });
}
