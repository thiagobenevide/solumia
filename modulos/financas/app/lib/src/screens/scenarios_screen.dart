import 'dart:math';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../finance_api.dart';
import '../format.dart';
import 'common.dart';
import 'finance_chat.dart';

/// Number from a server JSON (null becomes 0).
double _n(dynamic v) => (v as num?)?.toDouble() ?? 0;

/// Scenarios (predictive analysis): free question to the AI ("quero um EcoSport 2015 de 45 mil, em quanto
/// tempo junto? financiar compensa?") or manual simulation; the server computes save up × finance over
/// your statement and the AI explains. Also shows the open installments.
class ScenariosScreen extends StatefulWidget {
  const ScenariosScreen({super.key, required this.api});

  final FinanceApi api;

  @override
  State<ScenariosScreen> createState() => _ScenariosScreenState();
}

class _ScenariosScreenState extends State<ScenariosScreen> {
  final _question = TextEditingController();
  late Future<List<Doc>> _installments = widget.api.installments();
  Doc? _result;
  String? _analysis;
  String? _error;
  bool _thinking = false;
  bool _cancelled = false;

  @override
  void dispose() {
    _question.dispose();
    super.dispose();
  }

  Future<void> _ask() async {
    final text = _question.text.trim();
    if (text.isEmpty || _thinking) return;
    setState(() {
      _thinking = true;
      _cancelled = false;
      _error = null;
    });
    try {
      final r = await widget.api.ask(text, isCancelled: () => _cancelled);
      if (!mounted) return;
      setState(() {
        _result = r['resultado'] as Doc;
        _analysis = r['analise'] as String?;
      });
    } on ApiErro catch (e) {
      if (mounted && !_cancelled) setState(() => _error = e.mensagem);
    } finally {
      if (mounted) setState(() => _thinking = false);
    }
  }

  Future<void> _simulateManual() async {
    final p = _result?['pedido'] as Doc? ?? const {};
    final d = await form(context, 'Simular compra', [
      const FormFieldSpec('descricao', 'O que é', help: 'ex.: EcoSport 2015'),
      const FormFieldSpec('tipo', 'Tipo', type: FieldKind.option, options: {
        'carro': 'Carro',
        'moto': 'Moto',
        'terreno': 'Terreno',
        'imovel': 'Imóvel (SFH)',
        'mcmv': 'Minha Casa Minha Vida',
        'outro': 'Outro bem',
      }),
      const FormFieldSpec('valor', 'Valor do bem (R\$)', type: FieldKind.number, isRequired: true),
      const FormFieldSpec('entrada', 'Entrada (R\$)', type: FieldKind.number),
      const FormFieldSpec('prazo_meses', 'Prazo do financiamento (meses)', type: FieldKind.number, help: 'vazio = padrão do tipo'),
      const FormFieldSpec('taxa_anual', 'Juros ao ano (%)', type: FieldKind.number, help: 'vazio = referência de mercado'),
      const FormFieldSpec('sistema', 'Tabela', type: FieldKind.option, options: {'': 'Padrão', 'price': 'Price (parcela fixa)', 'sac': 'SAC (parcela cai)'}),
      const FormFieldSpec('custo_mensal_extra', 'Custo mensal do bem (R\$)', type: FieldKind.number, help: 'IPVA, seguro, condomínio; vazio = estimativa'),
      const FormFieldSpec('aporte_mensal', 'Quanto vai guardar por mês (R\$)', type: FieldKind.number, help: 'vazio = sua sobra média'),
    ], {
      'tipo': p['tipo'] ?? 'carro',
      'descricao': p['descricao'] ?? '',
      if (p['valor'] != null) 'valor': p['valor'],
      if (p['entrada'] != null) 'entrada': p['entrada'],
    });
    if (d == null || !mounted) return;
    final parameters = <String, dynamic>{
      for (final e in d.entries)
        if (e.value != null && '${e.value}'.isNotEmpty && '${e.value}' != '0' || e.key == 'valor') e.key: e.value,
    };
    if (parameters['taxa_anual'] != null) parameters['taxa_anual'] = _n(parameters['taxa_anual']) / 100;
    await tentar(context, () async {
      final r = await widget.api.simulate(parameters);
      if (mounted) {
        setState(() {
          _result = r;
          _analysis = null;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(8),
    children: [
      Section(
        title: 'O que você quer comprar?',
        subtitle: 'A IA lê o seu extrato e responde quanto tempo leva para juntar e se financiar compensa.',
        stocks: [
          TextButton.icon(onPressed: _simulateManual, icon: const Icon(Icons.tune), label: const Text('Simular à mão')),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            TextField(
              controller: _question,
              minLines: 2,
              maxLines: 5,
              enabled: !_thinking,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Ex.: Quero comprar um EcoSport 2015 de R\$ 45 mil. Em quanto tempo consigo juntar? '
                    'Financiar compensa?\nOu: terreno de 80 mil com 20 mil de entrada; Minha Casa Minha Vida de 220 mil.',
              ),
            ),
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: _thinking ? null : _ask,
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('Analisar minha realidade'),
                ),
                if (_thinking) ...[
                  const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  const Text('Lendo o extrato e simulando… (até 1 min)'),
                  TextButton(onPressed: () => setState(() => _cancelled = true), child: const Text('Cancelar')),
                ],
              ],
            ),
            if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ),
      ),
      FinanceChat(
        api: widget.api,
        scenario: _analysis == null ? null : {'pergunta': _question.text.trim(), 'analise': _analysis},
      ),
      if (_result != null) ..._resultWidgets(context, _result!, _analysis),
      Waiting(
        future: _installments,
        reload: () => setState(() => _installments = widget.api.installments()),
        construir: (items) => _Installments(items),
      ),
    ],
  );
}

List<Widget> _resultWidgets(BuildContext context, Doc r, String? analysis) {
  final request = r['pedido'] as Doc;
  final real = r['realidade'] as Doc;
  final merge = r['juntar'] as Doc;
  final fin = r['financiar'] as Doc;
  final reserve = r['financiar_com_reserva'] as Doc?;
  final mcmv = r['mcmv'] as Doc?;
  final alerts = (r['alertas'] as List).cast<String>();
  final colors = Theme.of(context).colorScheme;
  final months = merge['meses'] as int?;
  final title = (request['descricao'] as String).isEmpty ? 'Compra de ${currency(_n(request['valor']))}' : request['descricao'] as String;
  return [
    Section(
      title: title,
      subtitle: r['veredito'] as String,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          IndicatorGrid(
            children: [
              Indicator('Renda média', currency(_n(real['renda_media'])), detail: '${real['meses_de_historico']} meses de extrato'),
              Indicator('Sobra média/mês', currency(_n(real['sobra_media'])),
                  color: _n(real['sobra_media']) > 0 ? Colors.green : colors.error,
                  detail: 'tendência ${currency(_n(real['tendencia_mensal']))}/mês'),
              Indicator('Reserva hoje', currency(_n(real['reserva']))),
              Indicator('Parcelas em aberto', currency(_n(real['parcelas_em_aberto'])), detail: 'por mês'),
            ],
          ),
          IndicatorGrid(
            children: [
              Indicator(
                'Juntar e comprar à vista',
                months == null ? 'não chega' : (months == 0 ? 'já tem' : '$months meses'),
                icone: Icons.savings_outlined,
                color: months == null ? colors.error : Colors.green,
                detail: months == null ? 'sem sobra suficiente' : 'em ${mesBr('${merge['data']}')} · guardando ${currency(_n(merge['aporte_mensal']))}/mês',
                width: 260,
              ),
              Indicator(
                'Financiar ${currency(_n(fin['valor_financiado']))}',
                '${currency(_n(fin['primeira']))}/mês',
                icone: Icons.account_balance_outlined,
                color: fin['cabe'] == true ? Colors.green : colors.error,
                detail: '${request['prazo_meses']}× ${(request['sistema'] as String).toUpperCase()} · ${pct(_n(request['taxa_anual']) * 100)} a.a. · '
                    'juros ${currency(_n(fin['juros']))}${fin['comprometimento'] == null ? '' : ' · ${pct(_n(fin['comprometimento']) * 100)} da renda'}',
                width: 300,
              ),
              if (reserve != null)
                Indicator(
                  'Usando a reserva de entrada',
                  '${currency(_n(reserve['primeira']))}/mês',
                  icone: Icons.payments_outlined,
                  color: reserve['cabe'] == true ? Colors.green : colors.error,
                  detail: 'entrada ${currency(_n(reserve['entrada']))} (guarda ${currency(_n(reserve['emergencia_guardada']))} de emergência) · '
                      'juros ${currency(_n(reserve['juros']))}',
                  width: 300,
                ),
              Indicator('Custo mensal do bem', currency(_n(request['custo_mensal_extra'])), detail: 'IPVA, seguro, manutenção…'),
              if (mcmv != null)
                Indicator('Minha Casa Minha Vida', '${mcmv['faixa']}',
                    detail: 'juros ${pct(_n(mcmv['taxa_anual']) * 100)} a.a. · imóvel até ${currency(_n(mcmv['imovel_maximo']))}'),
            ],
          ),
          for (final a in alerts)
            Row(spacing: 6, children: [Icon(Icons.warning_amber, size: 18, color: colors.error), Expanded(child: Text(a))]),
          const SizedBox(height: 4),
          Text('Saldo projetado', style: Theme.of(context).textTheme.titleSmall),
          _ScenariosChart(r['projecao'] as Doc),
          Text('Referências de mercado (taxas, faixas do MCMV): confirme com o banco antes de decidir.',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    ),
    if (analysis != null && analysis.isNotEmpty)
      Section(
        title: 'Análise da IA',
        child: SelectableText(analysis.replaceAll('**', '')),
      ),
  ];
}

/// Three projected balance lines: without buying, save up and buy in cash, finance now.
class _ScenariosChart extends StatelessWidget {
  const _ScenariosChart(this.projection);

  final Doc projection;

  static const series = [
    ('sem_compra', 'Sem comprar', Colors.blueGrey),
    ('juntar', 'Juntar e comprar à vista', Colors.green),
    ('financiar', 'Financiar agora', Colors.orange),
  ];

  @override
  Widget build(BuildContext context) {
    final data = {
      for (final (key, _, _) in series)
        key: [for (final p in (projection[key] as List).cast<Doc>()) _n(p['saldo'])],
    };
    final labels = [for (final p in (projection['sem_compra'] as List).cast<Doc>()) p['mes'] as String];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 220,
          width: double.infinity,
          child: CustomPaint(
            painter: _ScenariosPainter(data, labels, Theme.of(context).colorScheme, Theme.of(context).textTheme.bodySmall!),
          ),
        ),
        Wrap(
          spacing: 12,
          children: [
            for (final (_, name, color) in series)
              Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 4,
                children: [Container(width: 12, height: 3, color: color), Flexible(child: Text(name))],
              ),
          ],
        ),
      ],
    );
  }
}

class _ScenariosPainter extends CustomPainter {
  _ScenariosPainter(this.data, this.labels, this.colors, this.estilo);

  final Map<String, List<double>> data;
  final List<String> labels;
  final ColorScheme colors;
  final TextStyle estilo;

  @override
  void paint(Canvas canvas, Size size) {
    final all = data.values.expand((v) => v).toList();
    if (all.isEmpty) return;
    final minimum = min(0.0, all.reduce(min)), maximum = max(1.0, all.reduce(max));
    const left = 64.0, low = 18.0;
    final w = size.width - left, h = size.height - low;
    double y(double v) => h - (v - minimum) / (maximum - minimum) * h;
    final grade = Paint()
      ..color = colors.outlineVariant
      ..strokeWidth = 1;
    for (final v in [minimum, 0.0, maximum]) {
      canvas.drawLine(Offset(left, y(v)), Offset(size.width, y(v)), grade..strokeWidth = v == 0 ? 1.5 : 0.6);
      final t = TextPainter(text: TextSpan(text: shortCurrency(v), style: estilo), textDirection: TextDirection.ltr)..layout();
      t.paint(canvas, Offset(left - t.width - 6, y(v) - t.height / 2));
    }
    final n = labels.length;
    if (n < 2) return;
    for (final (key, _, color) in _ScenariosChart.series) {
      final v = data[key]!;
      final path = Path();
      for (var i = 0; i < v.length; i++) {
        final p = Offset(left + w * i / (n - 1), y(v[i]));
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    final step = max(1, (n / 6).ceil());
    for (var i = 0; i < n; i += step) {
      final t = TextPainter(text: TextSpan(text: mesBr(labels[i]), style: estilo), textDirection: TextDirection.ltr)..layout();
      t.paint(canvas, Offset((left + w * i / (n - 1) - t.width / 2).clamp(left, size.width - t.width), h + 2));
    }
  }

  @override
  bool shouldRepaint(_ScenariosPainter old) => old.data != data;
}

String shortCurrency(double v) {
  final a = v.abs();
  final s = a >= 1e6 ? '${number(a / 1e6, decimals: 1)} mi' : (a >= 1e3 ? '${number(a / 1e3, decimals: 0)} mil' : number(a, decimals: 0));
  return '${v < 0 ? '-' : ''}R\$ $s';
}

class _Installments extends StatelessWidget {
  const _Installments(this.items);

  final List<Doc> items;

  @override
  Widget build(BuildContext context) {
    final assets = items.where((p) => p['ativo'] == true).toList();
    final byMonth = assets.fold<double>(0, (s, p) => s + _n(p['valor_parcela']));
    final remainder = assets.fold<double>(0, (s, p) => s + _n(p['valor_restante']));
    return Section(
      title: 'Parcelamentos em aberto',
      subtitle: assets.isEmpty
          ? 'Nenhuma compra parcelada em aberto nos extratos importados.'
          : '${assets.length} compras · ${currency(byMonth)}/mês · faltam ${currency(remainder)}',
      child: Column(
        children: [
          for (final p in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  Row(
                    spacing: 8,
                    children: [
                      Icon(p['ativo'] == true ? Icons.schedule : Icons.check_circle_outline, size: 18),
                      Expanded(child: Text(p['descricao'] as String, maxLines: 2, overflow: TextOverflow.ellipsis)),
                      Text('${p['pagas']}/${p['parcelas']} · ${currency(_n(p['valor_parcela']))}'),
                    ],
                  ),
                  LinearProgressIndicator(value: _n(p['pagas']) / max(1, _n(p['parcelas']))),
                  Text(
                    p['ativo'] == true
                        ? 'faltam ${currency(_n(p['valor_restante']))} · até ${mesBr('${p['termina']}')}'
                        : 'quitado',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
