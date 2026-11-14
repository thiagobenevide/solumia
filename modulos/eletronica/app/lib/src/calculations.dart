import 'dart:math';

/// Bench calculator math (pure Dart, SI units: V, A, Ω, W, F, H, Hz, °C).

// ---------- Numbers ----------

const _prefixes = {'p': 1e-12, 'n': 1e-9, 'u': 1e-6, 'µ': 1e-6, 'm': 1e-3, 'k': 1e3, 'K': 1e3, 'M': 1e6, 'G': 1e9};

/// Reads "4k7", "4,7k", "100n", "10 mH", "1.5", "2e-3"; null if it is not a number.
double? readValue(String text) {
  final s = text.trim().replaceAll(',', '.');
  if (s.isEmpty) return null;
  final direct = double.tryParse(s);
  if (direct != null) return direct;
  final m = RegExp(r'^(-?\d*\.?\d+)\s*([pnuµmkKMG]?)(\d*)\s*[A-Za-zΩ°]*$').firstMatch(s);
  if (m == null) return null;
  var number = m[1]!;
  if (m[3]!.isNotEmpty) {
    if (number.contains('.') || m[2]!.isEmpty) return null;
    number = '$number.${m[3]}'; // 4k7 → 4,7 k
  }
  final v = double.tryParse(number);
  if (v == null) return null;
  return v * (_prefixes[m[2]] ?? 1);
}

/// "4,7 kΩ", "100 nF", "1,25 V": 3 significant digits with an engineering prefix.
String format(double v, String unit) {
  if (!v.isFinite) return '—';
  if (v == 0) return '0 $unit'.trim();
  const steps = [(1e9, 'G'), (1e6, 'M'), (1e3, 'k'), (1.0, ''), (1e-3, 'm'), (1e-6, 'µ'), (1e-9, 'n'), (1e-12, 'p')];
  var (factor, prefix) = steps.last;
  for (final (f, p) in steps) {
    if (v.abs() >= f * 0.9995) {
      (factor, prefix) = (f, p);
      break;
    }
  }
  final n = v / factor;
  final decimals = n.abs() >= 100 ? 0 : (n.abs() >= 10 ? 1 : 2);
  var t = n.toStringAsFixed(decimals);
  if (t.contains('.')) t = t.replaceFirst(RegExp(r'\.?0+$'), '');
  return '${t.replaceAll('.', ',')} $prefix$unit'.trim();
}

double _finite(double v) => v.isFinite ? v : double.nan;

// ---------- Ohm's law ----------

typedef Ohm = ({double v, double i, double r, double p});

/// Completes V, I, R and P from two of them (uses the first two given, in that order).
Ohm? leiDeOhm({double? v, double? i, double? r, double? p}) {
  Ohm? res;
  if (v != null && i != null) {
    res = (v: v, i: i, r: v / i, p: v * i);
  } else if (v != null && r != null) {
    res = (v: v, i: v / r, r: r, p: v * v / r);
  } else if (v != null && p != null) {
    res = (v: v, i: p / v, r: v * v / p, p: p);
  } else if (i != null && r != null) {
    res = (v: i * r, i: i, r: r, p: i * i * r);
  } else if (i != null && p != null) {
    res = (v: p / i, i: i, r: p / (i * i), p: p);
  } else if (r != null && p != null) {
    res = (v: sqrt(p * r), i: sqrt(p / r), r: r, p: p);
  }
  if (res == null || ![res.v, res.i, res.r, res.p].every((x) => x.isFinite)) return null;
  return res;
}

// ---------- Voltage divider ----------

double dividerVout(double vin, double r1, double r2) => _finite(vin * r2 / (r1 + r2));

/// R2 that gives [vout] with [r1] on top; NaN if [vout] is not between 0 and [vin].
double divisorR2(double vin, double vout, double r1) =>
    vout <= 0 || vout >= vin ? double.nan : _finite(r1 * vout / (vin - vout));

// ---------- E24 series ----------

const e24 = [
  1.0,
  1.1,
  1.2,
  1.3,
  1.5,
  1.6,
  1.8,
  2.0,
  2.2,
  2.4,
  2.7,
  3.0,
  3.3,
  3.6,
  3.9,
  4.3,
  4.7,
  5.1,
  5.6,
  6.2,
  6.8,
  7.5,
  8.2,
  9.1,
];

/// Smallest E24 commercial value greater than or equal to [r].
double e24Above(double r) {
  if (!(r > 0) || !r.isFinite) return double.nan;
  final decade = pow(10, (log(r) / ln10 + 1e-9).floor()).toDouble();
  for (final m in e24) {
    final v = m * decade;
    if (v >= r * (1 - 1e-9)) return double.parse(v.toStringAsPrecision(3));
  }
  return 10 * decade;
}

// ---------- LED resistor ----------

typedef Led = ({double r, double p, double rCommercial, double pCommercial});

/// Resistor in series with the LED: R = (Vsource − Vf) / If; the commercial one is the E24 above (slightly lower current).
Led? resistorLed(double vSource, double vf, double iF) {
  final drop = vSource - vf;
  if (drop <= 0 || iF <= 0) return null;
  final r = drop / iF;
  final rc = e24Above(r);
  return (r: r, p: drop * iF, rCommercial: rc, pCommercial: drop * drop / rc);
}

// ---------- Filtro RC ----------

double rcFrequency(double r, double c) => _finite(1 / (2 * pi * r * c));
double rcResistor(double fc, double c) => _finite(1 / (2 * pi * fc * c));
double rcCapacitor(double fc, double r) => _finite(1 / (2 * pi * fc * r));

// ---------- Color code ----------

const coresResistor = [
  'preto',
  'marrom',
  'vermelho',
  'laranja',
  'amarelo',
  'verde',
  'azul',
  'violeta',
  'cinza',
  'branco',
];

/// Color of the multiplier band for the exponent (−2 silver, −1 gold, 0..9 like the digits).
String multiplierColor(int exponent) => switch (exponent) {
  -2 => 'prata',
  -1 => 'ouro',
  _ => coresResistor[exponent],
};

/// Tolerance (%) by color of the last band.
const resistorTolerances = {
  'marrom': 1.0,
  'vermelho': 2.0,
  'verde': 0.5,
  'azul': 0.25,
  'violeta': 0.1,
  'cinza': 0.05,
  'ouro': 5.0,
  'prata': 10.0,
};

/// Value in Ω of the [digits] (2 for 4 bands, 3 for 5) times 10^[exponent].
double colorValue(List<int> digits, int exponent) {
  final n = digits.fold(0, (a, d) => a * 10 + d);
  return double.parse((n * pow(10, exponent)).toStringAsPrecision(digits.length));
}

/// Value bands for [ohms] with 4 or 5 [bands] (rounds to the band digits); null out of range.
({List<int> digits, int exponent})? coresDoValor(double ohms, int bands) {
  final n = bands == 5 ? 3 : 2;
  if (!(ohms > 0) || !ohms.isFinite) return null;
  var exponent = (log(ohms) / ln10 + 1e-9).floor() - (n - 1);
  var mantissa = (ohms / pow(10, exponent)).round();
  if (mantissa >= pow(10, n)) {
    mantissa ~/= 10;
    exponent++;
  }
  if (exponent < -2 || exponent > 9) return null;
  final digits = mantissa.toString().padLeft(n, '0').split('').map(int.parse).toList();
  return (digits: digits, exponent: exponent);
}

// ---------- Crossover passivo ----------

enum CrossoverType {
  firstOrder('1ª ordem (6 dB/oit)', 1),
  butterworth('2ª ordem Butterworth (12 dB/oit)', 1 / sqrt2),
  linkwitzRiley('2ª ordem Linkwitz-Riley (12 dB/oit)', 0.5);

  const CrossoverType(this.name, this.q);
  final String name;
  final double q;
}

/// Crossover inductor and capacitor for a speaker of [impedance] Ω at [frequency] Hz. In 1st
/// order each way uses only one (L in series on the woofer, C in series on the tweeter); in 2nd, L and C on both ways
/// (L = R / (Q·ω), C = Q / (R·ω)).
({double l, double c}) crossover(double impedance, double frequency, CrossoverType type) {
  final w = 2 * pi * frequency;
  return (l: _finite(impedance / (type.q * w)), c: _finite(type.q / (impedance * w)));
}

// ---------- Heat dissipation ----------

/// Maximum heatsink Rθsa (°C/W): (Tj max − Tamb) / P − Rθjc − Rθcs. ≤ 0 means it is not possible:
/// not even a perfect heatsink holds the junction.
double rthHeatsink({
  required double power,
  required double tjMax,
  required double tAmb,
  required double rthJc,
  required double rthCs,
}) => _finite((tjMax - tAmb) / power - rthJc - rthCs);

// ---------- LM317 ----------

const vrefLm317 = 1.25;
const iAdjLm317 = 50e-6;

/// Vout = 1,25 · (1 + R2/R1) + Iadj · R2.
double lm317Vout(double r1, double r2, {double iAdj = iAdjLm317}) => _finite(vrefLm317 * (1 + r2 / r1) + iAdj * r2);

/// R2 for [vout] with [r1] (usually 240 Ω); NaN below 1.25 V.
double lm317R2(double vout, double r1, {double iAdj = iAdjLm317}) =>
    vout < vrefLm317 ? double.nan : _finite((vout - vrefLm317) / (vrefLm317 / r1 + iAdj));
