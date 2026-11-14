import 'package:flutter/material.dart';

import '../calculos.dart';

/// Calculadoras de bancada em abas (contas em `calculos.dart`). Campos aceitam "4k7", "100n", "1,5".
Future<void> mostrarCalculadoras(BuildContext context) => showDialog<void>(
  context: context,
  builder: (c) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
      child: const CalculadorasTela(),
    ),
  ),
);

class CalculadorasTela extends StatelessWidget {
  const CalculadorasTela({super.key});

  static final _abas = <(String, Widget)>[
    ('Lei de Ohm', _Lista([_ohm])),
    ('Divisor', _Lista([_divisor, _divisorInverso])),
    ('LED', _Lista([_led])),
    ('Filtro RC', _Lista([_rcFc, _rcR, _rcC])),
    ('Código de cores', const _Cores()),
    ('Crossover', _Lista([_crossover])),
    ('Dissipador', _Lista([_dissipador])),
    ('LM317', _Lista([_lm317, _lm317Inverso])),
  ];

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: _abas.length,
    child: Column(
      children: [
        Row(
          children: [
            Expanded(
              child: TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [for (final (t, _) in _abas) Tab(text: t)],
              ),
            ),
            IconButton(
              tooltip: 'Fechar',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        Expanded(child: TabBarView(children: [for (final (_, w) in _abas) w])),
      ],
    ),
  );
}

// ---------- Calculadora genérica: campos → linhas de resultado ----------

typedef _Def = ({
  String titulo,
  List<(String, String, String)> campos, // rótulo, unidade, valor inicial
  List<String> opcoes,
  List<String> Function(List<double?> v, int opcao) calcular,
});

_Def _def(
  String titulo,
  List<(String, String, String)> campos,
  List<String> Function(List<double?> v, int opcao) calcular, {
  List<String> opcoes = const [],
}) => (titulo: titulo, campos: campos, opcoes: opcoes, calcular: calcular);

/// Linhas só quando todos os campos têm número.
List<String> Function(List<double?>, int) _todos(List<String> Function(List<double> v, int opcao) f) =>
    (v, o) => v.contains(null) ? const [] : f(v.cast<double>(), o);

class _Lista extends StatelessWidget {
  const _Lista(this.defs);

  final List<_Def> defs;

  @override
  Widget build(BuildContext context) =>
      ListView(padding: const EdgeInsets.all(16), children: [for (final d in defs) _Calculadora(d)]);
}

class _Calculadora extends StatefulWidget {
  const _Calculadora(this.d);

  final _Def d;

  @override
  State<_Calculadora> createState() => _CalculadoraState();
}

class _CalculadoraState extends State<_Calculadora> {
  late final _campos = [for (final (_, _, ini) in widget.d.campos) TextEditingController(text: ini)];
  var _opcao = 0;

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
    final linhas = d.calcular([for (final c in _campos) lerValor(c.text)], _opcao);
    final tema = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(d.titulo, style: tema.textTheme.titleMedium),
            const SizedBox(height: 12),
            if (d.opcoes.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: DropdownButton<int>(
                  value: _opcao,
                  items: [
                    for (var i = 0; i < d.opcoes.length; i++) DropdownMenuItem(value: i, child: Text(d.opcoes[i])),
                  ],
                  onChanged: (v) => setState(() => _opcao = v ?? 0),
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
                        labelText: d.campos[i].$1,
                        suffixText: d.campos[i].$2,
                        isDense: true,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            for (final l in linhas)
              SelectableText(l, style: tema.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

String _ou(double v, String unidade, String senao) => v.isFinite && v > 0 ? formatar(v, unidade) : senao;

// ---------- Lei de Ohm ----------

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
      'V = ${formatar(r.v, 'V')}',
      'I = ${formatar(r.i, 'A')}',
      'R = ${formatar(r.r, 'Ω')}',
      'P = ${formatar(r.p, 'W')}',
    ];
  },
);

// ---------- Divisor, LED, RC ----------

final _divisor = _def(
  'Vout = Vin · R2 / (R1 + R2)',
  [('Vin', 'V', '12'), ('R1', 'Ω', '10k'), ('R2', 'Ω', '4k7')],
  _todos((v, _) {
    final vout = divisorVout(v[0], v[1], v[2]);
    return ['Vout = ${formatar(vout, 'V')}', 'Corrente no divisor = ${formatar(v[0] / (v[1] + v[2]), 'A')}'];
  }),
);

final _divisorInverso = _def(
  'R2 para um Vout',
  [('Vin', 'V', '12'), ('Vout', 'V', '3,3'), ('R1', 'Ω', '10k')],
  _todos((v, _) {
    final r2 = divisorR2(v[0], v[1], v[2]);
    if (!r2.isFinite) return const ['Vout precisa ficar entre 0 e Vin.'];
    final rc = e24Acima(r2);
    return [
      'R2 = ${formatar(r2, 'Ω')}',
      'E24 acima: ${formatar(rc, 'Ω')} → Vout = ${formatar(divisorVout(v[0], v[2], rc), 'V')}',
    ];
  }),
);

final _led = _def(
  'R = (Vfonte − Vf) / If',
  [('Vfonte', 'V', '5'), ('Vf do LED', 'V', '2'), ('If', 'A', '20m')],
  _todos((v, _) {
    final r = resistorLed(v[0], v[1], v[2]);
    if (r == null) return const ['A fonte precisa ser maior que Vf e a corrente maior que zero.'];
    return [
      'R = ${formatar(r.r, 'Ω')} (dissipa ${formatar(r.p, 'W')})',
      'Comercial E24: ${formatar(r.rComercial, 'Ω')} → ${formatar((v[0] - v[1]) / r.rComercial, 'A')}, '
          '${formatar(r.pComercial, 'W')} (use resistor de ${formatar(r.pComercial * 2, 'W')} ou mais)',
    ];
  }),
);

final _rcFc = _def(
  'Frequência de corte fc = 1 / (2π·R·C)',
  [('R', 'Ω', '10k'), ('C', 'F', '100n')],
  _todos((v, _) {
    return ['fc = ${_ou(rcFrequencia(v[0], v[1]), 'Hz', '—')}', 'τ = R·C = ${formatar(v[0] * v[1], 's')}'];
  }),
);

final _rcR = _def(
  'R para fc e C',
  [('fc', 'Hz', '1k'), ('C', 'F', '100n')],
  _todos((v, _) {
    return ['R = ${_ou(rcResistor(v[0], v[1]), 'Ω', '—')}'];
  }),
);

final _rcC = _def(
  'C para fc e R',
  [('fc', 'Hz', '1k'), ('R', 'Ω', '10k')],
  _todos((v, _) {
    return ['C = ${_ou(rcCapacitor(v[0], v[1]), 'F', '—')}'];
  }),
);

// ---------- Crossover, dissipador, LM317 ----------

final _crossover = _def(
  'Crossover passivo (passa-baixa no grave, passa-alta no agudo)',
  [('Impedância', 'Ω', '8'), ('Frequência', 'Hz', '3k')],
  opcoes: [for (final t in TipoCrossover.values) t.nome],
  _todos((v, o) {
    final tipo = TipoCrossover.values[o];
    final x = crossover(v[0], v[1], tipo);
    if (tipo == TipoCrossover.primeiraOrdem) {
      return ['Grave: L em série = ${formatar(x.l, 'H')}', 'Agudo: C em série = ${formatar(x.c, 'F')}'];
    }
    return [
      'Grave: L em série = ${formatar(x.l, 'H')}, C em paralelo = ${formatar(x.c, 'F')}',
      'Agudo: C em série = ${formatar(x.c, 'F')}, L em paralelo = ${formatar(x.l, 'H')}',
    ];
  }),
);

final _dissipador = _def(
  'Rθsa = (Tj máx − Tamb) / P − Rθjc − Rθcs',
  [
    ('Potência', 'W', '10'),
    ('Tj máx', '°C', '150'),
    ('Tamb', '°C', '40'),
    ('Rθjc', '°C/W', '1,5'),
    ('Rθcs', '°C/W', '0,5'),
  ],
  _todos((v, _) {
    final r = rthDissipador(potencia: v[0], tjMax: v[1], tAmb: v[2], rthJc: v[3], rthCs: v[4]);
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
  _todos((v, _) {
    return ['Vout = ${formatar(lm317Vout(v[0], v[1]), 'V')}'];
  }),
);

final _lm317Inverso = _def(
  'R2 para um Vout',
  [('Vout', 'V', '5'), ('R1', 'Ω', '240')],
  _todos((v, _) {
    final r2 = lm317R2(v[0], v[1]);
    if (!r2.isFinite) return const ['O LM317 não desce abaixo de 1,25 V.'];
    final rc = e24Acima(r2);
    return [
      'R2 = ${formatar(r2, 'Ω')}',
      'E24 acima: ${formatar(rc, 'Ω')} → Vout = ${formatar(lm317Vout(v[1], rc), 'V')}',
    ];
  }),
);

// ---------- Código de cores ----------

const _corDe = {
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
  var _faixas = 4;
  final _digitos = [4, 7, 0];
  var _expoente = 2;
  var _tolerancia = 'ouro';
  final _valor = TextEditingController(text: '4k7');

  @override
  void dispose() {
    _valor.dispose();
    super.dispose();
  }

  List<int> get _usados => _digitos.sublist(0, _faixas == 5 ? 3 : 2);

  Widget _faixa(String cor) => Container(
    width: 18,
    height: 48,
    margin: const EdgeInsets.symmetric(horizontal: 3),
    decoration: BoxDecoration(
      color: _corDe[cor],
      border: Border.all(color: Colors.black26),
    ),
  );

  Widget _escolha(String rotulo, String valor, List<String> opcoes, ValueChanged<String> mudar) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(rotulo, style: Theme.of(context).textTheme.labelSmall),
      DropdownButton<String>(
        value: valor,
        items: [
          for (final o in opcoes)
            DropdownMenuItem(
              value: o,
              child: Row(
                children: [
                  Container(width: 14, height: 14, color: _corDe[o]),
                  const SizedBox(width: 6),
                  Text(o),
                ],
              ),
            ),
        ],
        onChanged: (v) {
          if (v != null) setState(() => mudar(v));
        },
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final valor = valorDasCores(_usados, _expoente);
    final volta = lerValor(_valor.text);
    final cores = volta == null ? null : coresDoValor(volta, _faixas);
    final expoentes = [for (var e = -2; e <= 9; e++) e];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 4, label: Text('4 faixas')),
            ButtonSegment(value: 5, label: Text('5 faixas')),
          ],
          selected: {_faixas},
          onSelectionChanged: (s) => setState(() => _faixas = s.first),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Cores → valor', style: tema.textTheme.titleMedium),
                Wrap(
                  spacing: 16,
                  children: [
                    for (var i = 0; i < _usados.length; i++)
                      _escolha(
                        '${i + 1}ª faixa',
                        coresResistor[_digitos[i]],
                        coresResistor,
                        (v) => _digitos[i] = coresResistor.indexOf(v),
                      ),
                    _escolha('Multiplicador', corMultiplicador(_expoente), [
                      for (final e in expoentes) corMultiplicador(e),
                    ], (v) => _expoente = expoentes.firstWhere((e) => corMultiplicador(e) == v)),
                    _escolha('Tolerância', _tolerancia, toleranciasResistor.keys.toList(), (v) => _tolerancia = v),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    for (final d in _usados) _faixa(coresResistor[d]),
                    _faixa(corMultiplicador(_expoente)),
                    const SizedBox(width: 12),
                    _faixa(_tolerancia),
                    const SizedBox(width: 16),
                    SelectableText(
                      '${formatar(valor, 'Ω')} ± ${toleranciasResistor[_tolerancia]!.toString().replaceAll('.', ',')} %',
                      style: tema.textTheme.titleLarge,
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
                Text('Valor → cores', style: tema.textTheme.titleMedium),
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
                if (cores == null)
                  const Text('Valor fora da faixa (0,1 Ω a centenas de GΩ).')
                else
                  Row(
                    children: [
                      for (final d in cores.digitos) _faixa(coresResistor[d]),
                      _faixa(corMultiplicador(cores.expoente)),
                      const SizedBox(width: 16),
                      Expanded(
                        child: SelectableText(
                          '${[...cores.digitos.map((d) => coresResistor[d]), corMultiplicador(cores.expoente)].join(', ')}'
                          ' (${formatar(valorDasCores(cores.digitos, cores.expoente), 'Ω')})',
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
