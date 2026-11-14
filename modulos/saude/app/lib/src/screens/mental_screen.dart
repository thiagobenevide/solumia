import 'dart:async';
import 'dart:math';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../health_api.dart';
import '../dates.dart';

void _notify(BuildContext context, Object e) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));

// ---------------------------------------------------------------- habits

/// Habits to build or avoid, with the streak of completed days.
class HabitsScreen extends StatefulWidget {
  const HabitsScreen({super.key, required this.api});

  final HealthApi api;

  @override
  State<HabitsScreen> createState() => _HabitsScreenState();
}

class _HabitsScreenState extends State<HabitsScreen> {
  List<Map<String, dynamic>>? _habits;
  DateTime _week = weekStart(today());

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final h = await widget.api.habits(_week, addDays(_week, 6));
      if (mounted) setState(() => _habits = h);
    } on ApiErro catch (e) {
      if (mounted) _notify(context, e);
    }
  }

  Future<void> _act(Future<void> Function() f) async {
    try {
      await f();
      await _load();
    } on ApiErro catch (e) {
      if (mounted) _notify(context, e);
    }
  }

  Future<void> _new([Map<String, dynamic>? current]) async {
    final name = TextEditingController(text: current?['nome'] as String?);
    final descricao = TextEditingController(text: current?['descricao'] as String?);
    var type = current?['tipo'] as String? ?? 'construir';
    final days = <int>{...(current?['dias_semana'] as List? ?? const [1, 2, 3, 4, 5, 6, 7]).cast<int>()};
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(current == null ? 'Novo hábito' : 'Editar hábito'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 10,
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'construir', icon: Icon(Icons.trending_up), label: Text('Construir')),
                    ButtonSegment(value: 'evitar', icon: Icon(Icons.block), label: Text('Evitar')),
                  ],
                  selected: {type},
                  onSelectionChanged: (s) => setState(() => type = s.first),
                ),
                TextField(
                  controller: name,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'Hábito',
                    hintText: type == 'evitar' ? 'ex.: celular na cama' : 'ex.: ler 20 páginas',
                  ),
                ),
                TextField(
                  controller: descricao,
                  decoration: const InputDecoration(labelText: 'Gatilho / plano (quando, onde, como)'),
                ),
                Wrap(
                  spacing: 4,
                  children: [
                    for (var d = 1; d <= 7; d++)
                      FilterChip(
                        label: Text(weekdays[d - 1]),
                        selected: days.contains(d),
                        onSelected: (s) => setState(() => s ? days.add(d) : days.remove(d)),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            if (current != null)
              TextButton(
                onPressed: () async {
                  Navigator.pop(context, false);
                  await _act(() => widget.api.deleteHabit(current['id'] as String));
                },
                child: const Text('Excluir'),
              ),
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Salvar')),
          ],
        ),
      ),
    );
    if (ok != true || name.text.trim().isEmpty || days.isEmpty) return;
    final data = {
      'nome': name.text.trim(),
      'descricao': descricao.text.trim(),
      'tipo': type,
      'dias_semana': days.toList()..sort(),
    };
    await _act(() => current == null ? widget.api.createHabit(data) : widget.api.editHabit(current['id'] as String, data));
  }

  @override
  Widget build(BuildContext context) {
    final habits = _habits;
    if (habits == null) return const Center(child: CircularProgressIndicator());
    final topic = Theme.of(context);
    final days = [for (var i = 0; i < 7; i++) addDays(_week, i)];
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _new,
        icon: const Icon(Icons.add),
        label: const Text('Hábito'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () {
                  setState(() => _week = addDays(_week, -7));
                  _load();
                },
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () {
                  setState(() => _week = addDays(_week, 7));
                  _load();
                },
              ),
              Text('Semana de ${shortDay(_week)}', style: topic.textTheme.titleSmall),
            ],
          ),
          if (habits.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Comece com um hábito pequeno e um gatilho claro: "depois do café, leio 10 páginas". '
                'Hábitos a evitar contam os dias em que você resistiu.',
                textAlign: TextAlign.center,
              ),
            ),
          for (final h in habits)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InkWell(
                      onTap: () => _new(h),
                      child: Row(
                        children: [
                          Icon(h['tipo'] == 'evitar' ? Icons.block : Icons.trending_up, size: 18),
                          const SizedBox(width: 6),
                          Expanded(child: Text(h['nome'] as String, style: topic.textTheme.titleSmall)),
                          Text('🔥 ${h['sequencia']}', style: topic.textTheme.titleSmall),
                        ],
                      ),
                    ),
                    if ((h['descricao'] as String? ?? '').isNotEmpty)
                      Text(h['descricao'] as String, style: topic.textTheme.bodySmall),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        for (final d in days)
                          Expanded(child: _habitDay(h, d)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _habitDay(Map<String, dynamic> h, DateTime d) {
    final expected = (h['dias_semana'] as List).contains(d.weekday);
    final done = (h['feitos'] as List).contains(iso(d));
    final future = d.isAfter(today());
    return Column(
      children: [
        Text(weekdays[d.weekday - 1], style: Theme.of(context).textTheme.labelSmall),
        Checkbox(
          value: done,
          onChanged: !expected || future
              ? null
              : (v) => _act(() => widget.api.markHabit(h['id'] as String, d, v ?? false)),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- foco

/// Focus against procrastination (pomodoro) and the minutes per day.
class FocusScreen extends StatefulWidget {
  const FocusScreen({super.key, required this.api});

  final HealthApi api;

  @override
  State<FocusScreen> createState() => _FocusScreenState();
}

class _FocusScreenState extends State<FocusScreen> {
  final _task = TextEditingController();
  int _focusMinutes = 25;
  int _breakMinutes = 5;
  bool _break = false;
  int _remaining = 25 * 60;
  int _distractions = 0;
  DateTime? _start;
  Timer? _timer;
  Map<String, dynamic>? _dados;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _task.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await widget.api.focus(addDays(today(), -6), today());
      if (mounted) setState(() => _dados = d);
    } on ApiErro catch (e) {
      if (mounted) _notify(context, e);
    }
  }

  bool get _running => _timer != null;

  void _begin() {
    _start ??= DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_remaining <= 1) {
        _end();
      } else {
        setState(() => _remaining--);
      }
    });
    setState(() {});
  }

  void _stop() {
    _timer?.cancel();
    setState(() => _timer = null);
  }

  Future<void> _registrar({required bool completed}) async {
    final start = _start;
    if (start == null || _break) return;
    final minutes = completed ? _focusMinutes : (DateTime.now().difference(start).inMinutes);
    if (minutes < 1) return;
    try {
      await widget.api.logFocus({
        'minutos': minutes,
        'tarefa': _task.text.trim(),
        'concluida': completed,
        'distracoes': _distractions,
        'inicio': start.toIso8601String().substring(0, 19),
      });
      await _load();
    } on ApiErro catch (e) {
      if (mounted) _notify(context, e);
    }
  }

  Future<void> _end() async {
    _stop();
    SystemSound.play(SystemSoundType.alert);
    HapticFeedback.heavyImpact();
    final wasFocus = !_break;
    if (wasFocus) await _registrar(completed: true);
    if (!mounted) return;
    setState(() {
      _break = wasFocus;
      _remaining = (wasFocus ? _breakMinutes : _focusMinutes) * 60;
      _start = null;
      _distractions = 0;
    });
    _notify(context, wasFocus ? 'Bloco concluído! Pausa de $_breakMinutes min.' : 'Pausa encerrada. Bora para o próximo bloco.');
  }

  Future<void> _cancel() async {
    _stop();
    await _registrar(completed: false);
    setState(() {
      _break = false;
      _remaining = _focusMinutes * 60;
      _start = null;
      _distractions = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final topic = Theme.of(context);
    final total = (_break ? _breakMinutes : _focusMinutes) * 60;
    final mm = (_remaining ~/ 60).toString().padLeft(2, '0');
    final ss = (_remaining % 60).toString().padLeft(2, '0');
    final byDay = (_dados?['minutos_por_dia'] as Map? ?? const {}).cast<String, int>();
    final todaySessions = [
      for (final s in (_dados?['sessoes'] as List? ?? const []).cast<Map<String, dynamic>>())
        if ((s['inicio'] as String).startsWith(iso(today()))) s,
    ];
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        TextField(
          controller: _task,
          enabled: !_running,
          decoration: const InputDecoration(
            labelText: 'No que vou focar agora (o menor próximo passo)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        if (!_running && _start == null)
          Wrap(
            spacing: 6,
            alignment: WrapAlignment.center,
            children: [
              for (final (f, p) in const [(15, 3), (25, 5), (50, 10)])
                ChoiceChip(
                  label: Text('$f / $p min'),
                  selected: _focusMinutes == f,
                  onSelected: (_) => setState(() {
                    _focusMinutes = f;
                    _breakMinutes = p;
                    _break = false;
                    _remaining = f * 60;
                  }),
                ),
            ],
          ),
        const SizedBox(height: 12),
        Center(
          child: SizedBox(
            width: 220,
            height: 220,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CircularProgressIndicator(
                  value: 1 - _remaining / total,
                  strokeWidth: 10,
                  color: _break ? Colors.green : topic.colorScheme.primary,
                ),
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('$mm:$ss', style: topic.textTheme.displayMedium),
                      Text(_break ? 'pausa' : 'foco'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          alignment: WrapAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: _running ? _stop : _begin,
              icon: Icon(_running ? Icons.pause : Icons.play_arrow),
              label: Text(_running ? 'Pausar' : (_start == null ? 'Começar' : 'Continuar')),
            ),
            if (_start != null || _break)
              OutlinedButton.icon(onPressed: _cancel, icon: const Icon(Icons.stop), label: const Text('Encerrar')),
            if (_running && !_break)
              OutlinedButton.icon(
                onPressed: () => setState(() => _distractions++),
                icon: const Icon(Icons.notifications_paused_outlined),
                label: Text('Me distraí ($_distractions)'),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Text('Hoje: ${byDay[iso(today())] ?? 0} min de foco em ${todaySessions.where((s) => s['concluida'] == true).length} blocos',
            style: topic.textTheme.titleSmall),
        const SizedBox(height: 8),
        SizedBox(height: 90, child: _Bars(valueList: {for (var i = 6; i >= 0; i--) addDays(today(), -i): (byDay[iso(addDays(today(), -i))] ?? 0).toDouble()})),
        for (final s in todaySessions.reversed)
          ListTile(
            dense: true,
            leading: Icon(s['concluida'] == true ? Icons.check_circle_outline : Icons.cancel_outlined),
            title: Text((s['tarefa'] as String).isEmpty ? 'Sem tarefa' : s['tarefa'] as String),
            subtitle: Text('${(s['inicio'] as String).substring(11, 16)} · ${s['minutos']} min · ${s['distracoes']} distrações'),
          ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Contra a procrastinação: comece pelo passo de 2 minutos; deixe o celular em outro cômodo; '
              'anote a distração em vez de segui-la; ao fim do bloco, levante e respire antes do próximo.',
              style: topic.textTheme.bodySmall,
            ),
          ),
        ),
      ],
    );
  }
}

/// Simple bars per day (day label below).
class _Bars extends StatelessWidget {
  const _Bars({required this.valueList, this.maximum});

  final Map<DateTime, double> valueList;
  final double? maximum;

  @override
  Widget build(BuildContext context) {
    final topic = Theme.of(context);
    final ceiling = maximum ?? max(1, valueList.values.fold<double>(0, max));
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final MapEntry(key: d, value: v) in valueList.entries)
          Expanded(
            child: Tooltip(
              message: '${shortDay(d)}: ${v.round()}',
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Flexible(
                    child: FractionallySizedBox(
                      heightFactor: (v / ceiling).clamp(0.02, 1),
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: BoxDecoration(
                          color: topic.colorScheme.primary,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
                  if (valueList.length <= 14) Text(weekdays[d.weekday - 1], style: topic.textTheme.labelSmall),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------- anxiety and mood

/// Breathing for anxiety and the day journal (mood, anxiety, triggers, gratitude).
class AnxietyScreen extends StatefulWidget {
  const AnxietyScreen({super.key, required this.api});

  final HealthApi api;

  @override
  State<AnxietyScreen> createState() => _AnxietyScreenState();
}

class _AnxietyScreenState extends State<AnxietyScreen> {
  List<Map<String, dynamic>> _history = const [];
  int? _humor;
  double _anxiety = 3;
  final _triggers = TextEditingController();
  final _whatIDid = TextEditingController();
  final _gratitude = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_triggers, _whatIDid, _gratitude]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final h = await widget.api.daily(addDays(today(), -29), today());
      if (!mounted) return;
      final day = h.where((d) => d['data'] == iso(today())).firstOrNull;
      setState(() {
        _history = h;
        if (day != null) {
          _humor = day['humor'] as int?;
          _anxiety = ((day['ansiedade'] as int?) ?? 3).toDouble();
          _triggers.text = day['gatilhos'] as String? ?? '';
          _whatIDid.text = day['o_que_fiz'] as String? ?? '';
          _gratitude.text = day['gratidao'] as String? ?? '';
        }
      });
    } on ApiErro catch (e) {
      if (mounted) _notify(context, e);
    }
  }

  Future<void> _save() async {
    try {
      await widget.api.saveDay(today(), {
        'humor': ?_humor,
        'ansiedade': _anxiety.round(),
        'gatilhos': _triggers.text.trim(),
        'o_que_fiz': _whatIDid.text.trim(),
        'gratidao': _gratitude.text.trim(),
      });
      await _load();
      if (mounted) _notify(context, 'Registro de hoje salvo');
    } on ApiErro catch (e) {
      if (mounted) _notify(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final topic = Theme.of(context);
    final byDate = {for (final d in _history) d['data']: d};
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Respiração guiada', style: topic.textTheme.titleMedium),
                const SizedBox(height: 8),
                const _Breathing(),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Text('Como estou hoje', style: topic.textTheme.titleMedium),
                SegmentedButton<int>(
                  emptySelectionAllowed: true,
                  showSelectedIcon: false,
                  segments: [
                    for (final (n, e) in const [(1, '😞'), (2, '🙁'), (3, '😐'), (4, '🙂'), (5, '😄')])
                      ButtonSegment(value: n, label: Text(e, style: const TextStyle(fontSize: 20))),
                  ],
                  selected: {?_humor},
                  onSelectionChanged: (s) => setState(() => _humor = s.firstOrNull),
                ),
                Text('Ansiedade: ${_anxiety.round()} de 10'),
                Slider(value: _anxiety, max: 10, divisions: 10, label: '${_anxiety.round()}', onChanged: (v) => setState(() => _anxiety = v)),
                TextField(controller: _triggers, decoration: const InputDecoration(labelText: 'O que disparou (gatilhos, pensamentos)')),
                TextField(controller: _whatIDid, decoration: const InputDecoration(labelText: 'O que fiz a respeito')),
                TextField(controller: _gratitude, decoration: const InputDecoration(labelText: 'Três coisas pelas quais sou grato')),
                Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: _save, child: const Text('Salvar'))),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Text('Ansiedade nos últimos 30 dias', style: topic.textTheme.titleMedium),
                SizedBox(
                  height: 90,
                  child: _Bars(
                    maximum: 10,
                    valueList: {
                      for (var i = 29; i >= 0; i--)
                        addDays(today(), -i): ((byDate[iso(addDays(today(), -i))]?['ansiedade'] as int?) ?? 0).toDouble(),
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Breathing in phases (box 4-4-4-4 or 4-7-8), with the circle growing on the inhale.
class _Breathing extends StatefulWidget {
  const _Breathing();

  @override
  State<_Breathing> createState() => _BreathingState();
}

class _BreathingState extends State<_Breathing> {
  static const _techniques = {
    'Caixa 4-4-4-4': [('Inspire', 4), ('Segure', 4), ('Expire', 4), ('Segure', 4)],
    '4-7-8': [('Inspire', 4), ('Segure', 7), ('Expire', 8)],
  };
  String _technique = 'Caixa 4-4-4-4';
  Timer? _timer;
  int _phase = 0;
  int _segundo = 0;
  int _cycles = 0;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _toggle() {
    if (_timer != null) {
      _timer!.cancel();
      return setState(() => _timer = null);
    }
    setState(() {
      _phase = 0;
      _segundo = 0;
      _cycles = 0;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final phases = _techniques[_technique]!;
      setState(() {
        _segundo++;
        if (_segundo >= phases[_phase].$2) {
          _segundo = 0;
          _phase = (_phase + 1) % phases.length;
          if (_phase == 0) _cycles++;
          HapticFeedback.selectionClick();
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final phases = _techniques[_technique]!;
    final (label, duration) = phases[_phase];
    // circle size: grows on inhale, shrinks on exhale, still while holding
    final progress = (_segundo + 1) / duration;
    final size = switch (label) {
      'Inspire' => 0.4 + 0.6 * progress,
      'Expire' => 1.0 - 0.6 * progress,
      _ => _phase == 1 ? 1.0 : 0.4,
    };
    final active = _timer != null;
    final color = Theme.of(context).colorScheme.primary;
    return Column(
      children: [
        Wrap(
          spacing: 6,
          children: [
            for (final t in _techniques.keys)
              ChoiceChip(
                label: Text(t),
                selected: _technique == t,
                onSelected: active ? null : (_) => setState(() => _technique = t),
              ),
          ],
        ),
        SizedBox(
          height: 180,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 950),
              curve: Curves.easeInOut,
              width: 160 * (active ? size : 0.5),
              height: 160 * (active ? size : 0.5),
              decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.35), border: Border.all(color: color, width: 2)),
              alignment: Alignment.center,
              child: Text(active ? '$label\n${duration - _segundo}' : '', textAlign: TextAlign.center),
            ),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 12,
          children: [
            FilledButton.icon(
              onPressed: _toggle,
              icon: Icon(active ? Icons.stop : Icons.air),
              label: Text(active ? 'Parar' : 'Começar'),
            ),
            Text('$_cycles ciclos'),
          ],
        ),
      ],
    );
  }
}
