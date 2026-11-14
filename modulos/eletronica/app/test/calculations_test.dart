import 'package:agent_eletronica/src/calculations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lerValor entende prefixos, vírgula e o estilo 4k7', () {
    expect(readValue('4k7'), closeTo(4700, 1e-9));
    expect(readValue('4,7k'), closeTo(4700, 1e-9));
    expect(readValue('100n'), closeTo(100e-9, 1e-18));
    expect(readValue('10 mH'), closeTo(0.01, 1e-12));
    expect(readValue('1MHz'), 1e6);
    expect(readValue('5V'), 5);
    expect(readValue('2e-3'), 0.002);
    expect(readValue(''), isNull);
    expect(readValue('abc'), isNull);
  });

  test('formatar usa prefixo de engenharia e vírgula', () {
    expect(format(4700, 'Ω'), '4,7 kΩ');
    expect(format(100e-9, 'F'), '100 nF');
    expect(format(1.25, 'V'), '1,25 V');
    expect(format(0.02, 'A'), '20 mA');
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
    expect(dividerVout(12, 10000, 10000), 6);
    expect(divisorR2(12, 3, 9000), closeTo(3000, 1e-9));
    expect(divisorR2(5, 6, 1000).isNaN, isTrue);
  });

  test('E24 acima e resistor de LED', () {
    expect(e24Above(150), 150);
    expect(e24Above(151), 160);
    expect(e24Above(9500), 10000);
    expect(e24Above(0.33), 0.33);
    final led = resistorLed(5, 2, 0.02)!;
    expect(led.r, closeTo(150, 1e-9));
    expect(led.p, closeTo(0.06, 1e-12));
    expect(led.rCommercial, 150);
    final led2 = resistorLed(12, 3.2, 0.02)!; // 440 Ω → 470 Ω
    expect(led2.rCommercial, 470);
    expect(led2.pCommercial, closeTo(8.8 * 8.8 / 470, 1e-12));
    expect(resistorLed(2, 3, 0.02), isNull);
  });

  test('filtro RC: fc, R e C', () {
    final fc = rcFrequency(10000, 100e-9);
    expect(fc, closeTo(159.15, 0.01));
    expect(rcResistor(fc, 100e-9), closeTo(10000, 1e-6));
    expect(rcCapacitor(fc, 10000), closeTo(100e-9, 1e-15));
  });

  test('código de cores de ida e volta', () {
    expect(colorValue([4, 7], 2), 4700);
    expect(colorValue([4, 7], -2), 0.47);
    expect(colorValue([1, 0, 0], 1), 1000);
    expect(multiplierColor(-1), 'ouro');
    final four = coresDoValor(4700, 4)!;
    expect(four.digits, [4, 7]);
    expect(four.exponent, 2);
    final five = coresDoValor(4700, 5)!;
    expect(five.digits, [4, 7, 0]);
    expect(five.exponent, 1);
    final hundred = coresDoValor(100, 4)!;
    expect(hundred.digits, [1, 0]);
    expect(hundred.exponent, 1);
    final rounds = coresDoValor(9990, 4)!; // 9,99k → 10k
    expect(rounds.digits, [1, 0]);
    expect(rounds.exponent, 3);
    expect(coresDoValor(0.001, 4), isNull);
  });

  test('crossover de 1ª e 2ª ordem', () {
    final p1 = crossover(8, 3000, CrossoverType.firstOrder);
    expect(p1.l, closeTo(424.4e-6, 0.1e-6));
    expect(p1.c, closeTo(6.63e-6, 0.01e-6));
    final bw = crossover(8, 3000, CrossoverType.butterworth);
    expect(bw.l, closeTo(0.2251 * 8 / 3000, 1e-7));
    expect(bw.c, closeTo(0.1125 / (8 * 3000), 1e-8));
    final lr = crossover(8, 3000, CrossoverType.linkwitzRiley);
    expect(lr.l, closeTo(0.3183 * 8 / 3000, 1e-7));
    expect(lr.c, closeTo(0.0796 / (8 * 3000), 1e-8));
  });

  test('dissipador e LM317', () {
    expect(rthHeatsink(power: 10, tjMax: 150, tAmb: 40, rthJc: 1.5, rthCs: 0.5), closeTo(9, 1e-9));
    expect(rthHeatsink(power: 100, tjMax: 150, tAmb: 40, rthJc: 1.5, rthCs: 0.5), lessThan(0));
    expect(lm317Vout(240, 720, iAdj: 0), closeTo(5, 1e-9));
    expect(lm317Vout(240, 720), closeTo(5.036, 1e-9));
    expect(lm317Vout(240, lm317R2(5, 240)), closeTo(5, 1e-9));
    expect(lm317R2(1, 240).isNaN, isTrue);
  });
}
