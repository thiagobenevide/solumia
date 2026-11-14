import 'dart:math';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import 'toolbox.dart';
import 'painting.dart';

/// Table dialog: type in the cells, add/remove rows and columns, background and text colors,
/// bold and alignment. A click marks the cell; Shift+click marks the rectangle up to it. Returns the
/// new table (with the sizes redone from the text) or null if cancelled.
Future<BoardTable?> editTable(BuildContext context, BoardTable table, Estojo toolbox) =>
    showDialog<BoardTable>(context: context, builder: (_) => _TableEditor(table, toolbox));

class _TableEditor extends StatefulWidget {
  const _TableEditor(this.table, this.toolbox);

  final BoardTable table;
  final Estojo toolbox;

  @override
  State<_TableEditor> createState() => _TableEditorState();
}

class _TableEditorState extends State<_TableEditor> {
  late final List<List<Cell>> _cells = [for (final l in widget.table.cells) [...l]];
  late List<List<TextEditingController>> _texts = _controllers();
  late bool _header = widget.table.header;
  late Color _grade = widget.table.color;
  late double _size = widget.table.size;

  /// Cell where the marked rectangle starts ([_anchor]) and ends ([_current]).
  (int, int) _anchor = (0, 0), _current = (0, 0);

  int get _lines => _cells.length;
  int get _columns => _cells.isEmpty ? 0 : _cells.first.length;

  List<List<TextEditingController>> _controllers() => [
    for (final l in _cells) [for (final c in l) TextEditingController(text: c.text)],
  ];

  Iterable<(int, int)> get _checkedItems sync* {
    for (var l = min(_anchor.$1, _current.$1); l <= max(_anchor.$1, _current.$1); l++) {
      for (var c = min(_anchor.$2, _current.$2); c <= max(_anchor.$2, _current.$2); c++) {
        yield (l, c);
      }
    }
  }

  bool _checked(int l, int c) =>
      l >= min(_anchor.$1, _current.$1) &&
      l <= max(_anchor.$1, _current.$1) &&
      c >= min(_anchor.$2, _current.$2) &&
      c <= max(_anchor.$2, _current.$2);

  void _storeTexts() {
    for (var l = 0; l < _lines; l++) {
      for (var c = 0; c < _columns; c++) {
        _cells[l][c] = _cells[l][c].copy(text: _texts[l][c].text);
      }
    }
  }

  @override
  void dispose() {
    for (final l in _texts) {
      for (final t in l) {
        t.dispose();
      }
    }
    super.dispose();
  }

  /// Change of rows/columns: stores what was typed and redoes the fields.
  void _structure(void Function() change) {
    _storeTexts();
    final oldItems = _texts;
    change();
    _texts = _controllers();
    _current = (_current.$1.clamp(0, _lines - 1), _current.$2.clamp(0, _columns - 1));
    _anchor = _current;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final l in oldItems) {
        for (final t in l) {
          t.dispose();
        }
      }
    });
  }

  void _insertRow(int em) =>
      _structure(() => _cells.insert(em, List.generate(_columns, (_) => const Cell())));

  void _insertColumn(int em) => _structure(() {
    for (final l in _cells) {
      l.insert(em, const Cell());
    }
  });

  void _deleteRows() {
    final de = min(_anchor.$1, _current.$1), ate = max(_anchor.$1, _current.$1);
    if (ate - de + 1 >= _lines) return;
    _structure(() => _cells.removeRange(de, ate + 1));
  }

  void _deleteColumns() {
    final de = min(_anchor.$2, _current.$2), ate = max(_anchor.$2, _current.$2);
    if (ate - de + 1 >= _columns) return;
    _structure(() {
      for (final l in _cells) {
        l.removeRange(de, ate + 1);
      }
    });
  }

  void _apply(Cell Function(Cell) f) {
    _storeTexts();
    setState(() {
      for (final (l, c) in _checkedItems) {
        _cells[l][c] = f(_cells[l][c]);
      }
    });
  }

  Future<Color?> _color(Color initial) async {
    final c = await escolherCor(context, initial, widget.toolbox.recent, paleta: quickColors);
    if (c != null) widget.toolbox.rememberColor(c);
    return c;
  }

  void _mark(int l, int c) {
    setState(() {
      _current = (l, c);
      if (!HardwareKeyboard.instance.isShiftPressed) _anchor = (l, c);
    });
  }

  BoardTable _result() {
    _storeTexts();
    return widget.table
        .copy(
          cells: [for (final l in _cells) List.unmodifiable(l)],
          widths: List.filled(_columns, 0),
          heights: List.filled(_lines, 0),
          header: _header,
          color: _grade,
          size: _size,
        )
        .fitted();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final current = _cells[_current.$1][_current.$2];
    final screen = MediaQuery.sizeOf(context);
    return AlertDialog(
      title: const Text('Tabela'),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: min(960, screen.width * 0.9),
        height: min(600, screen.height * 0.7),
        child: Column(
          children: [
            Wrap(
              spacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                PopupMenuButton<VoidCallback>(
                  tooltip: 'Linhas',
                  onSelected: (f) => f(),
                  itemBuilder: (_) => [
                    PopupMenuItem(value: () => _insertRow(min(_anchor.$1, _current.$1)), child: const Text('Inserir linha acima')),
                    PopupMenuItem(value: () => _insertRow(max(_anchor.$1, _current.$1) + 1), child: const Text('Inserir linha abaixo')),
                    PopupMenuItem(value: _deleteRows, child: const Text('Excluir linha(s) marcada(s)')),
                  ],
                  child: const Chip(avatar: Icon(Icons.table_rows_outlined, size: 18), label: Text('Linhas')),
                ),
                PopupMenuButton<VoidCallback>(
                  tooltip: 'Colunas',
                  onSelected: (f) => f(),
                  itemBuilder: (_) => [
                    PopupMenuItem(value: () => _insertColumn(min(_anchor.$2, _current.$2)), child: const Text('Inserir coluna à esquerda')),
                    PopupMenuItem(value: () => _insertColumn(max(_anchor.$2, _current.$2) + 1), child: const Text('Inserir coluna à direita')),
                    PopupMenuItem(value: _deleteColumns, child: const Text('Excluir coluna(s) marcada(s)')),
                  ],
                  child: const Chip(avatar: Icon(Icons.view_column_outlined, size: 18), label: Text('Colunas')),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Cor de fundo das células marcadas',
                  icon: Icon(Icons.format_color_fill, color: current.background),
                  onPressed: () async {
                    final c = await _color(current.background ?? Colors.white);
                    if (c != null) _apply((cel) => cel.copy(background: c));
                  },
                ),
                IconButton(
                  tooltip: 'Cor do texto das células marcadas',
                  icon: Icon(Icons.format_color_text, color: current.textColor),
                  onPressed: () async {
                    final c = await _color(current.textColor ?? Colors.black);
                    if (c != null) _apply((cel) => cel.copy(textColor: c));
                  },
                ),
                IconButton(
                  tooltip: 'Tirar as cores das células marcadas',
                  icon: const Icon(Icons.format_color_reset),
                  onPressed: () => _apply((cel) => cel.copy(noBackground: true, noTextColor: true)),
                ),
                IconButton(
                  tooltip: 'Negrito',
                  isSelected: current.bold,
                  icon: const Icon(Icons.format_bold),
                  onPressed: () => _apply((cel) => cel.copy(bold: !current.bold)),
                ),
                for (final (i, icone, hint) in [
                  (0, Icons.format_align_left, 'Alinhar à esquerda'),
                  (1, Icons.format_align_center, 'Centralizar'),
                  (2, Icons.format_align_right, 'Alinhar à direita'),
                ])
                  IconButton(
                    tooltip: hint,
                    isSelected: current.alignmentMode == i,
                    icon: Icon(icone),
                    onPressed: () => _apply((cel) => cel.copy(alignmentMode: i)),
                  ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Cor da grade',
                  icon: Icon(Icons.border_all, color: _grade),
                  onPressed: () async {
                    final c = await _color(_grade);
                    if (c != null) setState(() => _grade = c);
                  },
                ),
                IconButton(
                  tooltip: 'Letra menor',
                  icon: const Icon(Icons.text_decrease),
                  onPressed: _size > 8 ? () => setState(() => _size -= 2) : null,
                ),
                Text('${_size.round()}'),
                IconButton(
                  tooltip: 'Letra maior',
                  icon: const Icon(Icons.text_increase),
                  onPressed: () => setState(() => _size += 2),
                ),
                FilterChip(
                  label: const Text('Cabeçalho'),
                  selected: _header,
                  onSelected: (v) => setState(() => _header = v),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Scrollbar(
                child: SingleChildScrollView(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Table(
                      defaultColumnWidth: const FixedColumnWidth(150),
                      border: TableBorder.all(color: _grade),
                      children: [
                        for (var l = 0; l < _lines; l++)
                          TableRow(
                            children: [
                              for (var c = 0; c < _columns; c++) _input(l, c, colors),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                '$_lines × $_columns · Shift+clique marca várias células · **negrito**, *itálico* no texto',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(context, _result()), child: const Text('Salvar')),
      ],
    );
  }

  Widget _input(int l, int c, ColorScheme colors) {
    final cel = _cells[l][c];
    final header = _header && l == 0;
    final checked = _checked(l, c);
    return Container(
      decoration: BoxDecoration(
        color: cel.background ?? (header ? headerBackground : Colors.white),
        border: checked ? Border.all(color: colors.primary, width: 2) : null,
      ),
      child: TextField(
        controller: _texts[l][c],
        maxLines: null,
        textAlign: const [TextAlign.left, TextAlign.center, TextAlign.right][cel.alignmentMode.clamp(0, 2)],
        onTap: () => _mark(l, c),
        style: TextStyle(
          color: cel.textColor ?? Colors.black,
          fontWeight: cel.bold || header ? FontWeight.bold : null,
        ),
        decoration: const InputDecoration(
          border: InputBorder.none,
          isDense: true,
          contentPadding: EdgeInsets.all(8),
        ),
      ),
    );
  }
}
