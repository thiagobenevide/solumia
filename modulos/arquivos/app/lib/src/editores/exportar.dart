import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api_arquivos.dart';
import '../modelos.dart';
import '../telas/acoes_destaque.dart';
import 'docx.dart';

/// Formatos de exportação pelo LibreOffice do servidor (casam com `EXPORTACOES` do backend).
const formatosExportacao = {
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

/// Exporta o original salvo (o editor salva antes de chamar). [markdown] acrescenta "Markdown"
/// e "Nota de referência" (vai para o módulo Notas, para citar o arquivo depois).
Future<void> exportarArquivo(BuildContext context, ApiArquivos api, Arquivo a, {String? markdown}) async {
  final opcoes = {
    ...?formatosExportacao[a.tipo],
    if (markdown != null) 'md': 'Markdown (.md)',
    if (markdown != null) 'nota': 'Nota de referência (módulo Notas)',
  };
  final escolha = await showDialog<String>(
    context: context,
    builder: (c) => SimpleDialog(
      title: Text('Exportar "${a.titulo}"'),
      children: [
        for (final e in opcoes.entries)
          SimpleDialogOption(onPressed: () => Navigator.pop(c, e.key), child: Text(e.value)),
      ],
    ),
  );
  if (escolha == null || !context.mounted) return;
  final base = a.nomeOriginal.contains('.') ? a.nomeOriginal.substring(0, a.nomeOriginal.lastIndexOf('.')) : a.nomeOriginal;
  try {
    if (escolha == 'nota') {
      await api.notaDeReferencia(a, markdown!);
      if (context.mounted) avisar(context, 'Nota de referência criada em Notas (tag "referencia").');
      return;
    }
    final Uint8List bytes = escolha == 'md' ? utf8.encode(markdown!) : await api.exportar(a.id, escolha);
    final salvo = await FilePicker.saveFile(fileName: '$base.$escolha', bytes: bytes);
    if (salvo != null && context.mounted) avisar(context, 'Exportado: $base.$escolha');
  } on ApiErro catch (e) {
    if (context.mounted) avisar(context, 'Não consegui exportar: ${e.mensagem}');
  }
}

/// Delta do Quill → Markdown (títulos, listas, citação, negrito/itálico/tachado, links). O que
/// está marcado como excluído na revisão fica de fora.
String deltaParaMarkdown(List<Map<String, dynamic>> delta) {
  final s = StringBuffer();
  var linha = StringBuffer();
  var emLista = false;
  for (final op in delta) {
    final ins = op['insert'];
    if (ins is! String) continue;
    final attr = (op['attributes'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    if (attr[atributoExclusao] != null && !ins.contains('\n')) continue;
    final partes = ins.split('\n');
    for (var i = 0; i < partes.length; i++) {
      linha.write(_inline(partes[i], attr));
      if (i == partes.length - 1) break;
      final recuo = '  ' * ((attr['indent'] as int?) ?? 0);
      final (prefixo, lista) = switch (attr) {
        {'header': final int n} => ('${'#' * n.clamp(1, 6)} ', false),
        {'list': 'bullet'} => ('$recuo- ', true),
        {'list': 'ordered'} => ('${recuo}1. ', true),
        {'list': 'checked'} => ('$recuo- [x] ', true),
        {'list': 'unchecked'} => ('$recuo- [ ] ', true),
        {'blockquote': true} => ('> ', false),
        {'code-block': _} => ('    ', false),
        _ => ('', false),
      };
      if (emLista && !lista) s.write('\n');
      s.write('$prefixo$linha\n');
      if (!lista) s.write('\n');
      emLista = lista;
      linha = StringBuffer();
    }
  }
  return s.toString().trimRight();
}

String _inline(String t, Map<String, dynamic> attr) {
  final nucleo = t.trim();
  if (nucleo.isEmpty) return t;
  final antes = t.substring(0, t.indexOf(nucleo));
  final depois = t.substring(antes.length + nucleo.length);
  var x = nucleo;
  if (attr['code'] == true) x = '`$x`';
  if (attr['bold'] == true) x = '**$x**';
  if (attr['italic'] == true) x = '*$x*';
  if (attr['strike'] == true) x = '~~$x~~';
  final link = attr['link'];
  if (link is String && link.isNotEmpty) x = '[$x]($link)';
  return '$antes$x$depois';
}
