import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../l10n/app_text.dart';
import '../core.dart';
import '../plan.dart';

/// Media folders of this computer (Linux or Windows).
class FoldersScreen extends StatefulWidget {
  const FoldersScreen({super.key, required this.core});
  final Core core;
  @override
  State<FoldersScreen> createState() => _FoldersScreenState();
}

class _FoldersScreenState extends State<FoldersScreen> {
  static const _order = ['imagens', 'videos', 'audio', 'producao', 'produzidos'];
  final Map<String, TextEditingController> _c = {for (final k in _order) k: TextEditingController()};
  Map<String, List<String>> _errors = {};
  Map<String, List<String>> _warnings = {};
  Map<String, dynamic> _m = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final fallback = await widget.core.get('/pastas/padrao') as Map<String, dynamic>;
    final m = await widget.core.manifest();
    final saved = ((m['nos'] as Map)['casa'] as Map?)?['pastas'] as Map?;
    setState(() {
      _m = m;
      for (final k in _order) {
        final v = (saved?[k] as String?) ?? '';
        _c[k]!.text = v.isNotEmpty ? v : (fallback['pastas'] as Map)[k] as String;
      }
    });
  }

  Map<String, String> get _folders => {for (final k in _order) k: _c[k]!.text.trim()};

  Future<bool> _validate() async {
    final r = await widget.core.post('/pastas/validar', {'pastas': _folders}) as Map<String, dynamic>;
    setState(() {
      _errors = (r['erros'] as Map).map((k, v) => MapEntry(k as String, (v as List).cast<String>()));
      _warnings = (r['avisos'] as Map).map((k, v) => MapEntry(k as String, (v as List).cast<String>()));
    });
    return r['ok'] as bool;
  }

  Future<void> _pick(String fieldKey) async {
    final currentPath = _c[fieldKey]!.text;
    final initialDir = Directory(currentPath).existsSync() ? currentPath : null;
    final chosen = await getDirectoryPath(initialDirectory: initialDir, confirmButtonText: AppText.of(context).useThisFolder);
    if (chosen != null) setState(() => _c[fieldKey]!.text = chosen);
  }

  Future<void> _saveAndCreate() async {
    if (!await _validate()) {
      if (mounted) notify(context, AppText.of(context).fixFolders, error: true);
      return;
    }
    try {
      final m = Map<String, dynamic>.from(_m);
      final nodes = Map<String, dynamic>.from(m['nos'] as Map);
      final home = Map<String, dynamic>.from((nodes['casa'] as Map?) ?? {'endereco': 'local', 'papeis': <String>[]});
      home['pastas'] = _folders;
      nodes['casa'] = home;
      m['nos'] = nodes;
      _m = await widget.core.saveManifest(m);
      final plan = await widget.core.post('/pastas/casa/plano') as Map<String, dynamic>;
      if (mounted) await showPlan(context, widget.core, plan);
      await _validate();
    } on CoreError catch (e) {
      if (mounted) notify(context, e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppText.of(context);
    final labels = {
      'imagens': (t.folderImages, t.helpImages),
      'videos': (t.folderVideos, t.helpVideos),
      'audio': (t.folderAudio, t.helpAudio),
      'producao': (t.folderProduction, t.helpProduction),
      'produzidos': (t.folderProduced, t.helpProduced),
    };
    return ListView(padding: const EdgeInsets.all(24), children: [
      Text(t.foldersTitle, style: Theme.of(context).textTheme.headlineSmall),
      Text(t.foldersDescription(Platform.isWindows ? 'Windows' : 'Linux')),
      const SizedBox(height: 16),
      for (final k in _order)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: TextField(
                controller: _c[k],
                decoration: InputDecoration(
                  labelText: labels[k]!.$1,
                  helperText: _warnings[k]?.join('; ') ?? labels[k]!.$2,
                  errorText: _errors[k]?.join('; '),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: IconButton.outlined(
                tooltip: t.pickFolder,
                onPressed: () => _pick(k),
                icon: const Icon(Icons.folder_open),
              ),
            ),
          ]),
        ),
      const SizedBox(height: 12),
      Row(children: [
        OutlinedButton(onPressed: _validate, child: Text(t.validate)),
        const SizedBox(width: 12),
        FilledButton(onPressed: _saveAndCreate, child: Text(t.saveAndCreate)),
      ]),
    ]);
  }
}
