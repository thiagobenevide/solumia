import 'dart:math';

/// Contas das calculadoras de bancada (Dart puro, unidades do SI: V, A, Ω, W, F, H, Hz, °C).

// ---------- Números ----------

const _prefixos = {'p': 1e-12, 'n': 1e-9, 'u': 1e-6, 'µ': 1e-6, 'm': 1e-3, 'k': 1e3, 'K': 1e3, 'M': 1e6, 'G': 1e9};

/// Lê "4k7", "4,7k", "100n", "10 mH", "1.5", "2e-3"; null se não for número.
double? lerValor(String texto) {
  final s = texto.trim().replaceAll(',', '.');
  if (s.isEmpty) return null;
  final direto = double.tryParse(s);
  if (direto != null) return direto;
  final m = RegExp(r'^(-?\d*\.?\d+)\s*([pnuµmkKMG]?)(\d*)\s*[A-Za-zΩ°]*$').firstMatch(s);
  if (m == null) return null;
  var numero = m[1]!;
  if (m[3]!.isNotEmpty) {
    if (numero.contains('.') || m[2]!.isEmpty) return null;
    numero = '$numero.${m[3]}'; // 4k7 → 4,7 k
  }
  final v = double.tryParse(numero);
  if (v == null) return null;
  return v * (_prefixos[m[2]] ?? 1);
}

/// "4,7 kΩ", "100 nF", "1,25 V": 3 algarismos significativos com prefixo de engenharia.
String formatar(double v, String unidade) {
  if (!v.isFinite) return '—';
  if (v == 0) return '0 $unidade'.trim();
  const passos = [(1e9, 'G'), (1e6, 'M'), (1e3, 'k'), (1.0, ''), (1e-3, 'm'), (1e-6, 'µ'), (1e-9, 'n'), (1e-12, 'p')];
  var (fator, prefixo) = passos.last;
  for (final (f, p) in passos) {
    if (v.abs() >= f * 0.9995) {
      (fator, prefixo) = (f, p);
      break;
    }
  }
  final n = v / fator;
  final casas = n.abs() >= 100 ? 0 : (n.abs() >= 10 ? 1 : 2);
  var t = n.toStringAsFixed(casas);
  if (t.contains('.')) t = t.replaceFirst(RegExp(r'\.?0+$'), '');
  return '${t.replaceAll('.', ',')} $prefixo$unidade'.trim();
}

double _finito(double v) => v.isFinite ? v : double.nan;

// ---------- Lei de Ohm ----------

typedef Ohm = ({double v, double i, double r, double p});

/// Completa V, I, R e P a partir de dois deles (usa os dois primeiros informados, nessa ordem).
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

// ---------- Divisor de tensão ----------

double divisorVout(double vin, double r1, double r2) => _finito(vin * r2 / (r1 + r2));

/// R2 que dá [vout] com [r1] em cima; NaN se [vout] não fica entre 0 e [vin].
double divisorR2(double vin, double vout, double r1) =>
    vout <= 0 || vout >= vin ? double.nan : _finito(r1 * vout / (vin - vout));

// ---------- Série E24 ----------

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

/// Menor valor comercial E24 maior ou igual a [r].
double e24Acima(double r) {
  if (!(r > 0) || !r.isFinite) return double.nan;
  final decada = pow(10, (log(r) / ln10 + 1e-9).floor()).toDouble();
  for (final m in e24) {
    final v = m * decada;
    if (v >= r * (1 - 1e-9)) return double.parse(v.toStringAsPrecision(3));
  }
  return 10 * decada;
}

// ---------- Resistor de LED ----------

typedef Led = ({double r, double p, double rComercial, double pComercial});

/// Resistor em série com o LED: R = (Vfonte − Vf) / If; o comercial é o E24 acima (corrente um pouco menor).
Led? resistorLed(double vFonte, double vf, double iF) {
  final queda = vFonte - vf;
  if (queda <= 0 || iF <= 0) return null;
  final r = queda / iF;
  final rc = e24Acima(r);
  return (r: r, p: queda * iF, rComercial: rc, pComercial: queda * queda / rc);
}

// ---------- Filtro RC ----------

double rcFrequencia(double r, double c) => _finito(1 / (2 * pi * r * c));
double rcResistor(double fc, double c) => _finito(1 / (2 * pi * fc * c));
double rcCapacitor(double fc, double r) => _finito(1 / (2 * pi * fc * r));

// ---------- Código de cores ----------

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

/// Cor da faixa multiplicadora para o expoente (−2 prata, −1 ouro, 0..9 como os algarismos).
String corMultiplicador(int expoente) => switch (expoente) {
  -2 => 'prata',
  -1 => 'ouro',
  _ => coresResistor[expoente],
};

/// Tolerância (%) por cor da última faixa.
const toleranciasResistor = {
  'marrom': 1.0,
  'vermelho': 2.0,
  'verde': 0.5,
  'azul': 0.25,
  'violeta': 0.1,
  'cinza': 0.05,
  'ouro': 5.0,
  'prata': 10.0,
};

/// Valor em Ω dos [digitos] (2 para 4 faixas, 3 para 5) vezes 10^[expoente].
double valorDasCores(List<int> digitos, int expoente) {
  final n = digitos.fold(0, (a, d) => a * 10 + d);
  return double.parse((n * pow(10, expoente)).toStringAsPrecision(digitos.length));
}

/// Faixas de valor para [ohms] com [faixas] 4 ou 5 (arredonda aos algarismos da faixa); null fora da faixa.
({List<int> digitos, int expoente})? coresDoValor(double ohms, int faixas) {
  final n = faixas == 5 ? 3 : 2;
  if (!(ohms > 0) || !ohms.isFinite) return null;
  var expoente = (log(ohms) / ln10 + 1e-9).floor() - (n - 1);
  var mantissa = (ohms / pow(10, expoente)).round();
  if (mantissa >= pow(10, n)) {
    mantissa ~/= 10;
    expoente++;
  }
  if (expoente < -2 || expoente > 9) return null;
  final digitos = mantissa.toString().padLeft(n, '0').split('').map(int.parse).toList();
  return (digitos: digitos, expoente: expoente);
}

// ---------- Crossover passivo ----------

enum TipoCrossover {
  primeiraOrdem('1ª ordem (6 dB/oit)', 1),
  butterworth('2ª ordem Butterworth (12 dB/oit)', 1 / sqrt2),
  linkwitzRiley('2ª ordem Linkwitz-Riley (12 dB/oit)', 0.5);

  const TipoCrossover(this.nome, this.q);
  final String nome;
  final double q;
}

/// Indutor e capacitor do crossover para um alto-falante de [impedancia] Ω em [frequencia] Hz. Na 1ª
/// ordem cada via usa um só (L em série no grave, C em série no agudo); na 2ª, L e C nas duas vias
/// (L = R / (Q·ω), C = Q / (R·ω)).
({double l, double c}) crossover(double impedancia, double frequencia, TipoCrossover tipo) {
  final w = 2 * pi * frequencia;
  return (l: _finito(impedancia / (tipo.q * w)), c: _finito(tipo.q / (impedancia * w)));
}

// ---------- Dissipação térmica ----------

/// Rθsa máxima do dissipador (°C/W): (Tj máx − Tamb) / P − Rθjc − Rθcs. ≤ 0 quer dizer que não dá:
/// nem um dissipador perfeito segura a junção.
double rthDissipador({
  required double potencia,
  required double tjMax,
  required double tAmb,
  required double rthJc,
  required double rthCs,
}) => _finito((tjMax - tAmb) / potencia - rthJc - rthCs);

// ---------- LM317 ----------

const vrefLm317 = 1.25;
const iAdjLm317 = 50e-6;

/// Vout = 1,25 · (1 + R2/R1) + Iadj · R2.
double lm317Vout(double r1, double r2, {double iAdj = iAdjLm317}) => _finito(vrefLm317 * (1 + r2 / r1) + iAdj * r2);

/// R2 para [vout] com [r1] (normalmente 240 Ω); NaN abaixo de 1,25 V.
double lm317R2(double vout, double r1, {double iAdj = iAdjLm317}) =>
    vout < vrefLm317 ? double.nan : _finito((vout - vrefLm317) / (vrefLm317 / r1 + iAdj));
