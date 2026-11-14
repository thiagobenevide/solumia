import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../exams_api.dart';
import '../models.dart';

const _letters = ['A', 'B', 'C', 'D', 'E'];

/// Mock exams tab of the exam: generate (general or per subject, by Claude in the board's style),
/// solve, see the commented grading and the performance per subject.
class MockExamsTab extends StatelessWidget {
  const MockExamsTab({super.key, required this.api, required this.exam});

  final ExamsApi api;
  final Exam exam;

  Future<void> _newExam(BuildContext context, Future<void> Function() reload) async {
    final request = await showDialog<(int, String)>(
      context: context,
      builder: (_) => _NewMockExam(subjects: [for (final d in exam.subjects) d.name]),
    );
    if (request == null) return;
    try {
      await api.newMockExam(exam.id, request.$1, discipline: request.$2);
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
    await reload();
  }

  @override
  Widget build(BuildContext context) {
    if (exam.structure == null) return const Center(child: Text('Gere o plano para criar simulados.'));
    return Sondagem<(List<MockExam>, Doc)>(
      intervalo: const Duration(seconds: 8),
      carregar: () => api.mockExams(exam.id),
      construir: (context, data, reload) {
        final (items, performance) = data;
        final topicName = Theme.of(context);
        final discs = [for (final d in performance['disciplinas'] as List) d as Doc];
        return Scaffold(
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _newExam(context, reload),
            icon: const Icon(Icons.add_task),
            label: const Text('Novo simulado'),
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              if (discs.isNotEmpty) ...[
                ListTile(title: Text('Desempenho por disciplina', style: topicName.textTheme.titleMedium), subtitle: const Text('Meta: 60% (nota mínima do edital)')),
                for (final d in discs)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Row(children: [
                      Expanded(flex: 3, child: Text(d['disciplina'] as String, overflow: TextOverflow.ellipsis)),
                      Expanded(
                        flex: 4,
                        child: LinearProgressIndicator(
                          value: (d['pct'] as int) / 100,
                          minHeight: 8,
                          borderRadius: BorderRadius.circular(4),
                          color: (d['pct'] as int) >= 60 ? Colors.green : topicName.colorScheme.error,
                        ),
                      ),
                      SizedBox(width: 72, child: Text('  ${d['pct']}% (${d['acertos']}/${d['total']})', style: topicName.textTheme.bodySmall)),
                    ]),
                  ),
                const Divider(height: 32),
              ],
              if (items.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'Nenhum simulado ainda. O Claude cria questões inéditas no estilo da banca, na proporção do edital, '
                    'dando preferência ao que você já estudou. Para provas reais anteriores, veja a aba Materiais.',
                    textAlign: TextAlign.center,
                  ),
                ),
              for (final s in items)
                ListTile(
                  leading: switch (s.state) {
                    'gerando' => const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                    'erro' => Icon(Icons.error_outline, color: topicName.colorScheme.error),
                    _ when s.answered => CircleAvatar(
                      backgroundColor: (s.result!['aprovado'] as bool) ? Colors.green : topicName.colorScheme.error,
                      child: Text('${s.result!['pct']}', style: const TextStyle(color: Colors.white, fontSize: 13)),
                    ),
                    _ => const Icon(Icons.play_circle_outline),
                  },
                  title: Text(s.title),
                  subtitle: Text(switch (s.state) {
                    'gerando' => 'O Claude está elaborando as questões…',
                    'erro' => s.error,
                    _ when s.answered =>
                      '${s.result!['acertos']}/${s.result!['total']} acertos · ${duration((s.result!['segundos'] as int) / 3600)}',
                    _ => '${s.questions.length} questões · ${s.minuteCount} min',
                  }),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      await api.deleteMockExam(exam.id, s.id);
                      await reload();
                    },
                  ),
                  onTap: s.state != 'pronto'
                      ? null
                      : () async {
                          await abrirTela<void>(context, (_) => SolveMockExam(api: api, examId: exam.id, mockExam: s), titulo: s.title);
                          await reload();
                        },
                ),
            ],
          ),
        );
      },
    );
  }
}

class _NewMockExam extends StatefulWidget {
  const _NewMockExam({required this.subjects});

  final List<String> subjects;

  @override
  State<_NewMockExam> createState() => _NewMockExamState();
}

class _NewMockExamState extends State<_NewMockExam> {
  int _n = 20;
  String _disc = '';

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Novo simulado'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _disc,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Conteúdo'),
          items: [
            const DropdownMenuItem(value: '', child: Text('Geral (proporção do edital)')),
            for (final d in widget.subjects) DropdownMenuItem(value: d, child: Text(d, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => setState(() => _disc = v ?? ''),
        ),
        const SizedBox(height: 12),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 10, label: Text('10')),
            ButtonSegment(value: 20, label: Text('20')),
            ButtonSegment(value: 30, label: Text('30')),
            ButtonSegment(value: 60, label: Text('60 (prova)')),
          ],
          selected: {_n},
          onSelectionChanged: (s) => setState(() => _n = s.first),
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(onPressed: () => Navigator.pop(context, (_n, _disc)), child: const Text('Gerar')),
    ],
  );
}

/// Solves a mock exam with a timer; on submit, shows the commented answer key.
class SolveMockExam extends StatefulWidget {
  const SolveMockExam({super.key, required this.api, required this.examId, required this.mockExam});

  final ExamsApi api;
  final String examId;
  final MockExam mockExam;

  @override
  State<SolveMockExam> createState() => _SolveMockExamState();
}

class _SolveMockExamState extends State<SolveMockExam> {
  late MockExam _s = widget.mockExam;
  late final List<int?> _resp = List.of(widget.mockExam.answers ?? List<int?>.filled(widget.mockExam.questions.length, null));
  final _clock = Stopwatch()..start();
  Timer? _tick;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _submit() async {
    final blanks = _resp.where((r) => r == null).length;
    if (blanks > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          content: Text('$blanks questão(ões) em branco. Entregar assim mesmo?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Voltar')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Entregar')),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _sending = true);
    try {
      final r = await widget.api.answer(widget.examId, _s.id, _resp, _clock.elapsed.inSeconds);
      _clock.stop();
      _tick?.cancel();
      setState(() => _s = r);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final topicName = Theme.of(context);
    final graded = _s.answered;
    final elapsed = _clock.elapsed;
    final limit = Duration(minutes: _s.minuteCount);
    final overran = !graded && elapsed > limit;
    final r = _s.result;
    return Scaffold(
      appBar: AppBar(
        title: Text(_s.title),
        actions: [
          if (!graded)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: Text(
                  '${elapsed.inMinutes}:${(elapsed.inSeconds % 60).toString().padLeft(2, '0')} / ${_s.minuteCount} min',
                  style: TextStyle(color: overran ? topicName.colorScheme.error : null, fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: graded
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  onPressed: _sending ? null : _submit,
                  icon: const Icon(Icons.send),
                  label: Text('Entregar (${_resp.where((x) => x != null).length}/${_resp.length} respondidas)'),
                ),
              ),
            ),
      body: LarguraMaxima(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (r != null)
              Card(
                color: (r['aprovado'] as bool) ? Colors.green.withValues(alpha: .12) : topicName.colorScheme.errorContainer,
                child: ListTile(
                  leading: Icon((r['aprovado'] as bool) ? Icons.emoji_events : Icons.trending_up, size: 36),
                  title: Text('${r['acertos']}/${r['total']} acertos · ${r['pct']}%', style: topicName.textTheme.titleLarge),
                  subtitle: Text(
                    '${(r['aprovado'] as bool) ? 'Acima' : 'Abaixo'} dos 60% exigidos · ${r['em_branco']} em branco · '
                    '${duration((r['segundos'] as int) / 3600)}',
                  ),
                ),
              ),
            for (final (i, q) in _s.questions.indexed)
              Card(
                margin: const EdgeInsets.symmetric(vertical: 8),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Questão ${q.n} · ${q.discipline}${q.topic.isEmpty ? '' : ' — ${q.topic}'}', style: topicName.textTheme.labelMedium),
                      const SizedBox(height: 8),
                      SelectableText(q.statement, style: topicName.textTheme.bodyLarge),
                      const SizedBox(height: 8),
                      for (final (a, alt) in q.choices.indexed)
                        _Choice(
                          letter: _letters[a],
                          text: alt,
                          checked: _resp[i] == a,
                          correct: graded ? q.correctAnswer == a : null,
                          onItemTap: graded ? null : () => setState(() => _resp[i] = _resp[i] == a ? null : a),
                        ),
                      if (graded && (q.comment ?? '').isNotEmpty) ...[
                        const Divider(),
                        Text('Comentário', style: topicName.textTheme.labelLarge),
                        SelectableText(q.comment!),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({required this.letter, required this.text, required this.checked, required this.correct, required this.onItemTap});

  final String letter, text;
  final bool checked;
  final bool? correct;
  final VoidCallback? onItemTap;

  @override
  Widget build(BuildContext context) {
    final topicName = Theme.of(context);
    final color = correct == true
        ? Colors.green
        : (correct == false && checked)
        ? topicName.colorScheme.error
        : checked
        ? topicName.colorScheme.primary
        : topicName.colorScheme.outlineVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onItemTap,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color, width: checked || correct == true ? 2 : 1),
            color: checked || correct == true ? color.withValues(alpha: .08) : null,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 13,
                backgroundColor: checked || correct == true ? color : topicName.colorScheme.surfaceContainerHighest,
                child: Text(letter, style: TextStyle(fontSize: 12, color: checked || correct == true ? Colors.white : null)),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(text)),
            ],
          ),
        ),
      ),
    );
  }
}

const _materialIcon = {
  'prova': Icons.assignment,
  'questoes': Icons.quiz_outlined,
  'apostila': Icons.menu_book,
  'video': Icons.smart_display_outlined,
  'resumo': Icons.notes,
  'edital': Icons.gavel,
};

/// Materials tab: past exams of the board, questions, handouts and videos found on the web by the local LLM.
class MaterialsTab extends StatelessWidget {
  const MaterialsTab({super.key, required this.api, required this.exam});

  final ExamsApi api;
  final Exam exam;

  @override
  Widget build(BuildContext context) => Sondagem<(String, List<StudyMaterial>)>(
    intervalo: const Duration(seconds: 8),
    carregar: () => api.materials(exam.id),
    construir: (context, data, reload) {
      final (state, itens) = data;
      final groups = <String, List<StudyMaterial>>{};
      for (final m in itens) {
        groups.putIfAbsent(m.type, () => []).add(m);
      }
      const names = {
        'prova': 'Provas anteriores', 'questoes': 'Questões', 'apostila': 'Apostilas e PDFs', 'video': 'Vídeos',
        'resumo': 'Resumos', 'edital': 'Editais', 'outro': 'Outros',
      };
      return ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          ListTile(
            title: const Text('Provas antigas da banca e materiais'),
            subtitle: Text(state == 'buscando'
                ? 'Buscando na web e classificando com a LLM local…'
                : 'Busca na web (DuckDuckGo) filtrada pela LLM local para ${exam.board.isEmpty ? 'este concurso' : 'a ${exam.board}'}.'),
            trailing: state == 'buscando'
                ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
                : FilledButton.tonalIcon(
                    onPressed: () async {
                      await api.searchMaterials(exam.id);
                      await reload();
                    },
                    icon: const Icon(Icons.travel_explore),
                    label: Text(itens.isEmpty ? 'Buscar' : 'Buscar de novo'),
                  ),
          ),
          for (final type in names.keys.where(groups.containsKey)) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(names[type]!, style: Theme.of(context).textTheme.titleSmall),
            ),
            for (final m in groups[type]!)
              ListTile(
                leading: Icon(_materialIcon[m.type] ?? Icons.link),
                title: Text(m.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text([if (m.discipline.isNotEmpty) m.discipline, m.descricao].join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: const Icon(Icons.open_in_new, size: 18),
                onTap: () => abrirLink(context, m.url),
              ),
          ],
        ],
      );
    },
  );
}
