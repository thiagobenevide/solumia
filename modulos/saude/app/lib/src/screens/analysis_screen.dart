import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../health_api.dart';
import '../dates.dart';

/// Analysis by the local LLM (PC worker): crosses sleep, activity and heart with mood, anxiety,
/// focus, habits, workouts, spending and routine, and proposes a plan for the week. Nothing leaves the house.
class AnalysisScreen extends StatefulWidget {
  const AnalysisScreen({super.key, required this.api});

  final HealthApi api;

  @override
  State<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends State<AnalysisScreen> {
  final _question = TextEditingController();
  int _days = 30;
  bool _thinking = false;
  List<Map<String, dynamic>>? _analyses;
  int _isOpen = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _question.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final a = await widget.api.analyses();
      if (mounted) setState(() => _analyses = a);
    } on ApiErro catch (e) {
      _notify(e);
      if (mounted) setState(() => _analyses ??= []);
    }
  }

  void _notify(Object e) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
  }

  Future<void> _analyze() async {
    setState(() => _thinking = true);
    try {
      await widget.api.analyze(_days, _question.text);
      _question.clear();
      _isOpen = 0;
      await _load();
    } on ApiErro catch (e) {
      _notify(e);
    } finally {
      if (mounted) setState(() => _thinking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final topic = Theme.of(context);
    final analyses = _analyses;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Análise de saúde', style: topic.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Feita pela LLM local no seu PC. Cruza o relógio com o diário, foco, hábitos, treinos, finanças, '
          'rotinas e estudos.',
          style: topic.textTheme.bodySmall,
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
              selected: {_days},
              onSelectionChanged: (s) => setState(() => _days = s.first),
            ),
            FilledButton.icon(
              onPressed: _thinking ? null : _analyze,
              icon: _thinking
                  ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.auto_awesome_outlined),
              label: Text(_thinking ? 'Analisando…' : 'Analisar'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _question,
          enabled: !_thinking,
          minLines: 1,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Pergunta (opcional)',
            hintText: 'Ex.: por que acordo cansado? Como encaixar caminhadas na semana?',
          ),
        ),
        const SizedBox(height: 16),
        if (analyses == null)
          const Center(child: CircularProgressIndicator())
        else if (analyses.isEmpty)
          const Text('Nenhuma análise ainda. Sincronize o relógio em "Sono e corpo" e toque em Analisar.')
        else ...[
          if (analyses.length > 1)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < analyses.length; i++)
                  ChoiceChip(
                    label: Text(_title(analyses[i])),
                    selected: i == _isOpen,
                    onSelected: (_) => setState(() => _isOpen = i),
                  ),
              ],
            ),
          const SizedBox(height: 12),
          _Analysis(analysis: analyses[_isOpen.clamp(0, analyses.length - 1)]),
        ],
      ],
    );
  }

  String _title(Map<String, dynamic> a) {
    final d = DateTime.tryParse(a['criada_em'] as String? ?? '')?.toLocal();
    return d == null ? '?' : shortDay(d);
  }
}

class _Analysis extends StatelessWidget {
  const _Analysis({required this.analysis});

  final Map<String, dynamic> analysis;

  @override
  Widget build(BuildContext context) {
    final topic = Theme.of(context);
    final de = DateTime.tryParse(analysis['de'] as String? ?? '');
    final ate = DateTime.tryParse(analysis['ate'] as String? ?? '');
    final question = analysis['pergunta'] as String? ?? '';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            if (de != null && ate != null)
              Text('Período: ${shortDay(de)} a ${shortDay(ate)}', style: topic.textTheme.bodySmall),
            if (question.isNotEmpty) Text('Pergunta: $question', style: topic.textTheme.bodySmall),
            VisualizadorMarkdown(texto: analysis['texto'] as String? ?? ''),
          ],
        ),
      ),
    );
  }
}
