import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../files_api.dart';
import '../screens/highlight_actions.dart';
import 'reader_screen.dart';

/// Preview of a PDF not yet in Arquivos (e.g. a CVM document). "Salvar" stores it in
/// [folder], keeps it on the device and swaps the preview for the reader (highlight and annotate).
Future<void> openPreview(BuildContext context, FilesApi api, String name, Uint8List pdf, {String pasta = ''}) =>
    abrirTela<void>(context, (_) => PreviewScreen(api: api, name: name, pdf: pdf, pasta: pasta));

class PreviewScreen extends StatefulWidget {
  const PreviewScreen({super.key, required this.api, required this.name, required this.pdf, this.pasta = ''});

  final FilesApi api;
  final String name;
  final Uint8List pdf;
  final String pasta;

  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> {
  bool _isSaving = false;

  Future<void> _save() async {
    setState(() => _isSaving = true);
    try {
      final (a, _) = await widget.api.send(widget.name, widget.pdf, pasta: widget.pasta);
      await widget.api.offline.download(a, pdf: widget.pdf);
      if (!mounted) return;
      notify(context, 'Salvo em Arquivos › ${widget.pasta.isEmpty ? 'raiz' : widget.pasta}.');
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => ReaderScreen(api: widget.api, file: a)),
      );
    } on ApiErro catch (e) {
      if (mounted) notify(context, 'Não consegui salvar: ${e.mensagem}');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: FilledButton.icon(
            onPressed: _isSaving ? null : _save,
            icon: _isSaving
                ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_alt),
            label: const Text('Salvar'),
          ),
        ),
      ],
    ),
    body: PdfViewer.data(widget.pdf, sourceName: widget.name),
  );
}
