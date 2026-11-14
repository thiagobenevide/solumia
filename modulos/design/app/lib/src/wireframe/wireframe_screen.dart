import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design_api.dart';
import 'model.dart';
import 'painting.dart';

/// Loads wireframe [id] and opens the editor.
class OpenWireframe extends StatelessWidget {
  const OpenWireframe({super.key, required this.api, required this.id});

  final ApiDesign api;
  final String id;

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: api.fetchWireframe(id),
    builder: (context, s) => s.hasData
        ? WireframeScreen(api: api, wireframe: s.data!)
        : Scaffold(
            appBar: AppBar(),
            body: Center(child: s.hasError ? Text('Não abriu: ${s.error}') : const CircularProgressIndicator()),
          ),
  );
}

/// Wireframe editor: screens (tabs), component palette, artboard in the reference style
/// (`docs/wireframes-nd`) and properties/notes panel. Saves on its own 1.2 s after the last change.
class WireframeScreen extends StatefulWidget {
  const WireframeScreen({super.key, required this.api, required this.wireframe});

  final ApiDesign api;
  final Wireframe wireframe;

  @override
  State<WireframeScreen> createState() => _WireframeScreenState();
}

class _WireframeScreenState extends State<WireframeScreen> {
  late Wireframe _wf = widget.wireframe;
  int _screen = 0;
  String? _sel;
  int _paintVersion = 0;

  /// Goes up when the document changes outside the fields (undo, import): redoes the panels.
  int _reload = 0;
  double _zoom = 1;
  Timer? _autosave;
  bool _isSaving = false, _dirty = false;
  final List<String> _undo = [];
  final _focus = FocusNode();

  // Drag: offset from the pointer to the component corner; resize = corner handle.
  Offset? _grab;
  bool _resizing = false;

  WfScreen get _currentScreen => _wf.screens[_screen];
  List<WfComponent> get _visible => [for (final c in _wf.components) if (c.page == _currentScreen.id) c];
  WfComponent? get _selected => _wf.components.where((c) => c.id == _sel).firstOrNull;

  @override
  void dispose() {
    _autosave?.cancel();
    if (_dirty) unawaited(_save());
    _focus.dispose();
    super.dispose();
  }

  String _photo() => jsonEncode({
    'telas': [for (final t in _wf.screens) t.toJson()],
    'componentes': [for (final c in _wf.components) c.toJson()],
  });

  /// Every change passes here: stores the undo, repaints and schedules the save.
  void _change(VoidCallback f, {bool history = true}) {
    if (history) {
      _undo.add(_photo());
      if (_undo.length > 100) _undo.removeAt(0);
    }
    setState(() {
      f();
      _paintVersion++;
      _dirty = true;
    });
    _autosave?.cancel();
    _autosave = Timer(const Duration(milliseconds: 1200), _save);
  }

  void _back() {
    if (_undo.isEmpty) return;
    final j = jsonDecode(_undo.removeLast()) as Map<String, dynamic>;
    _change(history: false, () {
      _wf.screens
        ..clear()
        ..addAll([for (final t in j['telas'] as List) WfScreen.fromJson(t as Map<String, dynamic>)]);
      _wf.components
        ..clear()
        ..addAll([for (final c in j['componentes'] as List) WfComponent.fromJson(c as Map<String, dynamic>)]);
      _screen = _screen.clamp(0, _wf.screens.length - 1);
      _reload++;
    });
  }

  Future<void> _save() async {
    if (_isSaving || !_dirty) return;
    _isSaving = true;
    _dirty = false;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await widget.api.editWireframe(_wf.id, title: _wf.title, screens: _wf.screens);
      final r = await widget.api.saveWireframe(_wf.id, _wf.version, _wf.components);
      _wf.version = r.version;
    } on ApiErro catch (e) {
      if (e.status == 409) {
        final current = await widget.api.fetchWireframe(_wf.id);
        if (mounted) setState(() => _swapDocument(current));
        messenger?.showSnackBar(const SnackBar(content: Text('Outro aparelho gravou antes: abri a versão dele.')));
      } else {
        _dirty = true;
        messenger?.showSnackBar(SnackBar(content: Text('Não gravou: ${e.mensagem}')));
      }
    } catch (_) {
      _dirty = true;
    } finally {
      _isSaving = false;
      if (mounted) setState(() {});
    }
  }

  void _swapDocument(Wireframe isNew) {
    _wf = isNew;
    _screen = _screen.clamp(0, _wf.screens.length - 1);
    _sel = null;
    _paintVersion++;
    _reload++;
  }

  // ---------- componentes ----------

  String _newId(String type) {
    final ids = {for (final c in _wf.components) c.id};
    var n = 1;
    while (ids.contains('$type-$n')) {
      n++;
    }
    return '$type-$n';
  }

  void _add(String type) {
    final (_, size, props) = catalog[type]!;
    final t = _currentScreen;
    final c = WfComponent(
      id: _newId(type),
      type: type,
      page: t.id,
      box: Rect.fromCenter(center: Offset(t.width / 2, t.height / 3), width: size.width, height: size.height),
      props: jsonDecode(jsonEncode(props)) as Map<String, dynamic>,
    );
    fitSize(c);
    _change(() {
      _wf.components.add(c);
      _sel = c.id;
    });
  }

  void _delete() {
    final c = _selected;
    if (c == null) return;
    _change(() {
      _wf.components.remove(c);
      _sel = null;
    });
  }

  void _duplicate() {
    final c = _selected;
    if (c == null) return;
    final copy = c.copyItems(id: _newId(c.type), shift: const Offset(16, 16));
    _change(() {
      _wf.components.add(copy);
      _sel = copy.id;
    });
  }

  /// Front/back: the list order is the drawing order.
  void _order(bool front) {
    final c = _selected;
    if (c == null) return;
    _change(() {
      _wf.components.remove(c);
      front ? _wf.components.add(c) : _wf.components.insert(0, c);
    });
  }

  void _mover(Offset d) {
    final c = _selected;
    if (c == null) return;
    _change(() {
      c.box = c.box.shift(d);
      _reload++;
    });
  }

  // ---------- telas ----------

  void _newScreen() {
    final ids = {for (final t in _wf.screens) t.id};
    var n = _wf.screens.length + 1;
    while (ids.contains('tela-$n')) {
      n++;
    }
    final base = _currentScreen;
    _change(() {
      _wf.screens.add(WfScreen.fromJson({
        'id': 'tela-$n',
        'nome': 'Tela $n',
        'codigo': 'WF-${n.toString().padLeft(2, '0')}',
        'caminho': base.path,
        'largura': base.width,
        'altura': base.height,
      }));
      _screen = _wf.screens.length - 1;
      _sel = null;
    });
  }

  Future<void> _deleteScreen() async {
    if (_wf.screens.length < 2) return;
    final t = _currentScreen;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Excluir a tela "${t.name}"?'),
        content: const Text('Os componentes dela também saem.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Excluir')),
        ],
      ),
    );
    if (ok != true) return;
    _change(() {
      _wf.components.removeWhere((c) => c.page == t.id);
      _wf.screens.remove(t);
      _screen = math.max(0, _screen - 1);
      _sel = null;
    });
  }

  // ---------- IA ----------

  Future<void> _export(bool soJson) async {
    final messenger = ScaffoldMessenger.of(context);
    await _save();
    try {
      if (!soJson) {
        // The PNGs come from here (same drawing as the editor) and the server puts them in the ZIP.
        for (final t in _wf.screens) {
          final png = await renderScreen(t, [for (final c in _wf.components) if (c.page == t.id) c]);
          await widget.api.uploadScreenPng(_wf.id, t.id, png);
        }
      }
      final bytes = await widget.api.exportWireframe(_wf.id, soJson: soJson);
      final name = _wf.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
      final saved = await FilePicker.saveFile(
        fileName: '${name.isEmpty ? 'wireframe' : name}.wireframe.${soJson ? 'json' : 'zip'}',
        bytes: bytes,
        mimeType: soJson ? 'application/json' : 'application/zip',
      );
      if (saved != null) messenger.showSnackBar(const SnackBar(content: Text('Pacote para IA exportado')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Não exportou: $e')));
    }
  }

  Future<void> _import() async {
    final messenger = ScaffoldMessenger.of(context);
    final a = (await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['json', 'zip', 'md', 'txt'])).firstOrNull;
    if (a == null) return;
    await _save();
    try {
      final isNew = await widget.api.reimportWireframe(_wf.id, a.name, await a.xFile.readAsBytes());
      _undo.add(_photo());
      setState(() => _swapDocument(isNew));
      messenger.showSnackBar(const SnackBar(content: Text('Edição da IA aplicada (Ctrl+Z desfaz)')));
    } on ApiErro catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Não importou: ${e.mensagem}')));
    }
  }

  // ---------- artboard input ----------

  Offset _onScreen(Offset artboard) => artboard - Artboard(_currentScreen).origin;

  void _tap(Offset p) {
    final pos = _onScreen(p);
    final target = _visible.reversed.where((c) => c.box.inflate(4).contains(pos)).firstOrNull;
    setState(() => _sel = target?.id);
    _focus.requestFocus();
  }

  void _dragStart(Offset p) {
    final pos = _onScreen(p);
    final sel = _selected;
    if (sel != null && (pos - sel.box.bottomRight).distance < 12) {
      _resizing = true;
      _grab = Offset.zero;
    } else {
      _tap(p);
      final c = _selected;
      _resizing = false;
      _grab = c == null ? null : pos - c.box.topLeft;
    }
    if (_grab != null) _undo.add(_photo());
  }

  void _drag(Offset p) {
    final c = _selected, grab = _grab;
    if (c == null || grab == null) return;
    final pos = _onScreen(p);
    double grade(double v) => (v / 4).roundToDouble() * 4;
    _change(history: false, () {
      if (_resizing) {
        c.box = Rect.fromLTRB(c.box.left, c.box.top, math.max(c.box.left + 8, grade(pos.dx)), math.max(c.box.top + 8, grade(pos.dy)));
      } else {
        final o = pos - grab;
        c.box = Rect.fromLTWH(grade(o.dx), grade(o.dy), c.box.width, c.box.height);
      }
    });
  }

  KeyEventResult _pressedKey(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final ctrl = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
    final step = HardwareKeyboard.instance.isShiftPressed ? 10.0 : 1.0;
    final k = e.logicalKey;
    if (ctrl && k == LogicalKeyboardKey.keyZ) {
      _back();
    } else if (ctrl && k == LogicalKeyboardKey.keyD) {
      _duplicate();
    } else if (k == LogicalKeyboardKey.delete || k == LogicalKeyboardKey.backspace) {
      _delete();
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      _mover(Offset(-step, 0));
    } else if (k == LogicalKeyboardKey.arrowRight) {
      _mover(Offset(step, 0));
    } else if (k == LogicalKeyboardKey.arrowUp) {
      _mover(Offset(0, -step));
    } else if (k == LogicalKeyboardKey.arrowDown) {
      _mover(Offset(0, step));
    } else if (k == LogicalKeyboardKey.escape) {
      setState(() => _sel = null);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // ---------- layout ----------

  Widget _artboard() {
    final size = Artboard(_currentScreen).size;
    return LayoutBuilder(
      builder: (context, box) {
        final scale = box.maxWidth / size.width * _zoom;
        return InteractiveViewer(
          constrained: false,
          panEnabled: false,
          scaleEnabled: false,
          child: SizedBox(
            width: size.width * scale,
            height: size.height * scale,
            child: FittedBox(
              child: GestureDetector(
                onTapDown: (d) => _tap(d.localPosition),
                onPanStart: (d) => _dragStart(d.localPosition),
                onPanUpdate: (d) => _drag(d.localPosition),
                onPanEnd: (_) => setState(() {
                  _grab = null;
                  _reload++;
                }),
                child: CustomPaint(
                  size: size,
                  painter: WireframePainter(_currentScreen, _visible, selectedItem: _sel, version: _paintVersion),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _palette() => ListView(
    padding: const EdgeInsets.all(8),
    children: [
      Text('Componentes', style: Theme.of(context).textTheme.titleSmall),
      for (final MapEntry(key: type, value: (label, _, _)) in catalog.entries)
        ListTile(dense: true, title: Text(label), subtitle: Text(type), trailing: const Icon(Icons.add, size: 18), onTap: () => _add(type)),
    ],
  );

  Widget _properties() {
    final c = _selected;
    return c == null
        ? _ScreenPanel(key: ValueKey('tela-${_currentScreen.id}-$_reload'), screen: _currentScreen, aoMudar: (f) => _change(f))
        : _ComponentPanel(
            key: ValueKey('comp-${c.id}-$_reload'),
            c: c,
            aoMudar: (f) => _change(() {
              f();
              fitSize(c);
            }),
            onDelete: _delete,
            onDuplicate: _duplicate,
            onReorder: _order,
          );
  }

  @override
  Widget build(BuildContext context) {
    final largo = MediaQuery.sizeOf(context).width >= 1100;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _pressedKey,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_wf.title),
          actions: [
            if (_isSaving) const Padding(padding: EdgeInsets.all(16), child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))),
            IconButton(tooltip: 'Desfazer (Ctrl+Z)', onPressed: _undo.isEmpty ? null : _back, icon: const Icon(Icons.undo)),
            IconButton(tooltip: 'Diminuir', onPressed: () => setState(() => _zoom = math.max(.5, _zoom / 1.25)), icon: const Icon(Icons.zoom_out)),
            IconButton(tooltip: 'Aumentar', onPressed: () => setState(() => _zoom = math.min(4, _zoom * 1.25)), icon: const Icon(Icons.zoom_in)),
            PopupMenuButton<String>(
              tooltip: 'Trocar com outras IAs',
              icon: const Icon(Icons.smart_toy_outlined),
              onSelected: (v) => switch (v) {
                'zip' => _export(false),
                'json' => _export(true),
                _ => _import(),
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'zip', child: Text('Exportar pacote para IA (.zip com PNG das telas)')),
                PopupMenuItem(value: 'json', child: Text('Exportar só o wireframe.json')),
                PopupMenuItem(value: 'importar', child: Text('Importar edição da IA…')),
              ],
            ),
            if (!largo) Builder(builder: (c) => IconButton(tooltip: 'Propriedades', onPressed: Scaffold.of(c).openEndDrawer, icon: const Icon(Icons.tune))),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(44),
            child: SizedBox(
              height: 44,
              child: Row(
                children: [
                  Expanded(
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      children: [
                        for (final (i, t) in _wf.screens.indexed)
                          Padding(
                            padding: const EdgeInsets.all(4),
                            child: ChoiceChip(
                              label: Text(t.code.isEmpty ? t.name : '${t.code} · ${t.name}'),
                              selected: i == _screen,
                              onSelected: (_) => setState(() {
                                _screen = i;
                                _sel = null;
                              }),
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(tooltip: 'Nova tela', onPressed: _newScreen, icon: const Icon(Icons.add)),
                  IconButton(tooltip: 'Excluir tela', onPressed: _wf.screens.length < 2 ? null : _deleteScreen, icon: const Icon(Icons.delete_outline)),
                ],
              ),
            ),
          ),
        ),
        drawer: largo ? null : Drawer(child: SafeArea(child: _palette())),
        endDrawer: largo ? null : Drawer(width: 360, child: SafeArea(child: _properties())),
        body: largo
            ? Row(
                children: [
                  SizedBox(width: 200, child: _palette()),
                  const VerticalDivider(width: 1),
                  Expanded(child: _artboard()),
                  const VerticalDivider(width: 1),
                  SizedBox(width: 340, child: _properties()),
                ],
              )
            : _artboard(),
      ),
    );
  }
}

// ---------- panels ----------

class _Field extends StatelessWidget {
  const _Field(this.label, this.value, this.aoMudar, {this.linhas = 1, this.number = false});

  final String label, value;
  final ValueChanged<String> aoMudar;
  final int linhas;
  final bool number;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: TextFormField(
      initialValue: value,
      minLines: linhas == 1 ? 1 : 3,
      maxLines: linhas,
      keyboardType: number ? TextInputType.number : null,
      style: linhas > 1 ? const TextStyle(fontFamily: 'monospace', fontSize: 12) : null,
      decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder()),
      onChanged: aoMudar,
    ),
  );
}

Widget _choice<T>(String label, T value, List<T> options, String Function(T) name, ValueChanged<T> aoMudar) => Padding(
  padding: const EdgeInsets.only(bottom: 8),
  child: DropdownButtonFormField<T>(
    initialValue: options.contains(value) ? value : null,
    isDense: true,
    decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
    items: [for (final o in options) DropdownMenuItem(value: o, child: Text(name(o)))],
    onChanged: (v) => v == null ? null : aoMudar(v),
  ),
);

/// Component properties: position, state, note and the catalog props (lists as JSON).
class _ComponentPanel extends StatefulWidget {
  const _ComponentPanel({super.key, required this.c, required this.aoMudar, required this.onDelete, required this.onDuplicate, required this.onReorder});

  final WfComponent c;
  final void Function(VoidCallback) aoMudar;
  final VoidCallback onDelete, onDuplicate;
  final ValueChanged<bool> onReorder;

  @override
  State<_ComponentPanel> createState() => _ComponentPanelState();
}

class _ComponentPanelState extends State<_ComponentPanel> {
  final Map<String, String> _errors = {};

  WfComponent get c => widget.c;

  void _number(String v, Rect Function(double) box) {
    final n = double.tryParse(v.replaceAll(',', '.'));
    if (n != null) widget.aoMudar(() => c.box = box(n));
  }

  Widget _prop(String k, Object? v) {
    if (v is bool) {
      return SwitchListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text(k), value: v, onChanged: (b) => widget.aoMudar(() => c.props[k] = b));
    }
    if (propOptions[k] case final options?) {
      return _choice<String>(k, '$v', options, (o) => o, (o) => widget.aoMudar(() => c.props[k] = o));
    }
    if (v is List || v is Map || (k == 'destaque' && v == null)) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextFormField(
          initialValue: const JsonEncoder.withIndent('  ').convert(v),
          minLines: 3,
          maxLines: 14,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: InputDecoration(labelText: '$k (JSON)', isDense: true, border: const OutlineInputBorder(), errorText: _errors[k]),
          onChanged: (s) {
            try {
              final isNew = jsonDecode(s);
              setState(() => _errors.remove(k));
              widget.aoMudar(() => c.props[k] = isNew);
            } on FormatException catch (e) {
              setState(() => _errors[k] = e.message);
            }
          },
        ),
      );
    }
    if (v is num) {
      return _Field(k, '$v', number: true, (s) {
        final n = num.tryParse(s.replaceAll(',', '.'));
        if (n != null) widget.aoMudar(() => c.props[k] = n);
      });
    }
    return _Field(k, '${v ?? ''}', (s) => widget.aoMudar(() => c.props[k] = s));
  }

  @override
  Widget build(BuildContext context) {
    // The catalog keys show up even if the AI did not send them; the extra ones too.
    final props = {...?catalog[c.type]?.$3.map((k, v) => MapEntry(k, c.props.containsKey(k) ? c.props[k] : v)), ...c.props}..remove('nota');
    final r = c.box;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            Expanded(child: Text('${catalog[c.type]?.$1 ?? c.type} · ${c.id}', style: Theme.of(context).textTheme.titleSmall)),
            IconButton(tooltip: 'Trazer para frente', onPressed: () => widget.onReorder(true), icon: const Icon(Icons.flip_to_front, size: 20)),
            IconButton(tooltip: 'Mandar para trás', onPressed: () => widget.onReorder(false), icon: const Icon(Icons.flip_to_back, size: 20)),
            IconButton(tooltip: 'Duplicar (Ctrl+D)', onPressed: widget.onDuplicate, icon: const Icon(Icons.copy, size: 20)),
            IconButton(tooltip: 'Excluir (Delete)', onPressed: widget.onDelete, icon: const Icon(Icons.delete_outline, size: 20)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          spacing: 8,
          children: [
            Expanded(child: _Field('x', '${r.left.round()}', number: true, (v) => _number(v, (n) => Rect.fromLTWH(n, c.box.top, c.box.width, c.box.height)))),
            Expanded(child: _Field('y', '${r.top.round()}', number: true, (v) => _number(v, (n) => Rect.fromLTWH(c.box.left, n, c.box.width, c.box.height)))),
            Expanded(child: _Field('largura', '${r.width.round()}', number: true, (v) => _number(v, (n) => Rect.fromLTWH(c.box.left, c.box.top, n, c.box.height)))),
            Expanded(child: _Field('altura', '${r.height.round()}', number: true, (v) => _number(v, (n) => Rect.fromLTWH(c.box.left, c.box.top, c.box.width, n)))),
          ],
        ),
        _choice<WfState>('estado', c.state, WfState.values, (e) => e.label, (e) => widget.aoMudar(() => c.state = e)),
        _Field('nota (nº do painel; vazio = sem marcador)', '${c.nota ?? ''}', number: true, (s) {
          final n = int.tryParse(s);
          widget.aoMudar(() => n == null ? c.props.remove('nota') : c.props['nota'] = n);
        }),
        const Divider(),
        for (final MapEntry(:key, :value) in props.entries) _prop(key, value),
      ],
    );
  }
}

/// No selection: screen data (code, title, breadcrumb, size) and the side panel notes.
class _ScreenPanel extends StatelessWidget {
  const _ScreenPanel({super.key, required this.screen, required this.aoMudar});

  final WfScreen screen;
  final void Function(VoidCallback) aoMudar;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(12),
    children: [
      Text('Tela', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      _Field('código', screen.code, (v) => aoMudar(() => screen.code = v)),
      _Field('título', screen.name, (v) => aoMudar(() => screen.name = v)),
      _Field('subtítulo', screen.subtitle, (v) => aoMudar(() => screen.subtitle = v)),
      _Field('caminho (separado por ›)', screen.path.join(' › '), (v) => aoMudar(() => screen.path = [for (final p in v.split('›')) if (p.trim().isNotEmpty) p.trim()])),
      Row(
        spacing: 8,
        children: [
          Expanded(child: _Field('largura', '${screen.width.round()}', number: true, (v) => aoMudar(() => screen.width = double.tryParse(v) ?? screen.width))),
          Expanded(child: _Field('altura', '${screen.height.round()}', number: true, (v) => aoMudar(() => screen.height = double.tryParse(v) ?? screen.height))),
        ],
      ),
      const Divider(),
      Row(
        children: [
          Expanded(child: Text('Notas (painel lateral)', style: Theme.of(context).textTheme.titleSmall)),
          IconButton(
            tooltip: 'Nova nota',
            icon: const Icon(Icons.add),
            onPressed: () => aoMudar(() => screen.notas.add(StickyNote(screen.notas.fold(0, (m, n) => math.max(m, n.n)) + 1, title: 'Nova nota'))),
          ),
        ],
      ),
      for (final n in screen.notas)
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                Row(
                  spacing: 8,
                  children: [
                    SizedBox(width: 56, child: _Field('nº', '${n.n}', number: true, (v) => aoMudar(() => n.n = int.tryParse(v) ?? n.n))),
                    Expanded(child: _choice<WfState>('estado', n.state, WfState.values, (e) => e.label, (e) => aoMudar(() => n.state = e))),
                    IconButton(tooltip: 'Excluir nota', onPressed: () => aoMudar(() => screen.notas.remove(n)), icon: const Icon(Icons.close, size: 18)),
                  ],
                ),
                _Field('título', n.title, (v) => aoMudar(() => n.title = v)),
                _Field('linhas ("Rótulo: texto" por linha)', n.textLines, linhas: 8, (v) => aoMudar(() => n.textLines = v)),
              ],
            ),
          ),
        ),
    ],
  );
}
