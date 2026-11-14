import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../files_api.dart';
import '../models.dart';
import '../screens/highlight_actions.dart';
import 'docx.dart';

/// Export formats through the server's LibreOffice (they match the backend `EXPORTACOES`).
const exportFormats = {
  'documento': {
    'docx': 'Word (.docx)',
    'odt': 'LibreOffice Writer (.odt)',
    'pdf': 'PDF',
    'rtf': 'RTF',
    'txt': 'Texto puro (.txt)',
    'html': 'Página HTML',
  },
  'planilha': {'xlsx': 'Excel (.xlsx)', 'ods': 'LibreOffice Calc (.ods)', 'csv': 'CSV', 'pdf': 'PDF'},
  'apresentacao': {'pptx': 'PowerPoint (.pptx)', 'odp': 'LibreOffice Impress (.odp)', 'pdf': 'PDF'},
};

/// Exports the saved original (the editor saves before calling). [markdown] adds "Markdown"
/// and "Nota de referência" (goes to the Notas module, to cite the file later).
Future<void> exportFile(BuildContext context, FilesApi api, FileItem a, {String? markdown}) async {
  final options = {
    ...?exportFormats[a.type],
    if (markdown != null) 'md': 'Markdown (.md)',
    if (markdown != null) 'nota': 'Nota de referência (módulo Notas)',
  };
  final choice = await showDialog<String>(
    context: context,
    builder: (c) => SimpleDialog(
      title: Text('Exportar "${a.title}"'),
      children: [
        for (final e in options.entries)
          SimpleDialogOption(onPressed: () => Navigator.pop(c, e.key), child: Text(e.value)),
      ],
    ),
  );
  if (choice == null || !context.mounted) return;
  final base = a.nomeOriginal.contains('.') ? a.nomeOriginal.substring(0, a.nomeOriginal.lastIndexOf('.')) : a.nomeOriginal;
  try {
    if (choice == 'nota') {
      await api.referenceNote(a, markdown!);
      if (context.mounted) notify(context, 'Nota de referência criada em Notas (tag "referencia").');
      return;
    }
    final Uint8List bytes = choice == 'md' ? utf8.encode(markdown!) : await api.export(a.id, choice);
    final saved = await FilePicker.saveFile(fileName: '$base.$choice', bytes: bytes);
    if (saved != null && context.mounted) notify(context, 'Exportado: $base.$choice');
  } on ApiErro catch (e) {
    if (context.mounted) notify(context, 'Não consegui exportar: ${e.mensagem}');
  }
}

/// Quill Delta → Markdown (headings, lists, quote, bold/italic/strikethrough, links). What
/// is marked as deleted in the revision stays out.
String deltaToMarkdown(List<Map<String, dynamic>> delta) {
  final s = StringBuffer();
  var line = StringBuffer();
  var inList = false;
  for (final op in delta) {
    final ins = op['insert'];
    if (ins is! String) continue;
    final attr = (op['attributes'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    if (attr[deletionAttribute] != null && !ins.contains('\n')) continue;
    final parts = ins.split('\n');
    for (var i = 0; i < parts.length; i++) {
      line.write(_inline(parts[i], attr));
      if (i == parts.length - 1) break;
      final indent = '  ' * ((attr['indent'] as int?) ?? 0);
      final (prefix, items) = switch (attr) {
        {'header': final int n} => ('${'#' * n.clamp(1, 6)} ', false),
        {'list': 'bullet'} => ('$indent- ', true),
        {'list': 'ordered'} => ('${indent}1. ', true),
        {'list': 'checked'} => ('$indent- [x] ', true),
        {'list': 'unchecked'} => ('$indent- [ ] ', true),
        {'blockquote': true} => ('> ', false),
        {'code-block': _} => ('    ', false),
        _ => ('', false),
      };
      if (inList && !items) s.write('\n');
      s.write('$prefix$line\n');
      if (!items) s.write('\n');
      inList = items;
      line = StringBuffer();
    }
  }
  return s.toString().trimRight();
}

String _inline(String t, Map<String, dynamic> attr) {
  final core = t.trim();
  if (core.isEmpty) return t;
  final antes = t.substring(0, t.indexOf(core));
  final after = t.substring(antes.length + core.length);
  var x = core;
  if (attr['code'] == true) x = '`$x`';
  if (attr['bold'] == true) x = '**$x**';
  if (attr['italic'] == true) x = '*$x*';
  if (attr['strike'] == true) x = '~~$x~~';
  final link = attr['link'];
  if (link is String && link.isNotEmpty) x = '[$x]($link)';
  return '$antes$x$after';
}
