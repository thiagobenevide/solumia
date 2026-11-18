import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../health_api.dart';
import '../dates.dart';
import '../models.dart';
import 'exercise_library.dart';
import 'calendar.dart';
import 'common.dart';
import 'dialogs.dart';
import 'workout_guide_screen.dart';

enum ViewMode { day, week, month }

/// Workout planning: calendar (day, week or month) and, on the right (or below on the phone), the
/// exercise library by body area to drag onto the day.
class WorkoutsScreen extends StatefulWidget {
  const WorkoutsScreen({super.key, required this.api});

  final HealthApi api;

  @override
  State<WorkoutsScreen> createState() => _WorkoutsScreenState();
}

class _WorkoutsScreenState extends State<WorkoutsScreen> {
  HealthApi get api => widget.api;

  List<String> _areas = const [];
  List<Exercise> _exercises = const [];
  Map<String, Exercise> _byId = const {};
  List<ItemAgenda> _items = const [];
  final _versions = <String, int>{};
  ViewMode _view = ViewMode.week;
  DateTime _focus = today();
  bool _libraryOpen = false;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  (DateTime, DateTime) get _window => switch (_view) {
    ViewMode.day => (_focus, _focus),
    ViewMode.week => (weekStart(_focus), addDays(weekStart(_focus), 6)),
    ViewMode.month => (gradeMes(_focus).first, gradeMes(_focus).last),
  };

  Future<void> _retry(Future<void> Function() action) async {
    try {
      await action();
      if (_error != null) setState(() => _error = null);
    } on ApiErro catch (e) {
      if (!mounted) return;
      if (_loading) {
        setState(() => _error = '$e');
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted && _loading) setState(() => _loading = false);
    }
  }

  Future<void> _loadAll() => _retry(() async {
    final (areas, exercises) = await api.exercises();
    _setExercises(areas, exercises);
    await _loadSchedule();
  });

  void _setExercises(List<String> areas, List<Exercise> exercises) => setState(() {
    _areas = areas;
    _exercises = exercises;
    _byId = {for (final e in exercises) e.id: e};
  });

  Future<void> _reloadExercises() async {
    final (areas, exercises) = await api.exercises();
    _setExercises(areas, exercises);
  }

  Future<void> _loadSchedule() async {
    final (de, ate) = _window;
    final itens = await api.agenda(de, ate);
    if (mounted) setState(() => _items = itens);
  }

  void _navigate(DateTime focus, [ViewMode? view]) {
    setState(() {
      _focus = day(focus);
      _view = view ?? _view;
    });
    _retry(_loadSchedule);
  }

  void _step(int direction) => _navigate(switch (_view) {
    ViewMode.day => addDays(_focus, direction),
    ViewMode.week => addDays(_focus, 7 * direction),
    ViewMode.month => DateTime(_focus.year, _focus.month + direction),
  });

  List<ItemAgenda> _ofDay(DateTime d) => [for (final i in _items) if (sameDay(i.data, d)) i];

  void _swapItem(ItemAgenda isNew) => setState(() => _items = [for (final i in _items) i.id == isNew.id ? isNew : i]);

  Future<void> _mark(Exercise e, DateTime d) => _retry(() async {
    final item = await api.mark(d, e.id);
    setState(() => _items = [..._items, item]);
  });

  Future<void> _drop(DragPayload a, DateTime d) => switch (a) {
    ExerciseDrag(:final exercise) => _mark(exercise, d),
    ItemDrag(:final item) when sameDay(item.data, d) => Future.value(),
    ItemDrag(:final item) => _retry(() async {
      final order = _ofDay(d).fold(-1, (m, i) => i.order > m ? i.order : m) + 1;
      _swapItem(await api.editItem(item.id, {'data': iso(d), 'ordem': order}));
    }),
  };

  Future<void> _toggleDone(ItemAgenda i) {
    if (!i.done) comemorar(context, mensagem: 'Exercício feito');
    return _retry(() async => _swapItem(await api.editItem(i.id, {'feito': !i.done})));
  }

  Future<void> _reorder(List<String> ids) => _retry(() async {
    final newItems = await Future.wait([for (final (n, id) in ids.indexed) api.editItem(id, {'ordem': n})]);
    setState(() {
      final byId = {for (final i in newItems) i.id: i};
      _items = [for (final i in _items) byId[i.id] ?? i]..sort((a, b) => a.order.compareTo(b.order));
    });
  });

  Future<void> _openItem(ItemAgenda i) async {
    final r = await editItem(context, i, _byId[i.exerciseId]);
    switch (r) {
      case ItemChanged(:final data):
        await _retry(() async => _swapItem(await api.editItem(i.id, data)));
      case ItemDeleted():
        await _retry(() async {
          await api.unmark(i.id);
          setState(() => _items = [for (final x in _items) if (x.id != i.id) x]);
        });
      case null:
    }
  }

  Future<void> _uploadPhoto(String id, Photo photo) async {
    await api.uploadImage(id, photo.name, photo.bytes);
    _versions[id] = (_versions[id] ?? 0) + 1;
  }

  Future<void> _createExercise() async {
    final r = await exerciseForm(context, _areas);
    if (r == null) return;
    final (data, photo) = r;
    await _retry(() async {
      final isNew = await api.createExercise(data);
      if (photo != null) await _uploadPhoto(isNew.id, photo);
      await _reloadExercises();
    });
  }

  Future<void> _openExercise(Exercise e) async {
    final action = await exerciseDetails(context, api, e, _versions[e.id] ?? 0);
    if (!mounted) return;
    switch (action) {
      case ExerciseAction.mark:
        await _mark(e, _focus);
      case ExerciseAction.edit:
        final r = await exerciseForm(context, _areas, current: e);
        if (r == null) return;
        await _retry(() async {
          await api.editExercise(e.id, r.$1);
          if (r.$2 != null) await _uploadPhoto(e.id, r.$2!);
          await _reloadExercises();
        });
      case ExerciseAction.changePhoto:
        final photo = await pickPhoto();
        if (photo == null) return;
        await _retry(() async {
          await _uploadPhoto(e.id, photo);
          await _reloadExercises();
        });
      case ExerciseAction.removePhoto:
        await _retry(() async {
          await api.removeImage(e.id);
          _versions[e.id] = (_versions[e.id] ?? 0) + 1;
          await _reloadExercises();
        });
      case ExerciseAction.delete:
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('Excluir "${e.name}"?'),
            content: const Text('Ele também sai de todos os dias em que estiver marcado.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Excluir')),
            ],
          ),
        );
        if (ok != true) return;
        await _retry(() async {
          await api.deleteExercise(e.id);
          await _reloadExercises();
          await _loadSchedule();
        });
      case null:
    }
  }

  Future<void> _repeatNext() => _retry(() async {
    final (de, ate) = switch (_view) {
      ViewMode.day => (_focus, _focus),
      _ => (weekStart(_focus), addDays(weekStart(_focus), 6)),
    };
    final destination = addDays(de, _view == ViewMode.day ? 1 : 7);
    await api.copy(de, ate, destination);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copiado para ${_view == ViewMode.day ? longDay(destination) : 'a semana de ${shortDay(destination)}'}')),
    );
    await _loadSchedule();
  });

  /// Workout guide: of the day open in the Day view, otherwise of today.
  Future<void> _train() async {
    final d = _view == ViewMode.day ? _focus : today();
    if (await openWorkoutGuide(context, api, d, _byId)) await _retry(_loadSchedule);
  }

  String get _title => switch (_view) {
    ViewMode.day => longDay(_focus),
    ViewMode.week => '${shortDay(weekStart(_focus))} – ${shortDay(addDays(weekStart(_focus), 6))}',
    ViewMode.month => monthYear(_focus),
  };

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && _exercises.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            Text(_error!),
            FilledButton(
              onPressed: () {
                setState(() => _loading = true);
                _loadAll();
              },
              child: const Text('Tentar de novo'),
            ),
          ],
        ),
      );
    }
    final agenda = Agenda(
      api: api,
      dayItems: _ofDay,
      exercise: (id) => _byId[id],
      drop: _drop,
      openItem: _openItem,
      toggleDone: _toggleDone,
      openDay: (d) => _navigate(d, ViewMode.day),
      imageVersion: (id) => _versions[id] ?? 0,
    );
    final calendar = switch (_view) {
      ViewMode.day => DayView(agenda: agenda, focus: _focus, reorder: _reorder),
      ViewMode.week => WeekView(agenda: agenda, focus: _focus),
      ViewMode.month => VistaMes(agenda: agenda, focus: _focus),
    };
    return LayoutBuilder(
      builder: (context, c) {
        final largo = c.maxWidth >= 900;
        ExerciseLibrary library({VoidCallback? close}) => ExerciseLibrary(
          api: api,
          areas: _areas,
          exercises: _exercises,
          imageVersion: (id) => _versions[id] ?? 0,
          adicionar: (e) => _mark(e, _focus),
          open: _openExercise,
          create: _createExercise,
          close: close,
        );
        final principal = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(c.maxWidth < 600, showLibrary: !largo),
            Expanded(child: Padding(padding: const EdgeInsets.all(6), child: calendar)),
            // portrait phone/tablet: library below, to drag up to the calendar
            if (!largo && _libraryOpen)
              SizedBox(
                height: c.maxHeight * 0.45,
                child: library(close: () => setState(() => _libraryOpen = false)),
              ),
          ],
        );
        if (!largo) return principal;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: principal),
            const VerticalDivider(width: 1),
            SizedBox(width: c.maxWidth >= 1300 ? 380 : 320, child: library()),
          ],
        );
      },
    );
  }

  Widget _header(bool narrow, {required bool showLibrary}) {
    final topic = Theme.of(context);
    final navigation = [
      IconButton(tooltip: 'Anterior', icon: const Icon(Icons.chevron_left), onPressed: () => _step(-1)),
      IconButton(tooltip: 'Próximo', icon: const Icon(Icons.chevron_right), onPressed: () => _step(1)),
      TextButton(onPressed: () => _navigate(today()), child: const Text('Hoje')),
    ];
    final title = InkWell(
      onTap: () async {
        final d = await showDatePicker(
          context: context,
          initialDate: _focus,
          firstDate: DateTime(2020),
          lastDate: DateTime(2100),
        );
        if (d != null) _navigate(d);
      },
      child: Text(_title, style: topic.textTheme.titleMedium, overflow: TextOverflow.ellipsis),
    );
    final views = SegmentedButton<ViewMode>(
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(value: ViewMode.day, label: Text('Dia')),
        ButtonSegment(value: ViewMode.week, label: Text('Semana')),
        ButtonSegment(value: ViewMode.month, label: Text('Mês')),
      ],
      selected: {_view},
      onSelectionChanged: (s) => _navigate(_focus, s.first),
    );
    final actions = [
      narrow
          ? IconButton.filled(tooltip: 'Treinar agora', icon: const Icon(Icons.play_arrow), onPressed: _train)
          : FilledButton.icon(onPressed: _train, icon: const Icon(Icons.play_arrow), label: const Text('Treinar')),
      PopupMenuButton<String>(
        tooltip: 'Mais',
        onSelected: (v) => switch (v) {
          'repetir' => _repeatNext(),
          'novo' => _createExercise(),
          _ => null,
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'repetir',
            child: Text(_view == ViewMode.day ? 'Repetir este dia amanhã' : 'Repetir esta semana na próxima'),
          ),
          const PopupMenuItem(value: 'novo', child: Text('Novo exercício')),
        ],
      ),
      if (showLibrary)
        IconButton.filledTonal(
          tooltip: 'Exercícios',
          isSelected: _libraryOpen,
          icon: const Icon(Icons.fitness_center),
          onPressed: () => setState(() => _libraryOpen = !_libraryOpen),
        ),
    ];
    if (narrow) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [...navigation, Expanded(child: title)]),
            Row(children: [Expanded(child: views), ...actions]),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Row(
        spacing: 4,
        children: [...navigation, Expanded(child: title), views, ...actions],
      ),
    );
  }
}
