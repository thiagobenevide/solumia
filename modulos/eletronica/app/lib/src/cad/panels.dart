import 'dart:async';

import 'package:flutter/material.dart';

import '../models.dart';
import '../screens/libraries_screen.dart';
import 'editor.dart';
import 'painting.dart';

/// One-line dialog; [suggestions] show up as shortcuts (e.g. nets already used).
Future<String?> askText(BuildContext context, String title, {String initial = '', List<String> suggestions = const []}) async {
  final controle = TextEditingController(text: initial);
  final r = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          TextField(controller: controle, autofocus: true, onSubmitted: (v) => Navigator.pop(c, v)),
          if (suggestions.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [for (final s in suggestions) ActionChip(label: Text(s), onPressed: () => Navigator.pop(c, s))],
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(c, controle.text), child: const Text('OK')),
      ],
    ),
  );
  controle.dispose();
  return r;
}

/// Item properties dialog (E or double tap); also used on the phone, without a side panel.
Future<void> editItem(BuildContext context, Editor editor, Item item) async {
  switch (item) {
    case Component c:
      final ref = TextEditingController(text: c.ref);
      final value = TextEditingController(text: c.value);
      final enc = TextEditingController(text: c.footprint);
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(editor.symbolOf(c).name),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              TextField(controller: ref, decoration: const InputDecoration(labelText: 'Referência')),
              TextField(controller: value, autofocus: true, decoration: const InputDecoration(labelText: 'Valor')),
              TextField(controller: enc, decoration: const InputDecoration(labelText: 'Encapsulamento')),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Salvar')),
          ],
        ),
      );
      if (ok == true) {
        editor.change(() {
          c
            ..ref = ref.text.trim()
            ..value = value.text.trim()
            ..footprint = enc.text.trim();
        });
      }
      for (final t in [ref, value, enc]) {
        t.dispose();
      }
    case NetLabel r:
      final name = await askText(context, 'Nome da rede', initial: r.name);
      if (name != null && name.trim().isNotEmpty) editor.change(() => r.name = name.trim());
    case CadText t:
      final text = await askText(context, 'Texto', initial: t.text);
      if (text != null && text.trim().isNotEmpty) editor.change(() => t.text = text);
    case Wire() || Probe():
      break;
  }
}

/// Symbol thumbnail, centered and at the scale that fits.
class SymbolPreview extends StatelessWidget {
  const SymbolPreview(this.symbol, {super.key, this.size = 44});

  final Symbol symbol;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(dimension: size, child: CustomPaint(painter: _PreviewPainter(symbol)));
}

class _PreviewPainter extends CustomPainter {
  _PreviewPainter(this.s);

  final Symbol s;

  @override
  void paint(Canvas canvas, Size size) {
    final r = s.bounds;
    if (r.isEmpty) return;
    final scale = (size.shortestSide / r.longestSide) * 0.9;
    canvas
      ..translate(size.width / 2, size.height / 2)
      ..scale(scale)
      ..translate(-r.center.dx, -r.center.dy);
    paintSymbol(canvas, s, pos: const P(0, 0), palette: Palette.dark, fields: false);
  }

  @override
  bool shouldRepaint(_PreviewPainter old) => old.s != s;
}

/// Library: Base tab (local search by category) and KiCad tab (server search among the imported ones).
/// Tapping a symbol arms the component tool.
class LibraryPanel extends StatefulWidget {
  const LibraryPanel({super.key, required this.editor, required this.focus, required this.onPick});

  final Editor editor;
  final FocusNode focus;
  final VoidCallback onPick;

  @override
  State<LibraryPanel> createState() => _LibraryPanelState();
}

class _LibraryPanelState extends State<LibraryPanel> {
  String _search = '';
  String? _category;
  bool _kicad = false;
  List<String> _imported = [];
  String? _lib;
  List<Symbol> _matches = [];
  bool _searching = false;
  String? _error;
  Timer? _wait;
  int _request = 0;

  @override
  void dispose() {
    _wait?.cancel();
    super.dispose();
  }

  Future<void> _loadImported() async {
    try {
      final libs = await widget.editor.api.libraries();
      if (mounted) setState(() => _imported = [for (final b in libs) '${b['nome']}']);
    } catch (_) {}
  }

  void _switchTab(bool kicad) {
    setState(() => _kicad = kicad);
    if (kicad) {
      _loadImported();
      _searchServer();
    }
  }

  void _searchChanged(String v) {
    setState(() => _search = v);
    if (!_kicad) return;
    _wait?.cancel();
    _wait = Timer(const Duration(milliseconds: 300), _searchServer);
  }

  Future<void> _searchServer() async {
    if (_search.trim().isEmpty && _lib == null) {
      setState(() => _matches = []);
      return;
    }
    final request = ++_request;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final r = await widget.editor.api.searchSymbols(_search, library: _lib);
      if (!mounted || request != _request) return;
      setState(() => _matches = r);
    } catch (e) {
      if (mounted && request == _request) setState(() => _error = '$e');
    } finally {
      if (mounted && request == _request) setState(() => _searching = false);
    }
  }

  Future<void> _manage() async {
    await showLibraries(context, widget.editor.api);
    await _loadImported();
    if (_lib != null && !_imported.contains(_lib)) _lib = null;
    _searchServer();
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.editor.library;
    final items = _kicad ? _matches : b.search(_search, category: _category);
    final chips = _kicad ? _imported : b.categories;
    final current = _kicad ? _lib : _category;
    return ListenableBuilder(
      listenable: widget.editor,
      builder: (context, _) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Row(
              spacing: 4,
              children: [
                Expanded(
                  child: SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('Base')),
                      ButtonSegment(value: true, label: Text('KiCad')),
                    ],
                    selected: {_kicad},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) => _switchTab(s.first),
                  ),
                ),
                IconButton(tooltip: 'Bibliotecas do KiCad', onPressed: _manage, icon: const Icon(Icons.library_add_outlined)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: TextField(
              focusNode: widget.focus,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: _kicad ? 'Buscar no KiCad (ex.: LM358, mosfet)' : 'Buscar componente (A)',
                isDense: true,
              ),
              onChanged: _searchChanged,
              onSubmitted: (_) {
                if (items.isNotEmpty) _pick(items.first);
              },
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              children: [
                for (final c in [null, ...chips])
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: ChoiceChip(
                      label: Text(c ?? 'Todos'),
                      selected: current == c,
                      onSelected: (_) {
                        setState(() => _kicad ? _lib = c : _category = c);
                        if (_kicad) _searchServer();
                      },
                    ),
                  ),
              ],
            ),
          ),
          if (_searching) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _list(items)),
        ],
      ),
    );
  }

  Widget _list(List<Symbol> items) {
    if (_kicad && _error != null) return Center(child: Padding(padding: const EdgeInsets.all(16), child: Text('Não buscou: $_error')));
    if (_kicad && _imported.isEmpty && !_searching) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              const Text('Nenhuma biblioteca do KiCad importada.', textAlign: TextAlign.center),
              FilledButton.icon(onPressed: _manage, icon: const Icon(Icons.library_add_outlined), label: const Text('Importar')),
            ],
          ),
        ),
      );
    }
    if (_kicad && items.isEmpty && !_searching) {
      return const Center(child: Text('Digite para buscar ou escolha uma biblioteca.'));
    }
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, i) {
        final s = items[i];
        final active = widget.editor.tool == Tool.component && widget.editor.symbol?.id == s.id;
        final detail = _kicad
            ? [s.category, if (s.descricao.isNotEmpty) s.descricao].join(' · ')
            : [s.prefix, s.value].where((t) => t.isNotEmpty).join(' · ');
        return ListTile(
          selected: active,
          leading: SymbolPreview(s),
          title: Text(s.name),
          subtitle: Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis),
          onTap: () => _pick(s),
        );
      },
    );
  }

  void _pick(Symbol s) {
    widget.editor.library.adicionar([s]);
    widget.editor.pick(Tool.component, s: s);
    widget.onPick();
  }
}

/// Toolbar, with large buttons for finger and pen (no keyboard).
class Toolbar extends StatelessWidget {
  const Toolbar({super.key, required this.editor, required this.onLibrary});

  final Editor editor;
  final VoidCallback onLibrary;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: editor,
    builder: (context, _) {
      final f = editor.tool;
      Widget tool(Tool target, IconData icone, String hint, [VoidCallback? action]) => IconButton(
        tooltip: hint,
        isSelected: f == target,
        onPressed: action ?? () => editor.pick(target),
        icon: Icon(icone),
      );
      final hasSelection = editor.selection.isNotEmpty;
      final armed = f == Tool.component;
      return Material(
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              tool(Tool.select, Icons.near_me_outlined, 'Selecionar (V)'),
              tool(Tool.component, Icons.memory, 'Componente (A)', onLibrary),
              tool(Tool.wire, Icons.timeline, 'Fio (W)'),
              tool(Tool.label, Icons.label_outline, 'Rótulo de rede (L)'),
              tool(Tool.text, Icons.title, 'Texto (T)'),
              tool(Tool.probe, Icons.colorize_outlined, 'Ponta de prova (P): na rede = tensão, no componente = corrente'),
              const SizedBox(height: 32, child: VerticalDivider()),
              IconButton(tooltip: 'Girar 90° (R)', onPressed: hasSelection || armed ? editor.rotate : null, icon: const Icon(Icons.rotate_90_degrees_cw_outlined)),
              IconButton(tooltip: 'Espelhar (X)', onPressed: hasSelection || armed ? editor.mirror : null, icon: const Icon(Icons.flip)),
              IconButton(tooltip: 'Duplicar (Ctrl+D)', onPressed: hasSelection ? editor.duplicateSelection : null, icon: const Icon(Icons.copy_all_outlined)),
              IconButton(tooltip: 'Excluir (Del)', onPressed: hasSelection ? editor.deleteSelection : null, icon: const Icon(Icons.delete_outline)),
              if (editor.wire != null) ...[
                const SizedBox(height: 32, child: VerticalDivider()),
                IconButton(
                  tooltip: 'Inverter o canto (/)',
                  onPressed: editor.flipCorner,
                  icon: const Icon(Icons.turn_right),
                ),
                FilledButton.tonalIcon(onPressed: editor.finishWire, icon: const Icon(Icons.check), label: const Text('Concluir fio')),
              ],
              if (armed && editor.symbol != null)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Chip(
                    avatar: SymbolPreview(editor.symbol!, size: 22),
                    label: Text(editor.symbol!.name),
                    onDeleted: () => editor.pick(Tool.select),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// Sheet tabs + cursor coordinates (mm), zoom and grid step.
class SheetBar extends StatelessWidget {
  const SheetBar({super.key, required this.editor, required this.camera});

  final Editor editor;
  final Camera camera;

  Future<void> _menu(BuildContext context, Sheet f) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Renomear'), onTap: () => Navigator.pop(c, 'renomear')),
            if (editor.project.sheets.length > 1)
              ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Excluir folha'), onTap: () => Navigator.pop(c, 'excluir')),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 'renomear') {
      final name = await askText(context, 'Nome da folha', initial: f.name);
      if (name != null && name.trim().isNotEmpty) editor.renameSheet(f.id, name.trim());
    } else if (action == 'excluir') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('Excluir "${f.name}" e tudo o que está nela?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Excluir')),
          ],
        ),
      );
      if (ok == true) editor.deleteSheet(f.id);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: editor,
    builder: (context, _) {
      final c = editor.cursor;
      final estilo = Theme.of(context).textTheme.labelSmall?.copyWith(fontFamily: 'monospace');
      String mm(int um) => (um / 1000).toStringAsFixed(2);
      // On the phone the grid and the coordinates shrink to leave room for the sheet tabs.
      final narrow = MediaQuery.sizeOf(context).width < 700;
      final label = narrow ? '' : 'grade ';
      return Material(
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: SizedBox(
          height: 44,
          child: Row(
            children: [
              Expanded(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  children: [
                    for (final f in editor.project.sheets)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: GestureDetector(
                          onLongPress: () => _menu(context, f),
                          onSecondaryTap: () => _menu(context, f),
                          child: ChoiceChip(label: Text(f.name), selected: f.id == editor.sheet, onSelected: (_) => editor.goTo(f.id)),
                        ),
                      ),
                    IconButton(tooltip: 'Nova folha', onPressed: editor.newSheet, icon: const Icon(Icons.add)),
                  ],
                ),
              ),
              DropdownButton<int>(
                value: editor.step,
                underline: const SizedBox.shrink(),
                style: estilo,
                items: [
                  DropdownMenuItem(value: 635, child: Text('${label}0,635 mm')),
                  DropdownMenuItem(value: grade, child: Text('${label}1,27 mm')),
                  DropdownMenuItem(value: 2540, child: Text('${label}2,54 mm')),
                ],
                onChanged: (v) => v == null ? null : editor.changeStep(v),
              ),
              SizedBox(width: narrow ? 6 : 12),
              SizedBox(
                width: narrow ? 96 : 190,
                child: Text(
                  c == null ? '' : (narrow ? 'X ${mm(c.x)}\nY ${mm(c.y)}' : 'X ${mm(c.x)}  Y ${mm(c.y)} mm'),
                  style: estilo,
                  maxLines: 2,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Right panel: properties of what is selected and the layers.
class PropertiesPanel extends StatelessWidget {
  const PropertiesPanel({super.key, required this.editor});

  final Editor editor;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: editor,
    builder: (context, _) {
      final sel = editor.selected;
      final title = Theme.of(context).textTheme.titleSmall;
      return ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text('Propriedades', style: title),
          const SizedBox(height: 8),
          if (sel.isEmpty) const Text('Nada selecionado. Toque num item ou arraste uma janela (mouse).'),
          if (sel.length > 1) Text('${sel.length} itens selecionados'),
          if (sel.length == 1) ..._campos(context, sel.single),
          const Divider(height: 32),
          Text('Camadas', style: title),
          for (final c in Layer.values)
            Row(
              children: [
                Expanded(child: Text(c.name)),
                IconButton(
                  tooltip: editor.hidden.contains(c) ? 'Mostrar' : 'Esconder',
                  onPressed: () => editor.toggleLayer(c),
                  icon: Icon(editor.hidden.contains(c) ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                ),
                if (c != Layer.grade && c != Layer.fields)
                  IconButton(
                    tooltip: editor.locked.contains(c) ? 'Destravar' : 'Travar (não seleciona)',
                    onPressed: () => editor.toggleLayer(c, lock: true),
                    icon: Icon(editor.locked.contains(c) ? Icons.lock_outline : Icons.lock_open_outlined),
                  ),
              ],
            ),
        ],
      );
    },
  );

  List<Widget> _campos(BuildContext context, Item item) => switch (item) {
    Component c => [
      Row(
        spacing: 12,
        children: [
          SymbolPreview(editor.symbolOf(c)),
          Expanded(child: Text(editor.symbolOf(c).name)),
        ],
      ),
      _Field(key: ValueKey('${c.id}ref'), label: 'Referência', value: c.ref, aoMudar: (v) => editor.change(() => c.ref = v)),
      _Field(key: ValueKey('${c.id}val'), label: 'Valor', value: c.value, aoMudar: (v) => editor.change(() => c.value = v)),
      _Field(
        key: ValueKey('${c.id}enc'),
        label: 'Encapsulamento',
        value: c.footprint,
        aoMudar: (v) => editor.change(() => c.footprint = v),
      ),
      const SizedBox(height: 8),
      Text('Posição: ${(c.pos.x / 1000).toStringAsFixed(2)}, ${(c.pos.y / 1000).toStringAsFixed(2)} mm · ${c.rot}°${c.mirrored ? ' · espelhado' : ''}'),
      const SizedBox(height: 8),
      Text('Pinos', style: Theme.of(context).textTheme.labelLarge),
      for (final p in editor.symbolOf(c).pins)
        Text('${p.n.padLeft(2)}  ${p.name.isEmpty ? '—' : p.name}  (${p.type})', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
    ],
    NetLabel r => [_Field(key: ValueKey(r.id), label: 'Rede', value: r.name, aoMudar: (v) => editor.change(() => r.name = v))],
    CadText t => [
      _Field(key: ValueKey(t.id), label: 'Texto', value: t.text, aoMudar: (v) => editor.change(() => t.text = v)),
      DropdownButton<int>(
        value: t.size,
        isExpanded: true,
        items: [for (final s in [635, 1016, grade, 1905, 2540, 3810]) DropdownMenuItem(value: s, child: Text('${(s / 1000).toStringAsFixed(2)} mm'))],
        onChanged: (v) => v == null ? null : editor.change(() => t.size = v),
      ),
    ],
    Wire f => [Text('Fio com ${f.points.length} pontos')],
    Probe s => [
      Text(s.type == 'v' ? 'Ponta de tensão V${editor.probeIndex(s) + 1}' : 'Ponta de corrente em ${s.ref}'),
      if (editor.readings[s.id] != null) Text('Última leitura: ${editor.readings[s.id]}'),
      const Text('O sinal dela abre ligado no osciloscópio, com a mesma cor.'),
    ],
  };
}

/// Field that only saves on confirm (Enter) or on leaving it: one undo entry per edit.
class _Field extends StatefulWidget {
  const _Field({super.key, required this.label, required this.value, required this.aoMudar});

  final String label, value;
  final ValueChanged<String> aoMudar;

  @override
  State<_Field> createState() => _FieldState();
}

class _FieldState extends State<_Field> {
  late final _controller = TextEditingController(text: widget.value);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _confirm();
    });
  }

  @override
  void didUpdateWidget(_Field old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && widget.value != _controller.text) _controller.text = widget.value;
  }

  void _confirm() {
    final v = _controller.text.trim();
    if (v.isNotEmpty && v != widget.value) widget.aoMudar(v);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: TextField(
      controller: _controller,
      focusNode: _focus,
      decoration: InputDecoration(labelText: widget.label, isDense: true),
      onSubmitted: (_) => _confirm(),
    ),
  );
}
