import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../dates.dart';
import '../health_api.dart';

const _mealTypes = ['café da manhã', 'lanche', 'almoço', 'pré-treino', 'pós-treino', 'jantar', 'ceia'];

/// AI coach: profile, home equipment, daily weight, the week's workout (written into the Workouts
/// agenda) and meals by photo with calories and macros. The AI is Claude (Claude Code on the PC)
/// or the local LLM, chosen at the top.
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
  bool _generating = false;
  bool _sending = false;

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

  Future<void> _load() async {
    try {
      final profile = await widget.api.coachProfile();
      final weights = await widget.api.weights(addDays(today(), -90), today());
      final plans = await widget.api.workoutPlans();
      final todayFood = await widget.api.foodDay(today());
      final agenda = await widget.api.agenda(today(), today());
      if (!mounted) return;
      setState(() {
        _todayFood = todayFood;
        _todayWorkout = (agenda.where((i) => i.done).length, agenda.length);
        _profile = profile;
        _weights = weights;
        _plans = plans;
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
      await _loadDay();
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
    final kg = double.tryParse(_weight.text.replaceAll(',', '.'));
    if (kg == null) return;
    try {
      await widget.api.saveWeight(today(), kg);
      _weight.clear();
      await _load();
    } on ApiErro catch (e) {
      _notify(e);
    }
  }

  Future<void> _generate() async {
    setState(() => _generating = true);
    try {
      final plan = await widget.api.generateWorkoutPlan(_request.text, _ai);
      _request.clear();
      _notify('${plan['agendados']} exercícios agendados até domingo. Veja em Treinos.');
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
          maxLines: 3,
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

  @override
  Widget build(BuildContext context) {
    if (_profile == null) return const Center(child: CircularProgressIndicator());
    final wide = MediaQuery.sizeOf(context).width > 1100;
    final left = [_aiPicker(), _todayCard(), _planCard(), _equipmentCard()];
    final right = [_bodyCard(), _mealsCard()];
    if (!wide) {
      return ListView(padding: const EdgeInsets.all(16), children: [...left, ...right]);
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Column(children: left)),
          const SizedBox(width: 16),
          Expanded(child: Column(children: right)),
        ],
      ),
    );
  }

  Widget _card(String title, IconData icon, List<Widget> children) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [Icon(icon, size: 20), const SizedBox(width: 8), Text(title, style: Theme.of(context).textTheme.titleMedium)]),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    ),
  );

  Widget _aiPicker() => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Row(
      children: [
        const Text('IA do treinador:'),
        const SizedBox(width: 12),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'claude', label: Text('Claude'), icon: Icon(Icons.auto_awesome)),
            ButtonSegment(value: 'local', label: Text('LLM local'), icon: Icon(Icons.computer)),
          ],
          selected: {_ai},
          onSelectionChanged: (s) => _saveProfile({'ia': s.first}),
        ),
      ],
    ),
  );

  Widget _planCard() {
    final last = _plans.isEmpty ? null : _plans.first;
    return _card('Treino da semana', Icons.fitness_center, [
      Text(
        'Monta de hoje até domingo com seu peso, objetivos (hipertrofia, depois resistência), materiais e '
        'histórico, e grava na agenda de Treinos (substitui o que ainda não foi feito).',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _request,
        maxLines: 2,
        decoration: const InputDecoration(
          hintText: 'Pedido extra (opcional): ex.: quinta só tenho 30 min; dor no ombro esquerdo',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 8),
      FilledButton.icon(
        onPressed: _generating ? null : _generate,
        icon: _generating
            ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.auto_awesome),
        label: Text(_generating ? 'Montando (pode levar alguns minutos)…' : 'Montar treino até domingo'),
      ),
      if (last != null) ...[
        const Divider(height: 24),
        Text('Último plano: ${last['de']} a ${last['ate']} · ${last['ia']} · ${last['agendados']} exercícios',
            style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 8),
        for (final d in (last['dias'] as List).cast<Map<String, dynamic>>())
          Text('• ${_weekday(d['data'] as String)}: ${d['foco']}'),
        const SizedBox(height: 8),
        VisualizadorMarkdown(texto: '${last['resumo']}\n\n**Alimentação:** ${last['nutricao']}'),
      ],
    ]);
  }

  String _weekday(String isoDay) {
    final d = DateTime.parse(isoDay);
    return '${weekdays[d.weekday - 1]} ${d.day}';
  }

  Widget _equipmentCard() => _card('Materiais em casa', Icons.home_repair_service_outlined, [
    Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final item in _equipment) InputChip(label: Text(item), onDeleted: () => _removeEquipment(item)),
      ],
    ),
    const SizedBox(height: 8),
    TextField(
      controller: _newItem,
      onSubmitted: (_) => _addEquipment(),
      decoration: InputDecoration(
        hintText: 'Adicionar material (ex.: elástico, banco, corda)',
        suffixIcon: IconButton(icon: const Icon(Icons.add), onPressed: _addEquipment),
      ),
    ),
  ]);

  /// Daily routine: weigh in, log every meal, do the day's workout.
  Widget _todayCard() {
    final weight = (_todayFood?['peso'] as Map?)?.cast<String, dynamic>();
    final weighed = weight != null && weight['data'] == iso(today());
    final meals = _todayFood?['refeicoes'] as int? ?? 0;
    final kcal = (_todayFood?['total'] as Map?)?['kcal'] ?? 0;
    final goal = (_todayFood?['metas'] as Map?)?['kcal'];
    final (done, total) = _todayWorkout;
    return _card('Hoje', Icons.today_outlined, [
      _check(weighed, weighed ? 'Pesagem: ${weight['peso_kg']} kg' : 'Pesar (de manhã, em jejum)'),
      _check(meals >= 3, 'Refeições registradas: $meals · $kcal${goal == null ? '' : ' / $goal'} kcal'),
      _check(total > 0 && done == total, total == 0 ? 'Treino: nada na agenda (monte a semana abaixo)' : 'Treino: $done de $total exercícios'),
    ]);
  }

  Widget _check(bool ok, String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Icon(ok ? Icons.check_circle : Icons.radio_button_unchecked, size: 18, color: ok ? Colors.green : null),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    ),
  );

  Widget _bodyCard() {
    final targets = (_food?['metas'] as Map?)?.cast<String, dynamic>() ?? const {};
    final last = _weights.isEmpty ? null : _weights.last;
    final first = _weights.isEmpty ? null : _weights.first;
    final change = last == null || first == null ? null : (last['peso_kg'] as num) - (first['peso_kg'] as num);
    return _card('Peso e corpo', Icons.monitor_weight_outlined, [
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          _field(_weight, 'Peso de hoje (kg)', 140),
          _field(_height, 'Altura (cm)', 110),
          _field(_age, 'Idade', 80),
          _field(_minutes, 'Min por treino', 110),
        ],
      ),
      const SizedBox(height: 8),
      TextField(controller: _limits, decoration: const InputDecoration(labelText: 'Restrições ou dores (opcional)')),
      const SizedBox(height: 8),
      FilledButton.tonal(onPressed: _saveBody, child: const Text('Salvar')),
      const SizedBox(height: 12),
      if (last != null)
        Text('Atual: ${last['peso_kg']} kg (${last['data']})'
            '${change == null || _weights.length < 2 ? '' : ' · ${change >= 0 ? '+' : ''}${change.toStringAsFixed(1)} kg em 90 dias'}'),
      Text('Metas do dia: ${targets['kcal'] ?? '? (preencha a idade)'} kcal · proteína ${targets['proteina_g'] ?? '?'} g'
          '${targets['imc'] == null ? '' : ' · IMC ${targets['imc']}'}'),
      if (_weights.length > 1) ...[
        const SizedBox(height: 8),
        SizedBox(height: 60, child: CustomPaint(size: Size.infinite, painter: _WeightLine(_weights, Theme.of(context).colorScheme.primary))),
      ],
    ]);
  }

  Widget _field(TextEditingController c, String label, double width) => SizedBox(
    width: width,
    child: TextField(
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label),
    ),
  );

  Widget _mealsCard() {
    final total = (_food?['total'] as Map?)?.cast<String, dynamic>() ?? const {};
    final targets = (_food?['metas'] as Map?)?.cast<String, dynamic>() ?? const {};
    final kcal = (total['kcal'] as num?) ?? 0;
    final goal = targets['kcal'] as num?;
    return _card('Alimentação', Icons.restaurant_outlined, [
      Row(
        children: [
          IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => _changeDay(-1)),
          Text(longDay(_day)),
          IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => _changeDay(1)),
        ],
      ),
      Text('$kcal${goal == null ? '' : ' / $goal'} kcal · P ${total['proteina_g'] ?? 0} g'
          '${targets['proteina_g'] == null ? '' : ' / ${targets['proteina_g']}'} · C ${total['carboidrato_g'] ?? 0} g · G ${total['gordura_g'] ?? 0} g'),
      if (goal != null) ...[
        const SizedBox(height: 4),
        LinearProgressIndicator(value: (kcal / goal).clamp(0, 1).toDouble()),
      ],
      const SizedBox(height: 12),
      Row(
        children: [
          DropdownButton<String>(
            value: _mealType,
            items: [for (final t in _mealTypes) DropdownMenuItem(value: t, child: Text(t))],
            onChanged: (v) => setState(() => _mealType = v ?? _mealType),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _mealText,
              decoration: const InputDecoration(hintText: 'Descrição (opcional com foto)'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        children: [
          FilledButton.icon(
            onPressed: _sending ? null : _sendMeal,
            icon: const Icon(Icons.photo_camera_outlined),
            label: const Text('Foto da refeição'),
          ),
          OutlinedButton(
            onPressed: _sending ? null : () => _sendMeal(withPhoto: false),
            child: const Text('Só descrição'),
          ),
          if (_sending) const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        ],
      ),
      const SizedBox(height: 8),
      for (final m in _meals) _mealTile(m),
    ]);
  }

  void _changeDay(int n) {
    setState(() => _day = addDays(_day, n));
    _loadDay();
  }

  Widget _mealTile(Map<String, dynamic> m) {
    final a = (m['analise'] as Map?)?.cast<String, dynamic>();
    final items = (a?['itens'] as List? ?? const []).cast<Map<String, dynamic>>();
    return Card.outlined(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (m['foto'] != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.network(
                  widget.api.mealPhotoUrl(m['id'] as String).toString(),
                  headers: widget.api.cabecalhos,
                  width: 96,
                  height: 96,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox.square(dimension: 96, child: Icon(Icons.broken_image)),
                ),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${m['hora']} ${m['tipo']}'.trim(), style: Theme.of(context).textTheme.titleSmall),
                  if ((m['descricao'] as String? ?? '').isNotEmpty) Text(m['descricao'] as String),
                  if (a == null) const Text('Sem estimativa: toque em recalcular.'),
                  if (a != null) ...[
                    Text('${a['kcal']} kcal · P ${a['proteina_g']} g · C ${a['carboidrato_g']} g · '
                        'G ${a['gordura_g']} g · confiança ${a['confianca']} (${a['ia']})'),
                    for (final i in items) Text('  • ${i['nome']} (${i['quantidade']}): ${i['kcal']} kcal'),
                    Text(a['comentario'] as String? ?? '', style: Theme.of(context).textTheme.bodySmall),
                  ],
                ],
              ),
            ),
            Column(
              children: [
                IconButton(tooltip: 'Corrigir e recalcular', icon: const Icon(Icons.refresh), onPressed: _sending ? null : () => _reanalyze(m)),
                IconButton(tooltip: 'Apagar', icon: const Icon(Icons.delete_outline), onPressed: () => _deleteMeal(m['id'] as String)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Weight line of the last 90 days (min-max of the period).
class _WeightLine extends CustomPainter {
  _WeightLine(this.weights, this.color);

  final List<Map<String, dynamic>> weights;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final values = [for (final w in weights) (w['peso_kg'] as num).toDouble()];
    var low = values.first;
    var high = values.first;
    for (final v in values) {
      if (v < low) low = v;
      if (v > high) high = v;
    }
    final range = high - low < 0.5 ? 0.5 : high - low;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1);
      final y = size.height - (values[i] - low) / range * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, Paint()..color = color..strokeWidth = 2..style = PaintingStyle.stroke);
  }

  @override
  bool shouldRepaint(_WeightLine old) => old.weights != weights;
}
