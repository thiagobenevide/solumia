import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_text.dart';
import '../core.dart';
import '../plan.dart';

/// Solumia apps for phone/tablet, watch, PC and laptop (GitHub Releases, verified).
class SolumiaAppsScreen extends StatefulWidget {
  const SolumiaAppsScreen({super.key, required this.core});
  final Core core;
  @override
  State<SolumiaAppsScreen> createState() => _SolumiaAppsScreenState();
}

class _SolumiaAppsScreenState extends State<SolumiaAppsScreen> {
  Map<String, dynamic>? _data;
  String? _error;
  String? _busy;
  final Set<String> _qr = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.core.get('/apps-solumia') as Map<String, dynamic>;
      if (mounted) setState(() => _data = r);
    } on CoreError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _download(String id, {required bool install}) async {
    setState(() => _busy = id);
    try {
      final plan = await widget.core.post('/apps-solumia/$id/plano', {'versao': 'ultima', 'instalar': install})
          as Map<String, dynamic>;
      if (mounted) await showPlan(context, widget.core, plan);
    } on CoreError catch (e) {
      if (mounted) notify(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  (IconData, String, String) _info(AppText t, String id) => switch (id) {
        'android' => (Icons.phone_android, t.appPhone, t.appPhoneDetail),
        'wear' => (Icons.watch, t.appWatch, t.appWatchDetail),
        'linux' => (Icons.laptop, t.appLinux, t.appLinuxDetail),
        'windows' => (Icons.desktop_windows, t.appWindows, t.appWindowsDetail),
        _ => (Icons.apps, id, ''),
      };

  @override
  Widget build(BuildContext context) {
    final t = AppText.of(context);
    final theme = Theme.of(context);
    final d = _data;
    if (d == null) {
      return Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!));
    }
    final signed = d['assinatura_fixada'] == true;
    final apps = (d['apps'] as List).cast<Map<String, dynamic>>();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(24), children: [
        Text(t.appsTitle, style: theme.textTheme.headlineSmall),
        Text(t.appsDescription),
        const SizedBox(height: 8),
        Wrap(spacing: 16, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(d['versao'] == null ? t.appsNoRelease : t.appsVersion('${d['versao']}'),
              style: theme.textTheme.titleSmall),
          TextButton.icon(
            onPressed: () => launchUrl(Uri.parse(d['releases'] as String)),
            icon: const Icon(Icons.open_in_new),
            label: Text(t.openReleases),
          ),
        ]),
        if (!signed)
          Card(
            color: theme.colorScheme.errorContainer,
            child: ListTile(
              leading: Icon(Icons.lock, color: theme.colorScheme.onErrorContainer),
              title: Text(t.appsUnsigned, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
            ),
          ),
        Text(t.appsFolder('${d['pasta']}'), style: theme.textTheme.bodySmall),
        const SizedBox(height: 16),
        Wrap(spacing: 16, runSpacing: 16, children: [
          for (final a in apps) _card(a, t, theme, signed),
        ]),
      ]),
    );
  }

  Widget _card(Map<String, dynamic> a, AppText t, ThemeData theme, bool signed) {
    final id = a['id'] as String;
    final (icon, title, detail) = _info(t, id);
    final url = a['url'] as String?;
    final canInstall = signed && url != null && _busy == null;
    final phone = id == 'android';
    return SizedBox(
      width: 340,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CircleAvatar(
                backgroundColor: theme.colorScheme.primaryContainer,
                foregroundColor: theme.colorScheme.onPrimaryContainer,
                child: Icon(icon),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: theme.textTheme.titleMedium),
                  Text(detail, style: theme.textTheme.bodySmall),
                ]),
              ),
            ]),
            const SizedBox(height: 12),
            Text(url == null ? t.fileUnavailable : '${a['arquivo']}',
                style: theme.textTheme.bodySmall),
            if (id == 'wear') Text(t.watchInstruction, style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (a['instala_aqui'] == true)
                FilledButton.icon(
                  onPressed: canInstall ? () => _download(id, install: true) : null,
                  icon: const Icon(Icons.install_desktop),
                  label: Text(t.installOnThisPc),
                ),
              OutlinedButton.icon(
                onPressed: canInstall ? () => _download(id, install: false) : null,
                icon: const Icon(Icons.download),
                label: Text(t.downloadToThisPc),
              ),
              if (phone)
                OutlinedButton.icon(
                  onPressed: url == null ? null : () => setState(() => _qr.contains(id) ? _qr.remove(id) : _qr.add(id)),
                  icon: const Icon(Icons.qr_code),
                  label: Text(t.showQr),
                ),
            ]),
            if (phone && url != null && _qr.contains(id)) ...[
              const SizedBox(height: 12),
              Container(
                color: Colors.white, // the QR code needs a light background in both themes
                padding: const EdgeInsets.all(8),
                child: QrImageView(data: url, size: 180),
              ),
              const SizedBox(height: 4),
              Text(t.qrPhone, style: theme.textTheme.bodySmall),
            ],
          ]),
        ),
      ),
    );
  }
}
