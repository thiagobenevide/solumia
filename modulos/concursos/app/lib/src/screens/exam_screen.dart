import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../exams_api.dart';
import '../models.dart';
import 'radar_screen.dart' show distanceColor;
import 'mock_exams_screen.dart';

const _typeIcon = {
  'conteudo': Icons.menu_book_outlined,
  'revisao': Icons.replay,
  'simulado': Icons.timer_outlined,
  'discursiva': Icons.edit_note,
  'final': Icons.flag_outlined,
};

/// One exam: what to study today (and what is late), the weekly schedule until the exam, the knowledge
/// flow (subjects → topics in Claude's order) and the notice deadlines.
class ExamScreen extends StatefulWidget {
  const ExamScreen({super.key, required this.api, required this.id});

  final ExamsApi api;
  final String id;

  @override
  State<ExamScreen> createState() => _ExamScreenState();
}

class _ExamScreenState extends State<ExamScreen> {
  ExamsApi get api => widget.api;

  Future<void> _act(Future<void> Function() f, Future<void> Function() reload) async {
    try {
      await f();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
    await reload();
  }

  Future<void> _newNotice(Future<void> Function() reload) async {
    final r = await FilePicker.pickFiles(dialogTitle: 'Edital (PDF)', type: FileType.custom, allowedExtensions: ['pdf']);
    if (r.isEmpty) return;
    final bytes = await r.first.xFile.readAsBytes();
    await _act(() => api.uploadNotice(widget.id, r.first.name, bytes), reload);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Excluir concurso?'),
        content: const Text('Apaga o edital, o plano e as tarefas.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Excluir')),
        ],
      ),
    );
    if (ok != true) return;
    await api.delete(widget.id);
    if (mounted) Navigator.maybePop(context);
  }

  @override
  Widget build(BuildContext context) => Sondagem<Exam>(
    intervalo: const Duration(seconds: 10),
    carregar: () => api.fetch(widget.id),
    construir: (context, c, reload) => DefaultTabController(
      length: 6,
      child: Scaffold(
        appBar: AppBar(
          title: Text(c.name),
          actions: [
            if (c.state == 'pronto')
              IconButton(
                tooltip: 'Replanejar: redistribuir o que não foi feito de hoje até a prova',
                icon: const Icon(Icons.event_repeat),
                onPressed: () => _act(() => api.replan(c.id), reload),
              ),
            PopupMenuButton<String>(
              onSelected: (v) => switch (v) {
                'gerar' => _act(() => api.generatePlan(c.id), reload),
                'edital' => _newNotice(reload),
                _ => _delete(),
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'gerar', enabled: !c.generating && c.noticeName != null, child: const Text('Gerar o plano de novo (Claude)')),
                const PopupMenuItem(value: 'edital', child: Text('Trocar o edital (PDF)')),
                const PopupMenuItem(value: 'excluir', child: Text('Excluir concurso')),
              ],
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Hoje'),
              Tab(text: 'Cronograma'),
              Tab(text: 'Fluxo'),
              Tab(text: 'Simulados'),
              Tab(text: 'Materiais'),
              Tab(text: 'Prazos'),
            ],
          ),
        ),
        body: Column(
          children: [
            _Header(c: c, generate: () => _act(() => api.generatePlan(c.id), reload)),
            Expanded(
              child: TabBarView(
                children: [
                  _TodayTab(c: c, mark: (t, v) => _act(() => api.mark(c.id, t.id, v), reload)),
                  _ScheduleTab(c: c, mark: (t, v) => _act(() => api.mark(c.id, t.id, v), reload)),
                  _FlowTab(c: c),
                  MockExamsTab(api: api, exam: c),
                  MaterialsTab(api: api, exam: c),
                  _DeadlinesTab(
                    c: c,
                    adicionar: (p) => _act(() => api.addDeadline(c.id, p), reload),
                    remover: (p) => _act(() => api.removeDeadline(c.id, p.id), reload),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.c, required this.generate});

  final Exam c;
  final VoidCallback generate;

  @override
  Widget build(BuildContext context) {
    final s = c.status;
    final topicName = Theme.of(context);
    final warning = switch (c.state) {
      'gerando' => const ListTile(
        leading: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2)),
        title: Text('O Claude está lendo o edital e montando o fluxo de estudo (alguns minutos)…'),
      ),
      'erro' => ListTile(
        leading: Icon(Icons.error_outline, color: topicName.colorScheme.error),
        title: Text('Falha ao gerar o plano: ${c.error}'),
        trailing: TextButton(onPressed: generate, child: const Text('Tentar de novo')),
      ),
      'sem_plano' => ListTile(
        leading: const Icon(Icons.auto_awesome),
        title: Text(c.noticeName == null ? 'Envie o edital (menu ⋮).' : 'Edital: ${c.noticeName}'),
        trailing: c.noticeName == null ? null : FilledButton(onPressed: generate, child: const Text('Gerar plano')),
      ),
      _ => null,
    };
    final r = c.planSummary;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Wrap(
            spacing: 24,
            runSpacing: 4,
            children: [
              Text('${c.cargo}${c.board.isEmpty ? '' : ' · ${c.board}'}'),
              Text('Prova: ${dataBr(c.examDate)}${s.daysToExam == null ? '' : ' (${s.daysToExam} dias)'}'),
              if (s.tasks > 0) Text('${s.doneCount}/${s.tasks} tarefas · ${s.overdue} atrasada(s)'),
              if (r != null) Text('Estudo até ${dataBr(r['fim_estudo'] as String?)}'),
              if (r != null && (r['fator'] as num) < 1)
                Text(
                  'Tempo curto: tópicos comprimidos a ${((r['fator'] as num) * 100).round()}%',
                  style: TextStyle(color: topicName.colorScheme.error),
                ),
            ],
          ),
        ),
        if (c.radar != null) _Sheet(radar: c.radar!),
        ?warning,
      ],
    );
  }
}

class _TaskItem extends StatelessWidget {
  const _TaskItem({required this.t, required this.mark, this.comData = false});

  final Task t;
  final void Function(Task, bool) mark;
  final bool comData;

  @override
  Widget build(BuildContext context) => CheckboxListTile(
    value: t.done,
    onChanged: (v) => mark(t, v ?? false),
    controlAffinity: ListTileControlAffinity.leading,
    secondary: Icon(_typeIcon[t.type] ?? Icons.task_alt),
    title: Text(t.title, style: t.done ? const TextStyle(decoration: TextDecoration.lineThrough) : null),
    subtitle: Text(
      [
        if (comData) dataBr(t.data, short: true),
        if (t.discipline.isNotEmpty) t.discipline,
        '${t.minuteCount} min',
        if (t.detail.isNotEmpty) t.detail,
      ].join(' · '),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    ),
  );
}

class _TodayTab extends StatelessWidget {
  const _TodayTab({required this.c, required this.mark});

  final Exam c;
  final void Function(Task, bool) mark;

  @override
  Widget build(BuildContext context) {
    final today = iso(DateTime.now());
    final overdue = c.tasks.where((t) => !t.done && t.data.compareTo(today) < 0).toList();
    final fromToday = c.tasks.where((t) => t.data == today).toList();
    final upcoming = c.tasks.where((t) => t.data.compareTo(today) > 0).take(5).toList();
    final minuteCount = fromToday.fold(0, (s, t) => s + t.minuteCount);
    return ListView(
      children: [
        ListTile(title: Text('Hoje · $minuteCount min', style: Theme.of(context).textTheme.titleMedium)),
        if (fromToday.isEmpty) const ListTile(title: Text('Nada planejado para hoje.')),
        for (final t in fromToday) _TaskItem(t: t, mark: mark),
        if (overdue.isNotEmpty) ...[
          ListTile(
            title: Text('Atrasadas (${overdue.length})', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            subtitle: const Text('Faça hoje ou use Replanejar (ícone no topo) para redistribuir até a prova.'),
          ),
          for (final t in overdue) _TaskItem(t: t, mark: mark, comData: true),
        ],
        if (upcoming.isNotEmpty) ...[
          const ListTile(title: Text('Próximas')),
          for (final t in upcoming) _TaskItem(t: t, mark: mark, comData: true),
        ],
      ],
    );
  }
}

class _ScheduleTab extends StatelessWidget {
  const _ScheduleTab({required this.c, required this.mark});

  final Exam c;
  final void Function(Task, bool) mark;

  @override
  Widget build(BuildContext context) {
    // groups by week (Monday to Sunday)
    final weeks = <String, List<Task>>{};
    for (final t in c.tasks) {
      final d = DateTime.parse(t.data);
      weeks.putIfAbsent(iso(d.subtract(Duration(days: d.weekday - 1))), () => []).add(t);
    }
    final today = iso(DateTime.now());
    return ListView(
      children: [
        for (final MapEntry(key: start, value: ts) in weeks.entries)
          ExpansionTile(
            initiallyExpanded: ts.any((t) => t.data == today),
            title: Text('Semana de ${dataBr(start, short: true)}'),
            subtitle: Text(
              '${ts.where((t) => t.done).length}/${ts.length} tarefas · '
              '${(ts.fold(0, (s, t) => s + t.minuteCount) / 60).toStringAsFixed(1)} h',
            ),
            children: [for (final t in ts) _TaskItem(t: t, mark: mark, comData: true)],
          ),
      ],
    );
  }
}

class _FlowTab extends StatelessWidget {
  const _FlowTab({required this.c});

  final Exam c;

  @override
  Widget build(BuildContext context) {
    final e = c.structure;
    if (e == null) return const Center(child: Text('O fluxo aparece quando o plano for gerado.'));
    final topicName = Theme.of(context);
    // topic completed = all its content blocks done (key "disciplina|tópico|parte")
    bool completed(String disc, String topic) {
      final blocks = c.tasks.where((t) => t.key?.startsWith('$disc|$topic|') ?? false);
      return blocks.isNotEmpty && blocks.every((t) => t.done);
    }

    final essay = e['discursiva'] as Doc?;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if ((e['resumo'] as String? ?? '').isNotEmpty) ListTile(title: Text(e['resumo'] as String)),
        if ((e['formato_prova'] as String? ?? '').isNotEmpty)
          ListTile(leading: const Icon(Icons.assignment_outlined), title: Text(e['formato_prova'] as String), subtitle: Text(e['horario_prova'] as String? ?? '')),
        for (final d in c.subjects)
          Builder(builder: (context) {
            final doneItems = d.topics.where((t) => completed(d.name, t.title)).length;
            return ExpansionTile(
              title: Text(d.name),
              subtitle: Text('${d.questions} questões · $doneItems/${d.topics.length} tópicos · ${d.modulo}'),
              children: [
                for (final (i, t) in d.topics.indexed)
                  ListTile(
                    leading: CircleAvatar(
                      radius: 14,
                      backgroundColor: completed(d.name, t.title) ? topicName.colorScheme.primary : null,
                      child: completed(d.name, t.title) ? const Icon(Icons.check, size: 16) : Text('${i + 1}'),
                    ),
                    title: Text(t.title),
                    subtitle: Text('${t.hours.toStringAsFixed(0)} h · prioridade ${t.priority}\n${t.content}'),
                    isThreeLine: true,
                  ),
              ],
            );
          }),
        if (essay != null)
          ExpansionTile(
            title: const Text('Discursiva'),
            subtitle: Text(essay['descricao'] as String? ?? ''),
            children: [for (final s in essay['temas_provaveis'] as List? ?? const []) ListTile(dense: true, title: Text('• $s'))],
          ),
        if (c.strategy.isNotEmpty)
          ExpansionTile(
            initiallyExpanded: true,
            title: const Text('Estratégia'),
            children: [for (final s in c.strategy) ListTile(dense: true, title: Text('• $s'))],
          ),
      ],
    );
  }
}

class _DeadlinesTab extends StatelessWidget {
  const _DeadlinesTab({required this.c, required this.adicionar, required this.remover});

  final Exam c;
  final void Function(Doc) adicionar;
  final void Function(Deadline) remover;

  Future<void> _newExam(BuildContext context) async {
    final title = TextEditingController();
    DateTime? data;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Novo prazo'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: title, decoration: const InputDecoration(labelText: 'O que fazer')),
              TextButton(
                onPressed: () async {
                  final d = await showDatePicker(
                    context: ctx,
                    firstDate: DateTime.now().subtract(const Duration(days: 30)),
                    lastDate: DateTime.now().add(const Duration(days: 730)),
                  );
                  if (d != null) set(() => data = d);
                },
                child: Text(data == null ? 'Escolher a data' : dataBr(iso(data!))),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Adicionar')),
          ],
        ),
      ),
    );
    if (ok == true && data != null && title.text.trim().isNotEmpty) {
      adicionar({'titulo': title.text.trim(), 'data': iso(data!)});
    }
  }

  @override
  Widget build(BuildContext context) {
    final today = iso(DateTime.now());
    final topicName = Theme.of(context);
    return Scaffold(
      floatingActionButton: FloatingActionButton.small(
        tooltip: 'Novo prazo',
        onPressed: () => _newExam(context),
        child: const Icon(Icons.add_alarm),
      ),
      body: ListView(
        children: [
          for (final p in c.deadlines)
            Builder(builder: (context) {
              final passed = p.data.compareTo(today) < 0;
              final days = DateTime.parse(p.data).difference(DateTime.parse(today)).inDays;
              final color = passed ? topicName.disabledColor : days <= 2 ? topicName.colorScheme.error : days <= 7 ? Colors.orange : null;
              return ListTile(
                leading: Icon(p.type == 'prova' ? Icons.flag : Icons.event, color: color),
                title: Text(p.title, style: TextStyle(color: passed ? topicName.disabledColor : null)),
                subtitle: Text([
                  '${dataBr(p.data)}${p.time.isEmpty ? '' : ' ${p.time}'}${passed ? '' : ' · em $days dia(s)'}',
                  if (p.detail.isNotEmpty) p.detail,
                ].join('\n')),
                trailing: p.origin == 'manual'
                    ? IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => remover(p))
                    : null,
              );
            }),
        ],
      ),
    );
  }
}

/// Sheet of an exam coming from the radar: chosen opening, salary, registration, exam and the nearest location.
class _Sheet extends StatelessWidget {
  const _Sheet({required this.radar});

  final Doc radar;

  @override
  Widget build(BuildContext context) {
    final topicName = Theme.of(context);
    final opening = radar['vaga'] == null ? null : ItJob.fromJson(radar['vaga'] as Doc);
    final local = radar['mais_proximo'] == null ? null : Local.fromJson(radar['mais_proximo'] as Doc);
    Widget dado(IconData i, String t, {Color? color}) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [Icon(i, size: 16, color: color ?? topicName.colorScheme.primary), const SizedBox(width: 4), Text(t)],
    );
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 18,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (opening != null) dado(Icons.work_outline, '${opening.openings} vaga(s)${opening.reserveList ? ' + CR' : ''}'),
            if (opening != null && opening.salary > 0) dado(Icons.payments_outlined, real(opening.salary)),
            if (radar['inscricoes_fim'] != null)
              dado(Icons.event_available, 'Inscrições ${radar['inscricoes_inicio'] == null || radar['inscricoes_inicio'] == '' ? 'até' : '${dataBr(radar['inscricoes_inicio'] as String, short: true)} a'} ${dataBr(radar['inscricoes_fim'] as String)}'),
            if ((radar['horario_prova'] as String? ?? '').isNotEmpty) dado(Icons.schedule, 'Prova ${radar['horario_prova']}'),
            if (local != null)
              dado(Icons.place, '${local.name} · ${local.km ?? local.straightKm} km${local.hours == null ? '' : ' · ${duration(local.hours!)}'}', color: distanceColor(local.km)),
            if ((radar['taxa'] as String? ?? '').isNotEmpty) dado(Icons.receipt_long, 'Taxa ${radar['taxa']}'),
            if ((radar['link_inscricao'] as String? ?? '').isNotEmpty)
              TextButton.icon(onPressed: () => abrirLink(context, radar['link_inscricao'] as String), icon: const Icon(Icons.how_to_reg, size: 16), label: const Text('Inscrição')),
            TextButton.icon(onPressed: () => abrirLink(context, radar['url'] as String), icon: const Icon(Icons.article_outlined, size: 16), label: const Text('Notícia')),
          ],
        ),
      ),
    );
  }
}
