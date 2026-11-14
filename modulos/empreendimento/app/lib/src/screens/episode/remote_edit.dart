import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../util.dart';

/// "Baixar" and "Enviar edição" of an editor file, to edit on any machine: downloads the file
/// (with the media it uses) and, after it is saved there, sends it back overwriting the episode's one.
class RemoteEdit extends StatelessWidget {
  const RemoteEdit({
    super.key,
    required this.url,
    required this.extensions,
    required this.send,
    required this.done,
    this.after,
  });

  final String url;

  /// Extensions accepted on upload, besides `zip` (the downloaded package, recompressed).
  final List<String> extensions;
  final Future<int> Function(String nome, List<int> bytes) send;

  /// Notice after the upload (what happens now with the file).
  final String done;
  final VoidCallback? after;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 4,
    children: [
      TextButton.icon(
        onPressed: () => openUrl(context, url),
        icon: const Icon(Icons.download, size: 18),
        label: const Text('Baixar'),
      ),
      TextButton.icon(
        onPressed: () => _send(context),
        icon: const Icon(Icons.upload, size: 18),
        label: const Text('Enviar edição'),
      ),
    ],
  );

  Future<void> _send(BuildContext context) async {
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: [...extensions, 'zip']);
    if (files.isEmpty || !context.mounted) return;
    final a = files.first;
    final confirmou = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Sobrescrever?'),
        content: Text('"${a.name}" substitui o arquivo atual do episódio (o atual fica guardado em log/envios/).'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Sobrescrever')),
        ],
      ),
    );
    if (confirmou != true || !context.mounted) return;
    await actionWithWarning(context, () async {
      final stillMissing = await send(a.name, await a.xFile.readAsBytes());
      return stillMissing == 0 ? done : '$done Atenção: $stillMissing mídia(s) não achada(s) no episódio.';
    });
    after?.call();
  }
}
