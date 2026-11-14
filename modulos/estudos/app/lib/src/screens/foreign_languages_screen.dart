import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../studies_api.dart';
import '../models.dart';

const _months = ['jan', 'fev', 'mar', 'abr', 'mai', 'jun', 'jul', 'ago', 'set', 'out', 'nov', 'dez'];
const _days = ['seg', 'ter', 'qua', 'qui', 'sex', 'sáb', 'dom'];

String _short(DateTime d) => '${d.day} ${_months[d.month - 1]}';
String _withYear(DateTime d) => '${_months[d.month - 1]}/${d.year}';
DateTime _today() => DateUtils.dateOnly(DateTime.now());
DateTime _monday(DateTime d) => DateTime(d.year, d.month, d.day - (d.weekday - 1));

/// Language tracks: pick the language, the starting and target levels, the pace; the server generates the
/// day and week schedule. Marking the day as done adds the hours and moves the A1–C2 milestones.
class ForeignLanguagesScreen extends StatefulWidget {
  const ForeignLanguagesScreen({super.key, required this.api, required this.options});

  final StudiesApi api;
  final StudyOptions options;

  @override
  State<ForeignLanguagesScreen> createState() => _ForeignLanguagesScreenState();
}

class _ForeignLanguagesScreenState extends State<ForeignLanguagesScreen> {
  StudiesApi get api => widget.api;
  List<Track>? _tracks;
  String? _selectedReading;
  bool _week = true;
  DateTime _focus = _today();
  List<StudyDay> _schedule = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Track? get _track => _tracks?.where((t) => t.id == _selectedReading).firstOrNull;

  Future<void> _retry(Future<void> Function() action) async {
    try {
      await action();
    } on ApiErro catch (e) {
      if (!mounted) return;
      if (_tracks == null) {
        setState(() => _error = '$e');
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _load() => _retry(() async {
    final t = await api.tracks();
    setState(() {
      _tracks = t;
      _error = null;
      if (_track == null) _selectedReading = t.firstOrNull?.id;
    });
    await _loadDays();
  });

  Future<void> _loadDays() async {
    final t = _track;
    if (t == null) return setState(() => _schedule = const []);
    final de = _week ? _monday(_focus) : _focus;
    final ate = _week ? de.add(const Duration(days: 6)) : _focus;
    final days = await api.schedule(t.id, de, ate);
    if (mounted) setState(() => _schedule = days);
  }

  void _mover(int direction) {
    setState(() => _focus = DateTime(_focus.year, _focus.month, _focus.day + direction * (_week ? 7 : 1)));
    _retry(_loadDays);
  }

  Future<void> _mark(StudyDay d) => _retry(() async {
    final t = await api.register(_selectedReading!, d.data, d.done ? 0 : d.minutes);
    setState(() => _tracks = [for (final x in _tracks!) x.id == t.id ? t : x]);
    await _loadDays();
  });

  Future<void> _form([Track? current]) async {
    final data = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _TrackForm(options: widget.options, current: current),
    );
    if (data == null) return;
    await _retry(() async {
      final t = current == null ? await api.createTrack(data) : await api.editTrack(current.id, data);
      _selectedReading = t.id;
      await _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, spacing: 12, children: [Text(_error!), FilledButton(onPressed: _load, child: const Text('Tentar de novo'))]));
    }
    final tracks = _tracks;
    if (tracks == null) return const Center(child: CircularProgressIndicator());
    if (tracks.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            const Text('Crie uma trilha (inglês, francês, espanhol ou português) para gerar o cronograma.'),
            FilledButton.icon(onPressed: _form, icon: const Icon(Icons.add), label: const Text('Nova trilha')),
          ],
        ),
      );
    }
    final t = _track!;
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final x in tracks)
              ChoiceChip(
                avatar: CircleAvatar(child: Text(x.language.toUpperCase(), style: const TextStyle(fontSize: 9))),
                label: Text('${x.name} · ${x.currentLevel}'),
                selected: x.id == _selectedReading,
                onSelected: (_) {
                  setState(() => _selectedReading = x.id);
                  _retry(_loadDays);
                },
              ),
            ActionChip(avatar: const Icon(Icons.add), label: const Text('Nova trilha'), onPressed: _form),
          ],
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${t.name}: ${t.currentLevel} → ${t.targetLevel} · ${t.hours.toStringAsFixed(1)} h estudadas',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    PopupMenuButton<String>(
                      onSelected: (v) async {
                        if (v == 'editar') return _form(t);
                        await _retry(() async {
                          await api.deleteTrack(t.id);
                          _selectedReading = null;
                          await _load();
                        });
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'editar', child: Text('Editar ritmo e níveis')),
                        PopupMenuItem(value: 'excluir', child: Text('Excluir trilha')),
                      ],
                    ),
                  ],
                ),
                Text(
                  '${t.minutesPerDay} min/dia · ${[for (final d in t.weekdays) _days[d - 1]].join(', ')}',
                  style: theme.textTheme.bodySmall,
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final m in t.marcos)
                      Chip(
                        avatar: Icon(m.isCompleted ? Icons.check_circle : Icons.flag_outlined, size: 18),
                        label: Text(
                          m.isCompleted
                              ? m.level
                              : '${m.level} · ${m.hoursLeft.round()} h · ${m.forecast == null ? '—' : _withYear(m.forecast!)}',
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        // Wrap: on the phone the Dia/Semana selector goes down to the next line
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          runSpacing: 4,
          children: [
            IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => _mover(-1)),
            IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => _mover(1)),
            TextButton(
              onPressed: () {
                setState(() => _focus = _today());
                _retry(_loadDays);
              },
              child: const Text('Hoje'),
            ),
            Text(
              _week ? 'Semana de ${_short(_monday(_focus))}' : '${_days[_focus.weekday - 1]}, ${_short(_focus)}',
              style: theme.textTheme.titleSmall,
            ),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('Dia')),
                ButtonSegment(value: true, label: Text('Semana')),
              ],
              selected: {_week},
              onSelectionChanged: (s) {
                setState(() => _week = s.first);
                _retry(_loadDays);
              },
            ),
          ],
        ),
        if (_schedule.isEmpty)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('Sem estudo marcado neste período.'))),
        for (final d in _schedule) _day(d),
      ],
    );
  }

  Widget _day(StudyDay d) {
    final theme = Theme.of(context);
    final isToday = DateUtils.isSameDay(d.data, _today());
    return Card(
      shape: isToday
          ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: theme.colorScheme.primary))
          : null,
      child: ExpansionTile(
        initiallyExpanded: !_week || isToday,
        leading: Checkbox(value: d.done, onChanged: (_) => _mark(d)),
        title: Text('${_days[d.data.weekday - 1]}, ${_short(d.data)} · ${d.minutes} min'),
        subtitle: Text('${d.level} · ${d.theme}'),
        children: [
          for (final b in d.blocks)
            ListTile(
              dense: true,
              leading: Icon(_icon(b.skill)),
              title: Text('${b.title} · ${b.minutes} min'),
              subtitle: Text(b.descricao),
            ),
        ],
      ),
    );
  }

  static IconData _icon(String h) => switch (h) {
    'gramatica' => Icons.rule,
    'escuta' => Icons.headphones,
    'leitura' => Icons.chrome_reader_mode_outlined,
    'fala' => Icons.record_voice_over_outlined,
    'escrita' => Icons.edit_note,
    'imersao' => Icons.movie_outlined,
    'revisao' => Icons.replay,
    'flashcards' => Icons.style_outlined,
    _ => Icons.translate,
  };
}

class _TrackForm extends StatefulWidget {
  const _TrackForm({required this.options, this.current});

  final StudyOptions options;
  final Track? current;

  @override
  State<_TrackForm> createState() => _TrackFormState();
}

class _TrackFormState extends State<_TrackForm> {
  late String _language = widget.current?.language ?? widget.options.languages.keys.first;
  late String _initial = widget.current?.startLevel ?? 'A1';
  late String _target = widget.current?.targetLevel ?? 'C2';
  late double _minutes = (widget.current?.minutesPerDay ?? 45).toDouble();
  late final Set<int> _selectedDays = {...widget.current?.weekdays ?? const [1, 2, 3, 4, 5, 6]};
  late DateTime _start = widget.current?.start ?? _today();

  @override
  Widget build(BuildContext context) {
    final levels = widget.options.levels;
    return AlertDialog(
      title: Text(widget.current == null ? 'Nova trilha de idioma' : 'Editar trilha'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 10,
            children: [
              if (widget.current == null)
                DropdownButtonFormField<String>(
                  initialValue: _language,
                  decoration: const InputDecoration(labelText: 'Idioma'),
                  items: [
                    for (final e in widget.options.languages.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) => setState(() => _language = v!),
                ),
              Row(
                spacing: 10,
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _initial,
                      decoration: const InputDecoration(labelText: 'Começo no nível'),
                      items: [for (final n in levels) DropdownMenuItem(value: n, child: Text(n))],
                      onChanged: (v) => setState(() {
                        _initial = v!;
                        if (levels.indexOf(_target) < levels.indexOf(_initial)) _target = _initial;
                      }),
                    ),
                  ),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      key: ValueKey(_target),
                      initialValue: _target,
                      decoration: const InputDecoration(labelText: 'Quero chegar a'),
                      items: [
                        for (final n in levels.skip(levels.indexOf(_initial))) DropdownMenuItem(value: n, child: Text(n)),
                      ],
                      onChanged: (v) => setState(() => _target = v!),
                    ),
                  ),
                ],
              ),
              Text('${_minutes.round()} minutos por dia'),
              Slider(
                value: _minutes,
                min: 15,
                max: 180,
                divisions: 33,
                label: '${_minutes.round()}',
                onChanged: (v) => setState(() => _minutes = v),
              ),
              const Text('Dias de estudo'),
              Wrap(
                spacing: 4,
                children: [
                  for (var d = 1; d <= 7; d++)
                    FilterChip(
                      label: Text(_days[d - 1]),
                      selected: _selectedDays.contains(d),
                      onSelected: (s) => setState(() => s ? _selectedDays.add(d) : _selectedDays.remove(d)),
                    ),
                ],
              ),
              TextButton.icon(
                icon: const Icon(Icons.event),
                label: Text('Início: ${_short(_start)} ${_start.year}'),
                onPressed: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: _start,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2100),
                  );
                  if (d != null) setState(() => _start = d);
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: _selectedDays.isEmpty
              ? null
              : () => Navigator.pop(context, {
                  if (widget.current == null) 'idioma': _language,
                  'nivel_inicial': _initial,
                  'nivel_alvo': _target,
                  'minutos_por_dia': _minutes.round(),
                  'dias_semana': _selectedDays.toList()..sort(),
                  'inicio': iso(_start),
                }),
          child: const Text('Salvar'),
        ),
      ],
    );
  }
}
