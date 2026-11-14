import 'dart:math' as math;

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../files_api.dart';
import '../reader/data_screen.dart';
import '../models.dart';
import '../screens/highlight_actions.dart';
import 'xlsx.dart';

/// Excel-style XLSX editor: formula bar, grid with fixed headers (only builds the
/// visible part), tabs below. Tapping a cell selects it; tapping again, Enter, F2 or typing edits it.
class SpreadsheetScreen extends StatefulWidget {
  const SpreadsheetScreen({super.key, required this.api, required this.file});

  final FilesApi api;
  final FileItem file;

  @override
  State<SpreadsheetScreen> createState() => _SpreadsheetScreenState();
}

class _SpreadsheetScreenState extends State<SpreadsheetScreen> {
  static const _width = 104.0;
  static const _height = 28.0;
  static const _numberWidth = 56.0;

  late final Future<void> _load = _read();
  Pasta? _pasta;
  int _tab = 0;
  int _line = 0;
  int _column = 0;
  bool _editing = false;
  bool _isSaving = false;

  final _formula = TextEditingController();
  final _cell = TextEditingController();
  final _focus = FocusNode(debugLabel: 'grade');
  final _cellFocus = FocusNode(debugLabel: 'celula');
  final _formulaFocus = FocusNode(debugLabel: 'formula');
  final _h = ScrollController();
  final _v = ScrollController();
  final _vNumeros = ScrollController();

  FileTab get _sheet => _pasta!.tabs[_tab];
  bool get _dirty => _pasta?.changedFlag ?? false;

  @override
  void initState() {
    super.initState();
    _v.addListener(() {
      if (_vNumeros.hasClients && _vNumeros.offset != _v.offset) _vNumeros.jumpTo(_v.offset);
    });
  }

  @override
  void dispose() {
    for (final c in [_formula, _cell]) {
      c.dispose();
    }
    for (final f in [_focus, _cellFocus, _formulaFocus]) {
      f.dispose();
    }
    for (final s in [_h, _v, _vNumeros]) {
      s.dispose();
    }
    super.dispose();
  }

  Future<void> _read() async {
    final id = widget.file.id;
    final bytes = await widget.api.offline.original(id) ?? await widget.api.original(id);
    _pasta = Pasta.read(bytes);
    _formula.text = _sheet.content(0, 0);
  }

  // ------------------------------------------------------------- editing

  void _select(int line, int column, {bool edit = false, String? initial}) {
    _confirm();
    final l = line.clamp(0, maxRows - 1), c = column.clamp(0, maxColumns - 1);
    setState(() {
      _line = l;
      _column = c;
      _formula.text = _sheet.content(l, c);
      _editing = edit;
      if (edit) {
        _cell.text = initial ?? _formula.text;
        _cell.selection = TextSelection.collapsed(offset: _cell.text.length);
      }
    });
    if (!edit) _focus.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) => _showSelection());
  }

  /// Writes what is in the cell editor (if open) into the selected cell.
  void _confirm() {
    if (!_editing) return;
    _assign(_cell.text);
    _editing = false;
  }

  void _assign(String value) {
    if (_sheet.content(_line, _column) == value) return;
    setState(() {
      _sheet.setValue(_line, _column, value);
      _formula.text = _sheet.content(_line, _column);
    });
  }

  void _cancel() {
    setState(() {
      _editing = false;
      _formula.text = _sheet.content(_line, _column);
    });
    _focus.requestFocus();
  }

  void _mover(int dl, int dc) => _select(_line + dl, _column + dc);

  void _showSelection() {
    void fit(ScrollController s, double start, double size) {
      if (!s.hasClients) return;
      final p = s.position;
      if (start < p.pixels) {
        s.jumpTo(start);
      } else if (start + size > p.pixels + p.viewportDimension) {
        s.jumpTo(math.min(start + size - p.viewportDimension, p.maxScrollExtent));
      }
    }

    fit(_v, _line * _height, _height);
    fit(_h, _column * _width, _width);
  }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final shift = keyboard.isShiftPressed;
    final ctrl = keyboard.isControlPressed || keyboard.isMetaPressed;
    final k = e.logicalKey;
    if (ctrl && k == LogicalKeyboardKey.keyS) {
      if (_dirty && !_isSaving) _save();
      return KeyEventResult.handled;
    }
    if (_editing) {
      if (k == LogicalKeyboardKey.escape) {
        _cancel();
      } else if (k == LogicalKeyboardKey.tab) {
        _mover(0, shift ? -1 : 1);
      } else if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
        _mover(k == LogicalKeyboardKey.arrowUp ? -1 : 1, 0);
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }
    switch (k) {
      case LogicalKeyboardKey.arrowUp:
        _mover(-1, 0);
      case LogicalKeyboardKey.arrowDown:
        _mover(1, 0);
      case LogicalKeyboardKey.arrowLeft:
        _mover(0, -1);
      case LogicalKeyboardKey.arrowRight:
        _mover(0, 1);
      case LogicalKeyboardKey.tab:
        _mover(0, shift ? -1 : 1);
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter || LogicalKeyboardKey.f2:
        _select(_line, _column, edit: true);
      case LogicalKeyboardKey.delete || LogicalKeyboardKey.backspace:
        _assign('');
      default:
        final ch = e.character;
        if (ch == null || ch.isEmpty || ch.codeUnitAt(0) < 32 || ctrl || keyboard.isAltPressed) {
          return KeyEventResult.ignored;
        }
        _select(_line, _column, edit: true, initial: ch);
    }
    return KeyEventResult.handled;
  }

  void _structure(String action) {
    _confirm();
    final f = _sheet;
    setState(() {
      switch (action) {
        case 'linhaAcima':
          f.insertRow(_line);
        case 'linhaAbaixo':
          f.insertRow(_line + 1);
        case 'excluirLinha':
          f.deleteRow(_line);
        case 'colunaEsquerda':
          f.insertColumn(_column);
        case 'colunaDireita':
          f.insertColumn(_column + 1);
        case 'excluirColuna':
          f.deleteColumn(_column);
      }
      _formula.text = f.content(_line, _column);
    });
    _focus.requestFocus();
  }

  void _switchTab(int i) {
    _confirm();
    setState(() {
      _tab = i;
      _line = 0;
      _column = 0;
      _formula.text = _sheet.content(0, 0);
    });
    for (final s in [_h, _v]) {
      if (s.hasClients) s.jumpTo(0);
    }
    _focus.requestFocus();
  }

  Future<void> _save() async {
    _confirm();
    setState(() => _isSaving = true);
    try {
      final bytes = _pasta!.save();
      final isNew = await widget.api.offline.saveOriginal(widget.file, bytes);
      // Rereads what was saved: it becomes the new base for the next saves.
      _pasta = Pasta.read(bytes);
      if (mounted) notify(context, isNew == null ? 'Sem conexão: salvo no aparelho; sobe quando a conexão voltar.' : 'Salvo.');
    } on ApiErro catch (e) {
      if (mounted) notify(context, 'Não consegui salvar: ${e.mensagem}');
    } on InvalidXlsx catch (e) {
      if (mounted) notify(context, 'Não consegui gerar a planilha: ${e.mensagem}');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ---------------------------------------------------------------- telas

  @override
  Widget build(BuildContext context) => ExitGuard(
    dirty: _dirty,
    child: Scaffold(
      appBar: AppBar(
        title: Text(widget.file.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              onPressed: _dirty && !_isSaving ? _save : null,
              icon: _isSaving
                  ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save_outlined),
              label: const Text('Salvar'),
            ),
          ),
        ],
      ),
      body: FutureBuilder(
        future: _load,
        builder: (context, s) {
          if (s.hasError) {
            final e = s.error;
            final msg = e is ApiErro ? e.mensagem : (e is InvalidXlsx ? e.mensagem : '$e');
            return Center(child: Text('Não consegui abrir: $msg'));
          }
          if (s.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          return Column(
            children: [
              _formulaBar(),
              const Divider(height: 1),
              Expanded(
                child: Focus(focusNode: _focus, autofocus: true, onKeyEvent: _key, child: _grade()),
              ),
              const Divider(height: 1),
              _tabs(),
            ],
          );
        },
      ),
    ),
  );

  Widget _formulaBar() {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Row(
        spacing: 8,
        children: [
          Container(
            width: 72,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(border: Border.all(color: colors.outlineVariant), borderRadius: BorderRadius.circular(4)),
            child: Text(cellRef(_line, _column), style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Text('fx', style: TextStyle(fontStyle: FontStyle.italic, color: colors.outline)),
          Expanded(
            child: TextField(
              controller: _formula,
              focusNode: _formulaFocus,
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), hintText: 'Valor ou =fórmula'),
              onTap: () {
                if (_editing) setState(() => _editing = false);
              },
              onSubmitted: (v) {
                _assign(v);
                _mover(1, 0);
              },
              onTapOutside: (_) {
                if (!_formulaFocus.hasFocus) return;
                _assign(_formula.text);
                _formulaFocus.unfocus();
              },
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Linhas e colunas',
            icon: const Icon(Icons.table_rows_outlined),
            onSelected: _structure,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'linhaAcima', child: Text('Inserir linha acima')),
              PopupMenuItem(value: 'linhaAbaixo', child: Text('Inserir linha abaixo')),
              PopupMenuItem(value: 'excluirLinha', child: Text('Excluir linha')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'colunaEsquerda', child: Text('Inserir coluna à esquerda')),
              PopupMenuItem(value: 'colunaDireita', child: Text('Inserir coluna à direita')),
              PopupMenuItem(value: 'excluirColuna', child: Text('Excluir coluna')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tabs() => SizedBox(
    height: 48,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      children: [
        for (var i = 0; i < _pasta!.tabs.length; i++)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ChoiceChip(
              label: Text(_pasta!.tabs[i].name + (_pasta!.tabs[i].changedFlag ? ' •' : '')),
              selected: i == _tab,
              onSelected: (_) => _switchTab(i),
            ),
          ),
      ],
    ),
  );

  Widget _grade() {
    final colors = Theme.of(context).colorScheme;
    final edge = BorderSide(color: colors.outlineVariant, width: 0.5);
    final header = colors.surfaceContainerHighest;
    final f = _sheet;
    return LayoutBuilder(
      builder: (context, box) {
        final visibleWidth = math.max(0.0, box.maxWidth - _numberWidth);
        final nRows = math.min(maxRows, math.max(math.max(f.lines, _line) + 50, (box.maxHeight / _height).ceil() + 1));
        final nColumns = math.min(
          maxColumns,
          math.max(math.max(f.columns, _column) + 10, (visibleWidth / _width).ceil() + 1),
        );

        Widget number(int i) => GestureDetector(
          onTap: () => _select(i, _column),
          child: Container(
            height: _height,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: i == _line ? colors.primaryContainer : header,
              border: Border(right: edge, bottom: edge),
            ),
            child: Text('${i + 1}', style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
          ),
        );

        Widget cell(int l, int c) {
          final selected = l == _line && c == _column;
          final decorationStyle = BoxDecoration(border: Border(right: edge, bottom: edge));
          if (selected && _editing) {
            return Container(
              width: _width,
              height: _height,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(border: Border.all(color: colors.primary, width: 2), color: colors.surface),
              child: TextField(
                controller: _cell,
                focusNode: _cellFocus,
                autofocus: true,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(isDense: true, border: InputBorder.none, contentPadding: EdgeInsets.symmetric(vertical: 6)),
                onChanged: (v) => _formula.text = v,
                onSubmitted: (_) => _mover(1, 0),
                onTapOutside: (_) {
                  if (!_editing) return;
                  _confirm();
                  setState(() {});
                },
              ),
            );
          }
          final text = f.cell(l, c);
          final numeric = text.isNotEmpty && double.tryParse(text) != null;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _select(l, c, edit: selected),
            onDoubleTap: () => _select(l, c, edit: true),
            child: Container(
              width: _width,
              height: _height,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              alignment: numeric ? Alignment.centerRight : Alignment.centerLeft,
              decoration: decorationStyle,
              foregroundDecoration: selected ? BoxDecoration(border: Border.all(color: colors.primary, width: 2)) : null,
              child: Text(text, maxLines: 1, overflow: TextOverflow.clip, softWrap: false, style: const TextStyle(fontSize: 13)),
            ),
          );
        }

        return ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: _numberWidth,
                child: Column(
                  children: [
                    Container(
                      height: _height,
                      decoration: BoxDecoration(color: header, border: Border(right: edge, bottom: edge)),
                    ),
                    Expanded(
                      child: ListView.builder(
                        controller: _vNumeros,
                        physics: const NeverScrollableScrollPhysics(),
                        itemExtent: _height,
                        itemCount: nRows,
                        itemBuilder: (_, i) => number(i),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Scrollbar(
                  controller: _h,
                  thumbVisibility: true,
                  child: Scrollbar(
                    controller: _v,
                    thumbVisibility: true,
                    notificationPredicate: (n) => n.depth == 1,
                    child: SingleChildScrollView(
                      controller: _h,
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: nColumns * _width,
                        child: ListenableBuilder(
                          listenable: _h,
                          builder: (context, _) {
                            // Only the columns in the visible window (plus one spare).
                            final offset = _h.hasClients ? _h.offset : 0.0;
                            final c0 = math.max(0, (offset / _width).floor());
                            final c1 = math.min(nColumns, c0 + (visibleWidth / _width).ceil() + 1);
                            return Column(
                              children: [
                                Padding(
                                  padding: EdgeInsets.only(left: c0 * _width),
                                  child: Row(
                                    children: [
                                      for (var c = c0; c < c1; c++)
                                        GestureDetector(
                                          onTap: () => _select(_line, c),
                                          child: Container(
                                            width: _width,
                                            height: _height,
                                            alignment: Alignment.center,
                                            decoration: BoxDecoration(
                                              color: c == _column ? colors.primaryContainer : header,
                                              border: Border(right: edge, bottom: edge),
                                            ),
                                            child: Text(
                                              columnLetters(c),
                                              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: ListView.builder(
                                    controller: _v,
                                    itemExtent: _height,
                                    itemCount: nRows,
                                    itemBuilder: (_, l) => Padding(
                                      padding: EdgeInsets.only(left: c0 * _width),
                                      child: Row(children: [for (var c = c0; c < c1; c++) cell(l, c)]),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
