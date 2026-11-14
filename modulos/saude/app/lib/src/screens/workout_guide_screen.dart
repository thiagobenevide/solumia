import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../health_api.dart';
import '../workout_notice.dart';
import '../dates.dart';
import '../health_connect.dart';
import '../models.dart';
import '../session.dart';
import 'common.dart';

/// Opens the workout guide of [day] (or continues the one in progress). Returns true if the workout
/// was finished or discarded (the schedule needs to reload).
Future<bool> openWorkoutGuide(BuildContext context, HealthApi api, DateTime day, Map<String, Exercise> byId) async {
  final messenger = ScaffoldMessenger.of(context);
  final browser = Navigator.of(context);
  try {
    final s = await api.activeSession() ?? await api.startSession(day);
    final r = await browser.push<bool>(
      MaterialPageRoute(builder: (_) => WorkoutGuideScreen(api: api, session: s, byId: byId)),
    );
    return r ?? false;
  } on ApiErro catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
    return false;
  }
}

/// The step-by-step workout: current set with reps and load, timed rest (pause,
/// add, skip) and, at the end, the summary with the watch heart rate. Every command goes to the
/// server, which keeps the state; the screen rereads every 5 s to pick up what comes from another device.
class WorkoutGuideScreen extends StatefulWidget {
  const WorkoutGuideScreen({super.key, required this.api, required this.session, required this.byId});

  final HealthApi api;
  final WorkoutSession session;
  final Map<String, Exercise> byId;

  @override
  State<WorkoutGuideScreen> createState() => _WorkoutGuideScreenState();
}

class _WorkoutGuideScreenState extends State<WorkoutGuideScreen> with WidgetsBindingObserver {
  late WorkoutSession _s = widget.session;
  Timer? _tick;
  Timer? _syncTask;
  bool _busy = false;
  String _setKey = '';
  int _reps = 10;
  double? _load;
  String? _restNotified;
  int _lastBeep = -1;
  bool _fetchingHr = false;
  bool _ahead = true;

  HealthApi get api => widget.api;

  @override
  void initState() {
    super.initState();
    _prepareSet();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _everySecond());
    _syncTask = Timer.periodic(const Duration(seconds: 5), (_) => _sync());
    WakelockPlus.enable().catchError((_) {});
    WidgetsBinding.instance.addObserver(this);
    WorkoutNotice.refresh(_s, background: false);
  }

  /// Left the foreground (another app, screen off): the end of the rest becomes a system alarm.
  @override
  void didChangeAppLifecycleState(AppLifecycleState status) {
    _ahead = status == AppLifecycleState.resumed;
    WorkoutNotice.refresh(_s, background: !_ahead);
    if (_ahead) _sync();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _syncTask?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    // closed the guide with the workout in progress: the notice keeps going outside
    WorkoutNotice.refresh(_s, background: true);
    WakelockPlus.disable().catchError((_) {});
    super.dispose();
  }

  void _assign(WorkoutSession s) {
    if (!mounted) return;
    setState(() => _s = s);
    _prepareSet();
    WorkoutNotice.refresh(s, background: !_ahead);
  }

  /// Reps and load go back to the suggested ones when the exercise or the set changes.
  void _prepareSet() {
    final e = _s.current;
    final key = '${_s.score}:${e?.series.length}';
    if (e == null || key == _setKey) return;
    _setKey = key;
    _reps = e.initialReps;
    _load = e.initialLoad;
  }

  void _everySecond() {
    if (!mounted || _s.status != 'andamento') return;
    final remaining = _s.restRemaining();
    final ate = _s.controle['descanso_ate'] as String?;
    // in the background the system alarm does the notifying (WorkoutNotice)
    if (_ahead && remaining != null && !_s.paused && ate != null) {
      if (remaining <= 3 && remaining > 0 && remaining != _lastBeep) {
        _lastBeep = remaining;
        SystemSound.play(SystemSoundType.click);
      }
      if (remaining == 0 && _restNotified != ate) {
        _restNotified = ate;
        SystemSound.play(SystemSoundType.alert);
        HapticFeedback.heavyImpact();
        _sync();
      }
    }
    setState(() {});
  }

  Future<void> _sync() async {
    if (_busy || _s.status != 'andamento') return;
    try {
      _assign(await api.session(_s.id));
    } on ApiErro {
      // no network for a moment: the next cycle tries again
    }
  }

  Future<void> _cmd(String action, [Map<String, dynamic> data = const {}]) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      _assign(await api.sessionCommand(_s.id, action, data));
    } on ApiErro catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _setDone(SessionExercise e) {
    HapticFeedback.mediumImpact();
    _cmd('concluir_serie', {
      if (e.tempoMeta == null) 'repeticoes': _reps,
      if (e.tempoMeta != null) 'tempo_s': _s.setTime(),
      'carga_kg': ?_load,
    });
  }

  // --- fim ---

  Future<void> _finish() async {
    final r = await showDialog<(int, String)>(context: context, builder: (_) => const _Closing());
    if (r == null || !mounted) return;
    setState(() => _busy = true);
    try {
      _assign(await api.finishSession(_s.id, {'esforco': r.$1, if (r.$2.isNotEmpty) 'notas': r.$2}));
    } on ApiErro catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    // a live measurement on the watch already counts; otherwise, reads Health Connect
    if (_s.status == 'concluida' && !_s.watchHr) await _fetchHeartRate(silent: true);
  }

  Future<void> _fetchHeartRate({bool silent = false}) async {
    if (!HealthConnectReader.disponivel) return;
    setState(() => _fetchingHr = true);
    String? warning;
    try {
      final reader = HealthConnectReader();
      if (!await reader.authorized()) {
        warning = 'Autorize o Health Connect em Sono e corpo.';
      } else {
        final end = DateTime.parse(_s.j['fim'] as String? ?? DateTime.now().toUtc().toIso8601String());
        final fc = await reader.frequency(_s.start.toLocal(), end.toLocal());
        if (fc == null) {
          warning = 'O relógio ainda não mandou a frequência. Tente de novo em alguns minutos.';
        } else {
          _assign(await api.editSession(_s.id, {'frequencia': fc}));
        }
      }
    } catch (e) {
      warning = '$e';
    } finally {
      if (mounted) setState(() => _fetchingHr = false);
    }
    if (warning != null && !silent && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(warning)));
    }
  }

  Future<void> _discard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Descartar o treino?'),
        content: const Text('As séries registradas nesta sessão serão apagadas.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Descartar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await api.deleteSession(_s.id);
      if (mounted) Navigator.pop(context, true);
    } on ApiErro catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _pickRest() async {
    final s = await showDialog<int>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Descanso entre séries'),
        children: [
          for (final v in const [30, 45, 60, 90, 120, 180])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, v),
              child: Text(watch(v), style: TextStyle(fontWeight: v == _s.restSeconds ? FontWeight.bold : null)),
            ),
        ],
      ),
    );
    if (s != null) await _cmd('descanso_padrao', {'segundos': s});
  }

  // --- tela ---

  @override
  Widget build(BuildContext context) {
    final progressInfo = _s.status == 'andamento';
    return Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Treino · ${shortDay(_s.data)}'),
              Text(
                '${watch(_s.active().inSeconds)}${_s.paused ? ' · pausado' : ''}'
                '${_s.currentHr() == null ? '' : ' · ♥ ${_s.currentHr()} bpm'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            if (progressInfo)
              IconButton(
                tooltip: _s.paused ? 'Continuar treino' : 'Pausar treino',
                icon: Icon(_s.paused ? Icons.play_arrow : Icons.pause),
                onPressed: () => _cmd(_s.paused ? 'continuar' : 'pausar'),
              ),
            if (progressInfo)
              PopupMenuButton<String>(
                onSelected: (v) => switch (v) {
                  'descanso' => _pickRest(),
                  'pular' => _cmd('pular_exercicio'),
                  'desfazer' => _cmd('desfazer_serie'),
                  'concluir' => _finish(),
                  'descartar' => _discard(),
                  _ => null,
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'descanso', child: Text('Descanso: ${watch(_s.restSeconds)}')),
                  const PopupMenuItem(value: 'pular', child: Text('Pular este exercício')),
                  const PopupMenuItem(value: 'desfazer', child: Text('Desfazer última série')),
                  const PopupMenuItem(value: 'concluir', child: Text('Encerrar treino agora')),
                  const PopupMenuItem(value: 'descartar', child: Text('Descartar treino')),
                ],
              ),
          ],
        ),
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LinearProgressIndicator(
                value: _s.plannedSets == 0 ? 0 : _s.setsDone / _s.plannedSets,
              ),
              if (progressInfo) _track(),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: ListView(padding: const EdgeInsets.all(16), children: _content()),
                  ),
                ),
              ),
            ],
          ),
        ),
    );
  }

  /// The day's exercises in a queue; tapping goes to it.
  Widget _track() => SizedBox(
    height: 48,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      children: [
        for (final e in _s.exercises)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ChoiceChip(
              selected: e.score == _s.score,
              avatar: e.complete ? const Icon(Icons.check, size: 16) : null,
              label: Text('${e.name} ${e.series.length}/${e.planned}'),
              onSelected: _busy || e.score == _s.score ? null : (_) => _cmd('ir_para', {'indice': e.score}),
            ),
          ),
      ],
    ),
  );

  List<Widget> _content() {
    if (_s.status == 'concluida') return [_summary()];
    final breakTime = _s.paused
        ? Card(
            color: Theme.of(context).colorScheme.tertiaryContainer,
            child: ListTile(
              leading: const Icon(Icons.pause_circle),
              title: const Text('Treino pausado'),
              trailing: FilledButton(onPressed: () => _cmd('continuar'), child: const Text('Continuar')),
            ),
          )
        : null;
    final body = switch (_s.phase()) {
      'descanso' => _rest(),
      'fim' => _end(),
      _ => _set(),
    };
    return [?breakTime, body];
  }

  Widget _rest() {
    final topic = Theme.of(context);
    final remaining = _s.restRemaining() ?? 0;
    final total = _s.restSeconds < remaining ? remaining : _s.restSeconds;
    final next = _s.current;
    return Column(
      spacing: 16,
      children: [
        Text('Descanso', style: topic.textTheme.titleLarge),
        SizedBox.square(
          dimension: 220,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CircularProgressIndicator(value: total == 0 ? 0 : remaining / total, strokeWidth: 10),
              Center(child: Text(watch(remaining), style: topic.textTheme.displayMedium)),
            ],
          ),
        ),
        if (next != null)
          Text(
            'Próximo: ${next.name} · série ${next.series.length + 1} de ${next.planned}',
            textAlign: TextAlign.center,
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 12,
          children: [
            OutlinedButton(onPressed: () => _cmd('somar_descanso', {'segundos': -15}), child: const Text('−15 s')),
            IconButton.filledTonal(
              iconSize: 32,
              tooltip: _s.paused ? 'Continuar descanso' : 'Pausar descanso',
              icon: Icon(_s.paused ? Icons.play_arrow : Icons.pause),
              onPressed: () => _cmd(_s.paused ? 'continuar' : 'pausar'),
            ),
            OutlinedButton(onPressed: () => _cmd('somar_descanso', {'segundos': 30}), child: const Text('+30 s')),
          ],
        ),
        FilledButton.icon(
          onPressed: _busy ? null : () => _cmd('pular_descanso'),
          icon: const Icon(Icons.skip_next),
          label: const Text('Pular descanso'),
        ),
        _lastSets(),
      ],
    );
  }

  Widget _set() {
    final e = _s.current;
    if (e == null) return _end();
    final topic = Theme.of(context);
    final ex = widget.byId[e.exerciseId];
    final step = (_load ?? 0) >= 20 ? 2.5 : 1.0;
    final sug = e.suggestion;
    final anterior = e.anterior;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        if (ex != null && ex.hasImage)
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(height: 200, child: ExerciseImage(api: api, exercise: ex)),
          ),
        Text(e.name, style: topic.textTheme.headlineSmall),
        Text(
          'Série ${e.series.length + 1} de ${e.planned} · meta ${e.reps}'
          '${e.plannedLoad == null ? '' : ' · ${formatLoad(e.plannedLoad!)} kg'}',
          style: topic.textTheme.titleMedium,
        ),
        if (anterior != null)
          Text(
            'Última vez (${shortDay(DateTime.parse(anterior['data'] as String))}): '
            '${[for (final s in anterior['series'] as List) _setText(s as Map<String, dynamic>)].join(' · ')}',
            style: topic.textTheme.bodySmall,
          ),
        if (sug != null && e.series.isEmpty)
          Card(
            color: topic.colorScheme.secondaryContainer,
            child: ListTile(
              leading: const Icon(Icons.trending_up),
              title: Text(sug['motivo'] as String),
              trailing: sug['carga_kg'] == null
                  ? null
                  : TextButton(
                      onPressed: () => setState(() => _load = (sug['carga_kg'] as num).toDouble()),
                      child: Text('${formatLoad((sug['carga_kg'] as num).toDouble())} kg'),
                    ),
            ),
          ),
        if (e.tempoMeta != null)
          Center(
            child: Text(
              '${watch(_s.setTime())} / ${watch(e.tempoMeta!)}',
              style: topic.textTheme.displaySmall?.copyWith(
                color: _s.setTime() >= e.tempoMeta! ? topic.colorScheme.primary : null,
              ),
            ),
          )
        else
          _Adjustment(
            label: 'Repetições',
            value: '$_reps',
            less: _reps > 0 ? () => setState(() => _reps--) : null,
            more: () => setState(() => _reps++),
          ),
        _Adjustment(
          label: 'Carga',
          value: _load == null ? 'peso do corpo' : '${formatLoad(_load!)} kg',
          less: _load == null ? null : () => setState(() => _load = _load! - step <= 0 ? null : _load! - step),
          more: () => setState(() => _load = (_load ?? 0) + step),
        ),
        if (e.instructions.isNotEmpty)
          ExpansionTile(
            title: const Text('Como fazer'),
            tilePadding: EdgeInsets.zero,
            children: [Text(e.instructions)],
          ),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(64)),
          onPressed: _busy || _s.paused ? null : () => _setDone(e),
          icon: const Icon(Icons.check),
          label: const Text('Série feita'),
        ),
        _lastSets(),
      ],
    );
  }

  Widget _end() => Column(
    spacing: 16,
    children: [
      const Icon(Icons.emoji_events_outlined, size: 72),
      Text('Todos os exercícios feitos', style: Theme.of(context).textTheme.titleLarge),
      Text('${_s.setsDone} séries em ${watch(_s.active().inSeconds)}'),
      FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
        onPressed: _busy ? null : _finish,
        icon: const Icon(Icons.flag),
        label: const Text('Concluir treino'),
      ),
      TextButton(onPressed: _busy ? null : () => _cmd('desfazer_serie'), child: const Text('Desfazer última série')),
    ],
  );

  Widget _summary() {
    final topic = Theme.of(context);
    final r = _s.summary ?? const {};
    final fc = _s.frequency;
    String num(String k) => '${r[k] ?? '–'}'.replaceAll('.', ',');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        Text('Treino concluído', style: topic.textTheme.headlineSmall),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Chip(label: Text('${num('ativo_min')} min ativos')),
            Chip(label: Text('${r['series_feitas']}/${r['series_planejadas']} séries')),
            Chip(label: Text('${num('volume_kg')} kg de volume')),
            if (_s.j['esforco'] != null) Chip(label: Text('esforço ${_s.j['esforco']}/10')),
            if (fc != null) Chip(avatar: const Icon(Icons.favorite, size: 16), label: Text('FC média ${fc['media']} · máx ${fc['maxima']}')),
          ],
        ),
        for (final e in _s.exercises)
          if (e.series.isNotEmpty)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(e.name),
              subtitle: Text([for (final s in e.series) _setText(s)].join(' · ')),
            ),
        if (HealthConnectReader.disponivel && fc == null)
          OutlinedButton.icon(
            onPressed: _fetchingHr ? null : _fetchHeartRate,
            icon: const Icon(Icons.watch),
            label: Text(_fetchingHr ? 'Lendo o relógio…' : 'Buscar frequência cardíaca do relógio'),
          ),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Fechar')),
      ],
    );
  }

  Widget _lastSets() {
    final e = _s.current;
    if (e == null || e.series.isEmpty) return const SizedBox.shrink();
    return Text(
      'Feitas: ${[for (final s in e.series) _setText(s)].join(' · ')}',
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}

/// "10 × 40 kg", "12" or "0:30".
String _setText(Map<String, dynamic> s) {
  final load = (s['carga_kg'] as num?)?.toDouble();
  final base = s['tempo_s'] != null ? watch(s['tempo_s'] as int) : '${s['repeticoes'] ?? '?'}';
  final fc = s['fc_max'] == null ? '' : ' ♥${s['fc_max']}';
  return '${load == null ? base : '$base × ${formatLoad(load)} kg'}$fc';
}

class _Adjustment extends StatelessWidget {
  const _Adjustment({required this.label, required this.value, this.less, this.more});

  final String label;
  final String value;
  final VoidCallback? less;
  final VoidCallback? more;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: Text(label, style: Theme.of(context).textTheme.titleMedium)),
      IconButton.outlined(iconSize: 28, onPressed: less, icon: const Icon(Icons.remove)),
      SizedBox(
        width: 130,
        child: Text(value, textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
      ),
      IconButton.outlined(iconSize: 28, onPressed: more, icon: const Icon(Icons.add)),
    ],
  );
}

/// Perceived effort (1–10) and notes on closing the workout.
class _Closing extends StatefulWidget {
  const _Closing();

  @override
  State<_Closing> createState() => _ClosingState();
}

class _ClosingState extends State<_Closing> {
  double _effort = 7;
  final _notes = TextEditingController();

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Como foi o treino?'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Esforço: ${_effort.round()}/10'),
        Slider(value: _effort, min: 1, max: 10, divisions: 9, onChanged: (v) => setState(() => _effort = v)),
        TextField(controller: _notes, decoration: const InputDecoration(labelText: 'Notas (opcional)'), maxLines: 3),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Voltar')),
      FilledButton(
        onPressed: () => Navigator.pop(context, (_effort.round(), _notes.text.trim())),
        child: const Text('Concluir'),
      ),
    ],
  );
}
