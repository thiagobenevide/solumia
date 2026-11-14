import 'package:agent_core/agent_core.dart';
import 'package:agent_notas/agent_notas.dart';
import 'package:flutter/material.dart';

import '../health_api.dart';
import '../dates.dart';

/// Spiritual life: Bible reading plan with the reading of the day, reflections on the text and theology
/// studies. Reflections and studies are vault notes (tags `reflexao` and `teologia`).
class SpiritualScreen extends StatefulWidget {
  const SpiritualScreen({super.key, required this.api});

  final HealthApi api;

  @override
  State<SpiritualScreen> createState() => _SpiritualScreenState();
}

class _SpiritualScreenState extends State<SpiritualScreen> {
  HealthApi get api => widget.api;
  List<Map<String, dynamic>>? _plans;
  String? _plan;
  List<Map<String, dynamic>> _week = const [];
  List<NoteSummary> _reflections = const [];
  List<NoteSummary> _theology = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Map<String, dynamic>? get _current => _plans?.where((p) => p['id'] == _plan).firstOrNull;

  Future<void> _retry(Future<void> Function() f) async {
    try {
      await f();
    } on ApiErro catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _load() => _retry(() async {
    final plans = await api.plans();
    final reflections = await api.notesWithTag('reflexao');
    final theology = await api.notesWithTag('teologia');
    setState(() {
      _plans = plans;
      _reflections = reflections;
      _theology = theology;
      if (_current == null) _plan = plans.firstOrNull?['id'] as String?;
    });
    await _loadWeek();
  });

  Future<void> _loadWeek() async {
    final p = _current;
    if (p == null) return;
    final s = await api.planReadings(p['id'] as String, today(), addDays(today(), 6));
    if (mounted) setState(() => _week = s);
  }

  Future<void> _mark(String data, bool done) => _retry(() async {
    await api.markReading(_plan!, DateTime.parse(data), done);
    await _load();
  });

  Future<void> _newPlan() async {
    final scopes = await api.scopes();
    if (!mounted) return;
    var scope = 'biblia';
    var days = 365.0;
    var start = today();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Novo plano de leitura'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: scope,
                  decoration: const InputDecoration(labelText: 'O que ler'),
                  items: [
                    for (final e in scopes) DropdownMenuItem(value: e['id'] as String, child: Text(e['nome'] as String)),
                  ],
                  onChanged: (v) => setState(() => scope = v!),
                ),
                Text('Em ${days.round()} dias'),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final d in const [30, 90, 180, 365, 730])
                      ChoiceChip(label: Text('$d'), selected: days.round() == d, onSelected: (_) => setState(() => days = d.toDouble())),
                  ],
                ),
                Slider(value: days, min: 7, max: 730, onChanged: (v) => setState(() => days = v)),
                TextButton.icon(
                  icon: const Icon(Icons.event),
                  label: Text('Começa em ${longDay(start)}'),
                  onPressed: () async {
                    final d = await showDatePicker(context: context, initialDate: start, firstDate: DateTime(2020), lastDate: DateTime(2100));
                    if (d != null) setState(() => start = d);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Criar')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _retry(() async {
      final p = await api.createPlan({'escopo': scope, 'dias': days.round(), 'inicio': iso(start)});
      _plan = p['id'] as String;
      await _load();
    });
  }

  Future<void> _openNote(String id) async {
    final isOpen = OpenNote(api.notes)..open(id);
    await abrirTela(context, (_) => Scaffold(appBar: AppBar(title: const Text('Nota')), body: NoteEditor(openNote: isOpen)));
    await _load();
  }

  Future<void> _newNote(String tag, String title, String body) => _retry(() async {
    final note = await api.notes.create({'titulo': title, 'tags': [tag, 'espiritual'], 'corpo': body});
    await _openNote(note.id);
  });

  Future<void> _reflect(Map<String, dynamic> day) {
    final excerpts = (day['trechos'] as List).cast<String>();
    return _newNote(
      'reflexao',
      'Reflexão ${day['data']} — ${excerpts.join(', ')}',
      '**Leitura:** ${excerpts.join('; ')}\n\n## O que o texto diz\n\n## O que aprendo sobre Deus\n\n'
          '## Como aplico hoje\n\n## Oração\n',
    );
  }

  Future<void> _newStudy() async {
    final c = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Novo estudo de teologia'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Tema', hintText: 'ex.: Graça, Trindade, Escatologia'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Criar')),
        ],
      ),
    );
    if (title == null || title.trim().isEmpty) return;
    await _newNote(
      'teologia',
      title.trim(),
      '## Definição\n\n## Textos-chave\n\n## Visões e autores\n\n## Conclusões\n\n## Ligações\n',
    );
  }

  @override
  Widget build(BuildContext context) {
    final plans = _plans;
    if (plans == null) return const Center(child: CircularProgressIndicator());
    final topic = Theme.of(context);
    final p = _current;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final x in plans)
              ChoiceChip(
                label: Text(x['nome'] as String),
                selected: x['id'] == _plan,
                onSelected: (_) {
                  setState(() => _plan = x['id'] as String);
                  _retry(_loadWeek);
                },
              ),
            ActionChip(avatar: const Icon(Icons.add), label: const Text('Plano de leitura'), onPressed: _newPlan),
          ],
        ),
        if (p == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('Crie um plano (Bíblia em 1 ano, NT em 90 dias…) para ver a leitura de cada dia.', textAlign: TextAlign.center),
          )
        else ...[
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 6,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${p['nome_escopo']} · ${p['capitulos']} capítulos em ${p['dias']} dias',
                          style: topic.textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Excluir plano',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _retry(() async {
                          await api.deletePlan(p['id'] as String);
                          _plan = null;
                          await _load();
                        }),
                      ),
                    ],
                  ),
                  LinearProgressIndicator(value: (p['lidos'] as int) / (p['dias'] as int)),
                  Text('${p['lidos']} de ${p['dias']} dias lidos · termina em ${longDay(DateTime.parse(p['fim'] as String))}'),
                  if ((p['atrasados'] as List).isNotEmpty)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      leading: Icon(Icons.warning_amber, color: topic.colorScheme.error),
                      title: Text('${(p['atrasados'] as List).length} dias atrasados'),
                      children: [
                        for (final d in (p['atrasados'] as List).cast<String>().take(30))
                          CheckboxListTile(
                            dense: true,
                            value: false,
                            title: Text(longDay(DateTime.parse(d))),
                            onChanged: (_) => _mark(d, true),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          for (final day in _week)
            Card(
              shape: day['data'] == iso(today())
                  ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: topic.colorScheme.primary))
                  : null,
              child: ListTile(
                leading: Checkbox(value: day['feito'] as bool, onChanged: (v) => _mark(day['data'] as String, v ?? false)),
                title: Text((day['trechos'] as List).join('; ')),
                subtitle: Text('Dia ${day['dia']} · ${longDay(DateTime.parse(day['data'] as String))}'),
                trailing: IconButton(
                  tooltip: 'Escrever reflexão',
                  icon: const Icon(Icons.edit_note),
                  onPressed: () => _reflect(day),
                ),
              ),
            ),
        ],
        const SizedBox(height: 16),
        _section('Reflexões', _reflections, null),
        _section('Teologia', _theology, _newStudy),
      ],
    );
  }

  Widget _section(String title, List<NoteSummary> notes, VoidCallback? create) => Card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: Text(title, style: Theme.of(context).textTheme.titleMedium),
          trailing: create == null ? null : IconButton(icon: const Icon(Icons.add), tooltip: 'Novo estudo', onPressed: create),
        ),
        if (notes.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(create == null ? 'Use o ✎ da leitura do dia para escrever uma reflexão.' : 'Nenhum estudo ainda.'),
          ),
        for (final n in notes.take(20))
          ListTile(
            dense: true,
            leading: const Icon(Icons.sticky_note_2_outlined),
            title: Text(n.title),
            subtitle: n.updated == null ? null : Text(longDay(n.updated!.toLocal())),
            onTap: () => _openNote(n.id),
          ),
      ],
    ),
  );
}
