import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../exams_api.dart';
import '../models.dart';
import 'exam_screen.dart';
import 'radar_screen.dart';
import 'rumors_screen.dart';

Color levelColor(BuildContext context, String level) => switch (level) {
  'critico' => Theme.of(context).colorScheme.error,
  'aviso' => Colors.orange,
  _ => Theme.of(context).colorScheme.primary,
};

IconData levelIcon(String level) => switch (level) {
  'critico' => Icons.error_outline,
  'aviso' => Icons.warning_amber,
  _ => Icons.info_outline,
};

/// List of exams with the day's alerts on top; "Novo concurso" registers, uploads the notice and
/// already asks Claude for the plan.
class ExamsScreen extends StatelessWidget {
  const ExamsScreen({super.key, required this.api});

  final ExamsApi api;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Column(
      children: [
        const TabBar(tabs: [
          Tab(icon: Icon(Icons.school_outlined), text: 'Meus concursos'),
          Tab(icon: Icon(Icons.map_outlined), text: 'Radar TI · mapa'),
          Tab(icon: Icon(Icons.campaign_outlined), text: 'Rumores TI'),
        ]),
        Expanded(
          child: Builder(
            builder: (context) => TabBarView(
              physics: const NeverScrollableScrollPhysics(), // the map uses dragging
              children: [
                MyExams(api: api),
                RadarScreen(
                  api: api,
                  onFollow: (id) {
                    DefaultTabController.of(context).animateTo(0);
                    abrirTela<void>(context, (_) => ExamScreen(api: api, id: id), titulo: 'Concurso', icone: Icons.school_outlined);
                  },
                ),
                RumorsScreen(api: api),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

/// List of followed exams with the day's alerts on top.
class MyExams extends StatelessWidget {
  const MyExams({super.key, required this.api});

  final ExamsApi api;

  Future<(List<ExamSummary>, List<Alert>)> _load() async => (await api.list(), await api.alerts());

  Future<void> _open(BuildContext context, String id, Future<void> Function() reload) async {
    await abrirTela<void>(context, (_) => ExamScreen(api: api, id: id), titulo: 'Concurso', icone: Icons.school_outlined);
    await reload();
  }

  @override
  Widget build(BuildContext context) => Sondagem<(List<ExamSummary>, List<Alert>)>(
    intervalo: const Duration(seconds: 30),
    carregar: _load,
    construir: (context, data, reload) {
      final (exams, alerts) = data;
      return Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () async {
            final id = await showDialog<String>(context: context, builder: (_) => NewExam(api: api));
            if (id != null && context.mounted) await _open(context, id, reload);
          },
          icon: const Icon(Icons.add),
          label: const Text('Novo concurso'),
        ),
        body: LarguraMaxima(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
              for (final a in alerts.where((a) => a.level != 'info'))
                ListTile(
                  dense: true,
                  leading: Icon(levelIcon(a.level), color: levelColor(context, a.level)),
                  title: Text(a.text),
                  onTap: a.examId == null ? null : () => _open(context, a.examId!, reload),
                ),
              if (exams.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'Nenhum concurso ainda. Cadastre um e envie o edital: o Claude monta o fluxo de estudo, '
                    'as tarefas diárias até 1 semana antes da prova e os alertas de prazos.',
                    textAlign: TextAlign.center,
                  ),
                ),
              for (final c in exams) _ExamCard(c: c, open: () => _open(context, c.id, reload)),
            ],
          ),
        ),
      );
    },
  );
}

class _ExamCard extends StatelessWidget {
  const _ExamCard({required this.c, required this.open});

  final ExamSummary c;
  final VoidCallback open;

  @override
  Widget build(BuildContext context) {
    final topicName = Theme.of(context);
    final due = c.nextDeadline;
    final state = switch (c.state) {
      'gerando' => 'O Claude está montando o plano…',
      'erro' => 'Falha ao gerar o plano',
      'sem_plano' => c.hasNotice ? 'Plano ainda não gerado' : 'Envie o edital',
      _ => '${c.doneCount}/${c.tasks} tarefas${c.overdue > 0 ? ' · ${c.overdue} atrasada(s)' : ''}',
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: open,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c.name, style: topicName.textTheme.titleMedium),
                    Text([c.cargo, if (c.board.isNotEmpty) c.board].join(' · '), style: topicName.textTheme.bodySmall),
                    const SizedBox(height: 8),
                    if (c.state == 'pronto') LinearProgressIndicator(value: c.progress),
                    if (c.state == 'gerando') const LinearProgressIndicator(),
                    const SizedBox(height: 4),
                    Text(state, style: topicName.textTheme.bodySmall),
                    if (due != null)
                      Text(
                        'Próximo prazo: ${due.title} — ${dataBr(due.data)}${due.time.isEmpty ? '' : ' ${due.time}'}',
                        style: topicName.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Column(
                children: [
                  Text(c.daysToExam?.toString() ?? '—', style: topicName.textTheme.headlineMedium),
                  Text(c.examDate == null ? 'sem data' : 'dias · ${dataBr(c.examDate)}', style: topicName.textTheme.bodySmall),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Registration: exam data + notice (link or PDF). On save, creates it, uploads the notice and asks for the
/// plan; returns the exam id.
class NewExam extends StatefulWidget {
  const NewExam({super.key, required this.api});

  final ExamsApi api;

  @override
  State<NewExam> createState() => _NewExamState();
}

class _NewExamState extends State<NewExam> {
  final _nome = TextEditingController();
  final _cargo = TextEditingController();
  final _board = TextEditingController();
  final _link = TextEditingController();
  final _weekday = TextEditingController(text: '120');
  final _weekend = TextEditingController(text: '240');
  final _notes = TextEditingController();
  DateTime? _examDate;
  (String, List<int>)? _pdf;
  String? _stage, _error;

  Future<void> _pickPdf() async {
    final r = await FilePicker.pickFiles(dialogTitle: 'Edital (PDF)', type: FileType.custom, allowedExtensions: ['pdf']);
    if (r.isEmpty) return;
    final bytes = await r.first.xFile.readAsBytes();
    setState(() => _pdf = (r.first.name, bytes));
  }

  Future<void> _save() async {
    if (_nome.text.trim().isEmpty || _cargo.text.trim().isEmpty) {
      setState(() => _error = 'Informe o nome do concurso e o cargo/especialidade.');
      return;
    }
    if (_pdf == null && _link.text.trim().isEmpty) {
      setState(() => _error = 'Cole o link do edital ou escolha o PDF.');
      return;
    }
    final api = widget.api;
    String? id;
    try {
      setState(() {
        _stage = 'Criando o concurso…';
        _error = null;
      });
      final c = await api.create({
        'nome': _nome.text.trim(),
        'cargo': _cargo.text.trim(),
        'banca': _board.text.trim(),
        'data_prova': ?(_examDate == null ? null : iso(_examDate!)),
        'minutos_util': int.tryParse(_weekday.text) ?? 120,
        'minutos_fds': int.tryParse(_weekend.text) ?? 240,
        'observacoes': _notes.text.trim(),
      });
      id = c.id;
      setState(() => _stage = 'Enviando o edital…');
      if (_pdf case (final name, final bytes)) {
        await api.uploadNotice(id, name, bytes);
      } else {
        await api.noticeByLink(id, _link.text.trim());
      }
      setState(() => _stage = 'Pedindo o plano ao Claude…');
      await api.generatePlan(id);
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      // exam created but notice/plan failed: opens it anyway, it can be retried inside
      if (id != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
        Navigator.pop(context, id);
      } else {
        setState(() {
          _stage = null;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _stage != null;
    return AlertDialog(
      title: const Text('Novo concurso'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: _nome, decoration: const InputDecoration(labelText: 'Concurso (ex.: TJPB 2026)')),
              TextField(controller: _cargo, decoration: const InputDecoration(labelText: 'Cargo / especialidade')),
              TextField(controller: _board, decoration: const InputDecoration(labelText: 'Banca (opcional)')),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: Text(_examDate == null ? 'Data da prova: a IA tira do edital' : 'Prova: ${dataBr(iso(_examDate!))}')),
                  TextButton(
                    onPressed: () async {
                      final d = await showDatePicker(
                        context: context,
                        firstDate: DateTime.now(),
                        lastDate: DateTime.now().add(const Duration(days: 730)),
                      );
                      if (d != null) setState(() => _examDate = d);
                    },
                    child: const Text('Escolher'),
                  ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _weekday,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Min/dia útil'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _weekend,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Min/dia fim de semana'),
                    ),
                  ),
                ],
              ),
              TextField(
                controller: _notes,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'Sobre você (base, pontos fracos) — opcional'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _link,
                enabled: _pdf == null,
                decoration: const InputDecoration(labelText: 'Link do edital (PDF)'),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton.icon(onPressed: busy ? null : _pickPdf, icon: const Icon(Icons.picture_as_pdf), label: const Text('Escolher PDF')),
                  const SizedBox(width: 8),
                  if (_pdf != null) Expanded(child: Text(_pdf!.$1, overflow: TextOverflow.ellipsis)),
                ],
              ),
              if (_stage != null) ...[const SizedBox(height: 12), const LinearProgressIndicator(), Text(_stage!)],
              if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: busy ? null : _save, child: const Text('Criar e gerar plano')),
      ],
    );
  }
}
