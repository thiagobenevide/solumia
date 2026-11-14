import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../electronics_api.dart';
import '../models.dart';
import '../screens/bom_screen.dart';
import '../screens/calculators_screen.dart';
import '../screens/simulation_screen.dart';
import 'editor.dart';
import 'export.dart';
import 'panels.dart';
import 'painting.dart';

/// Schematic CAD screen. Input for every device:
/// - mouse: left uses the tool (on empty space, with Select, opens the selection window); middle or right
///   drag the sheet; the wheel zooms; CAD shortcuts (see [_shortcuts]);
/// - pen: the tip uses the tool, hovering shows the preview; the side button drags;
/// - finger: a tap uses the tool, dragging on empty space moves the sheet, two fingers zoom.
class CadScreen extends StatefulWidget {
  const CadScreen({super.key, required this.api, required this.project, required this.library});

  final ElectronicsApi api;
  final Project project;
  final Library library;

  @override
  State<CadScreen> createState() => _CadScreenState();
}

enum _Gesture { none, move, window, pan, pinch, touch }

const _shortcuts = [
  ('V / Esc', 'Selecionar'),
  ('A', 'Componente (biblioteca)'),
  ('W', 'Fio — clique duas vezes no mesmo ponto ou num pino para terminar'),
  ('/', 'Inverter o canto do fio'),
  ('L', 'Rótulo de rede'),
  ('T', 'Texto'),
  ('P', 'Ponta de prova: na rede mede tensão, no componente mede corrente'),
  ('R / X', 'Girar 90° / espelhar'),
  ('E', 'Editar o selecionado'),
  ('Del', 'Excluir'),
  ('Ctrl+D', 'Duplicar'),
  ('Setas', 'Mover a seleção um passo'),
  ('Ctrl+Z / Ctrl+Y', 'Desfazer / refazer'),
  ('F', 'Enquadrar a folha'),
];

class _CadScreenState extends State<CadScreen> {
  late final Editor _editor = Editor(api: widget.api, project: widget.project, library: widget.library)
    ..addListener(_onChanged);
  final Camera _camera = Camera();
  final FocusNode _focus = FocusNode(debugLabel: 'cad');
  final FocusNode _searchFocus = FocusNode(debugLabel: 'busca');
  final Map<int, Offset> _toques = {};
  Size _size = Size.zero;
  bool _framed = false;

  _Gesture _gesture = _Gesture.none;
  int? _pointer;
  Offset _screenStart = Offset.zero;
  Offset _worldStart = Offset.zero;
  P _last = const P(0, 0);
  Rect? _window;
  bool _conflictShown = false;
  double _pinchDistance = 0, _trackpadScale = 1;

  @override
  void dispose() {
    _editor
      ..removeListener(_onChanged)
      ..dispose();
    _focus.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (_editor.conflict && !_conflictShown) {
      _conflictShown = true;
      setState(() {});
    } else if (!_editor.conflict) {
      _conflictShown = false;
    }
  }

  double get _tolerance => 8 / _camera.scale;

  bool get _sum => HardwareKeyboard.instance.isShiftPressed || HardwareKeyboard.instance.isControlPressed;

  void _frame() => setState(() => _camera.frame(sheetBounds(_editor), _size));

  // ---------- Ponteiros ----------

  void _downloaded(PointerDownEvent e) {
    _focus.requestFocus();
    final world = _camera.toWorld(e.localPosition);
    final snap = snapToGrid(world, _editor.step);
    if (e.kind == PointerDeviceKind.touch) {
      _toques[e.pointer] = e.localPosition;
      if (_toques.length == 2) {
        if (_gesture == _Gesture.move) _editor.endBatch();
        final [a, b] = _toques.values.toList();
        _pinchDistance = (a - b).distance;
        _gesture = _Gesture.pinch;
        _window = null;
        return;
      }
      if (_toques.length > 2) return;
    }
    _pointer = e.pointer;
    _screenStart = e.localPosition;
    _worldStart = world;
    final pan = (e.kind == PointerDeviceKind.mouse && e.buttons & (kMiddleMouseButton | kSecondaryMouseButton) != 0) ||
        (e.kind == PointerDeviceKind.stylus && e.buttons & kPrimaryStylusButton != 0);
    if (pan) {
      _gesture = _Gesture.pan;
      return;
    }
    _editor.moverCursor(snap);
    if (_editor.tool == Tool.select) {
      final target = _editor.fix(world, _tolerance);
      if (target != null) {
        setState(() {
          if (_sum) {
            _editor.selection.contains(target.id) ? _editor.selection.remove(target.id) : _editor.selection.add(target.id);
          } else if (!_editor.selection.contains(target.id)) {
            _editor.selection
              ..clear()
              ..add(target.id);
          }
        });
        _editor.startBatch();
        _last = snap;
        _gesture = _Gesture.move;
        return;
      }
      if (e.kind == PointerDeviceKind.touch) {
        _gesture = _Gesture.touch;
        return;
      }
      _gesture = _Gesture.window;
      _window = Rect.fromPoints(world, world);
      return;
    }
    // Finger: the tool acts on release without dragging (dragging moves the sheet).
    if (e.kind == PointerDeviceKind.touch) {
      _gesture = _Gesture.touch;
      return;
    }
    _useTool(snap);
  }

  void _moved(PointerMoveEvent e) {
    if (e.kind == PointerDeviceKind.touch && _toques.containsKey(e.pointer)) {
      final antes = _toques[e.pointer]!;
      _toques[e.pointer] = e.localPosition;
      if (_gesture == _Gesture.pinch && _toques.length == 2) {
        final [a, b] = _toques.values.toList();
        final dist = (a - b).distance;
        setState(() {
          _camera.offset += (e.localPosition - antes) / 2;
          if (_pinchDistance > 0) _camera.zoom(dist / _pinchDistance, (a + b) / 2);
        });
        _pinchDistance = dist;
        return;
      }
    }
    if (e.pointer != _pointer) return;
    final world = _camera.toWorld(e.localPosition);
    final snap = snapToGrid(world, _editor.step);
    switch (_gesture) {
      case _Gesture.pan:
        setState(() => _camera.offset += e.delta);
      case _Gesture.touch:
        if ((e.localPosition - _screenStart).distance > 10) _gesture = _Gesture.pan;
      case _Gesture.move:
        final d = snap - _last;
        if (d != const P(0, 0)) {
          _editor.changeLive(() => _editor.moveSelection(d));
          _last = snap;
        }
      case _Gesture.window:
        setState(() => _window = Rect.fromPoints(_worldStart, world));
      case _Gesture.none || _Gesture.pinch:
        break;
    }
    _editor.moverCursor(snap);
  }

  void _released(PointerEvent e) {
    if (e.kind == PointerDeviceKind.touch) {
      _toques.remove(e.pointer);
      if (_gesture == _Gesture.pinch) {
        if (_toques.isEmpty) _gesture = _Gesture.none;
        return;
      }
    }
    if (e.pointer != _pointer) return;
    final world = _camera.toWorld(e.localPosition);
    switch (_gesture) {
      case _Gesture.move:
        _editor.endBatch();
      case _Gesture.window:
        final j = _window;
        if (j != null && (e.localPosition - _screenStart).distance > 4) {
          _editor.selectArea(j, sum: _sum);
        } else if (!_sum) {
          setState(_editor.selection.clear);
        }
      case _Gesture.touch:
        if (_editor.tool == Tool.select) {
          setState(_editor.selection.clear);
        } else if (e is PointerUpEvent) {
          _useTool(snapToGrid(world, _editor.step));
        }
      case _Gesture.pan:
        // A still right click ends the wire.
        if (e.kind == PointerDeviceKind.mouse && (e.localPosition - _screenStart).distance < 4 && _editor.wire != null) {
          _editor.finishWire();
        }
      case _Gesture.none || _Gesture.pinch:
        break;
    }
    if (e.kind == PointerDeviceKind.touch && _editor.tool == Tool.select) _editor.moverCursor(null);
    setState(() {
      _gesture = _Gesture.none;
      _window = null;
      _pointer = null;
    });
  }

  Future<void> _useTool(P p) async {
    switch (_editor.tool) {
      case Tool.component:
        _editor.placeComponent(p);
      case Tool.wire:
        final wire = _editor.wire;
        if (wire != null && wire.last == p) {
          _editor.finishWire();
        } else {
          _editor.wirePoint(p);
        }
      case Tool.label:
        final names = {for (final r in _editor.project.labels) r.name}.toList()..sort();
        final name = await askText(context, 'Nome da rede', suggestions: names);
        if (name != null && name.trim().isNotEmpty) _editor.placeLabel(p, name);
      case Tool.text:
        final text = await askText(context, 'Texto');
        if (text != null && text.trim().isNotEmpty) _editor.placeText(p, text);
      case Tool.probe:
        final warning = _editor.placeProbe(p, p.offset, _tolerance);
        if (warning != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(warning)));
      case Tool.select:
        break;
    }
  }

  void _scrolled(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      setState(() => _camera.zoom(exp(-e.scrollDelta.dy / 400), e.localPosition));
    }
  }

  void _trackpad(PointerPanZoomUpdateEvent e) {
    setState(() {
      _camera.offset += e.panDelta;
      _camera.zoom(e.scale / _trackpadScale, e.localPosition);
    });
    _trackpadScale = e.scale;
  }

  // ---------- Teclado ----------

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final ctrl = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final k = e.logicalKey;
    final step = _editor.step;
    P? arrow;
    if (k == LogicalKeyboardKey.arrowLeft) arrow = P(-step, 0);
    if (k == LogicalKeyboardKey.arrowRight) arrow = P(step, 0);
    if (k == LogicalKeyboardKey.arrowUp) arrow = P(0, -step);
    if (k == LogicalKeyboardKey.arrowDown) arrow = P(0, step);
    if (arrow != null && _editor.selection.isNotEmpty) {
      final d = arrow;
      _editor.change(() => _editor.moveSelection(d));
      return KeyEventResult.handled;
    }
    if (e is KeyRepeatEvent) return KeyEventResult.ignored;
    if (ctrl) {
      if (k == LogicalKeyboardKey.keyZ) shift ? _editor.redo() : _editor.undo();
      if (k == LogicalKeyboardKey.keyY) _editor.redo();
      if (k == LogicalKeyboardKey.keyD) _editor.duplicateSelection();
      if (k == LogicalKeyboardKey.keyS) _editor.save();
      if (k == LogicalKeyboardKey.keyA) _editor.selectArea(Rect.largest);
      return KeyEventResult.handled;
    }
    switch (k) {
      case LogicalKeyboardKey.escape:
        if (_editor.wire != null) {
          _editor.finishWire();
        } else if (_editor.tool != Tool.select) {
          _editor.pick(Tool.select);
        } else {
          setState(_editor.selection.clear);
        }
      case LogicalKeyboardKey.delete || LogicalKeyboardKey.backspace:
        _editor.deleteSelection();
      case LogicalKeyboardKey.keyV:
        _editor.pick(Tool.select);
      case LogicalKeyboardKey.keyA:
        _openLibrary();
      case LogicalKeyboardKey.keyW:
        _editor.pick(Tool.wire);
      case LogicalKeyboardKey.keyL:
        _editor.pick(Tool.label);
      case LogicalKeyboardKey.keyT:
        _editor.pick(Tool.text);
      case LogicalKeyboardKey.keyP:
        _editor.pick(Tool.probe);
      case LogicalKeyboardKey.keyR:
        _editor.rotate();
      case LogicalKeyboardKey.keyX:
        _editor.mirror();
      case LogicalKeyboardKey.keyE:
        _editSelected();
      case LogicalKeyboardKey.keyF:
        _frame();
      case LogicalKeyboardKey.slash:
        _editor.flipCorner();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  bool get _largo => MediaQuery.sizeOf(context).width >= 1100;

  void _openLibrary() {
    if (_largo) {
      _searchFocus.requestFocus();
    } else {
      Scaffold.of(_bodyContext!).openDrawer();
    }
  }

  BuildContext? _bodyContext;

  Future<void> _editSelected() async {
    final sel = _editor.selected;
    if (sel.length != 1) return;
    await editItem(context, _editor, sel.single);
    _focus.requestFocus();
  }

  Future<void> _export(ExportFormat f) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (await export(_editor, f)) messenger.showSnackBar(SnackBar(content: Text('Exportado em ${f.name.toUpperCase()}.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Não exportou: $e')));
    }
  }

  // ---------- Montagem ----------

  @override
  Widget build(BuildContext context) {
    final largo = _largo;
    final library = LibraryPanel(
      editor: _editor,
      focus: _searchFocus,
      onPick: () {
        if (!largo) Navigator.of(context).maybePop();
        _focus.requestFocus();
      },
    );
    final properties = PropertiesPanel(editor: _editor);
    final narrow = MediaQuery.sizeOf(context).width < 700;
    void calculators() => showCalculators(context);
    Future<void> bom() async {
      await _editor.save();
      if (context.mounted) await showBom(context, widget.api, widget.project);
    }

    void shortcuts() => showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Atalhos'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (t, d) in _shortcuts)
                  ListTile(dense: true, leading: SizedBox(width: 110, child: Text(t, style: const TextStyle(fontFamily: 'monospace'))), title: Text(d)),
              ],
            ),
          ),
        ),
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: ListenableBuilder(
          listenable: _editor,
          builder: (_, _) => Row(
            spacing: 12,
            children: [
              Flexible(child: Text(widget.project.title, overflow: TextOverflow.ellipsis)),
              _RecordingState(editor: _editor),
            ],
          ),
        ),
        actions: [
          ListenableBuilder(
            listenable: _editor,
            builder: (_, _) => Row(
              children: [
                IconButton(tooltip: 'Desfazer (Ctrl+Z)', onPressed: _editor.canUndo() ? _editor.undo : null, icon: const Icon(Icons.undo)),
                IconButton(tooltip: 'Refazer (Ctrl+Y)', onPressed: _editor.canRedo() ? _editor.redo : null, icon: const Icon(Icons.redo)),
              ],
            ),
          ),
          IconButton(tooltip: 'Enquadrar (F)', onPressed: _frame, icon: const Icon(Icons.fit_screen_outlined)),
          IconButton(
            tooltip: 'Simular (ngspice)',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SimulationScreen(
                  api: widget.api,
                  project: widget.project,
                  save: _editor.save,
                  onRead: _editor.readProbes,
                ),
              ),
            ),
            icon: const Icon(Icons.ssid_chart),
          ),
          if (!narrow) ...[
            IconButton(tooltip: 'Calculadoras', onPressed: calculators, icon: const Icon(Icons.calculate_outlined)),
            IconButton(tooltip: 'Lista de peças e ligações', onPressed: bom, icon: const Icon(Icons.list_alt_outlined)),
            PopupMenuButton<ExportFormat>(
              tooltip: 'Exportar a folha',
              icon: const Icon(Icons.ios_share),
              onSelected: _export,
              itemBuilder: (_) => const [
                PopupMenuItem(value: ExportFormat.pdf, child: Text('PDF (A4)')),
                PopupMenuItem(value: ExportFormat.png, child: Text('PNG')),
              ],
            ),
            IconButton(tooltip: 'Atalhos', onPressed: shortcuts, icon: const Icon(Icons.keyboard_outlined)),
          ] else
            // On the phone the secondary actions go to the "more" menu, otherwise the AppBar overflows.
            PopupMenuButton<VoidCallback>(
              tooltip: 'Mais',
              onSelected: (action) => action(),
              itemBuilder: (_) => [
                PopupMenuItem(value: calculators, child: const ListTile(leading: Icon(Icons.calculate_outlined), title: Text('Calculadoras'))),
                PopupMenuItem(value: bom, child: const ListTile(leading: Icon(Icons.list_alt_outlined), title: Text('Lista de peças e ligações'))),
                PopupMenuItem(value: () => _export(ExportFormat.pdf), child: const ListTile(leading: Icon(Icons.picture_as_pdf_outlined), title: Text('Exportar PDF (A4)'))),
                PopupMenuItem(value: () => _export(ExportFormat.png), child: const ListTile(leading: Icon(Icons.image_outlined), title: Text('Exportar PNG'))),
                PopupMenuItem(value: shortcuts, child: const ListTile(leading: Icon(Icons.keyboard_outlined), title: Text('Atalhos'))),
              ],
            ),
          if (!largo)
            Builder(
              builder: (c) => IconButton(tooltip: 'Propriedades', onPressed: () => Scaffold.of(c).openEndDrawer(), icon: const Icon(Icons.tune)),
            ),
        ],
      ),
      drawer: largo ? null : Drawer(width: 300, child: SafeArea(child: library)),
      endDrawer: largo ? null : Drawer(width: 300, child: SafeArea(child: properties)),
      body: Builder(
        builder: (body) {
          _bodyContext = body;
          return Row(
            children: [
              if (largo) SizedBox(width: 280, child: library),
              if (largo) const VerticalDivider(width: 1),
              Expanded(
                child: Column(
                  children: [
                    Toolbar(editor: _editor, onLibrary: _openLibrary),
                    if (_editor.conflict)
                      MaterialBanner(
                        content: const Text('Este projeto mudou em outro aparelho.'),
                        actions: [
                          TextButton(onPressed: () => _editor.reload().then((_) => setState(() {})), child: const Text('Recarregar')),
                          TextButton(onPressed: () => _editor.save(onTop: true).then((_) => setState(() {})), child: const Text('Manter o meu')),
                        ],
                      ),
                    Expanded(child: _screen()),
                    SheetBar(editor: _editor, camera: _camera),
                  ],
                ),
              ),
              if (largo) const VerticalDivider(width: 1),
              if (largo) SizedBox(width: 300, child: properties),
            ],
          );
        },
      ),
    );
  }

  Widget _screen() => Focus(
    focusNode: _focus,
    autofocus: true,
    onKeyEvent: _key,
    child: LayoutBuilder(
      builder: (context, c) {
        _size = c.biggest;
        if (!_framed) {
          _framed = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => _frame());
        }
        return MouseRegion(
          cursor: _editor.tool == Tool.select ? SystemMouseCursors.basic : SystemMouseCursors.precise,
          onExit: (_) => _editor.moverCursor(null),
          child: Listener(
            onPointerDown: _downloaded,
            onPointerMove: _moved,
            onPointerUp: _released,
            onPointerCancel: _released,
            onPointerHover: (e) => _editor.moverCursor(snapToGrid(_camera.toWorld(e.localPosition), _editor.step)),
            onPointerSignal: _scrolled,
            onPointerPanZoomStart: (_) => _trackpadScale = 1,
            onPointerPanZoomUpdate: _trackpad,
            child: GestureDetector(
              onDoubleTap: _editor.tool == Tool.select ? _editSelected : null,
              child: CustomPaint(
                size: Size.infinite,
                painter: CadPainter(_editor, _camera, window: _window, palette: Palette.dark),
              ),
            ),
          ),
        );
      },
    ),
  );
}

class _RecordingState extends StatelessWidget {
  const _RecordingState({required this.editor});

  final Editor editor;

  @override
  Widget build(BuildContext context) {
    final estilo = Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.outline);
    final (icone, text) = editor.conflict
        ? (Icons.sync_problem, 'conflito')
        : editor.error != null
        ? (Icons.cloud_off, 'sem conexão — tenta de novo')
        : editor.saving || editor.pending
        ? (Icons.cloud_upload_outlined, 'gravando…')
        : (Icons.cloud_done_outlined, 'gravado');
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [Icon(icone, size: 16, color: estilo?.color), Text(text, style: estilo)],
    );
  }
}
