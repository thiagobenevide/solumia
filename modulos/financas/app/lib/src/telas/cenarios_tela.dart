import 'dart:math';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_financas.dart';
import '../formato.dart';
import 'comuns.dart';
import 'conversa_financas.dart';

/// Número de um JSON do servidor (null vira 0).
double _n(dynamic v) => (v as num?)?.toDouble() ?? 0;

/// Cenários (análise preditiva): pergunta livre à IA ("quero um EcoSport 2015 de 45 mil, em quanto
/// tempo junto? financiar compensa?") ou simulação manual; o servidor calcula juntar × financiar sobre
/// o seu extrato e a IA explica. Mostra também os parcelamentos em aberto.
class CenariosTela extends StatefulWidget {
  const CenariosTela({super.key, required this.api});

  final ApiFinancas api;

  @override
  State<CenariosTela> createState() => _CenariosTelaState();
}

class _CenariosTelaState extends State<CenariosTela> {
  final _pergunta = TextEditingController();
  late Future<List<Doc>> _parcelamentos = widget.api.parcelamentos();
  Doc? _resultado;
  String? _analise;
  String? _erro;
  bool _pensando = false;
  bool _cancelado = false;

  @override
  void dispose() {
    _pergunta.dispose();
    super.dispose();
  }

  Future<void> _perguntar() async {
    final texto = _pergunta.text.trim();
    if (texto.isEmpty || _pensando) return;
    setState(() {
      _pensando = true;
      _cancelado = false;
      _erro = null;
    });
    try {
      final r = await widget.api.perguntar(texto, cancelado: () => _cancelado);
      if (!mounted) return;
      setState(() {
        _resultado = r['resultado'] as Doc;
        _analise = r['analise'] as String?;
      });
    } on ApiErro catch (e) {
      if (mounted && !_cancelado) setState(() => _erro = e.mensagem);
    } finally {
      if (mounted) setState(() => _pensando = false);
    }
  }

  Future<void> _simularManual() async {
    final p = _resultado?['pedido'] as Doc? ?? const {};
    final d = await formulario(context, 'Simular compra', [
      const Campo('descricao', 'O que é', ajuda: 'ex.: EcoSport 2015'),
      const Campo('tipo', 'Tipo', tipo: TipoCampo.opcao, opcoes: {
        'carro': 'Carro',
        'moto': 'Moto',
        'terreno': 'Terreno',
        'imovel': 'Imóvel (SFH)',
        'mcmv': 'Minha Casa Minha Vida',
        'outro': 'Outro bem',
      }),
      const Campo('valor', 'Valor do bem (R\$)', tipo: TipoCampo.numero, obrigatorio: true),
      const Campo('entrada', 'Entrada (R\$)', tipo: TipoCampo.numero),
      const Campo('prazo_meses', 'Prazo do financiamento (meses)', tipo: TipoCampo.numero, ajuda: 'vazio = padrão do tipo'),
      const Campo('taxa_anual', 'Juros ao ano (%)', tipo: TipoCampo.numero, ajuda: 'vazio = referência de mercado'),
      const Campo('sistema', 'Tabela', tipo: TipoCampo.opcao, opcoes: {'': 'Padrão', 'price': 'Price (parcela fixa)', 'sac': 'SAC (parcela cai)'}),
      const Campo('custo_mensal_extra', 'Custo mensal do bem (R\$)', tipo: TipoCampo.numero, ajuda: 'IPVA, seguro, condomínio; vazio = estimativa'),
      const Campo('aporte_mensal', 'Quanto vai guardar por mês (R\$)', tipo: TipoCampo.numero, ajuda: 'vazio = sua sobra média'),
    ], {
      'tipo': p['tipo'] ?? 'carro',
      'descricao': p['descricao'] ?? '',
      if (p['valor'] != null) 'valor': p['valor'],
      if (p['entrada'] != null) 'entrada': p['entrada'],
    });
    if (d == null || !mounted) return;
    final parametros = <String, dynamic>{
      for (final e in d.entries)
        if (e.value != null && '${e.value}'.isNotEmpty && '${e.value}' != '0' || e.key == 'valor') e.key: e.value,
    };
    if (parametros['taxa_anual'] != null) parametros['taxa_anual'] = _n(parametros['taxa_anual']) / 100;
    await tentar(context, () async {
      final r = await widget.api.simular(parametros);
      if (mounted) {
        setState(() {
          _resultado = r;
          _analise = null;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(8),
    children: [
      Secao(
        titulo: 'O que você quer comprar?',
        subtitulo: 'A IA lê o seu extrato e responde quanto tempo leva para juntar e se financiar compensa.',
        acoes: [
          TextButton.icon(onPressed: _simularManual, icon: const Icon(Icons.tune), label: const Text('Simular à mão')),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            TextField(
              controller: _pergunta,
              minLines: 2,
              maxLines: 5,
              enabled: !_pensando,
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
                  onPressed: _pensando ? null : _perguntar,
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('Analisar minha realidade'),
                ),
                if (_pensando) ...[
                  const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  const Text('Lendo o extrato e simulando… (até 1 min)'),
                  TextButton(onPressed: () => setState(() => _cancelado = true), child: const Text('Cancelar')),
                ],
              ],
            ),
            if (_erro != null) Text(_erro!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ),
      ),
      ConversaFinancas(
        api: widget.api,
        cenario: _analise == null ? null : {'pergunta': _pergunta.text.trim(), 'analise': _analise},
      ),
      if (_resultado != null) ..._resultadoWidgets(context, _resultado!, _analise),
      Esperar(
        futuro: _parcelamentos,
        recarregar: () => setState(() => _parcelamentos = widget.api.parcelamentos()),
        construir: (lista) => _Parcelamentos(lista),
      ),
    ],
  );
}

List<Widget> _resultadoWidgets(BuildContext context, Doc r, String? analise) {
  final pedido = r['pedido'] as Doc;
  final real = r['realidade'] as Doc;
  final juntar = r['juntar'] as Doc;
  final fin = r['financiar'] as Doc;
  final reserva = r['financiar_com_reserva'] as Doc?;
  final mcmv = r['mcmv'] as Doc?;
  final alertas = (r['alertas'] as List).cast<String>();
  final cores = Theme.of(context).colorScheme;
  final meses = juntar['meses'] as int?;
  final titulo = (pedido['descricao'] as String).isEmpty ? 'Compra de ${moeda(_n(pedido['valor']))}' : pedido['descricao'] as String;
  return [
    Secao(
      titulo: titulo,
      subtitulo: r['veredito'] as String,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          GradeIndicadores(
            children: [
              Indicador('Renda média', moeda(_n(real['renda_media'])), detalhe: '${real['meses_de_historico']} meses de extrato'),
              Indicador('Sobra média/mês', moeda(_n(real['sobra_media'])),
                  cor: _n(real['sobra_media']) > 0 ? Colors.green : cores.error,
                  detalhe: 'tendência ${moeda(_n(real['tendencia_mensal']))}/mês'),
              Indicador('Reserva hoje', moeda(_n(real['reserva']))),
              Indicador('Parcelas em aberto', moeda(_n(real['parcelas_em_aberto'])), detalhe: 'por mês'),
            ],
          ),
          GradeIndicadores(
            children: [
              Indicador(
                'Juntar e comprar à vista',
                meses == null ? 'não chega' : (meses == 0 ? 'já tem' : '$meses meses'),
                icone: Icons.savings_outlined,
                cor: meses == null ? cores.error : Colors.green,
                detalhe: meses == null ? 'sem sobra suficiente' : 'em ${mesBr('${juntar['data']}')} · guardando ${moeda(_n(juntar['aporte_mensal']))}/mês',
                largura: 260,
              ),
              Indicador(
                'Financiar ${moeda(_n(fin['valor_financiado']))}',
                '${moeda(_n(fin['primeira']))}/mês',
                icone: Icons.account_balance_outlined,
                cor: fin['cabe'] == true ? Colors.green : cores.error,
                detalhe: '${pedido['prazo_meses']}× ${(pedido['sistema'] as String).toUpperCase()} · ${pct(_n(pedido['taxa_anual']) * 100)} a.a. · '
                    'juros ${moeda(_n(fin['juros']))}${fin['comprometimento'] == null ? '' : ' · ${pct(_n(fin['comprometimento']) * 100)} da renda'}',
                largura: 300,
              ),
              if (reserva != null)
                Indicador(
                  'Usando a reserva de entrada',
                  '${moeda(_n(reserva['primeira']))}/mês',
                  icone: Icons.payments_outlined,
                  cor: reserva['cabe'] == true ? Colors.green : cores.error,
                  detalhe: 'entrada ${moeda(_n(reserva['entrada']))} (guarda ${moeda(_n(reserva['emergencia_guardada']))} de emergência) · '
                      'juros ${moeda(_n(reserva['juros']))}',
                  largura: 300,
                ),
              Indicador('Custo mensal do bem', moeda(_n(pedido['custo_mensal_extra'])), detalhe: 'IPVA, seguro, manutenção…'),
              if (mcmv != null)
                Indicador('Minha Casa Minha Vida', '${mcmv['faixa']}',
                    detalhe: 'juros ${pct(_n(mcmv['taxa_anual']) * 100)} a.a. · imóvel até ${moeda(_n(mcmv['imovel_maximo']))}'),
            ],
          ),
          for (final a in alertas)
            Row(spacing: 6, children: [Icon(Icons.warning_amber, size: 18, color: cores.error), Expanded(child: Text(a))]),
          const SizedBox(height: 4),
          Text('Saldo projetado', style: Theme.of(context).textTheme.titleSmall),
          _GraficoCenarios(r['projecao'] as Doc),
          Text('Referências de mercado (taxas, faixas do MCMV): confirme com o banco antes de decidir.',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    ),
    if (analise != null && analise.isNotEmpty)
      Secao(
        titulo: 'Análise da IA',
        child: SelectableText(analise.replaceAll('**', '')),
      ),
  ];
}

/// Três linhas de saldo projetado: sem comprar, juntar e comprar à vista, financiar agora.
class _GraficoCenarios extends StatelessWidget {
  const _GraficoCenarios(this.projecao);

  final Doc projecao;

  static const series = [
    ('sem_compra', 'Sem comprar', Colors.blueGrey),
    ('juntar', 'Juntar e comprar à vista', Colors.green),
    ('financiar', 'Financiar agora', Colors.orange),
  ];

  @override
  Widget build(BuildContext context) {
    final dados = {
      for (final (chave, _, _) in series)
        chave: [for (final p in (projecao[chave] as List).cast<Doc>()) _n(p['saldo'])],
    };
    final rotulos = [for (final p in (projecao['sem_compra'] as List).cast<Doc>()) p['mes'] as String];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 220,
          width: double.infinity,
          child: CustomPaint(
            painter: _PintorCenarios(dados, rotulos, Theme.of(context).colorScheme, Theme.of(context).textTheme.bodySmall!),
          ),
        ),
        Wrap(
          spacing: 12,
          children: [
            for (final (_, nome, cor) in series)
              Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 4,
                children: [Container(width: 12, height: 3, color: cor), Flexible(child: Text(nome))],
              ),
          ],
        ),
      ],
    );
  }
}

class _PintorCenarios extends CustomPainter {
  _PintorCenarios(this.dados, this.rotulos, this.cores, this.estilo);

  final Map<String, List<double>> dados;
  final List<String> rotulos;
  final ColorScheme cores;
  final TextStyle estilo;

  @override
  void paint(Canvas canvas, Size size) {
    final todos = dados.values.expand((v) => v).toList();
    if (todos.isEmpty) return;
    final minimo = min(0.0, todos.reduce(min)), maximo = max(1.0, todos.reduce(max));
    const esquerda = 64.0, baixo = 18.0;
    final w = size.width - esquerda, h = size.height - baixo;
    double y(double v) => h - (v - minimo) / (maximo - minimo) * h;
    final grade = Paint()
      ..color = cores.outlineVariant
      ..strokeWidth = 1;
    for (final v in [minimo, 0.0, maximo]) {
      canvas.drawLine(Offset(esquerda, y(v)), Offset(size.width, y(v)), grade..strokeWidth = v == 0 ? 1.5 : 0.6);
      final t = TextPainter(text: TextSpan(text: moedaCurta(v), style: estilo), textDirection: TextDirection.ltr)..layout();
      t.paint(canvas, Offset(esquerda - t.width - 6, y(v) - t.height / 2));
    }
    final n = rotulos.length;
    if (n < 2) return;
    for (final (chave, _, cor) in _GraficoCenarios.series) {
      final v = dados[chave]!;
      final caminho = Path();
      for (var i = 0; i < v.length; i++) {
        final p = Offset(esquerda + w * i / (n - 1), y(v[i]));
        i == 0 ? caminho.moveTo(p.dx, p.dy) : caminho.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(
        caminho,
        Paint()
          ..color = cor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    final passo = max(1, (n / 6).ceil());
    for (var i = 0; i < n; i += passo) {
      final t = TextPainter(text: TextSpan(text: mesBr(rotulos[i]), style: estilo), textDirection: TextDirection.ltr)..layout();
      t.paint(canvas, Offset((esquerda + w * i / (n - 1) - t.width / 2).clamp(esquerda, size.width - t.width), h + 2));
    }
  }

  @override
  bool shouldRepaint(_PintorCenarios old) => old.dados != dados;
}

String moedaCurta(double v) {
  final a = v.abs();
  final s = a >= 1e6 ? '${numero(a / 1e6, casas: 1)} mi' : (a >= 1e3 ? '${numero(a / 1e3, casas: 0)} mil' : numero(a, casas: 0));
  return '${v < 0 ? '-' : ''}R\$ $s';
}

class _Parcelamentos extends StatelessWidget {
  const _Parcelamentos(this.lista);

  final List<Doc> lista;

  @override
  Widget build(BuildContext context) {
    final ativos = lista.where((p) => p['ativo'] == true).toList();
    final porMes = ativos.fold<double>(0, (s, p) => s + _n(p['valor_parcela']));
    final restante = ativos.fold<double>(0, (s, p) => s + _n(p['valor_restante']));
    return Secao(
      titulo: 'Parcelamentos em aberto',
      subtitulo: ativos.isEmpty
          ? 'Nenhuma compra parcelada em aberto nos extratos importados.'
          : '${ativos.length} compras · ${moeda(porMes)}/mês · faltam ${moeda(restante)}',
      child: Column(
        children: [
          for (final p in lista)
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
                      Text('${p['pagas']}/${p['parcelas']} · ${moeda(_n(p['valor_parcela']))}'),
                    ],
                  ),
                  LinearProgressIndicator(value: _n(p['pagas']) / max(1, _n(p['parcelas']))),
                  Text(
                    p['ativo'] == true
                        ? 'faltam ${moeda(_n(p['valor_restante']))} · até ${mesBr('${p['termina']}')}'
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
