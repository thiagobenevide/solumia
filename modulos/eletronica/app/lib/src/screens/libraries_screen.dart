import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../electronics_api.dart';

/// KiCad libraries on the server: download the official ones (suggested list), import a `.kicad_sym` from the
/// device and remove. Re-importing an existing one updates it.
Future<void> showLibraries(BuildContext context, ElectronicsApi api) => showDialog<void>(
  context: context,
  builder: (_) => Dialog(
    child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640, maxHeight: 680), child: _Libraries(api: api)),
  ),
);

class _Libraries extends StatefulWidget {
  const _Libraries({required this.api});

  final ElectronicsApi api;

  @override
  State<_Libraries> createState() => _LibrariesState();
}

class _LibrariesState extends State<_Libraries> {
  List<Map<String, dynamic>> _imported = [];
  List<String> _suggested = [];
  String _version = '';
  final Set<String> _checked = {};
  bool _loading = true, _working = false;
  String? _warning;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final (libs, kicad) = (await widget.api.libraries(), await widget.api.kicad());
      if (!mounted) return;
      setState(() {
        _imported = libs;
        _version = '${kicad['versao']}';
        _suggested = [for (final n in kicad['sugeridas'] as List) '$n'];
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _warning = 'Não carregou: $e';
          _loading = false;
        });
      }
    }
  }

  bool _has(String name) => _imported.any((b) => b['nome'] == name);

  Future<void> _work(Future<String> Function() task) async {
    setState(() {
      _working = true;
      _warning = null;
    });
    try {
      final msg = await task();
      if (mounted) setState(() => _warning = msg);
    } catch (e) {
      if (mounted) setState(() => _warning = 'Falhou: $e');
    } finally {
      if (mounted) setState(() => _working = false);
      await _load();
    }
  }

  Future<void> _download() => _work(() async {
    final r = await widget.api.downloadKicad(_checked.toList()..sort());
    _checked.clear();
    final ok = [for (final l in r) if (l['erro'] == null) '${l['nome']} (${l['total']})'];
    final errors = [for (final l in r) if (l['erro'] != null) '${l['nome']}: ${l['erro']}'];
    return [if (ok.isNotEmpty) 'Importadas: ${ok.join(', ')}', ...errors].join('\n');
  });

  Future<void> _file() async {
    final a = (await FilePicker.pickFiles(type: FileType.any)).firstOrNull;
    if (a == null) return;
    final bytes = await a.xFile.readAsBytes();
    await _work(() async {
      final r = await widget.api.importLibrary(a.name, bytes);
      return 'Importada ${r['nome']} com ${r['total']} símbolos.';
    });
  }

  Future<void> _remover(String name) => _work(() async {
    await widget.api.removeLibrary(name);
    return 'Removida $name. Componentes já colocados dela aparecem como "?" até importar de novo.';
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) return const SizedBox(height: 200, child: Center(child: CircularProgressIndicator()));
    return Column(
      children: [
        ListTile(
          title: Text('Bibliotecas do KiCad', style: theme.textTheme.titleLarge),
          subtitle: Text('Oficiais do KiCad $_version (licença CC-BY-SA 4.0) ou um arquivo .kicad_sym seu.'),
          trailing: IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
        ),
        if (_working) const LinearProgressIndicator(),
        if (_warning != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(_warning!, style: theme.textTheme.bodySmall),
          ),
        Expanded(
          child: ListView(
            children: [
              if (_imported.isNotEmpty) ...[
                const _Heading('Importadas'),
                for (final b in _imported)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.inventory_2_outlined),
                    title: Text('${b['nome']}'),
                    subtitle: Text('${b['total']} símbolos · ${b['origem']}'),
                    trailing: IconButton(
                      tooltip: 'Remover',
                      onPressed: _working ? null : () => _remover('${b['nome']}'),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ),
              ],
              const _Heading('Oficiais sugeridas (PC, celular, monitor e som)'),
              for (final n in _suggested)
                CheckboxListTile(
                  dense: true,
                  value: _checked.contains(n),
                  onChanged: _working ? null : (v) => setState(() => v == true ? _checked.add(n) : _checked.remove(n)),
                  title: Text(n),
                  subtitle: _has(n) ? const Text('já importada — marcar atualiza') : null,
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: [
              TextButton(
                onPressed: _working
                    ? null
                    : () => setState(() => _checked.addAll(_suggested.where((n) => !_has(n)))),
                child: const Text('Marcar as que faltam'),
              ),
              OutlinedButton.icon(
                onPressed: _working ? null : _file,
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('Importar arquivo'),
              ),
              FilledButton.icon(
                onPressed: _working || _checked.isEmpty ? null : _download,
                icon: const Icon(Icons.download),
                label: Text('Baixar ${_checked.isEmpty ? '' : '(${_checked.length})'}'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(text, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary)),
  );
}
