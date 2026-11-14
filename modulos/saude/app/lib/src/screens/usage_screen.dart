import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../health_api.dart';
import '../native_usage.dart';
import '../dates.dart';

void _notify(BuildContext context, Object e) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));

const _modes = {'livre': 'Livre', 'limite': 'Com limite', 'bloqueado': 'Bloqueado'};
const _categoryIcons = {
  'redes_sociais': Icons.forum_outlined,
  'videos': Icons.play_circle_outline,
  'compras': Icons.shopping_bag_outlined,
  'noticias': Icons.newspaper_outlined,
  'navegadores': Icons.public,
  'adulto': Icons.block,
  'vpn': Icons.vpn_lock_outlined,
};

/// Saúde › Mental › Consumo: rules with a 24 h lock, device usage and the "watcher" (local LLM).
class UsageScreen extends StatefulWidget {
  const UsageScreen({super.key, required this.api});

  final HealthApi api;

  @override
  State<UsageScreen> createState() => _UsageScreenState();
}

class _UsageScreenState extends State<UsageScreen> {
  Map<String, dynamic>? _config;
  Map<String, dynamic>? _summary;
  List<Map<String, dynamic>> _devices = const [];
  Map<String, bool> _permissions = const {};
  int _period = 7;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
    // on Android, applies the backend rules on this device every time it opens
    NativeUsage.sync(widget.api);
  }

  Future<void> _load() async {
    try {
      final cfg = await widget.api.usageConfig();
      final res = await widget.api.usageSummary(addDays(today(), -(_period - 1)), today());
      final dev = await widget.api.devices();
      final perm = await NativeUsage.permissions();
      if (mounted) {
        setState(() => (_config = cfg, _summary = res, _devices = dev, _permissions = perm));
      }
    } on ApiErro catch (e) {
      if (mounted) _notify(context, e);
    }
  }

  Future<void> _requestPermission(String permission) async {
    await NativeUsage.requestPermission(permission);
    // on returning from the system screen, rereads the state (it may still be granting)
    if (mounted) await _load();
  }

  Future<void> _act(Future<Map<String, dynamic>> Function() f) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await f();
      final pend = r['pendencia'] as Map<String, dynamic>?;
      if (mounted && pend != null) {
        _notify(context, 'Afrouxar espera 24 h: libera ${_when(pend['libera_em'] as String?)}.');
      }
      await _load();
      await NativeUsage.sync(widget.api);
    } on ApiErro catch (e) {
      if (mounted) _notify(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = _config;
    final topic = Theme.of(context);
    if (cfg == null) return const Center(child: CircularProgressIndicator());
    final categories = (cfg['categorias'] as Map).cast<String, String>();
    final rules = (cfg['regras'] as Map).cast<String, dynamic>();
    final pendingItems = (cfg['pendencias'] as List).cast<Map<String, dynamic>>();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (NativeUsage.disponivel)
            _Permissions(permissions: _permissions, onRequest: _requestPermission),
          Row(
            children: [
              Expanded(child: Text('Regras por categoria', style: topic.textTheme.titleLarge)),
              if (_busy)
                const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Apertar vale na hora; afrouxar só depois de 24 h. O WhatsApp fica de fora — é o seu trabalho.',
            style: topic.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          for (final c in categories.keys)
            _RuleCard(
              category: c,
              name: categories[c]!,
              rule: (rules[c] as Map).cast<String, dynamic>(),
              busy: _busy,
              aoMudar: (r) => _act(() => widget.api.setRule(c, r)),
            ),
          if (pendingItems.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Esperando 24 h', style: topic.textTheme.titleMedium),
            for (final p in pendingItems)
              Card(
                color: topic.colorScheme.tertiaryContainer,
                child: ListTile(
                  leading: const Icon(Icons.hourglass_bottom),
                  title: Text(p['descricao'] as String? ?? 'Afrouxar regra'),
                  subtitle: Text('Libera ${_when(p['libera_em'] as String?)}'),
                  trailing: TextButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            await widget.api.cancelPending(p['id'] as String);
                            await _load();
                          },
                    child: const Text('Cancelar'),
                  ),
                ),
              ),
          ],
          const Divider(height: 40),
          _Protection(devices: _devices),
          const Divider(height: 40),
          Row(
            children: [
              Expanded(child: Text('Como foi o uso', style: topic.textTheme.titleLarge)),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 7, label: Text('7 d')),
                  ButtonSegment(value: 30, label: Text('30 d')),
                ],
                selected: {_period},
                onSelectionChanged: (s) {
                  setState(() => _period = s.first);
                  _load();
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          _Uso(summary: _summary, categories: categories),
          const SizedBox(height: 24),
          _Guard(api: widget.api, period: _period),
        ],
      ),
    );
  }
}

String _when(String? iso) {
  if (iso == null) return '—';
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return iso;
  String twoDigits(int n) => n.toString().padLeft(2, '0');
  return '${twoDigits(d.day)}/${twoDigits(d.month)} ${twoDigits(d.hour)}:${twoDigits(d.minute)}';
}

/// Card that shows when some Android authorization to apply the rules is missing.
class _Permissions extends StatelessWidget {
  const _Permissions({required this.permissions, required this.onRequest});

  final Map<String, bool> permissions;
  final void Function(String permission) onRequest;

  // only usage access: accessibility, VPN and device admin were removed (banks flag the app)
  static const _items = [
    ('uso', 'Leitura de uso', 'Para medir o tempo em cada app.', Icons.timelapse_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    final topic = Theme.of(context);
    if (permissions.isEmpty) return const SizedBox.shrink();
    final missing = _items.where((i) => permissions[i.$1] == false).toList();
    if (missing.isEmpty) return const SizedBox.shrink();
    return Card(
      color: topic.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.lock_outline, color: topic.colorScheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Faltam autorizações neste aparelho',
                      style: topic.textTheme.titleMedium
                          ?.copyWith(color: topic.colorScheme.onErrorContainer)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('Sem elas, as regras não são aplicadas aqui. Toque para conceder.',
                style: topic.textTheme.bodySmall
                    ?.copyWith(color: topic.colorScheme.onErrorContainer)),
            const SizedBox(height: 8),
            for (final i in missing)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(i.$4, color: topic.colorScheme.onErrorContainer),
                title: Text(i.$2),
                subtitle: Text(i.$3),
                trailing: FilledButton(onPressed: () => onRequest(i.$1), child: const Text('Conceder')),
                isThreeLine: true,
              ),
          ],
        ),
      ),
    );
  }
}

class _RuleCard extends StatelessWidget {
  const _RuleCard({
    required this.category,
    required this.name,
    required this.rule,
    required this.busy,
    required this.aoMudar,
  });

  final String category;
  final String name;
  final Map<String, dynamic> rule;
  final bool busy;
  final void Function(Map<String, dynamic> rule) aoMudar;

  @override
  Widget build(BuildContext context) {
    final topic = Theme.of(context);
    final mode = rule['modo'] as String? ?? 'livre';
    final limit = (rule['limite_min'] as num?)?.toInt() ?? 0;
    final times = (rule['horarios'] as List).cast<Map<String, dynamic>>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_categoryIcons[category] ?? Icons.apps, color: topic.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(child: Text(name, style: topic.textTheme.titleMedium)),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              children: [
                for (final m in _modes.entries)
                  ChoiceChip(
                    label: Text(m.value),
                    selected: mode == m.key,
                    onSelected: busy ? null : (_) => aoMudar({...rule, 'modo': m.key}),
                  ),
              ],
            ),
            if (mode == 'limite') ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('Limite por dia: '),
                  Text('$limit min', style: topic.textTheme.titleSmall),
                  Expanded(
                    child: Slider(
                      value: limit.clamp(5, 240).toDouble(),
                      min: 5,
                      max: 240,
                      divisions: 47,
                      label: '$limit min',
                      onChanged: busy ? null : (v) {},
                      onChangeEnd: busy
                          ? null
                          : (v) => aoMudar({...rule, 'limite_min': (v / 5).round() * 5}),
                    ),
                  ),
                ],
              ),
            ],
            if (mode != 'bloqueado') ...[
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('Bloqueado em:'),
                  for (final h in times)
                    InputChip(
                      label: Text('${h['inicio']}–${h['fim']}'),
                      onDeleted: busy
                          ? null
                          : () => aoMudar({
                              ...rule,
                              'horarios': [
                                for (final o in times) if (o != h) o,
                              ],
                            }),
                    ),
                  ActionChip(
                    avatar: const Icon(Icons.add, size: 18),
                    label: const Text('Horário'),
                    onPressed: busy
                        ? null
                        : () async {
                            final isNew = await _pickTime(context);
                            if (isNew != null) aoMudar({...rule, 'horarios': [...times, isNew]});
                          },
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

Future<Map<String, String>?> _pickTime(BuildContext context) async {
  final start = await showTimePicker(
    context: context,
    initialTime: const TimeOfDay(hour: 22, minute: 0),
    helpText: 'Começa a bloquear às',
  );
  if (start == null || !context.mounted) return null;
  final end = await showTimePicker(
    context: context,
    initialTime: const TimeOfDay(hour: 7, minute: 0),
    helpText: 'Libera às',
  );
  if (end == null) return null;
  String hm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  return {'inicio': hm(start), 'fim': hm(end)};
}

class _Protection extends StatelessWidget {
  const _Protection({required this.devices});

  final List<Map<String, dynamic>> devices;

  @override
  Widget build(BuildContext context) {
    final topic = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Aparelhos', style: topic.textTheme.titleMedium),
        if (devices.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Nenhum aparelho sincronizado ainda. Abra o app no celular e nos tablets para registrar.',
              style: topic.textTheme.bodyMedium,
            ),
          ),
        for (final d in devices)
          _DeviceCard(device: d),
      ],
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.device});

  final Map<String, dynamic> device;

  static const _labels = {
    'uso': 'Leitura de uso',
  };

  @override
  Widget build(BuildContext context) {
    final topic = Theme.of(context);
    final status = (device['estado'] as Map?)?.cast<String, dynamic>() ?? const {};
    final disabled = [
      for (final e in status.entries)
        if (e.value == false && _labels.containsKey(e.key)) _labels[e.key]!,
    ];
    final color = disabled.isEmpty ? topic.colorScheme.primary : topic.colorScheme.error;
    return Card(
      child: ListTile(
        leading: Icon(disabled.isEmpty ? Icons.shield_outlined : Icons.gpp_bad_outlined, color: color),
        title: Text(device['nome'] as String? ?? 'Aparelho'),
        subtitle: Text(
          'Visto ${_when(device['visto_em'] as String?)}'
          '${disabled.isEmpty ? ' · tudo ativo' : ' · desligado: ${disabled.join(', ')}'}',
        ),
      ),
    );
  }
}

class _Uso extends StatelessWidget {
  const _Uso({required this.summary, required this.categories});

  final Map<String, dynamic>? summary;
  final Map<String, String> categories;

  @override
  Widget build(BuildContext context) {
    final r = summary;
    final topic = Theme.of(context);
    if (r == null) return const Center(child: CircularProgressIndicator());
    final byDay = (r['por_dia'] as Map).cast<String, dynamic>();
    final apps = (r['apps'] as List).cast<Map<String, dynamic>>();
    if (byDay.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text('Sem dados de uso ainda. O app Android manda o tempo por app todo dia.',
            style: topic.textTheme.bodyMedium),
      );
    }
    final totals = <String, double>{};
    for (final day in byDay.values) {
      for (final e in (day as Map).cast<String, dynamic>().entries) {
        totals[e.key] = (totals[e.key] ?? 0) + (e.value as num).toDouble();
      }
    }
    final sorted = totals.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final labelFor = {...categories, 'outros': 'Outros apps'};
    final maxApp = apps.isEmpty ? 1.0 : (apps.first['minutos'] as num).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in sorted)
              Chip(
                avatar: Icon(_categoryIcons[e.key] ?? Icons.apps, size: 18),
                label: Text('${labelFor[e.key] ?? e.key}: ${_hours(e.value)}'),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Text('Apps campeões', style: topic.textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final a in apps.take(8))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(a['nome'] as String? ?? '')),
                    Text('${_hours((a['minutos'] as num).toDouble())} · ${a['aberturas']}×',
                        style: topic.textTheme.bodySmall),
                  ],
                ),
                const SizedBox(height: 2),
                LinearProgressIndicator(
                  value: ((a['minutos'] as num).toDouble() / maxApp).clamp(0, 1),
                  backgroundColor: topic.colorScheme.surfaceContainerHighest,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

String _hours(double min) {
  if (min < 60) return '${min.round()} min';
  return '${(min / 60).floor()}h${(min % 60).round().toString().padLeft(2, '0')}';
}

class _Guard extends StatefulWidget {
  const _Guard({required this.api, required this.period});

  final HealthApi api;
  final int period;

  @override
  State<_Guard> createState() => _GuardState();
}

class _GuardState extends State<_Guard> {
  Map<String, dynamic>? _analysis;
  bool _thinking = false;

  @override
  void initState() {
    super.initState();
    _last();
  }

  Future<void> _last() async {
    try {
      final items = await widget.api.usageAnalyses();
      if (mounted && items.isNotEmpty) setState(() => _analysis = items.first);
    } on ApiErro catch (_) {}
  }

  Future<void> _analyze() async {
    setState(() => _thinking = true);
    try {
      final a = await widget.api.analyzeUsage(widget.period, '');
      if (mounted) setState(() => _analysis = a);
    } on ApiErro catch (e) {
      if (mounted) _notify(context, e);
    } finally {
      if (mounted) setState(() => _thinking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final topic = Theme.of(context);
    final a = _analysis;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.visibility_outlined, color: topic.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(child: Text('O vigia', style: topic.textTheme.titleLarge)),
            FilledButton.icon(
              onPressed: _thinking ? null : _analyze,
              icon: _thinking
                  ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.auto_awesome),
              label: Text(_thinking ? 'Pensando…' : 'Analisar'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text('Leitura franca pela sua LLM local — nada sai do seu PC.', style: topic.textTheme.bodySmall),
        const SizedBox(height: 12),
        if (a == null)
          Text('Peça uma análise quando houver alguns dias de uso registrados.',
              style: topic.textTheme.bodyMedium)
        else
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${a['de']} a ${a['ate']} · ${_when(a['criada_em'] as String?)}',
                      style: topic.textTheme.bodySmall),
                  const SizedBox(height: 8),
                  VisualizadorMarkdown(texto: a['texto'] as String? ?? ''),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
