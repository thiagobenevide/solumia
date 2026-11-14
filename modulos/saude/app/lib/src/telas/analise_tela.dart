import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_saude.dart';
import '../datas.dart';

/// Análise pela LLM local (worker do PC): cruza sono, atividade e coração com humor, ansiedade,
/// foco, hábitos, treinos, gastos e rotina, e propõe um plano para a semana. Nada vai para fora.
class AnaliseTela extends StatefulWidget {
  const AnaliseTela({super.key, required this.api});

  final ApiSaude api;

  @override
  State<AnaliseTela> createState() => _AnaliseTelaState();
}

class _AnaliseTelaState extends State<AnaliseTela> {
  final _pergunta = TextEditingController();
  int _dias = 30;
  bool _pensando = false;
  List<Map<String, dynamic>>? _analises;
  int _aberta = 0;

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  @override
  void dispose() {
    _pergunta.dispose();
    super.dispose();
  }

  Future<void> _carregar() async {
    try {
      final a = await widget.api.analises();
      if (mounted) setState(() => _analises = a);
    } on ApiErro catch (e) {
      _avisar(e);
      if (mounted) setState(() => _analises ??= []);
    }
  }

  void _avisar(Object e) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
  }

  Future<void> _analisar() async {
    setState(() => _pensando = true);
    try {
      await widget.api.analisar(_dias, _pergunta.text);
      _pergunta.clear();
      _aberta = 0;
      await _carregar();
    } on ApiErro catch (e) {
      _avisar(e);
    } finally {
      if (mounted) setState(() => _pensando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final analises = _analises;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Análise de saúde', style: tema.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Feita pela LLM local no seu PC. Cruza o relógio com o diário, foco, hábitos, treinos, finanças, '
          'rotinas e estudos.',
          style: tema.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 7, label: Text('7 dias')),
                ButtonSegment(value: 30, label: Text('30 dias')),
                ButtonSegment(value: 90, label: Text('90 dias')),
              ],
              selected: {_dias},
              onSelectionChanged: (s) => setState(() => _dias = s.first),
            ),
            FilledButton.icon(
              onPressed: _pensando ? null : _analisar,
              icon: _pensando
                  ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.auto_awesome_outlined),
              label: Text(_pensando ? 'Analisando…' : 'Analisar'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _pergunta,
          enabled: !_pensando,
          minLines: 1,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Pergunta (opcional)',
            hintText: 'Ex.: por que acordo cansado? Como encaixar caminhadas na semana?',
          ),
        ),
        const SizedBox(height: 16),
        if (analises == null)
          const Center(child: CircularProgressIndicator())
        else if (analises.isEmpty)
          const Text('Nenhuma análise ainda. Sincronize o relógio em "Sono e corpo" e toque em Analisar.')
        else ...[
          if (analises.length > 1)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < analises.length; i++)
                  ChoiceChip(
                    label: Text(_titulo(analises[i])),
                    selected: i == _aberta,
                    onSelected: (_) => setState(() => _aberta = i),
                  ),
              ],
            ),
          const SizedBox(height: 12),
          _Analise(analise: analises[_aberta.clamp(0, analises.length - 1)]),
        ],
      ],
    );
  }

  String _titulo(Map<String, dynamic> a) {
    final d = DateTime.tryParse(a['criada_em'] as String? ?? '')?.toLocal();
    return d == null ? '?' : diaCurto(d);
  }
}

class _Analise extends StatelessWidget {
  const _Analise({required this.analise});

  final Map<String, dynamic> analise;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final de = DateTime.tryParse(analise['de'] as String? ?? '');
    final ate = DateTime.tryParse(analise['ate'] as String? ?? '');
    final pergunta = analise['pergunta'] as String? ?? '';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            if (de != null && ate != null)
              Text('Período: ${diaCurto(de)} a ${diaCurto(ate)}', style: tema.textTheme.bodySmall),
            if (pergunta.isNotEmpty) Text('Pergunta: $pergunta', style: tema.textTheme.bodySmall),
            VisualizadorMarkdown(texto: analise['texto'] as String? ?? ''),
          ],
        ),
      ),
    );
  }
}
