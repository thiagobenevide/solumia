import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_text.dart';
import '../core.dart';
import '../plan.dart';

/// Craft Apps: a download button for each app, straight from GitHub Releases, verified.
class CraftAppsScreen extends StatefulWidget {
  const CraftAppsScreen({super.key, required this.core});
  final Core core;
  @override
  State<CraftAppsScreen> createState() => _CraftAppsScreenState();
}

class _CraftAppsScreenState extends State<CraftAppsScreen> {
  List<Map<String, dynamic>> _apps = [];
  final Map<String, Map<String, dynamic>> _releases = {};
  final Map<String, String> _formats = {};
  final Map<String, String> _errors = {};
  String? _busy;

  List<(String, String)> _formatOptions(AppText t) => Platform.isWindows
      ? [('auto', t.formatPortable), ('msi', t.formatMsi)]
      : [('auto', t.formatAppimage), ('tar.gz', '.tar.gz'), ('deb', t.formatDeb)];

  static String _description(AppText t, String id, String fallback) => switch (id) {
        'filmcraft' => t.craftFilmcraft,
        'soundcraft' => t.craftSoundcraft,
        'effectcraft' => t.craftEffectcraft,
        'photocraft' => t.craftPhotocraft,
        _ => fallback,
      };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await widget.core.get('/craft-apps') as Map<String, dynamic>;
    setState(() => _apps = (r['apps'] as List).cast<Map<String, dynamic>>());
    for (final a in _apps) {
      final id = a['id'] as String;
      widget.core.get('/craft-apps/$id/release').then((rel) {
        if (mounted) setState(() => _releases[id] = (rel as Map).cast<String, dynamic>());
      }).catchError((Object e) {
        if (mounted) setState(() => _errors[id] = '$e');
      });
    }
  }

  Future<void> _install(String id) async {
    setState(() => _busy = id);
    try {
      final plan = await widget.core.post('/craft-apps/$id/plano', {
        'versao': 'ultima',
        'formato': _formats[id] ?? 'auto',
      }) as Map<String, dynamic>;
      if (mounted) await showPlan(context, widget.core, plan);
      await _load();
    } on CoreError catch (e) {
      if (mounted) notify(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final t = AppText.of(context);
    return ListView(padding: const EdgeInsets.all(24), children: [
      Text(t.navCraft, style: tt.headlineSmall),
      Text(t.craftDescription),
      const SizedBox(height: 16),
      Wrap(spacing: 16, runSpacing: 16, children: [
        for (final a in _apps) _card(a, tt, t),
      ]),
    ]);
  }

  Widget _card(Map<String, dynamic> a, TextTheme tt, AppText t) {
    final id = a['id'] as String;
    final rel = _releases[id];
    final installed = a['instalado'] as Map<String, dynamic>?;
    final update = installed != null && rel != null && installed['versao'] != rel['versao'];
    return SizedBox(
      width: 360,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(a['nome'] as String, style: tt.titleLarge),
            Text(_description(t, id, a['descricao'] as String)),
            const SizedBox(height: 8),
            InkWell(
              onTap: () => launchUrl(Uri.parse(a['github'] as String)),
              child: Text(a['github'] as String,
                  style: TextStyle(decoration: TextDecoration.underline, color: Theme.of(context).colorScheme.primary)),
            ),
            const SizedBox(height: 8),
            Text(rel == null
                ? (_errors[id] ?? t.checkingVersion)
                : t.latestVersion('${rel['versao']}', '${rel['arquivo']}')),
            Text(installed == null ? t.notInstalled : t.installedAt('${installed['versao']}', '${installed['caminho']}'),
                style: tt.bodySmall),
            const SizedBox(height: 8),
            DropdownButton<String>(
              value: _formats[id] ?? 'auto',
              isExpanded: true,
              items: [for (final (v, r) in _formatOptions(t)) DropdownMenuItem(value: v, child: Text(r))],
              onChanged: (v) => setState(() => _formats[id] = v ?? 'auto'),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy != null || rel == null || rel['disponivel'] != true ? null : () => _install(id),
              icon: const Icon(Icons.download),
              label: Text(installed == null ? t.downloadInstall : (update ? t.update : t.reinstall)),
            ),
          ]),
        ),
      ),
    );
  }
}
