import 'package:flutter/material.dart';

import '../calculations.dart';

/// Bench calculators in tabs (math in `calculations.dart`). Fields accept "4k7", "100n", "1,5".
Future<void> showCalculators(BuildContext context) => showDialog<void>(
  context: context,
  builder: (c) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
      child: const CalculatorsScreen(),
    ),
  ),
);

class CalculatorsScreen extends StatelessWidget {
  const CalculatorsScreen({super.key});

  static final _tabs = <(String, Widget)>[
    ('Lei de Ohm', _ItemList([_ohm])),
    ('Divisor', _ItemList([_divisor, _inverseDivider])),
    ('LED', _ItemList([_led])),
    ('Filtro RC', _ItemList([_rcFc, _rcR, _rcC])),
    ('Código de cores', const _Cores()),
    ('Crossover', _ItemList([_crossover])),
    ('Dissipador', _ItemList([_heatsink])),
    ('LM317', _ItemList([_lm317, _lm317Inverse])),
  ];

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: _tabs.length,
    child: Column(
      children: [
        Row(
          children: [
            Expanded(
              child: TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [for (final (t, _) in _tabs) Tab(text: t)],
              ),
            ),
            IconButton(
              tooltip: 'Fechar',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        Expanded(child: TabBarView(children: [for (final (_, w) in _tabs) w])),
      ],
    ),
  );
}

// ---------- Generic calculator: fields → result lines ----------

typedef _Def = ({
  String title,
  List<(String, String, String)> fields, // label, unit, initial value
  List<String> options,
  List<String> Function(List<double?> v, int option) calculate,
});

_Def _def(
  String title,
  List<(String, String, String)> fields,
  List<String> Function(List<double?> v, int option) calculate, {
  List<String> options = const [],
}) => (title: title, fields: fields, options: options, calculate: calculate);

/// Lines only when every field has a number.
List<String> Function(List<double?>, int) _all(List<String> Function(List<double> v, int option) f) =>
    (v, o) => v.contains(null) ? const [] : f(v.cast<double>(), o);

class _ItemList extends StatelessWidget {
  const _ItemList(this.defs);

  final List<_Def> defs;

  @override
  Widget build(BuildContext context) =>
      ListView(padding: const EdgeInsets.all(16), children: [for (final d in defs) _Calculator(d)]);
}

class _Calculator extends StatefulWidget {
  const _Calculator(this.d);

  final _Def d;

  @override
  State<_Calculator> createState() => _CalculatorState();
}

class _CalculatorState extends State<_Calculator> {
  late final _campos = [for (final (_, _, start) in widget.d.fields) TextEditingController(text: start)];
  var _option = 0;

  @override
  void dispose() {
    for (final c in _campos) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.d;
    final lines = d.calculate([for (final c in _campos) readValue(c.text)], _option);
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(d.title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            if (d.options.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: DropdownButton<int>(
                  value: _option,
                  items: [
                    for (var i = 0; i < d.options.length; i++) DropdownMenuItem(value: i, child: Text(d.options[i])),
                  ],
                  onChanged: (v) => setState(() => _option = v ?? 0),
                ),
              ),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (var i = 0; i < _campos.length; i++)
                  SizedBox(
                    width: 150,
                    child: TextField(
                      controller: _campos[i],
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: d.fields[i].$1,
                        suffixText: d.fields[i].$2,
                        isDense: true,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            for (final l in lines)
              SelectableText(l, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

String _ou(double v, String unit, String otherwise) => v.isFinite && v > 0 ? format(v, unit) : otherwise;

// ---------- Ohm's law ----------

final _ohm = _def(
  'Informe dois valores (deixe os outros vazios)',
  [('Tensão', 'V', ''), ('Corrente', 'A', ''), ('Resistência', 'Ω', ''), ('Potência', 'W', '')],
  (v, _) {
    final n = v.where((x) => x != null).length;
    if (n < 2) return const [];
    if (n > 2) return const ['Informe só dois valores.'];
    final r = leiDeOhm(v: v[0], i: v[1], r: v[2], p: v[3]);
    if (r == null) return const ['Não dá para calcular com esses valores.'];
    return [
      'V = ${format(r.v, 'V')}',
      'I = ${format(r.i, 'A')}',
      'R = ${format(r.r, 'Ω')}',
      'P = ${format(r.p, 'W')}',
    ];
  },
);

// ---------- Divisor, LED, RC ----------

final _divisor = _def(
  'Vout = Vin · R2 / (R1 + R2)',
  [('Vin', 'V', '12'), ('R1', 'Ω', '10k'), ('R2', 'Ω', '4k7')],
  _all((v, _) {
    final vout = dividerVout(v[0], v[1], v[2]);
    return ['Vout = ${format(vout, 'V')}', 'Corrente no divisor = ${format(v[0] / (v[1] + v[2]), 'A')}'];
  }),
);

final _inverseDivider = _def(
  'R2 para um Vout',
  [('Vin', 'V', '12'), ('Vout', 'V', '3,3'), ('R1', 'Ω', '10k')],
  _all((v, _) {
    final r2 = divisorR2(v[0], v[1], v[2]);
    if (!r2.isFinite) return const ['Vout precisa ficar entre 0 e Vin.'];
    final rc = e24Above(r2);
    return [
      'R2 = ${format(r2, 'Ω')}',
      'E24 acima: ${format(rc, 'Ω')} → Vout = ${format(dividerVout(v[0], v[2], rc), 'V')}',
    ];
  }),
);

final _led = _def(
  'R = (Vfonte − Vf) / If',
  [('Vfonte', 'V', '5'), ('Vf do LED', 'V', '2'), ('If', 'A', '20m')],
  _all((v, _) {
    final r = resistorLed(v[0], v[1], v[2]);
    if (r == null) return const ['A fonte precisa ser maior que Vf e a corrente maior que zero.'];
    return [
      'R = ${format(r.r, 'Ω')} (dissipa ${format(r.p, 'W')})',
      'Comercial E24: ${format(r.rCommercial, 'Ω')} → ${format((v[0] - v[1]) / r.rCommercial, 'A')}, '
          '${format(r.pCommercial, 'W')} (use resistor de ${format(r.pCommercial * 2, 'W')} ou mais)',
    ];
  }),
);

final _rcFc = _def(
  'Frequência de corte fc = 1 / (2π·R·C)',
  [('R', 'Ω', '10k'), ('C', 'F', '100n')],
  _all((v, _) {
    return ['fc = ${_ou(rcFrequency(v[0], v[1]), 'Hz', '—')}', 'τ = R·C = ${format(v[0] * v[1], 's')}'];
  }),
);

final _rcR = _def(
  'R para fc e C',
  [('fc', 'Hz', '1k'), ('C', 'F', '100n')],
  _all((v, _) {
    return ['R = ${_ou(rcResistor(v[0], v[1]), 'Ω', '—')}'];
  }),
);

final _rcC = _def(
  'C para fc e R',
  [('fc', 'Hz', '1k'), ('R', 'Ω', '10k')],
  _all((v, _) {
    return ['C = ${_ou(rcCapacitor(v[0], v[1]), 'F', '—')}'];
  }),
);

// ---------- Crossover, dissipador, LM317 ----------

final _crossover = _def(
  'Crossover passivo (passa-baixa no grave, passa-alta no agudo)',
  [('Impedância', 'Ω', '8'), ('Frequência', 'Hz', '3k')],
  options: [for (final t in CrossoverType.values) t.name],
  _all((v, o) {
    final type = CrossoverType.values[o];
    final x = crossover(v[0], v[1], type);
    if (type == CrossoverType.firstOrder) {
      return ['Grave: L em série = ${format(x.l, 'H')}', 'Agudo: C em série = ${format(x.c, 'F')}'];
    }
    return [
      'Grave: L em série = ${format(x.l, 'H')}, C em paralelo = ${format(x.c, 'F')}',
      'Agudo: C em série = ${format(x.c, 'F')}, L em paralelo = ${format(x.l, 'H')}',
    ];
  }),
);

final _heatsink = _def(
  'Rθsa = (Tj máx − Tamb) / P − Rθjc − Rθcs',
  [
    ('Potência', 'W', '10'),
    ('Tj máx', '°C', '150'),
    ('Tamb', '°C', '40'),
    ('Rθjc', '°C/W', '1,5'),
    ('Rθcs', '°C/W', '0,5'),
  ],
  _all((v, _) {
    final r = rthHeatsink(power: v[0], tjMax: v[1], tAmb: v[2], rthJc: v[3], rthCs: v[4]);
    if (!r.isFinite) return const ['Valores inválidos.'];
    if (r <= 0) {
      return const ['Não dá: nem um dissipador perfeito segura a junção. Reduza a potência ou divida a carga.'];
    }
    return ['Dissipador com Rθsa ≤ ${r.toStringAsFixed(2).replaceAll('.', ',')} °C/W'];
  }),
);

final _lm317 = _def(
  'Vout = 1,25 · (1 + R2/R1) + 50 µA · R2',
  [('R1', 'Ω', '240'), ('R2', 'Ω', '720')],
  _all((v, _) {
    return ['Vout = ${format(lm317Vout(v[0], v[1]), 'V')}'];
  }),
);

final _lm317Inverse = _def(
  'R2 para um Vout',
  [('Vout', 'V', '5'), ('R1', 'Ω', '240')],
  _all((v, _) {
    final r2 = lm317R2(v[0], v[1]);
    if (!r2.isFinite) return const ['O LM317 não desce abaixo de 1,25 V.'];
    final rc = e24Above(r2);
    return [
      'R2 = ${format(r2, 'Ω')}',
      'E24 acima: ${format(rc, 'Ω')} → Vout = ${format(lm317Vout(v[1], rc), 'V')}',
    ];
  }),
);

// ---------- Color code ----------

const _colorOf = {
  'preto': Colors.black,
  'marrom': Color(0xFF795548),
  'vermelho': Colors.red,
  'laranja': Colors.orange,
  'amarelo': Colors.yellow,
  'verde': Colors.green,
  'azul': Colors.blue,
  'violeta': Colors.purple,
  'cinza': Colors.grey,
  'branco': Colors.white,
  'ouro': Color(0xFFD4AF37),
  'prata': Color(0xFFC0C0C0),
};

class _Cores extends StatefulWidget {
  const _Cores();

  @override
  State<_Cores> createState() => _CoresState();
}

class _CoresState extends State<_Cores> {
  var _bands = 4;
  final _digits = [4, 7, 0];
  var _exponent = 2;
  var _tolerance = 'ouro';
  final _valor = TextEditingController(text: '4k7');

  @override
  void dispose() {
    _valor.dispose();
    super.dispose();
  }

  List<int> get _used => _digits.sublist(0, _bands == 5 ? 3 : 2);

  Widget _band(String color) => Container(
    width: 18,
    height: 48,
    margin: const EdgeInsets.symmetric(horizontal: 3),
    decoration: BoxDecoration(
      color: _colorOf[color],
      border: Border.all(color: Colors.black26),
    ),
  );

  Widget _choice(String label, String value, List<String> options, ValueChanged<String> edit) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelSmall),
      DropdownButton<String>(
        value: value,
        items: [
          for (final o in options)
            DropdownMenuItem(
              value: o,
              child: Row(
                children: [
                  Container(width: 14, height: 14, color: _colorOf[o]),
                  const SizedBox(width: 6),
                  Text(o),
                ],
              ),
            ),
        ],
        onChanged: (v) {
          if (v != null) setState(() => edit(v));
        },
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = colorValue(_used, _exponent);
    final volta = readValue(_valor.text);
    final colors = volta == null ? null : coresDoValor(volta, _bands);
    final exponents = [for (var e = -2; e <= 9; e++) e];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 4, label: Text('4 faixas')),
            ButtonSegment(value: 5, label: Text('5 faixas')),
          ],
          selected: {_bands},
          onSelectionChanged: (s) => setState(() => _bands = s.first),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Cores → valor', style: theme.textTheme.titleMedium),
                Wrap(
                  spacing: 16,
                  children: [
                    for (var i = 0; i < _used.length; i++)
                      _choice(
                        '${i + 1}ª faixa',
                        coresResistor[_digits[i]],
                        coresResistor,
                        (v) => _digits[i] = coresResistor.indexOf(v),
                      ),
                    _choice('Multiplicador', multiplierColor(_exponent), [
                      for (final e in exponents) multiplierColor(e),
                    ], (v) => _exponent = exponents.firstWhere((e) => multiplierColor(e) == v)),
                    _choice('Tolerância', _tolerance, resistorTolerances.keys.toList(), (v) => _tolerance = v),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    for (final d in _used) _band(coresResistor[d]),
                    _band(multiplierColor(_exponent)),
                    const SizedBox(width: 12),
                    _band(_tolerance),
                    const SizedBox(width: 16),
                    SelectableText(
                      '${format(value, 'Ω')} ± ${resistorTolerances[_tolerance]!.toString().replaceAll('.', ',')} %',
                      style: theme.textTheme.titleLarge,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Valor → cores', style: theme.textTheme.titleMedium),
                const SizedBox(height: 12),
                SizedBox(
                  width: 180,
                  child: TextField(
                    controller: _valor,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Resistência',
                      suffixText: 'Ω',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                if (colors == null)
                  const Text('Valor fora da faixa (0,1 Ω a centenas de GΩ).')
                else
                  Row(
                    children: [
                      for (final d in colors.digits) _band(coresResistor[d]),
                      _band(multiplierColor(colors.exponent)),
                      const SizedBox(width: 16),
                      Expanded(
                        child: SelectableText(
                          '${[...colors.digits.map((d) => coresResistor[d]), multiplierColor(colors.exponent)].join(', ')}'
                          ' (${format(colorValue(colors.digits, colors.exponent), 'Ω')})',
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
