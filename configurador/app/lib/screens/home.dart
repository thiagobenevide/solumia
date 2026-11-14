import 'package:flutter/material.dart';

import '../l10n/app_text.dart';
import '../core.dart';
import '../plan.dart';
import '../theme.dart';

/// Home: what is already configured and the next step.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.core, required this.goTo});
  final Core core;
  final void Function(int index) goTo;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Map<String, dynamic>? _health;
  Map<String, dynamic>? _m;
  List<String> _vault = [];
  List<Map<String, dynamic>> _apps = [];
  String _worker = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await Future.wait([
      widget.core.get('/saude'),
      widget.core.manifest(),
      widget.core.get('/cofre'),
      widget.core.get('/craft-apps'),
      widget.core.get('/worker'),
    ]);
    if (!mounted) return;
    setState(() {
      _health = r[0] as Map<String, dynamic>;
      _m = r[1] as Map<String, dynamic>;
      _vault = ((r[2] as Map)['segredos'] as List).cast<String>();
      _apps = ((r[3] as Map)['apps'] as List).cast<Map<String, dynamic>>();
      _worker = '${(r[4] as Map)['estado']}';
    });
  }

  Future<void> _update() async {
    try {
      final plan = await widget.core.post('/configurador/atualizar/plano') as Map<String, dynamic>;
      if (mounted) await showPlan(context, widget.core, plan);
    } on CoreError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppText.of(context);
    final colors = Theme.of(context).colorScheme;
    final s = _health, m = _m;
    if (s == null || m == null) return const Center(child: CircularProgressIndicator());
    final nodes = m['nos'] as Map;
    final ssh = (nodes['vps'] as Map?)?['ssh'] as Map?;
    final entries = <(String, bool, String, int)>[
      (t.itemAccount, _vault.contains('conta.totp'), t.itemAccountDetail, 1),
      (t.navVps, (ssh?['impressao_host'] as String? ?? '').isNotEmpty,
          ssh == null ? t.itemVpsDetail : '${ssh['usuario']}@${ssh['host']}', 2),
      (t.itemFolders, (nodes['casa'] as Map?)?['pastas'] != null, t.itemFoldersDetail, 3),
      (t.navCraft, _apps.any((a) => a['instalado'] != null),
          t.itemCraftDetail(_apps.where((a) => a['instalado'] != null).length, _apps.length), 4),
      (t.itemApps, false, t.itemAppsDetail, 5),
      (t.itemWorker, _worker == 'active', t.itemWorkerDetail, 6),
    ];
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(24), children: [
        Text('Solumia', style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: colors.primary)),
        Text(t.homeVersion('${s['versao']}', '${s['protocolo']}', '${s['so']}', '${s['arquitetura']}')),
        Text(t.homeManifest('${s['manifesto']}'), style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 24),
        for (final (title, ok, detail, index) in entries)
          Card(
            child: ListTile(
              leading: Icon(ok ? Icons.check_circle : Icons.radio_button_unchecked, color: ok ? colors.success : null),
              title: Text(title),
              subtitle: Text(detail),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => widget.goTo(index),
            ),
          ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.system_update_alt),
            title: Text(t.updateConfigurator),
            subtitle: Text(t.updateConfiguratorDetail),
            trailing: FilledButton(onPressed: _update, child: Text(t.updateButton)),
          ),
        ),
        const SizedBox(height: 16),
        Text(t.homeCoexistence('${(s['nomes'] as Map)['prefixo']}', '${(s['nomes'] as Map)['porta_gateway']}',
            '${(s['nomes'] as Map)['porta_tunel']}'),
            style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}
