import 'dart:math';

import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../health_api.dart';
import '../dates.dart';
import '../health_connect.dart';
import '../sync.dart';

/// Galaxy Watch dashboard: sleep, activity, heart and body. On Android, Health Connect is read on its own
/// (on opening the app and every hour in the background, see `sync.dart`) and by the buttons; on
/// any device it imports the Samsung Health export zip (history, stress, sleep score).
class WatchScreen extends StatefulWidget {
  const WatchScreen({super.key, required this.api});

  final HealthApi api;

  @override
  State<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends State<WatchScreen> {
  final _reader = HealthConnectReader();
  int _period = 30;
  List<Map<String, dynamic>>? _days;
  Map<String, dynamic> _summary = const {};
  Map<String, dynamic> _status = const {};
  String? _busy;

  /// Background reading authorized (null: not known yet or not Android).
  bool? _automatic;

  HealthApi get api => widget.api;

  @override
  void initState() {
    super.initState();
    _load();
    if (HealthConnectReader.disponivel) _checkAutomatic();
  }

  Future<void> _checkAutomatic() async {
    try {
      final ok =
          await _reader.problem() == null && await _reader.authorized() && await _reader.backgroundAuthorized();
      if (mounted) setState(() => _automatic = ok);
    } catch (_) {
      if (mounted) setState(() => _automatic = false);
    }
  }

  /// Requests the missing permissions (reading and background) and syncs the period right away.
  Future<void> _enableAutomatic() async {
    try {
      final problem = await _reader.problem();
      if (problem != null) return _notify(problem);
      if (!await _reader.authorized() && !await _reader.authorize()) {
        return _notify('Sem permissão de leitura no Health Connect.');
      }
      if (!await _reader.authorizeBackground()) {
        _notify('Permita "acessar dados em segundo plano" para o agent no Health Connect.');
      }
    } catch (e) {
      _notify(e);
    }
    await _checkAutomatic();
    await _sync(days: _period);
  }

  void _notify(Object e) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
  }

  Future<void> _load() async {
    final ate = today();
    final de = addDays(ate, -(_period - 1));
    try {
      final r = await Future.wait([api.watchDays(de, ate), api.watchSummary(de, ate), api.watchStatus()]);
      if (!mounted) return;
      setState(() {
        _days = r[0] as List<Map<String, dynamic>>;
        _summary = r[1] as Map<String, dynamic>;
        _status = r[2] as Map<String, dynamic>;
      });
    } on ApiErro catch (e) {
      _notify(e);
      if (mounted) setState(() => _days ??= []);
    }
  }

  /// Reads [days] of Health Connect and sends them to the backend; the first time it requests the permissions.
  Future<void> _sync({required int days}) async {
    if (_busy != null) return;
    try {
      final problem = await _reader.problem();
      if (problem != null) return _notify(problem);
      if (!await _reader.authorized()) {
        if (!await _reader.authorize()) return _notify('Sem permissão de leitura no Health Connect.');
        await _checkAutomatic();
      }
      final sent = await syncWatch(
        api,
        _reader,
        days: days,
        onRead: (de, ate) {
          if (mounted) setState(() => _busy = 'Lendo ${shortDay(de)} a ${shortDay(ate)}…');
        },
      );
      _notify('$sent dias sincronizados do Health Connect.');
      await _load();
    } catch (e) {
      _notify(e);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _import() async {
    final r = await FilePicker.pickFiles(
      dialogTitle: 'Exportação do Samsung Health (.zip)',
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    if (r.isEmpty) return;
    setState(() => _busy = 'Importando ${r.first.name}…');
    try {
      final res = await api.importSamsung(r.first.name, await r.first.xFile.readAsBytes());
      _notify('${res['dias']} dias importados (${(res['arquivos'] as List).join(', ')}).');
      await _load();
    } on ApiErro catch (e) {
      _notify(e);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  String _when(String? isoUtc) {
    final d = DateTime.tryParse(isoUtc ?? '')?.toLocal();
    if (d == null) return 'nunca';
    return '${shortDay(d)} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final days = _days;
    final topic = Theme.of(context);
    return RefreshIndicator(
      onRefresh: HealthConnectReader.disponivel ? () => _sync(days: 7) : _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Header(
            period: _period,
            changePeriod: (p) {
              setState(() => _period = p);
              _load();
            },
            busy: _busy != null,
            sync: HealthConnectReader.disponivel ? () => _sync(days: _period) : null,
            fetchYear: HealthConnectReader.disponivel ? () => _sync(days: 365) : null,
            importData: _import,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              _Status(Icons.watch_outlined, 'Health Connect: ${_when(_status['health_connect'] as String?)}'),
              _Status(Icons.folder_zip_outlined, 'Exportação: ${_when(_status['exportacao'] as String?)}'),
              if (_automatic == true) const _Status(Icons.sync, 'Automática a cada hora'),
            ],
          ),
          if (_automatic == false) ...[
            const SizedBox(height: 8),
            Card(
              color: topic.colorScheme.secondaryContainer,
              child: ListTile(
                leading: const Icon(Icons.sync_disabled),
                title: const Text('Sincronização automática desligada'),
                subtitle: const Text('Permita a leitura em segundo plano para o relógio chegar sozinho, a cada hora.'),
                trailing: FilledButton(
                  onPressed: _busy == null ? _enableAutomatic : null,
                  child: const Text('Ativar'),
                ),
              ),
            ),
          ],
          if (_busy != null) ...[
            const SizedBox(height: 8),
            Row(
              spacing: 8,
              children: [
                const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                Flexible(child: Text(_busy!)),
              ],
            ),
          ],
          const SizedBox(height: 16),
          if (days == null)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (days.isEmpty)
            const _NoData()
          else ...[
            _Indicators(key: ValueKey(_period), summary: _summary, last: days.last),
            const SizedBox(height: 16),
            _Charts(
              key: ValueKey('g$_period'),
              days: days,
              de: addDays(today(), -(_period - 1)),
              period: _period,
            ),
            const SizedBox(height: 16),
            _Exercises(days: days),
          ],
        ],
      ),
    );
  }
}

/// Period and actions. On the phone: period across the full width and "Sincronizar" with the other actions as
/// icon buttons beside it (before, the three large buttons wrapped into loose lines).
class _Header extends StatelessWidget {
  const _Header({
    required this.period,
    required this.changePeriod,
    required this.busy,
    required this.sync,
    required this.fetchYear,
    required this.importData,
  });

  final int period;
  final ValueChanged<int> changePeriod;
  final bool busy;
  final VoidCallback? sync, fetchYear;
  final VoidCallback importData;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final narrow = c.maxWidth < 600;
      final periods = SegmentedButton<int>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: 7, label: Text('7 dias')),
          ButtonSegment(value: 30, label: Text('30 dias')),
          ButtonSegment(value: 90, label: Text('90 dias')),
        ],
        selected: {period},
        onSelectionChanged: (s) => changePeriod(s.first),
      );
      final syncState = sync == null
          ? null
          : FilledButton.icon(
              onPressed: busy ? null : sync,
              icon: const Icon(Icons.sync),
              label: const Text('Sincronizar'),
            );
      final title = Text('Sono e corpo', style: Theme.of(context).textTheme.titleLarge);
      if (!narrow) {
        return Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            title,
            periods,
            ?syncState,
            if (fetchYear != null)
              OutlinedButton.icon(
                onPressed: busy ? null : fetchYear,
                icon: const Icon(Icons.history),
                label: const Text('Buscar 1 ano'),
              ),
            OutlinedButton.icon(
              onPressed: busy ? null : importData,
              icon: const Icon(Icons.upload_file),
              label: const Text('Importar exportação'),
            ),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          title,
          periods,
          Row(
            spacing: 8,
            children: [
              if (syncState != null) Expanded(child: syncState) else const Spacer(),
              if (fetchYear != null)
                IconButton.outlined(
                  tooltip: 'Buscar 1 ano',
                  onPressed: busy ? null : fetchYear,
                  icon: const Icon(Icons.history),
                ),
              IconButton.outlined(
                tooltip: 'Importar exportação',
                onPressed: busy ? null : importData,
                icon: const Icon(Icons.upload_file),
              ),
            ],
          ),
        ],
      );
    },
  );
}

class _Status extends StatelessWidget {
  const _Status(this.icone, this.text);

  final IconData icone;
  final String text;

  @override
  Widget build(BuildContext context) {
    final estilo = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        Icon(icone, size: 14, color: estilo?.color),
        Flexible(child: Text(text, style: estilo)),
      ],
    );
  }
}

/// Staggered entrance: each child rises and appears [delay] after the previous one.
class _Entry extends StatelessWidget {
  const _Entry({required this.order, required this.child});

  final int order;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: Duration(milliseconds: 350 + 60 * min(order, 8)),
    curve: Interval(min(order, 8) * 60 / (350 + 60 * min(order, 8)), 1, curve: Curves.easeOutCubic),
    builder: (_, t, child) => Opacity(
      opacity: t,
      child: Transform.translate(offset: Offset(0, 16 * (1 - t)), child: child),
    ),
    child: child,
  );
}

class _NoData extends StatelessWidget {
  const _NoData();

  @override
  Widget build(BuildContext context) => const Card(
    child: Padding(
      padding: EdgeInsets.all(16),
      child: Text(
        'Nenhum dado do relógio neste período.\n\n'
        '• No celular: Samsung Health › Configurações › Health Connect, ative a sincronização; '
        'depois toque em "Sincronizar" aqui.\n'
        '• Histórico completo (com estresse e pontuação do sono): Samsung Health › Configurações › '
        'Baixar dados pessoais, e "Importar exportação" com o .zip.',
      ),
    ),
  );
}

String hours(num minutes) => '${minutes ~/ 60}h${(minutes % 60).round().toString().padLeft(2, '0')}';

class _Indicators extends StatelessWidget {
  const _Indicators({super.key, required this.summary, required this.last});

  final Map<String, dynamic> summary;
  final Map<String, dynamic> last;

  @override
  Widget build(BuildContext context) {
    final m = (summary['medias'] as Map?)?.cast<String, num>() ?? const {};
    final goals = (summary['metas'] as Map?)?.cast<String, dynamic>() ?? const {};
    String meta(String k) {
      final x = goals[k] as Map?;
      return x == null || x['dias'] == 0 ? '' : '${x['batidos']} de ${x['dias']} dias na meta';
    }

    (int, int)? progress(String k) {
      final x = goals[k] as Map?;
      return x == null || x['dias'] == 0 ? null : ((x['batidos'] as num).toInt(), (x['dias'] as num).toInt());
    }

    String whole(num v) => '${v.round()}';
    final peso = (last['peso_kg'] ?? m['peso_kg']) as num?;
    final cards = <_Card>[
      if (m['sono_min'] != null)
        _Card(
          'Sono médio',
          m['sono_min']!,
          hours,
          meta('sono_min'),
          Icons.bedtime_outlined,
          Colors.indigo.shade300,
          progress('sono_min'),
        ),
      if (m['passos'] != null)
        _Card(
          'Passos por dia',
          m['passos']!,
          whole,
          meta('passos'),
          Icons.directions_walk,
          Colors.green.shade400,
          progress('passos'),
        ),
      if (m['minutos_ativos'] != null)
        _Card(
          'Minutos ativos',
          m['minutos_ativos']!,
          whole,
          meta('minutos_ativos'),
          Icons.local_fire_department_outlined,
          Colors.orange,
          progress('minutos_ativos'),
        ),
      if (m['fc_repouso'] != null)
        _Card(
          'FC em repouso',
          m['fc_repouso']!,
          (v) => '${v.round()} bpm',
          '',
          Icons.favorite_border,
          Colors.red.shade400,
        ),
      if (m['hrv_ms'] != null)
        _Card(
          'Variabilidade (HRV)',
          m['hrv_ms']!,
          (v) => '${v.round()} ms',
          '',
          Icons.monitor_heart_outlined,
          Colors.teal,
        ),
      if (m['estresse'] != null)
        _Card('Estresse', m['estresse']!, whole, 'de 0 a 100', Icons.psychology_outlined, Colors.amber.shade700),
      if (m['spo2'] != null) _Card('Oxigênio (SpO₂)', m['spo2']!, (v) => '${v.round()}%', '', Icons.air, Colors.cyan),
      if (m['sono_pontuacao'] != null)
        _Card(
          'Nota do sono',
          m['sono_pontuacao']!,
          whole,
          // without the Samsung export, the backend computes it from the duration and the stages
          last['sono_pontuacao_estimada'] == true ? 'pelos estágios do sono' : 'do Samsung Health',
          Icons.star_outline,
          Colors.purple.shade300,
        ),
      if (peso != null)
        _Card(
          'Peso',
          peso,
          (v) => '${v.toStringAsFixed(1)} kg',
          last['gordura_pct'] != null ? '${last['gordura_pct']}% de gordura' : '',
          Icons.monitor_weight_outlined,
          Colors.blueGrey.shade300,
        ),
      if (m['agua_ml'] != null)
        _Card(
          'Água',
          m['agua_ml']!,
          (v) => '${(v / 1000).toStringAsFixed(1)} L',
          meta('agua_ml'),
          Icons.water_drop_outlined,
          Colors.lightBlue,
          progress('agua_ml'),
        ),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        // 2 columns on the phone, up to 5 on a wide screen; cards take the full width.
        final columns = (c.maxWidth / 200).floor().clamp(2, 5);
        final width = (c.maxWidth - 12 * (columns - 1)) / columns;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final (i, card) in cards.indexed)
              SizedBox(
                width: width,
                child: _Entry(order: i, child: card),
              ),
          ],
        );
      },
    );
  }
}

/// Indicator with the number counting up from zero and, when there is a goal, the bar of the days met.
class _Card extends StatelessWidget {
  const _Card(this.title, this.value, this.formatStr, this.sub, this.icone, this.color, [this.progress]);

  final String title;
  final num value;
  final String Function(num) formatStr;
  final String sub;
  final IconData icone;
  final Color color;
  final (int, int)? progress;

  @override
  Widget build(BuildContext context) {
    final topic = Theme.of(context);
    final p = progress;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 6,
          children: [
            Row(
              spacing: 6,
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: color.withValues(alpha: .18),
                  child: Icon(icone, size: 16, color: color),
                ),
                Expanded(
                  child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: topic.textTheme.labelLarge),
                ),
              ],
            ),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: value.toDouble()),
              duration: const Duration(milliseconds: 900),
              curve: Curves.easeOutCubic,
              builder: (_, v, _) => FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  // at the end shows the exact value (the animation goes through fractions)
                  formatStr(v == value.toDouble() ? value : v),
                  style: topic.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ),
            if (p != null)
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: p.$1 / p.$2),
                duration: const Duration(milliseconds: 900),
                curve: Curves.easeOutCubic,
                builder: (_, t, _) => LinearProgressIndicator(
                  value: t,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                  color: color,
                  backgroundColor: color.withValues(alpha: .15),
                ),
              ),
            if (sub.isNotEmpty)
              Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: topic.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

/// Bars per day, stacked when there are [parts] (e.g. sleep stages), with a Y axis, the [goal] line,
/// period average/min/max and the detail of the tapped day (tap or drag over the bars).
class DaysChart extends StatefulWidget {
  const DaysChart({
    super.key,
    required this.title,
    required this.days,
    required this.parts,
    this.meta,
    this.label,
    this.unit,
    this.stepY,
    this.fromMinimum = false,
  });

  final String title;
  final List<DateTime> days;

  /// nome → (cor, valor por dia ISO).
  final Map<String, (Color, Map<String, num>)> parts;
  final num? meta;
  final String Function(num)? label;

  /// Unit shown next to the value in the detail (e.g. 'bpm').
  final String? unit;

  /// Fixed step of the Y axis ticks (e.g. 120 min on sleep); without it, an automatic "round" step.
  final num? stepY;

  /// Y axis starts near the smallest value (HR, weight): the variation between days stays visible.
  final bool fromMinimum;

  @override
  State<DaysChart> createState() => _DaysChartState();
}

class _DaysChartState extends State<DaysChart> with SingleTickerProviderStateMixin {
  static const _marginY = 44.0;
  static const _top = 18.0;

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..forward();
  String? _sel;

  String _signature(DaysChart w) => [
    for (final d in w.days) iso(d),
    for (final MapEntry(:key, value: (_, v)) in w.parts.entries) '$key${v.entries.map((e) => '${e.key}${e.value}')}',
  ].join('|');

  @override
  void didUpdateWidget(DaysChart oldValue) {
    super.didUpdateWidget(oldValue);
    if (_signature(oldValue) != _signature(widget)) {
      _sel = null;
      _anim.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  num? _total(String d) {
    num? sum;
    for (final (_, valueList) in widget.parts.values) {
      final v = valueList[d];
      if (v != null) sum = (sum ?? 0) + v;
    }
    return sum;
  }

  String _fmt(num v) => widget.label?.call(v) ?? (v is int || v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1));

  String _fmtAxis(num v) {
    if (widget.label != null) return widget.label!(v);
    if (v.abs() >= 1000) {
      final k = v / 1000;
      return '${k == k.roundToDouble() ? k.round() : k.toStringAsFixed(1)}k';
    }
    return _fmt(v);
  }

  /// "Round" step (1, 2, 2.5 or 5 × 10ⁿ) for ~4 ticks in the range.
  static num _roundStep(num intervalo) {
    if (intervalo <= 0) return 1;
    final raw = intervalo / 4;
    final mag = pow(10, (log(raw) / ln10).floor());
    for (final m in [1, 2, 2.5, 5, 10]) {
      if (raw <= m * mag) return m * mag;
    }
    return 10 * mag;
  }

  @override
  Widget build(BuildContext context) {
    final topic = Theme.of(context);
    final w = widget;
    final totals = {for (final d in w.days) iso(d): _total(iso(d))};
    final comDados = [for (final v in totals.values) ?v];
    final larger = [...comDados, ?w.meta].fold<num>(0, max);
    final smaller = comDados.isEmpty ? 0 : comDados.reduce(min);
    final step = w.stepY ?? _roundStep(w.fromMinimum ? max<num>(larger - smaller, 1) * 1.5 : max<num>(larger, 1));
    final floor = w.fromMinimum ? max<num>(0, (smaller / step).floor() * step - step) : 0;
    final ceiling = max<num>(floor + step, ((larger / step).floor() + 1) * step);
    final marks = [for (var t = floor; t <= ceiling + step / 1000; t += step) t];
    final media = comDados.isEmpty ? null : comDados.reduce((a, b) => a + b) / comDados.length;
    final sel = _sel ?? [for (final d in w.days.reversed) if (totals[iso(d)] != null) iso(d)].firstOrNull;
    final n = w.days.length;
    final colors = topic.colorScheme;

    Widget detail() {
      final day = w.days.where((d) => iso(d) == sel).firstOrNull;
      if (day == null) return Text('Toque numa barra para ver o dia.', style: topic.textTheme.bodySmall);
      final total = totals[sel];
      final un = w.unit == null ? '' : ' ${w.unit}';
      final partsText = w.parts.length > 1 && total != null
          ? ' (${[for (final MapEntry(key: name, value: (_, v)) in w.parts.entries) if (v[sel] != null) '$name ${_fmt(v[sel]!)}'].join(' · ')})'
          : '';
      final diff = total != null && w.meta != null ? total - w.meta! : null;
      return Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '${weekdays[day.weekday - 1]}, ${shortDay(day)}: ', style: topic.textTheme.bodySmall),
            TextSpan(
              text: total == null ? 'sem dados' : '${_fmt(total)}$un',
              style: topic.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            TextSpan(text: partsText, style: topic.textTheme.bodySmall),
            if (diff != null)
              TextSpan(
                text: diff >= 0 ? '  meta batida' : '  faltou ${_fmt(-diff)}',
                style: topic.textTheme.bodySmall?.copyWith(color: diff >= 0 ? Colors.green : colors.error),
              ),
          ],
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(w.title, style: topic.textTheme.titleMedium),
                if (w.parts.length > 1)
                  for (final MapEntry(key: name, value: (color, _)) in w.parts.entries)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 4,
                      children: [
                        Container(width: 10, height: 10, color: color),
                        Text(name, style: topic.textTheme.bodySmall),
                      ],
                    ),
                if (w.meta != null) Text('meta ${_fmt(w.meta!)}', style: topic.textTheme.bodySmall),
              ],
            ),
            if (media != null)
              Text(
                'média ${_fmt(media)} · mín ${_fmt(smaller)} · máx ${_fmt(comDados.reduce(max))}'
                '${w.unit == null ? '' : ' (${w.unit})'}',
                style: topic.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
            SizedBox(
              height: 170,
              child: LayoutBuilder(
                builder: (context, c) {
                  final area = c.maxHeight - _top;
                  double y(num v) => area * ((v - floor) / (ceiling - floor)).clamp(0, 1);
                  void play(double x) {
                    final i = ((x - _marginY) / (c.maxWidth - _marginY) * n).floor();
                    if (i >= 0 && i < n) setState(() => _sel = iso(w.days[i]));
                  }

                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (e) => play(e.localPosition.dx),
                    onHorizontalDragUpdate: (e) => play(e.localPosition.dx),
                    child: AnimatedBuilder(
                      animation: _anim,
                      builder: (context, _) => Stack(
                        clipBehavior: Clip.none,
                        children: [
                          for (final t in marks) ...[
                            Positioned(
                              left: _marginY,
                              right: 0,
                              bottom: y(t),
                              child: Container(height: 1, color: colors.outlineVariant.withValues(alpha: .35)),
                            ),
                            Positioned(
                              left: 0,
                              width: _marginY - 6,
                              bottom: y(t) - 7,
                              child: Text(
                                _fmtAxis(t),
                                textAlign: TextAlign.right,
                                style: topic.textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant, fontSize: 10),
                              ),
                            ),
                          ],
                          if (w.meta != null)
                            Positioned(
                              left: _marginY,
                              right: 0,
                              bottom: y(w.meta!),
                              child: Container(height: 1.5, color: colors.error.withValues(alpha: .7)),
                            ),
                          Positioned.fill(
                            left: _marginY,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (final (i, d) in w.days.indexed)
                                  Expanded(child: _bar(context, i, d, totals[iso(d)], y, iso(d) == sel)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: _marginY),
              child: n <= 14
                  ? Row(
                      children: [
                        for (final d in w.days)
                          Expanded(
                            child: Text(
                              n <= 7 ? '${weekdays[d.weekday - 1]}\n${d.day}' : '${d.day}',
                              textAlign: TextAlign.center,
                              style: topic.textTheme.labelSmall?.copyWith(
                                fontWeight: iso(d) == sel ? FontWeight.bold : null,
                                color: iso(d) == sel ? colors.primary : null,
                              ),
                            ),
                          ),
                      ],
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(shortDay(w.days.first), style: topic.textTheme.labelSmall),
                        Text(shortDay(w.days[n ~/ 2]), style: topic.textTheme.labelSmall),
                        Text(shortDay(w.days.last), style: topic.textTheme.labelSmall),
                      ],
                    ),
            ),
            detail(),
          ],
        ),
      ),
    );
  }

  /// One chart column: value on top (up to 7 days or on the selected day) and the bar growing from below.
  Widget _bar(BuildContext context, int i, DateTime d, num? total, double Function(num) y, bool selected) {
    final topic = Theme.of(context);
    final n = widget.days.length;
    if (total == null) return const SizedBox.shrink();
    final start = n <= 1 ? 0.0 : .4 * i / (n - 1);
    final grows = Curves.easeOutCubic.transform(((_anim.value - start) / .6).clamp(0, 1));
    final height = max(2.0, y(total) * grows);
    final off = widget.days.any((x) => iso(x) == _sel) && !selected;
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (n <= 7 || selected)
          Opacity(
            opacity: grows,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                _fmtAxis(total),
                style: topic.textTheme.labelSmall?.copyWith(fontWeight: selected ? FontWeight.bold : null, fontSize: 10),
              ),
            ),
          ),
        const SizedBox(height: 2),
        AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: off ? .45 : 1,
          child: Container(
            height: height,
            margin: EdgeInsets.symmetric(horizontal: n > 45 ? .5 : (n > 14 ? 1 : 3)),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.vertical(top: Radius.circular(n > 14 ? 1 : 4)),
              border: selected ? Border.all(color: topic.colorScheme.onSurface, width: 1.5) : null,
            ),
            child: Column(
              children: [
                for (final (color, valueList) in widget.parts.values.toList().reversed)
                  if ((valueList[iso(d)] ?? 0) > 0)
                    Expanded(flex: max(1, (valueList[iso(d)]! * 100).round()), child: Container(color: color)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Charts extends StatelessWidget {
  const _Charts({super.key, required this.days, required this.de, required this.period});

  final List<Map<String, dynamic>> days;
  final DateTime de;
  final int period;

  Map<String, num> _set(String field) => {
    for (final d in days)
      if (d[field] is num) d['data'] as String: d[field] as num,
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final axis = [for (var i = 0; i < period; i++) addDays(de, i)];
    final withStages = days.any((d) => d['sono_profundo_min'] != null);
    final lightSleep = {
      for (final d in days)
        if (d['sono_min'] is num)
          d['data'] as String: withStages
              ? max<num>(0, (d['sono_min'] as num) - (d['sono_profundo_min'] ?? 0) - (d['sono_rem_min'] ?? 0))
              : d['sono_min'] as num,
    };
    final charts = <Widget>[
      if (lightSleep.isNotEmpty)
        DaysChart(
          title: 'Sono por noite',
          days: axis,
          meta: 420,
          label: hours,
          stepY: 120,
          parts: {
            if (withStages) 'profundo': (Colors.indigo, _set('sono_profundo_min')),
            if (withStages) 'REM': (Colors.purple.shade300, _set('sono_rem_min')),
            withStages ? 'leve' : 'sono': (Colors.lightBlue.shade300, lightSleep),
          },
        ),
      if (_set('passos').isNotEmpty)
        DaysChart(title: 'Passos', days: axis, meta: 8000, unit: 'passos', parts: {'passos': (colors.primary, _set('passos'))}),
      if (_set('minutos_ativos').isNotEmpty)
        DaysChart(
          title: 'Minutos ativos',
          days: axis,
          meta: 30,
          unit: 'min',
          parts: {'min': (Colors.orange, _set('minutos_ativos'))},
        ),
      if (_set('fc_repouso').isNotEmpty || _set('fc_media').isNotEmpty)
        DaysChart(
          title: _set('fc_repouso').isNotEmpty ? 'FC em repouso (bpm)' : 'FC média (bpm)',
          days: axis,
          unit: 'bpm',
          fromMinimum: true,
          parts: {'bpm': (Colors.red.shade400, _set(_set('fc_repouso').isNotEmpty ? 'fc_repouso' : 'fc_media'))},
        ),
      if (_set('hrv_ms').isNotEmpty)
        DaysChart(title: 'HRV (ms)', days: axis, unit: 'ms', fromMinimum: true, parts: {'ms': (Colors.teal, _set('hrv_ms'))}),
      if (_set('estresse').isNotEmpty)
        DaysChart(title: 'Estresse', days: axis, parts: {'estresse': (Colors.amber.shade700, _set('estresse'))}),
      if (_set('peso_kg').isNotEmpty)
        DaysChart(
          title: 'Peso (kg)',
          days: axis,
          label: (v) => v.toStringAsFixed(1),
          unit: 'kg',
          fromMinimum: true,
          parts: {'kg': (Colors.blueGrey, _set('peso_kg'))},
        ),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final columns = c.maxWidth >= 1100 ? 2 : 1;
        final width = (c.maxWidth - 12 * (columns - 1)) / columns;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final (i, g) in charts.indexed)
              SizedBox(
                width: width,
                child: _Entry(order: i, child: g),
              ),
          ],
        );
      },
    );
  }
}

class _Exercises extends StatelessWidget {
  const _Exercises({required this.days});

  final List<Map<String, dynamic>> days;

  @override
  Widget build(BuildContext context) {
    final itens = [
      for (final d in days.reversed)
        for (final e in (d['exercicios'] as List? ?? const []).cast<Map<String, dynamic>>()) (d['data'] as String, e),
    ];
    if (itens.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text('Exercícios registrados pelo relógio', style: Theme.of(context).textTheme.titleMedium),
          ),
          for (final (data, e) in itens.take(20))
            ListTile(
              dense: true,
              leading: const Icon(Icons.directions_run),
              title: Text('${e['tipo']} · ${e['minutos']} min'),
              subtitle: Text(
                [
                  '${shortDay(DateTime.parse(data))} ${e['inicio'] ?? ''}',
                  if (e['calorias'] != null) '${e['calorias']} kcal',
                  if (e['distancia_km'] != null) '${e['distancia_km']} km',
                ].join(' · '),
              ),
            ),
        ],
      ),
    );
  }
}
