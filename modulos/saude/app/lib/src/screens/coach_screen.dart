import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../dates.dart';
import '../health_api.dart';

const _mealTypes = ['café da manhã', 'lanche', 'almoço', 'pré-treino', 'pós-treino', 'jantar', 'ceia'];

const _sections = [
  (Icons.today_rounded, 'Hoje'),
  (Icons.fitness_center_rounded, 'Treino'),
  (Icons.restaurant_rounded, 'Alimentação'),
  (Icons.monitor_weight_rounded, 'Corpo'),
];

/// AI coach, in glass cards and four sections: today's checklist, the workout of the chosen days
/// (written into the Workouts agenda), meals by photo with calories and macros, and body/equipment.
/// The AI is Claude (Claude Code on the PC) or the local LLM, chosen at the top.
class CoachScreen extends StatefulWidget {
  const CoachScreen({super.key, required this.api});

  final HealthApi api;

  @override
  State<CoachScreen> createState() => _CoachScreenState();
}

class _CoachScreenState extends State<CoachScreen> {
  Map<String, dynamic>? _profile;
  List<Map<String, dynamic>> _weights = [];
  List<Map<String, dynamic>> _plans = [];
  List<Map<String, dynamic>> _meals = [];
  Map<String, dynamic>? _food;
  Map<String, dynamic>? _todayFood;
  (int, int) _todayWorkout = (0, 0);
  DateTime _day = today();
  int _section = 0;
  bool _generating = false;
  bool _sending = false;
  bool _planOpen = false;
  final Set<DateTime> _planDays = {today()};

  final _weight = TextEditingController();
  final _height = TextEditingController();
  final _age = TextEditingController();
  final _minutes = TextEditingController();
  final _limits = TextEditingController();
  final _request = TextEditingController();
  final _newItem = TextEditingController();
  final _mealText = TextEditingController();
  String _mealType = 'almoço';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_weight, _height, _age, _minutes, _limits, _request, _newItem, _mealText]) {
      c.dispose();
    }
    super.dispose();
  }

  String get _ai => _profile?['ia'] as String? ?? 'claude';

  List<String> get _equipment => [...(_profile?['materiais'] as List? ?? const []).cast<String>()];

  Map<String, dynamic> get _targets => (_todayFood?['metas'] as Map?)?.cast<String, dynamic>() ?? const {};

  // --- data ---

  Future<void> _load() async {
    try {
      final profile = await widget.api.coachProfile();
      final weights = await widget.api.weights(addDays(today(), -90), today());
      final plans = await widget.api.workoutPlans();
      final todayFood = await widget.api.foodDay(today());
      final agenda = await widget.api.agenda(today(), today());
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _weights = weights;
        _plans = plans;
        _todayFood = todayFood;
        _todayWorkout = (agenda.where((i) => i.done).length, agenda.length);
        _height.text = _text(profile['altura_cm']);
        _age.text = _text(profile['idade']);
        _minutes.text = _text(profile['minutos_sessao']);
        _limits.text = profile['restricoes'] as String? ?? '';
      });
      await _loadDay();
    } on ApiErro catch (e) {
      _notify(e);
    }
  }

  Future<void> _loadDay() async {
    try {
      final meals = await widget.api.meals(_day);
      final food = await widget.api.foodDay(_day);
      if (!mounted) return;
      setState(() {
        _meals = meals;
        _food = food;
        if (sameDay(_day, today())) _todayFood = food;
      });
    } on ApiErro catch (e) {
      _notify(e);
    }
  }

  String _text(Object? v) {
    if (v == null) return '';
    if (v is double && v == v.roundToDouble()) return v.toInt().toString();
    return '$v';
  }

  void _notify(Object e) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
  }

  Future<void> _saveProfile(Map<String, dynamic> data) async {
    try {
      final p = await widget.api.saveCoachProfile(data);
      if (mounted) setState(() => _profile = p);
    } on ApiErro catch (e) {
      _notify(e);
    }
  }

  Future<void> _saveWeight() async {
    final kg = double.tryParse(_weight.text.replaceAll(',', '.'));
    if (kg == null) {
      _notify('Digite o peso em kg (ex.: 91,6).');
      return;
    }
    try {
      await widget.api.saveWeight(today(), kg);
      _weight.clear();
      if (mounted) comemorar(context, mensagem: 'Pesagem registrada');
      await _load();
    } on ApiErro catch (e) {
      _notify(e);
    }
  }

  Future<void> _saveBody() async {
    final data = <String, dynamic>{
      'altura_cm': double.tryParse(_height.text.replaceAll(',', '.')),
      'idade': int.tryParse(_age.text),
      'minutos_sessao': int.tryParse(_minutes.text),
      'restricoes': _limits.text.trim(),
    };
    data.removeWhere((k, v) => v == null);
    await _saveProfile(data);
    if (_weight.text.trim().isNotEmpty) {
      await _saveWeight();
    } else {
      await _load();
      _notify('Perfil salvo.');
    }
  }

  Future<void> _generate() async {
    if (_planDays.isEmpty) {
      _notify('Escolha pelo menos um dia.');
      return;
    }
    setState(() => _generating = true);
    final days = _planDays.toList()..sort();
    try {
      final plan = await widget.api.generateWorkoutPlan(_request.text, _ai, days);
      _request.clear();
      if (mounted) comemorar(context, mensagem: '${plan['agendados']} exercícios na agenda');
      await _load();
    } on ApiErro catch (e) {
      _notify(e);
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _sendMeal({bool withPhoto = true}) async {
    ({String name, List<int> bytes})? photo;
    if (withPhoto) {
      final r = await FilePicker.pickFiles(dialogTitle: 'Foto da refeição', type: FileType.image);
      if (r.isEmpty) return;
      photo = (name: r.first.name, bytes: await r.first.xFile.readAsBytes());
    } else if (_mealText.text.trim().isEmpty) {
      _notify('Descreva a refeição ou mande a foto.');
      return;
    }
    setState(() => _sending = true);
    try {
      await widget.api.sendMeal(_day, _mealType, _mealText.text.trim(), _ai, photo: photo);
      _mealText.clear();
      if (mounted) comemorar(context, mensagem: 'Refeição registrada');
      await _loadDay();
    } on ApiErro catch (e) {
      _notify(e);
      await _loadDay();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _reanalyze(Map<String, dynamic> meal) async {
    final controller = TextEditingController();
    final correction = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Corrigir a estimativa'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 3,
          maxLines: 6,
          keyboardType: TextInputType.multiline,
          decoration: const InputDecoration(hintText: 'ex.: eram 2 conchas de feijão e 150 g de frango'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Recalcular')),
        ],
      ),
    );
    controller.dispose();
    if (correction == null) return;
    setState(() => _sending = true);
    try {
      await widget.api.reanalyzeMeal(meal['id'] as String, correction, _ai);
      await _loadDay();
    } on ApiErro catch (e) {
      _notify(e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _deleteMeal(String id) async {
    try {
      await widget.api.deleteMeal(id);
      await _loadDay();
    } on ApiErro catch (e) {
      _notify(e);
    }
  }

  void _addEquipment() {
    final text = _newItem.text.trim();
    if (text.isEmpty) return;
    _newItem.clear();
    _saveProfile({'materiais': [..._equipment, text]});
  }

  void _removeEquipment(String item) {
    final items = _equipment..remove(item);
    _saveProfile({'materiais': items});
  }

  void _changeDay(int n) {
    setState(() => _day = addDays(_day, n));
    _loadDay();
  }

  void _toggleDay(DateTime d) => setState(() {
    if (!_planDays.remove(d)) _planDays.add(d);
  });

  void _pickDays(List<DateTime> days) => setState(() {
    _planDays
      ..clear()
      ..addAll(days);
  });

  List<DateTime> _untilSunday() {
    final days = [today()];
    while (days.last.weekday != DateTime.sunday) {
      days.add(addDays(days.last, 1));
    }
    return days;
  }

  // --- layout ---

  @override
  Widget build(BuildContext context) {
    if (_profile == null) return const FundoVidro(child: Center(child: CircularProgressIndicator()));
    return FundoVidro(
      child: LayoutBuilder(
        builder: (context, box) {
          final narrow = box.maxWidth < 600;
          final side = narrow ? 12.0 : 24.0;
          final width = box.maxWidth > 1100 ? 1100.0 : box.maxWidth - side * 2;
          return ListView(
            padding: EdgeInsets.fromLTRB(side, narrow ? 12 : 20, side, 32),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _header(narrow),
                      const SizedBox(height: 14),
                      _sectionBar(narrow),
                      const SizedBox(height: 16),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 280),
                        switchInCurve: Curves.easeOutCubic,
                        transitionBuilder: _slideFade,
                        child: KeyedSubtree(key: ValueKey(_section), child: _sectionBody(width)),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static Widget _slideFade(Widget child, Animation<double> a) => FadeTransition(
    opacity: a,
    child: SlideTransition(
      position: Tween(begin: const Offset(0, 0.03), end: Offset.zero).animate(a),
      child: child,
    ),
  );

  Widget _sectionBody(double width) => switch (_section) {
    0 => _todaySection(width),
    1 => _workoutSection(width),
    2 => _foodSection(width),
    _ => _bodySection(width),
  };

  /// Two columns from 900 px; one column on the phone.
  Widget _columns(double width, List<Widget> left, List<Widget> right) {
    if (width < 900) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...left, ...right]);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: left)),
        const SizedBox(width: 16),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: right)),
      ],
    );
  }

  Widget _header(bool narrow) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Treinador IA', style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
        Text(
          'Hipertrofia em primeiro, resistência em segundo',
          style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
        ),
      ],
    );
    final picker = SegmentedButton<String>(
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(value: 'claude', label: Text('Claude'), icon: Icon(Icons.auto_awesome_rounded, size: 18)),
        ButtonSegment(value: 'local', label: Text('Local'), icon: Icon(Icons.memory_rounded, size: 18)),
      ],
      selected: {_ai},
      onSelectionChanged: (s) => _saveProfile({'ia': s.first}),
    );
    if (narrow) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [title, const SizedBox(height: 10), picker]);
    }
    return Row(children: [Expanded(child: title), picker]);
  }

  /// Glass pill bar with the four sections; the selected one lights up.
  Widget _sectionBar(bool narrow) {
    final colors = Theme.of(context).colorScheme;
    return Vidro(
      padding: const EdgeInsets.all(5),
      raio: 18,
      child: Row(
        children: [
          for (var i = 0; i < _sections.length; i++)
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _section = i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  padding: EdgeInsets.symmetric(vertical: narrow ? 8 : 10),
                  decoration: BoxDecoration(
                    color: i == _section ? colors.primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: _sectionLabel(i, narrow),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _sectionLabel(int i, bool narrow) {
    final colors = Theme.of(context).colorScheme;
    final color = i == _section ? colors.onPrimary : colors.onSurfaceVariant;
    final (icon, label) = _sections[i];
    final style = TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: narrow ? 11 : 13);
    if (narrow) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [Icon(icon, color: color, size: 20), const SizedBox(height: 2), Text(label, style: style, maxLines: 1)],
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [Icon(icon, color: color, size: 18), const SizedBox(width: 6), Text(label, style: style)],
    );
  }

  // --- Hoje ---

  Widget _todaySection(double width) {
    final colors = Theme.of(context).colorScheme;
    final weight = (_todayFood?['peso'] as Map?)?.cast<String, dynamic>();
    final weighed = weight != null && weight['data'] == iso(today());
    final kcal = ((_todayFood?['total'] as Map?)?['kcal'] as num?) ?? 0;
    final goal = _targets['kcal'] as num?;
    final meals = _todayFood?['refeicoes'] as int? ?? 0;
    final (done, total) = _todayWorkout;
    final tiles = [
      _StatTile(
        icon: Icons.monitor_weight_rounded,
        color: colors.primary,
        label: 'Peso',
        value: weight == null ? '—' : '${_text(weight['peso_kg'])} kg',
        detail: weighed ? 'pesado hoje' : 'pese-se de manhã',
        progress: weighed ? 1 : 0,
      ),
      _StatTile(
        icon: Icons.local_fire_department_rounded,
        color: Colors.orange,
        label: 'Calorias',
        value: '$kcal',
        detail: goal == null ? '$meals refeições' : 'de $goal kcal · $meals refeições',
        progress: goal == null || goal == 0 ? 0 : kcal / goal,
      ),
      _StatTile(
        icon: Icons.fitness_center_rounded,
        color: colors.tertiary,
        label: 'Treino',
        value: total == 0 ? '—' : '$done/$total',
        detail: total == 0 ? 'nada na agenda hoje' : 'exercícios feitos',
        progress: total == 0 ? 0 : done / total,
      ),
    ];
    final narrow = width < 640;
    final tileRows = <Widget>[];
    if (narrow) {
      for (var i = 0; i < tiles.length; i++) {
        tileRows.add(Surgir(ordem: i, child: Padding(padding: const EdgeInsets.only(bottom: 12), child: tiles[i])));
      }
    } else {
      final row = <Widget>[];
      for (var i = 0; i < tiles.length; i++) {
        if (i > 0) row.add(const SizedBox(width: 12));
        row.add(Expanded(child: Surgir(ordem: i, child: tiles[i])));
      }
      tileRows.add(Padding(padding: const EdgeInsets.only(bottom: 16), child: Row(children: row)));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...tileRows,
        _columns(width, [Surgir(ordem: 3, child: _quickWeight(weighed))], [Surgir(ordem: 4, child: _upcoming())]),
      ],
    );
  }

  Widget _quickWeight(bool weighed) => Vidro(
    margem: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TituloVidro(icone: Icons.scale_rounded, texto: weighed ? 'Corrigir pesagem de hoje' : 'Pesagem de hoje'),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _weight,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Peso', suffixText: 'kg'),
                onSubmitted: (_) => _saveWeight(),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(onPressed: _saveWeight, child: const Text('Salvar')),
          ],
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ActionChip(
              avatar: const Icon(Icons.photo_camera_rounded, size: 18),
              label: const Text('Registrar refeição'),
              onPressed: () => setState(() => _section = 2),
            ),
            ActionChip(
              avatar: const Icon(Icons.auto_awesome_rounded, size: 18),
              label: const Text('Montar treino de hoje'),
              onPressed: () => setState(() {
                _pickDays([today()]);
                _section = 1;
              }),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _upcoming() {
    final last = _plans.isEmpty ? null : _plans.first;
    final days = (last?['dias'] as List? ?? const []).cast<Map<String, dynamic>>();
    return Vidro(
      margem: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const TituloVidro(icone: Icons.event_note_rounded, texto: 'Plano atual'),
          if (days.isEmpty) const Text('Nenhum plano ainda. Abra "Treino" e escolha os dias.'),
          for (final d in days) _dayRow(d),
        ],
      ),
    );
  }

  Widget _dayRow(Map<String, dynamic> d) {
    final colors = Theme.of(context).colorScheme;
    final date = DateTime.parse(d['data'] as String);
    final isToday = sameDay(date, today());
    final fg = isToday ? colors.onPrimary : colors.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 46,
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              color: isToday ? colors.primary : colors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              children: [
                Text(weekdays[date.weekday - 1], style: TextStyle(fontSize: 11, color: fg)),
                Text('${date.day}', style: TextStyle(fontWeight: FontWeight.w700, color: fg)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Padding(padding: const EdgeInsets.only(top: 6), child: Text(d['foco'] as String? ?? ''))),
        ],
      ),
    );
  }

  // --- Treino ---

  Widget _workoutSection(double width) =>
      _columns(width, [Surgir(ordem: 0, child: _planComposer())], [Surgir(ordem: 1, child: _lastPlan())]);

  Widget _planComposer() {
    final text = Theme.of(context).textTheme;
    final start = today();
    final days = <DateTime>[];
    for (var i = 0; i < 14; i++) {
      days.add(addDays(start, i));
    }
    final count = _planDays.length;
    final ai = _ai == 'claude' ? 'Claude' : 'LLM local';
    return Vidro(
      margem: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const TituloVidro(icone: Icons.auto_awesome_rounded, texto: 'Montar treino'),
          Text('Quais dias? Os outros ficam como estão.', style: text.bodyMedium),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ActionChip(label: const Text('Só hoje'), onPressed: () => _pickDays([start])),
              ActionChip(label: const Text('Até domingo'), onPressed: () => _pickDays(_untilSunday())),
              ActionChip(label: const Text('Próximos 7 dias'), onPressed: () => _pickDays(days.sublist(0, 7))),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 64,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: days.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) => _DayChip(
                day: days[i],
                selected: _planDays.contains(days[i]),
                isToday: i == 0,
                onTap: () => _toggleDay(days[i]),
              ),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _request,
            minLines: 2,
            maxLines: 6,
            keyboardType: TextInputType.multiline,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Pedido (opcional)',
              hintText: 'ex.: vou treinar agora à noite, 45 min; dor no ombro esquerdo',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: _generating || count == 0 ? null : _generate,
            icon: _generating
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.auto_awesome_rounded),
            label: Text(
              _generating ? 'Montando… (pode levar alguns minutos)' : 'Montar ${count == 1 ? '1 dia' : '$count dias'} com $ai',
            ),
          ),
        ],
      ),
    );
  }

  Widget _lastPlan() {
    final last = _plans.isEmpty ? null : _plans.first;
    if (last == null) {
      return const Vidro(child: Text('Os planos montados aparecem aqui, com a explicação da IA.'));
    }
    final text = Theme.of(context).textTheme;
    final days = (last['dias'] as List).cast<Map<String, dynamic>>();
    return Vidro(
      margem: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TituloVidro(
            icone: Icons.checklist_rounded,
            texto: 'Último plano',
            acao: Text('${last['agendados']} exercícios', style: text.labelMedium),
          ),
          for (final d in days) _dayRow(d),
          const SizedBox(height: 6),
          TextButton.icon(
            onPressed: () => setState(() => _planOpen = !_planOpen),
            icon: AnimatedRotation(
              turns: _planOpen ? 0.5 : 0,
              duration: const Duration(milliseconds: 220),
              child: const Icon(Icons.expand_more_rounded),
            ),
            label: Text(_planOpen ? 'Esconder explicação' : 'Ver explicação e alimentação'),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _planOpen
                ? VisualizadorMarkdown(texto: '${last['resumo']}\n\n**Alimentação:** ${last['nutricao']}')
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  // --- Alimentação ---

  Widget _foodSection(double width) {
    final cards = <Widget>[];
    for (var i = 0; i < _meals.length; i++) {
      cards.add(Surgir(ordem: 2 + i, child: _mealCard(_meals[i])));
    }
    if (_meals.isEmpty) {
      cards.add(const Surgir(ordem: 2, child: Vidro(child: Text('Nenhuma refeição neste dia ainda.'))));
    }
    return _columns(width, [Surgir(ordem: 0, child: _daySummary()), Surgir(ordem: 1, child: _mealComposer())], cards);
  }

  Widget _daySummary() {
    final total = (_food?['total'] as Map?)?.cast<String, dynamic>() ?? const {};
    final targets = (_food?['metas'] as Map?)?.cast<String, dynamic>() ?? const {};
    final colors = Theme.of(context).colorScheme;
    return Vidro(
      margem: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(icon: const Icon(Icons.chevron_left_rounded), onPressed: () => _changeDay(-1)),
              Expanded(
                child: Text(
                  sameDay(_day, today()) ? 'Hoje' : longDay(_day),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(icon: const Icon(Icons.chevron_right_rounded), onPressed: () => _changeDay(1)),
            ],
          ),
          const SizedBox(height: 6),
          _MacroBar(
            label: 'Calorias',
            value: (total['kcal'] as num?) ?? 0,
            goal: targets['kcal'] as num?,
            unit: 'kcal',
            color: Colors.orange,
          ),
          _MacroBar(
            label: 'Proteína',
            value: (total['proteina_g'] as num?) ?? 0,
            goal: targets['proteina_g'] as num?,
            unit: 'g',
            color: colors.primary,
          ),
          _MacroBar(label: 'Carboidrato', value: (total['carboidrato_g'] as num?) ?? 0, unit: 'g', color: colors.secondary),
          _MacroBar(label: 'Gordura', value: (total['gordura_g'] as num?) ?? 0, unit: 'g', color: colors.tertiary),
        ],
      ),
    );
  }

  Widget _mealComposer() => Vidro(
    margem: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const TituloVidro(icone: Icons.add_a_photo_rounded, texto: 'Nova refeição', cor: Colors.orange),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final t in _mealTypes)
              ChoiceChip(label: Text(t), selected: t == _mealType, onSelected: (_) => setState(() => _mealType = t)),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _mealText,
          minLines: 3,
          maxLines: 8,
          keyboardType: TextInputType.multiline,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'O que você comeu (opcional com foto)',
            hintText: 'ex.: 4 conchas de arroz, 2 de feijão, 2 bifes, 1 copo de suco',
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _sending ? null : _sendMeal,
                icon: const Icon(Icons.photo_camera_rounded),
                label: const Text('Foto'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _sending ? null : () => _sendMeal(withPhoto: false),
                icon: const Icon(Icons.notes_rounded),
                label: const Text('Só texto'),
              ),
            ),
          ],
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          child: _sending
              ? const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator())
              : const SizedBox(width: double.infinity),
        ),
      ],
    ),
  );

  String _mealTitle(Map<String, dynamic> m) {
    final type = '${m['tipo'] ?? ''}';
    if (type.isEmpty) return 'Refeição';
    return type[0].toUpperCase() + type.substring(1);
  }

  Widget _mealCard(Map<String, dynamic> m) {
    final a = (m['analise'] as Map?)?.cast<String, dynamic>();
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Vidro(
      margem: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(_mealTitle(m), style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
              Text('${m['hora']}', style: text.labelMedium?.copyWith(color: colors.onSurfaceVariant)),
              IconButton(
                tooltip: 'Corrigir e recalcular',
                icon: const Icon(Icons.refresh_rounded),
                onPressed: _sending ? null : () => _reanalyze(m),
              ),
              IconButton(
                tooltip: 'Apagar',
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: () => _deleteMeal(m['id'] as String),
              ),
            ],
          ),
          if (m['foto'] != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image.network(
                widget.api.mealPhotoUrl(m['id'] as String).toString(),
                headers: widget.api.cabecalhos,
                height: 170,
                width: double.infinity,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox(height: 60, child: Center(child: Icon(Icons.broken_image_rounded))),
              ),
            ),
            const SizedBox(height: 10),
          ],
          if ((m['descricao'] as String? ?? '').isNotEmpty)
            Text(m['descricao'] as String, style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant)),
          if (a == null) const Text('Sem estimativa: toque em recalcular.'),
          if (a != null) ..._analysis(a),
        ],
      ),
    );
  }

  List<Widget> _analysis(Map<String, dynamic> a) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final items = (a['itens'] as List? ?? const []).cast<Map<String, dynamic>>();
    final comment = a['comentario'] as String? ?? '';
    return [
      const SizedBox(height: 10),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          _Badge('${a['kcal']} kcal', Colors.orange),
          _Badge('P ${a['proteina_g']} g', colors.primary),
          _Badge('C ${a['carboidrato_g']} g', colors.secondary),
          _Badge('G ${a['gordura_g']} g', colors.tertiary),
          _Badge('confiança ${a['confianca']}', colors.outline),
        ],
      ),
      const SizedBox(height: 10),
      for (final i in items)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text('${i['nome']} · ${i['quantidade']}')),
              const SizedBox(width: 8),
              Text('${i['kcal']} kcal', style: text.labelMedium),
            ],
          ),
        ),
      if (comment.isNotEmpty) ...[
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: colors.primary.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(12)),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.tips_and_updates_rounded, size: 18, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(comment, style: text.bodySmall)),
            ],
          ),
        ),
      ],
    ];
  }

  // --- Corpo ---

  Widget _bodySection(double width) => _columns(
    width,
    [Surgir(ordem: 0, child: _profileCard(width))],
    [Surgir(ordem: 1, child: _weightHistory()), Surgir(ordem: 2, child: _equipmentCard())],
  );

  Widget _profileCard(double width) {
    // two fields per line on the phone (card padding 18 on each side + 12 between)
    final half = width < 600 ? (width - 36 - 12) / 2 : 150.0;
    final targets = _targets;
    final colors = Theme.of(context).colorScheme;
    return Vidro(
      margem: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const TituloVidro(icone: Icons.person_rounded, texto: 'Perfil'),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _field(_weight, 'Peso hoje', half, 'kg'),
              _field(_height, 'Altura', half, 'cm'),
              _field(_age, 'Idade', half, 'anos'),
              _field(_minutes, 'Por treino', half, 'min'),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _limits,
            minLines: 1,
            maxLines: 4,
            keyboardType: TextInputType.multiline,
            decoration: const InputDecoration(labelText: 'Restrições ou dores (opcional)'),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(onPressed: _saveBody, child: const Text('Salvar perfil')),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Badge('Meta ${targets['kcal'] ?? '?'} kcal', Colors.orange),
              _Badge('Proteína ${targets['proteina_g'] ?? '?'} g', colors.primary),
              if (targets['imc'] != null) _Badge('IMC ${targets['imc']}', colors.tertiary),
            ],
          ),
        ],
      ),
    );
  }

  Widget _field(TextEditingController c, String label, double width, String suffix) => SizedBox(
    width: width,
    child: TextField(
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label, suffixText: suffix),
    ),
  );

  Widget _weightHistory() {
    final change = _weights.length < 2 ? 0.0 : (_weights.last['peso_kg'] as num) - (_weights.first['peso_kg'] as num);
    final badge = _weights.length < 2
        ? null
        : _Badge('${change >= 0 ? '+' : ''}${change.toStringAsFixed(1)} kg', change <= 0 ? Colors.green : Colors.orange);
    return Vidro(
      margem: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TituloVidro(icone: Icons.show_chart_rounded, texto: 'Evolução do peso', acao: badge),
          if (_weights.length < 2) const Text('Pese-se todos os dias para ver a linha de evolução.'),
          if (_weights.length > 1)
            SizedBox(
              height: 120,
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 900),
                curve: Curves.easeOutCubic,
                builder: (context, t, _) => CustomPaint(
                  size: Size.infinite,
                  painter: _WeightLine(_weights, Theme.of(context).colorScheme.primary, t),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _equipmentCard() => Vidro(
    margem: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const TituloVidro(icone: Icons.home_repair_service_rounded, texto: 'Materiais em casa'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [for (final item in _equipment) InputChip(label: Text(item), onDeleted: () => _removeEquipment(item))],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _newItem,
          onSubmitted: (_) => _addEquipment(),
          decoration: InputDecoration(
            hintText: 'Adicionar (ex.: elástico, banco, corda)',
            suffixIcon: IconButton(icon: const Icon(Icons.add_rounded), onPressed: _addEquipment),
          ),
        ),
      ],
    ),
  );
}

/// Today tile: icon, value and an animated progress bar.
class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    required this.detail,
    required this.progress,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String value;
  final String detail;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Vidro(
      cor: color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(width: 8),
              Text(label, style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
              const Spacer(),
              if (progress >= 1) Icon(Icons.check_circle_rounded, color: color, size: 20),
            ],
          ),
          const SizedBox(height: 10),
          Text(value, style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
          Text(detail, style: text.bodySmall),
          const SizedBox(height: 10),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: progress.clamp(0, 1).toDouble()),
            duration: const Duration(milliseconds: 900),
            curve: Curves.easeOutCubic,
            builder: (context, v, _) => ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(value: v, minHeight: 6, color: color, backgroundColor: color.withValues(alpha: 0.15)),
            ),
          ),
        ],
      ),
    );
  }
}

/// One day button of the plan picker (weekday + number), animated when chosen.
class _DayChip extends StatelessWidget {
  const _DayChip({required this.day, required this.selected, required this.isToday, required this.onTap});

  final DateTime day;
  final bool selected;
  final bool isToday;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final fg = selected ? colors.onPrimary : colors.onSurface;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        width: 54,
        decoration: BoxDecoration(
          color: selected ? colors.primary : colors.surfaceContainerHigh.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: isToday ? colors.primary : Colors.transparent, width: 1.5),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(isToday ? 'hoje' : weekdays[day.weekday - 1], style: TextStyle(fontSize: 11, color: fg)),
            Text('${day.day}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: fg)),
          ],
        ),
      ),
    );
  }
}

/// Macro line: label, value/goal and an animated bar (only when there is a goal).
class _MacroBar extends StatelessWidget {
  const _MacroBar({required this.label, required this.value, required this.unit, required this.color, this.goal});

  final String label;
  final num value;
  final num? goal;
  final String unit;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final g = goal;
    final fraction = g == null || g == 0 ? 0.0 : (value / g).clamp(0, 1).toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: text.bodyMedium)),
              Text(
                g == null ? '$value $unit' : '$value / $g $unit',
                style: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          if (g != null) ...[
            const SizedBox(height: 6),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: fraction),
              duration: const Duration(milliseconds: 800),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) => ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(value: v, minHeight: 8, color: color, backgroundColor: color.withValues(alpha: 0.15)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, this.color);

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(20)),
    child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12)),
  );
}

/// Weight line of the last 90 days, drawn from left to right by [t] (0..1), with a soft fill.
class _WeightLine extends CustomPainter {
  _WeightLine(this.weights, this.color, this.t);

  final List<Map<String, dynamic>> weights;
  final Color color;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final values = <double>[];
    for (final w in weights) {
      values.add((w['peso_kg'] as num).toDouble());
    }
    var low = values.first;
    var high = values.first;
    for (final v in values) {
      if (v < low) low = v;
      if (v > high) high = v;
    }
    final range = high - low < 0.5 ? 0.5 : high - low;
    final line = Path();
    final area = Path()..moveTo(0, size.height);
    final shown = (values.length * t).ceil().clamp(1, values.length);
    for (var i = 0; i < shown; i++) {
      final x = size.width * i / (values.length - 1);
      final y = 8 + (size.height - 16) * (1 - (values[i] - low) / range);
      if (i == 0) {
        line.moveTo(x, y);
      } else {
        line.lineTo(x, y);
      }
      area.lineTo(x, y);
    }
    area.lineTo(size.width * (shown - 1) / (values.length - 1), size.height);
    area.close();
    final fill = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [color.withValues(alpha: 0.35), color.withValues(alpha: 0)],
      ).createShader(Offset.zero & size);
    canvas.drawPath(area, fill);
    final stroke = Paint()
      ..color = color
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(line, stroke);
  }

  @override
  bool shouldRepaint(_WeightLine old) => old.t != t || old.weights != weights;
}
