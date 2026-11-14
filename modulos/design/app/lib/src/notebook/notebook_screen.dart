import 'dart:math';

import 'package:flutter/material.dart';

import '../design_api.dart';
import '../cache.dart';
import '../models.dart';
import '../board/editor.dart';
import '../board/board_screen.dart';
import 'pen.dart';
import 'paper_dialog.dart';
import 'references.dart';

/// Opens a notebook: the same editor as the flowchart (shapes, images, text, selection, pages…) with the
/// ruled sheet of each page and the smart pen.
class OpenNotebook extends StatefulWidget {
  const OpenNotebook({super.key, required this.api, required this.cache, required this.id});

  final ApiDesign api;
  final BoardCache cache;
  final String id;

  @override
  State<OpenNotebook> createState() => _OpenNotebookState();
}

class _OpenNotebookState extends State<OpenNotebook> {
  late final Future<BoardEditor> _editor = _open();
  final _pen = SmartPen();

  Future<BoardEditor> _open() async {
    final e = await BoardEditor.open(widget.api, widget.cache, widget.id);
    e.defaultPaper = const Paper();
    e.fitStroke = (t) => _pen.fit(t, unit: e.role?.space ?? 28);
    return e;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _editor,
    builder: (context, s) {
      if (s.hasData) return NotebookScreen(editor: s.data!, caneta: _pen);
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: s.hasError ? Text('Não abriu: ${s.error}') : const CircularProgressIndicator()),
      );
    },
  );
}

class NotebookScreen extends StatefulWidget {
  const NotebookScreen({super.key, required this.editor, required this.caneta});

  final BoardEditor editor;
  final SmartPen caneta;

  @override
  State<NotebookScreen> createState() => _NotebookScreenState();
}

class _NotebookScreenState extends State<NotebookScreen> {
  BoardEditor get _editor => widget.editor;

  Future<void> _paper() async {
    final r = await editPaper(context, _editor.role ?? const Paper());
    if (r != null) await _editor.changePaper(r.role, allItems: r.allItems);
  }

  Future<void> _references() async {
    final text = await pickReference(context, _editor.api);
    if (text != null && text.trim().isNotEmpty) _insertReference(text.trim());
  }

  /// Reference card on the open sheet, right below what is already written.
  void _insertReference(String text) {
    final role = _editor.role ?? const Paper();
    final width = min(460.0, role.width - role.indent - role.space);
    final linhas = text.split('\n').fold<int>(0, (n, l) => n + max(1, (l.length / 52).ceil()));
    final height = max(role.space * 2, linhas * 20.0 + 24);
    final baixo = _editor.elements.isEmpty ? null : boundsOf(_editor.elements)?.bottom;
    final top = max(role.space * (role.margin ? 3 : 1), (baixo ?? 0) + role.space / 2);
    final a = Offset(role.indent + 6, top);
    _editor.adicionar(
      FlowNode(
        'ref${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
        type: NodeKind.nota,
        text: text,
        a: a,
        b: a + Offset(width, height),
        color: const Color(0xFFC9A227),
        background: const Color(0xFFFFF8D6),
        esquerda: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => BoardScreen(
    editor: _editor,
    actions: [
      IconButton(
        tooltip: widget.caneta.connected
            ? 'Caneta inteligente ligada: retas e figuras ficam alinhadas'
            : 'Caneta inteligente desligada: traço livre',
        isSelected: widget.caneta.connected,
        onPressed: () => setState(() => widget.caneta.connected = !widget.caneta.connected),
        icon: const Icon(Icons.auto_fix_off_outlined),
        selectedIcon: const Icon(Icons.auto_fix_high),
      ),
      IconButton(tooltip: 'Papel da folha (pauta, tamanho, cor)', onPressed: _paper, icon: const Icon(Icons.article_outlined)),
      IconButton(
        tooltip: 'Trazer referência (destaques dos Arquivos, Notas)',
        onPressed: _references,
        icon: const Icon(Icons.format_quote_outlined),
      ),
    ],
  );
}
