import 'dart:async';
import 'dart:math';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/gestures.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../design_api.dart';
import '../cache.dart';
import '../models.dart';
import 'editor.dart';
import 'input.dart';
import 'toolbox.dart';
import 'pen_menu.dart';
import 'export.dart';
import 'flow.dart';
import 'images.dart';
import 'panels.dart';
import 'painting.dart';
import 'table.dart';

/// Opens board [id]: loads it and shows the [BoardScreen].
class OpenBoard extends StatelessWidget {
  const OpenBoard({super.key, required this.api, required this.cache, required this.id});

  final ApiDesign api;
  final BoardCache cache;
  final String id;

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: BoardEditor.open(api, cache, id),
    builder: (context, s) {
      if (s.hasData) return BoardScreen(editor: s.data!);
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: s.hasError ? Text('Não abriu o quadro: ${s.error}') : const CircularProgressIndicator()),
      );
    },
  );
}

class BoardScreen extends StatefulWidget {
  const BoardScreen({super.key, required this.editor, this.actions = const []});

  final BoardEditor editor;

  /// Extra buttons on the top bar (the notebook adds paper, smart pen and references).
  final List<Widget> actions;

  @override
  State<BoardScreen> createState() => _BoardScreenState();
}

enum _SelectionMode { lasso, move, resize }

class _Signal extends ChangeNotifier {
  void avisar() => notifyListeners();
}

class _BoardScreenState extends State<BoardScreen> with SingleTickerProviderStateMixin {
  BoardEditor get _editor => widget.editor;
  final _toolbox = Estojo();
  // Clicking the pen button while hovering opens the radial menu where the pen is.
  final _penClick = ButtonClick();
  Offset? _penMenu;
  final _camera = Camera();
  final _cameraChanged = _Signal();
  final _live = _Signal();
  late final Ticker _clock = createTicker((_) => _animateLaser());
  Size _screen = Size.zero;
  bool _projection = false;
  // PC: visible side panels (buttons on the top bar hide each one).
  bool _showShapes = true, _showStyle = true;
  // Side panel for Google Images search (over the board, at any width).
  bool _showImages = false;
  bool _dark = false;
  bool _framed = false;
  // Toolbar: the board side where it sits, hidden or not (stored on the device) and the
  // offset of the drag in progress (on release, it snaps to the nearest side).
  _Side _barSide = _Side.baixo;
  bool _barHidden = false;
  Offset _barDrag = Offset.zero;
  final _barAreaKey = GlobalKey(), _barKey = GlobalKey();
  static const _prefSide = 'design.barra.lado', _prefHidden = 'design.barra.oculta';

  // Pointers that move/zoom (screen position) and the center/span of the last frame.
  final Map<int, Offset> _panning = {};
  Offset? _lastCenter;
  double? _lastOpened;
  double? _trackpadScale;

  // Pointer that draws/erases right now.
  int? _pointer;
  PointerDeviceKind? _type;
  Tool? _emUso;
  Offset _start = Offset.zero;
  List<StrokePoint> _points = [];
  Elemento? _liveElement;
  final List<(Offset, DateTime)> _laser = [];
  (Offset, double)? _ring;

  // Selection: chosen ids, lasso in progress and the live drag (move/resize).
  Set<String> _selectedItems = {};
  _SelectionMode? _mode;
  List<Offset> _lasso = [];
  Offset _anchor = Offset.zero;
  Map<String, Elemento> _originals = {};
  List<Elemento> _dragged = [];
  Set<String> _hidden = const {};

  /// Block or loose text being typed directly on the board (new text is not in the editor yet).
  /// Its text leaves the painting while the field stays on top, at the same place and font.
  Elemento? _typing;
  final _textField = TextEditingController();
  final _textFocus = FocusNode();
  final _boardFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    unawaited(
      SharedPreferences.getInstance().then((p) {
        if (!mounted) return;
        setState(() {
          _barSide = _Side.values.asNameMap()[p.getString(_prefSide)] ?? _Side.baixo;
          _barHidden = p.getBool(_prefHidden) ?? false;
        });
      }),
    );
  }

  @override
  void dispose() {
    _textField.dispose();
    _textFocus.dispose();
    _boardFocus.dispose();
    _editor.save();
    _editor.dispose();
    _toolbox.dispose();
    _clock.dispose();
    if (_projection) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // ---------- camera ----------

  void _moverCamera(void Function() changeEntry) {
    changeEntry();
    _cameraChanged.avisar();
  }

  void _frame() => _moverCamera(() => _camera.frame(_editor.bounds, _screen));

  void _zoomCenter(double factor) => _moverCamera(() => _camera.zoom(factor, _screen.center(Offset.zero)));

  void _pan() {
    if (_panning.isEmpty) return;
    final pontos = _panning.values;
    final center = pontos.reduce((a, b) => a + b) / pontos.length.toDouble();
    final opening = pontos.map((p) => (p - center).distance).reduce((a, b) => a + b) / pontos.length;
    _moverCamera(() {
      if (_lastCenter != null) _camera.offset += center - _lastCenter!;
      if (pontos.length > 1 && (_lastOpened ?? 0) > 0) _camera.zoom(opening / _lastOpened!, center);
    });
    _lastCenter = center;
    _lastOpened = opening;
  }

  // A finger came in or left: restarts the measurement so the camera does not jump.
  void _resetPan() {
    _lastCenter = null;
    _lastOpened = null;
    _pan();
  }

  // ---------- ponteiros ----------

  void _tap(PointerDownEvent e) {
    _penClick.cancel();
    if (isPen(e.kind)) _toolbox.penSeen();
    // A second finger while one finger draws: it was a pinch, not a stroke.
    if (e.kind == PointerDeviceKind.touch && _type == PointerDeviceKind.touch && _pointer != null) {
      final firstItem = _pointer!, last = _camera.toScreen(_points.last.offset);
      _cancel();
      _panning[firstItem] = last;
    }
    final gesture = classify(
      type: e.kind,
      buttons: e.buttons,
      tool: _toolbox.tool,
      fingerDraws: _toolbox.fingerDraws && _panning.isEmpty,
      space: HardwareKeyboard.instance.isLogicalKeyPressed(LogicalKeyboardKey.space),
    );
    if (gesture == Gesture.pan) {
      _panning[e.pointer] = e.localPosition;
      _resetPan();
      return;
    }
    if (_pointer != null) return;
    _pointer = e.pointer;
    _type = e.kind;
    _emUso = gesture == Gesture.erase ? Tool.eraser : _toolbox.tool;
    // Ctrl+mouse click selects with any tool.
    if (_emUso != Tool.eraser && e.kind == PointerDeviceKind.mouse && _ctrl) {
      _toolbox.tool = Tool.selection;
      _emUso = Tool.selection;
    }
    _start = _camera.toWorld(e.localPosition);
    _points = [StrokePoint(_start.dx, _start.dy, pressure(e))];
    if (gesture == Gesture.erase) {
      _editor.startGesture();
      _erase(_start);
      return;
    }
    switch (_emUso!) {
      case Tool.selection:
        _startSelection(e.localPosition);
      case Tool.laser:
        _laser.add((_start, DateTime.now()));
        if (!_clock.isActive) _clock.start();
      case Tool.caneta || Tool.marcador:
        _liveElement = _stroke();
      default:
        break;
    }
    _live.avisar();
  }

  void _mover(PointerMoveEvent e) {
    if (_panning.containsKey(e.pointer)) {
      _panning[e.pointer] = e.localPosition;
      _pan();
      return;
    }
    if (e.pointer != _pointer) return;
    final p = _camera.toWorld(e.localPosition);
    switch (_emUso) {
      case Tool.eraser:
        _erase(p);
      case Tool.selection:
        _dragSelection(p);
      case Tool.laser:
        _laser.add((p, DateTime.now()));
      case Tool.caneta || Tool.marcador:
        // Points less than ~1.5 px apart on screen do not change the drawing and only weigh on the JSON.
        if ((p - _points.last.offset).distance * _camera.scale < 1.5) return;
        _points.add(StrokePoint(p.dx, p.dy, pressure(e)));
        _liveElement = _stroke();
      case final f? when f.shape != null:
        _liveElement = _shape(f.shape!, p);
      default:
        break;
    }
    _live.avisar();
  }

  void _drop(PointerEvent e) {
    if (_panning.remove(e.pointer) != null) {
      _resetPan();
      return;
    }
    if (e.pointer != _pointer) return;
    final fim = _camera.toWorld(e.localPosition);
    if (_emUso == Tool.eraser) {
      _editor.endGesture();
    } else if (_emUso == Tool.selection) {
      _dropSelection(fim);
    } else if (_emUso == Tool.text && (fim - _start).distance * _camera.scale < 8) {
      _writeText(_start);
    } else if (_liveElement != null) {
      _editor.adicionar(_liveElement!);
    }
    _clearGesture();
  }

  void _cancel() {
    if (_emUso == Tool.eraser) _editor.endGesture();
    if (_emUso == Tool.selection) _dragEnd();
    _clearGesture();
  }

  void _clearGesture() {
    _pointer = null;
    _type = null;
    _emUso = null;
    _liveElement = null;
    _points = [];
    _live.avisar();
  }

  void _hover(PointerHoverEvent e) {
    if (_penClick.hover(e) case final p? when !_projection) {
      _toolbox.penSeen();
      setState(() => _penMenu = p);
    }
    final erasing = _toolbox.tool == Tool.eraser || e.kind == PointerDeviceKind.invertedStylus;
    final ring = erasing ? (_camera.toWorld(e.localPosition), _eraserRadius) : null;
    if (ring == null && _ring == null) return;
    _ring = ring;
    _live.avisar();
  }

  void _scroll(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      final keyboard = HardwareKeyboard.instance;
      if (keyboard.isControlPressed || keyboard.isMetaPressed) {
        _moverCamera(() => _camera.zoom(pow(0.998, e.scrollDelta.dy).toDouble(), e.localPosition));
      } else {
        final d = keyboard.isShiftPressed ? Offset(e.scrollDelta.dy, 0) : e.scrollDelta;
        _moverCamera(() => _camera.offset -= d);
      }
    } else if (e is PointerScaleEvent) {
      _moverCamera(() => _camera.zoom(e.scale, e.localPosition));
    }
  }

  // Laptop trackpad: two fingers move, pinch zooms.
  void _trackpad(PointerPanZoomUpdateEvent e) {
    final anterior = _trackpadScale ?? 1;
    _trackpadScale = e.scale;
    _moverCamera(() {
      _camera.offset += e.panDelta;
      _camera.zoom(e.scale / anterior, e.localPosition);
    });
  }

  // ---------- ferramentas ----------

  static final _random = Random();

  /// Ctrl+C/Ctrl+V clipboard (static: copies from one board and pastes into another).
  static List<Elemento> _copied = const [];
  static int _pastes = 0;
  String _newId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36) + _random.nextInt(1 << 30).toRadixString(36);

  // The live stroke id only counts when it enters the editor; until then it is disposable.
  Traco _stroke() => Traco(
    _liveElement?.id ?? _newId(),
    brush: _emUso == Tool.marcador ? Pincel.marcador : Pincel.caneta,
    color: _toolbox.colorOf(_emUso!),
    thickness: _toolbox.thicknessOf(_emUso!),
    pontos: List.unmodifiable(_points),
  );

  /// Shift locks the line/arrow at 45° and turns rectangle/ellipse into square/circle.
  Forma _shape(ShapeKind type, Offset fim) {
    var b = fim;
    if (HardwareKeyboard.instance.isShiftPressed) {
      final d = fim - _start;
      if (type == ShapeKind.reta || type == ShapeKind.seta) {
        final angle = (d.direction / (pi / 4)).round() * (pi / 4);
        b = _start + Offset.fromDirection(angle, d.distance);
      } else {
        final side = max(d.dx.abs(), d.dy.abs());
        b = _start + Offset(side * d.dx.sign, side * d.dy.sign);
      }
    }
    return Forma(
      _liveElement?.id ?? _newId(),
      shape: type,
      a: _start,
      b: b,
      color: _toolbox.colorOf(_emUso!),
      thickness: _toolbox.thicknessOf(_emUso!),
    );
  }

  double get _eraserRadius => _toolbox.thicknessOf(Tool.eraser) / _camera.scale;

  void _erase(Offset p) {
    final radius = _eraserRadius;
    _ring = (p, radius);
    _editor.remover({
      for (final e in _editor.elements)
        if (e.touches(p, radius)) e.id,
    }, store: false);
    _live.avisar();
  }

  // ---------- selection ----------

  Rect? get _box {
    if (_toolbox.tool != Tool.selection || _selectedItems.isEmpty) return null;
    if (_dragged.isNotEmpty) return boundsOf(_dragged.where((e) => _selectedItems.contains(e.id)));
    return boundsOf(_editor.elements.where((e) => _selectedItems.contains(e.id)));
  }

  List<Elemento> get _selectedElements => [
    for (final e in _editor.elements)
      if (_selectedItems.contains(e.id)) e,
  ];

  static bool get _ctrl => HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;

  /// [ids] plus the other elements of their groups (a group is selected whole).
  Set<String> _withGroups(Set<String> ids) {
    final groups = {
      for (final e in _editor.elements)
        if (e.group.isNotEmpty && ids.contains(e.id)) e.group,
    };
    if (groups.isEmpty) return ids;
    return {
      ...ids,
      for (final e in _editor.elements)
        if (groups.contains(e.group)) e.id,
    };
  }

  /// The topmost element under [p] (blocks and figures take precedence over the arrows passing over them).
  Elemento? _tappedAt(Offset p) {
    final radius = 8 / _camera.scale;
    final sob = _editor.elements.reversed.where((e) => e.touches(p, radius));
    return sob.where((e) => e is! Connector).firstOrNull ?? sob.firstOrNull;
  }

  /// Lasso with Ctrl adds to the existing selection.
  bool _adding = false;

  /// Box corner → resizes from the opposite corner; inside the box → moves; on top of an
  /// element → selects and drags right away; on empty space → new lasso. With Ctrl: the touched element joins
  /// the selection (or leaves, if it was already in) and the lasso adds.
  void _startSelection(Offset screen) {
    final box = _box;
    _tappedSelected = false;
    _adding = _ctrl;
    if (_adding) {
      final touched = _tappedAt(_start);
      if (touched != null) {
        final ids = _withGroups({touched.id});
        _selectedItems = _selectedItems.contains(touched.id) ? _selectedItems.difference(ids) : {..._selectedItems, ...ids};
        if (_selectedItems.isEmpty) {
          setState(() {});
          return;
        }
        _mode = _SelectionMode.move;
      }
    } else if (box != null) {
      final onScreen = Rect.fromPoints(_camera.toScreen(box.topLeft), _camera.toScreen(box.bottomRight));
      final i = cantos(onScreen).indexWhere((c) => (c - screen).distance < 18);
      if (i >= 0) {
        _anchor = cantos(box)[(i + 2) % 4];
        _mode = _SelectionMode.resize;
      } else if (onScreen.inflate(8).contains(screen)) {
        _mode = _SelectionMode.move;
        _tappedSelected = true;
      }
    }
    if (_mode == null && !_adding) {
      final touched = _tappedAt(_start);
      if (touched != null) {
        _selectedItems = _withGroups({touched.id});
        _mode = _SelectionMode.move;
      }
    }
    if (_mode == null) {
      _mode = _SelectionMode.lasso;
      _lasso = [_start];
      if (!_adding) setState(() => _selectedItems = {});
      return;
    }
    _originals = {for (final e in _selectedElements) e.id: e};
    if (_mode == _SelectionMode.move) {
      // A container takes along what is inside it (like the draw.io lane).
      for (final c in [..._originals.values.whereType<FlowNode>().where((n) => n.type == NodeKind.container)]) {
        for (final e in inside(c, _editor.elements)) {
          _originals.putIfAbsent(e.id, () => e);
        }
      }
    }
    _dragged = _withArrows([..._originals.values]);
    setState(() => _hidden = {for (final e in _dragged) e.id});
  }

  /// Tap without dragging on an element that was already selected: edits its text.
  bool _tappedSelected = false;

  /// [movedItems] plus the arrows connected to the moved blocks, already with the tips at the new positions (so
  /// the arrows follow the drag live).
  List<Elemento> _withArrows(List<Elemento> movedItems) {
    final blocks = {
      for (final e in movedItems)
        if (e is FlowNode) e.id,
    };
    if (blocks.isEmpty) return movedItems;
    final swapped = {for (final e in movedItems) e.id: e};
    final arrows = reconnect([for (final e in _editor.elements) swapped[e.id] ?? e], blocksOnly: blocks)
        .whereType<Connector>()
        .where((l) => !swapped.containsKey(l.id) && (blocks.contains(l.de) || blocks.contains(l.to)));
    return [...movedItems, ...arrows];
  }

  void _dragSelection(Offset p) {
    switch (_mode) {
      case _SelectionMode.lasso:
        _lasso.add(p);
      case _SelectionMode.move:
        final d = p - _start;
        _dragged = _withArrows([for (final e in _originals.values) e.transform((q) => q + d)]);
      case _SelectionMode.resize:
        final single = _originals.length == 1 ? _originals.values.first : null;
        if (single is FlowNode) {
          // Single block: free width and height, with a minimum readable size.
          final r = Rect.fromPoints(_anchor, p);
          final w = max(48.0, r.width), h = max(32.0, r.height);
          final canto = Offset(
            p.dx < _anchor.dx ? _anchor.dx - w : _anchor.dx,
            p.dy < _anchor.dy ? _anchor.dy - h : _anchor.dy,
          );
          _dragged = _withArrows([single.withRect(canto & Size(w, h))]);
          return;
        }
        final antes = (_start - _anchor).distance;
        if (antes < 1) return;
        final factor = max(0.05, (p - _anchor).distance / antes);
        _dragged = _withArrows([
          for (final e in _originals.values) e.transform((q) => _anchor + (q - _anchor) * factor, factor: factor),
        ]);
      case null:
        break;
    }
  }

  void _dropSelection(Offset fim) {
    if (_mode == _SelectionMode.lasso) {
      var chosen = {
        for (final e in _editor.elements)
          if (e.insideLasso(_lasso)) e.id,
      };
      // Tap without lasso: grabs the topmost element under the finger/cursor.
      if (chosen.isEmpty && (fim - _start).distance * _camera.scale < 8) {
        final touched = _editor.elements.reversed.where((e) => e.touches(fim, 8 / _camera.scale)).firstOrNull;
        chosen = {?touched?.id};
      }
      chosen = _withGroups(chosen);
      setState(() => _selectedItems = _adding ? {..._selectedItems, ...chosen} : chosen);
    } else if (_dragged.isNotEmpty && (fim - _start).distance * _camera.scale >= 1) {
      _editor.replace({for (final e in _dragged) e.id: e});
    } else if (_tappedSelected && !_adding && _selectedItems.length == 1) {
      _dragEnd();
      _editSelectedText();
      return;
    }
    _dragEnd();
  }

  void _dragEnd() {
    _mode = null;
    _lasso = [];
    _dragged = [];
    _originals = {};
    setState(() => _hidden = const {});
  }

  void _selectAll() {
    _toolbox.tool = Tool.selection;
    setState(() => _selectedItems = {for (final e in _editor.elements) e.id});
  }

  void _deleteSelection() {
    _editor.remover(_selectedItems);
    setState(() => _selectedItems = {});
  }

  void _duplicateSelection() => _pasteElements(_selectedElements, Offset(24, 24) / _camera.scale);

  /// Ctrl+C: stores the selection (works across boards and pages while the app is open).
  void _copySelection() {
    if (_selectedItems.isEmpty) return;
    setState(() {
      _copied = _selectedElements;
      _pastes = 0;
    });
  }

  /// Ctrl+V: pastes what was copied, one step offset on each paste.
  void _paste() {
    if (_copied.isEmpty) return;
    _pastes++;
    _pasteElements(_copied, Offset(24, 24) * _pastes.toDouble() / _camera.scale);
  }

  void _pasteElements(List<Elemento> font, Offset d) {
    final newItems = {for (final e in font) e.id: _newId()};
    // The copy of a group becomes another group (it does not join the original).
    final groups = {
      for (final e in font)
        if (e.group.isNotEmpty) e.group: _newId(),
    };
    final copies = <Elemento>[
      for (final e in font)
        if (e is! Connector)
          e.transform((q) => q + d, id: newItems[e.id], group: groups[e.group])
        // The copy of the arrow connects the copies of the blocks; without both blocks copied, it does not come.
        else if (newItems.containsKey(e.de) && newItems.containsKey(e.to))
          e.withBlocks(newItems[e.de]!, newItems[e.to]!).transform((q) => q + d, id: newItems[e.id], group: groups[e.group]),
    ];
    _editor.addMany(copies);
    setState(() => _selectedItems = {for (final e in copies) e.id});
  }

  /// Ctrl+G: joins the selection into a single group (groups that were in it merge).
  void _group() {
    if (_selectedItems.length < 2) return;
    final g = _newId();
    _editor.replace({for (final e in _selectedElements) e.id: e.withGroup(g)});
    setState(() {});
  }

  /// Ctrl+Shift+G: undoes the groups of the selection (the elements stay selected).
  void _ungroup() {
    final inGroup = _selectedElements.where((e) => e.group.isNotEmpty);
    if (inGroup.isEmpty) return;
    _editor.replace({for (final e in inGroup) e.id: e.withGroup('')});
    setState(() {});
  }

  /// New 3 × 3 table in the center of the screen, already open to fill in.
  Future<void> _insertTable() async {
    final center = _camera.toWorld((context.size ?? const Size(800, 600)).center(Offset.zero));
    final base = BoardTable.nova(_newId(), center, 3, 3);
    final t = base.copy(origin: center - Offset(base.retangulo.width / 2, base.retangulo.height / 2));
    _editor.adicionar(t);
    setState(() {
      _toolbox.tool = Tool.selection;
      _selectedItems = {t.id};
    });
    await _editSelectedText();
  }

  /// Copies the image chosen on Google to the server and puts it at [at] (world) or in the center of the screen
  /// (larger side up to 320).
  Future<void> _insertImage(Map<String, dynamic> r, {Offset? em}) async {
    final id = await _editor.api.storeImage(r['url'] as String);
    if (!mounted) return;
    final w = (r['largura'] as num? ?? 0).toDouble(), h = (r['altura'] as num? ?? 0).toDouble();
    final scale = w > 0 && h > 0 ? 320 / max(w, h) : 1.0;
    final size = w > 0 && h > 0 ? Size(w * scale, h * scale) : const Size(240, 240);
    final center = em ?? _camera.toWorld(_screen.center(Offset.zero));
    final e = BoardImage(
      _newId(),
      a: center - Offset(size.width / 2, size.height / 2),
      b: center + Offset(size.width / 2, size.height / 2),
      image: id,
      title: '${r['titulo'] ?? ''}',
    );
    _editor.adicionar(e);
    setState(() {
      _toolbox.tool = Tool.selection;
      _selectedItems = {e.id};
    });
  }

  /// Layers: 2 = to the front of everything, 1 = one forward, -1 = one back, -2 = behind everything.
  void _moveLayer(int step) {
    if (_selectedItems.isEmpty) return;
    final ids = [for (final e in _editor.elements) e.id];
    final sel = _selectedItems;
    switch (step) {
      case 2:
        _editor.reorder([...ids.where((i) => !sel.contains(i)), ...ids.where(sel.contains)]);
      case -2:
        _editor.reorder([...ids.where(sel.contains), ...ids.where((i) => !sel.contains(i))]);
      case 1:
        for (var i = ids.length - 2; i >= 0; i--) {
          if (sel.contains(ids[i]) && !sel.contains(ids[i + 1])) ids.insert(i + 1, ids.removeAt(i));
        }
        _editor.reorder(ids);
      case -1:
        for (var i = 1; i < ids.length; i++) {
          if (sel.contains(ids[i]) && !sel.contains(ids[i - 1])) ids.insert(i - 1, ids.removeAt(i));
        }
        _editor.reorder(ids);
    }
  }

  void _recolorSelection(Color color) =>
      _editor.replace({for (final e in _selectedElements) e.id: e.transform((q) => q, color: color)});

  /// Palette color: recolors the selection (Selection tool) or becomes the tool color.
  void _useColor(Color c) {
    if (_toolbox.tool == Tool.selection) {
      _toolbox.rememberColor(c);
      _recolorSelection(c);
    } else {
      _toolbox.color = c;
    }
  }

  Future<void> _moreColors() async {
    final c = await escolherCor(context, _toolbox.color, _toolbox.recent, paleta: quickColors);
    if (c != null) _useColor(c);
  }

  Future<void> _export(ExportFormat fileFormat, {bool selectionOnly = false}) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final saved = await export(
        _editor.title,
        selectionOnly ? _selectedElements : _editor.elements,
        _editor.background,
        fileFormat,
        dark: _dark,
      );
      if (saved) messenger.showSnackBar(SnackBar(content: Text('${fileFormat.name.toUpperCase()} exportado')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Não exportou: $e')));
    }
  }

  void _animateLaser() {
    final limit = DateTime.now().subtract(LivePainter.laserDuration);
    _laser.removeWhere((p) => p.$2.isBefore(limit));
    if (_laser.isEmpty && _emUso != Tool.laser) _clock.stop();
    _live.avisar();
  }

  void _writeText(Offset position) => _typeChar(
    BoardText(
      _newId(),
      position: position,
      text: '',
      color: _toolbox.colorOf(Tool.text),
      size: _toolbox.thicknessOf(Tool.text),
    ),
  );

  // ---------- typing on the board ----------

  void _typeChar(Elemento e) {
    _finishText();
    final text = switch (e) {
      FlowNode() => e.text,
      BoardText() => e.text,
      _ => '',
    };
    _textField.value = TextEditingValue(
      text: text,
      selection: TextSelection(baseOffset: 0, extentOffset: text.length),
    );
    setState(() => _typing = e);
    _textFocus.requestFocus();
  }

  /// Saves what was typed (Esc or tap outside). Uses the current version of the element so it does not undo
  /// a style changed in the panel during typing; empty loose text disappears.
  void _finishText() {
    final e = _typing;
    if (e == null) return;
    final current = _editor.elements.where((x) => x.id == e.id).firstOrNull;
    final t = _textField.text.trim();
    setState(() => _typing = null);
    _boardFocus.requestFocus();
    switch (current ?? e) {
      case FlowNode n when t != n.text:
        _editor.replace({n.id: n.withText(t)});
      case BoardText x when t.isEmpty:
        if (current != null) _editor.remover({x.id});
      case BoardText x when t != x.text:
        final isNew = BoardText(x.id, group: x.group, position: x.position, text: t, color: x.color, size: x.size);
        current == null ? _editor.adicionar(isNew) : _editor.replace({x.id: isNew});
      default:
    }
  }

  /// Wraps the selected excerpt of the field in the marks that `formattedText` draws.
  void _format(String mark) {
    final sel = _textField.selection;
    final t = _textField.text;
    final ini = sel.isValid ? sel.start : t.length, fim = sel.isValid ? sel.end : t.length;
    _textField.value = TextEditingValue(
      text: t.replaceRange(ini, fim, '$mark${t.substring(ini, fim)}$mark'),
      selection: TextSelection(baseOffset: ini + mark.length, extentOffset: fim + mark.length),
    );
    _textFocus.requestFocus();
  }

  /// Field over the element being typed, with the same area, font and alignment as the painting.
  Widget _boardField() => ListenableBuilder(
    listenable: Listenable.merge([_cameraChanged, _textField]),
    builder: (context, _) {
      final e = _editor.elements.where((x) => x.id == _typing!.id).firstOrNull ?? _typing!;
      final s = _camera.scale;
      Widget field(TextStyle estilo, TextAlign alignmentMode) => CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): _finishText},
        child: TextField(
          controller: _textField,
          focusNode: _textFocus,
          maxLines: null,
          style: estilo,
          textAlign: alignmentMode,
          cursorColor: estilo.color,
          decoration: const InputDecoration.collapsed(hintText: ''),
          onTapOutside: (_) => _finishText(),
        ),
      );
      switch (e) {
        case FlowNode n:
          final r = Rect.fromPoints(_camera.toScreen(n.retangulo.topLeft), _camera.toScreen(n.retangulo.bottomRight));
          final container = n.type == NodeKind.container;
          final estilo = TextStyle(
            color: ink(n.textColor ?? const Color(0xFF111111), _dark),
            fontSize: (container ? 14 : 15) * s,
            height: 1.2,
            fontWeight: container ? FontWeight.w600 : null,
          );
          if (container) {
            return Positioned(
              left: r.left + 8 * s,
              top: r.top,
              width: max(20, r.width - 16 * s),
              height: FlowNode.titleHeight * s,
              child: Align(alignment: Alignment.centerLeft, child: field(estilo, TextAlign.left)),
            );
          }
          final narrow = n.type == NodeKind.decisao || n.type == NodeKind.circulo || n.type == NodeKind.hexagono;
          final width = n.esquerda ? r.width - 16 * s : r.width * (narrow ? 0.62 : 0.82);
          final esquerda = n.type == NodeKind.nota || n.esquerda;
          return Positioned.fromRect(
            rect: Rect.fromCenter(center: r.center, width: max(20, width), height: r.height),
            child: Center(child: field(estilo, esquerda ? TextAlign.left : TextAlign.center)),
          );
        case BoardText t:
          final estilo = TextStyle(color: ink(t.color, _dark), fontSize: t.size * s, height: 1.25);
          final measure = TextPainter(
            text: TextSpan(text: _textField.text.isEmpty ? ' ' : _textField.text, style: estilo),
            textDirection: TextDirection.ltr,
          )..layout();
          final p = _camera.toScreen(t.position);
          return Positioned(
            left: p.dx,
            top: p.dy,
            width: max(40, measure.width + 4 * s),
            child: field(estilo, TextAlign.left),
          );
        default:
          return const SizedBox.shrink();
      }
    },
  );

  // ---------- fluxograma ----------

  /// Flow block inserted by hand in the center of the screen (or at [at], in the world, when dropped by dragging).
  void _insertBlock(NodeKind type, {Offset? em}) {
    final center = em ?? _camera.toWorld(_screen.center(Offset.zero));
    final size = switch (type) {
      NodeKind.decisao => const Size(200, 120),
      NodeKind.circulo => const Size(110, 110),
      NodeKind.quadrado => const Size(140, 140),
      NodeKind.banco => const Size(110, 100),
      NodeKind.nota => const Size(200, 110),
      NodeKind.container => const Size(420, 300),
      _ => const Size(190, 80),
    };
    final no = FlowNode(
      _newId(),
      type: type,
      text: type == NodeKind.inicio ? 'Início' : type.label,
      a: center - Offset(size.width / 2, size.height / 2),
      b: center + Offset(size.width / 2, size.height / 2),
      color: flowColors[type]!,
    );
    _editor.adicionar(no);
    setState(() {
      _toolbox.tool = Tool.selection;
      _selectedItems = {no.id};
    });
  }

  /// Arrow from the first selected block to the second, with an optional label ("Sim", "Não"…).
  Future<void> _connectSelected() async {
    final nos = _selectedElements.whereType<FlowNode>().toList();
    if (nos.length != 2) return;
    final label = await _ask('Rótulo da seta (opcional)', '');
    if (label == null) return;
    final l = Connector(
      _newId(),
      de: nos[0].id,
      to: nos[1].id,
      a: Offset.zero,
      b: Offset.zero,
      color: const Color(0xFF37474F),
      label: label.trim(),
      flow: nos[0].flow,
      orthogonal: true,
    );
    _editor.adicionar(l);
  }

  /// Edits the text of the single selected element (loose text, block or arrow label).
  Future<void> _editSelectedText() async {
    final e = _selectedElements.singleOrNull;
    switch (e) {
      case BoardText() || FlowNode():
        _typeChar(e!);
      case Connector():
        final t = await _ask('Rótulo da seta', e.label);
        if (t != null) {
          _editor.replace({e.id: e.copy(label: t.trim())});
        }
      case BoardTable():
        final t = await editTable(context, e, _toolbox);
        if (t != null) _editor.replace({e.id: t});
      default:
    }
  }

  /// Arrow being pulled from a handle: origin block and the tip (in the world).
  (FlowNode, Offset)? _pulling;

  /// Tip of an arrow being dragged to another block: the arrow and whether it is the end tip ([fim]).
  (Connector, bool)? _reconnecting;

  /// Single arrow selected: handles on both tips to change the exit/arrival block (and side).
  List<Widget> _arrowHandles() {
    if (_toolbox.tool != Tool.selection || _dragged.isNotEmpty || _selectedItems.length != 1) {
      return const [];
    }
    final l = _selectedElements.firstOrNull;
    if (l is! Connector) return const [];
    final blocks = {for (final n in _editor.elements.whereType<FlowNode>()) n.id: n};
    return [
      Positioned.fill(
        child: IgnorePointer(
          child: ListenableBuilder(
            listenable: _live,
            builder: (_, _) => CustomPaint(painter: _PullPainter(_pulling, _camera)),
          ),
        ),
      ),
      for (final fim in [false, true])
        ListenableBuilder(
          listenable: Listenable.merge([_cameraChanged, _live]),
          builder: (context, _) {
            final tip = _reconnecting?.$1.id == l.id && _reconnecting?.$2 == fim ? _pulling?.$2 : null;
            final c = _camera.toScreen(tip ?? (fim ? l.b : l.a));
            final fixed = blocks[fim ? l.de : l.to];
            return Positioned(
              left: c.dx - 9,
              top: c.dy - 9,
              child: Tooltip(
                message: fim ? 'Arraste para trocar onde a seta chega' : 'Arraste para trocar de onde a seta sai',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: fixed == null
                      ? null
                      : (_) {
                          _reconnecting = (l, fim);
                          _pulling = (fixed, fim ? l.b : l.a);
                        },
                  onPanUpdate: (d) {
                    final current = _pulling;
                    if (current == null || _reconnecting == null) return;
                    _pulling = (current.$1, current.$2 + d.delta / _camera.scale);
                    _live.avisar();
                  },
                  onPanEnd: (_) => _dropArrowTip(),
                  onPanCancel: () {
                    _reconnecting = null;
                    _pulling = null;
                    _live.avisar();
                  },
                  child: MouseRegion(
                    cursor: SystemMouseCursors.move,
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: fim ? Theme.of(context).colorScheme.primary : Colors.white,
                        shape: BoxShape.circle,
                        border: Border.all(color: Theme.of(context).colorScheme.primary, width: 3),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
    ];
  }

  /// Released the arrow tip: on the block under the cursor, connects to it through the side nearest to where it was released.
  void _dropArrowTip() {
    final reconnecting = _reconnecting, pull = _pulling;
    _reconnecting = null;
    _pulling = null;
    _live.avisar();
    if (reconnecting == null || pull == null) return;
    final (l, fim) = reconnecting;
    final tip = pull.$2;
    final target = _editor.elements.reversed
        .whereType<FlowNode>()
        .where((n) => n.retangulo.inflate(12 / _camera.scale).contains(tip))
        .firstOrNull;
    if (target == null) return;
    final r = target.retangulo;
    final middles = [r.topCenter, r.centerRight, r.bottomCenter, r.centerLeft];
    var side = 0;
    for (var i = 1; i < 4; i++) {
      if ((middles[i] - tip).distance < (middles[side] - tip).distance) side = i;
    }
    _editor.replace({l.id: fim ? l.copy(to: target.id, sideTo: side) : l.copy(de: target.id, sideOf: side)});
  }

  /// Single block selected (shows the connection handles), outside a drag.
  FlowNode? get _blockWithHandles {
    if (_toolbox.tool != Tool.selection || _dragged.isNotEmpty || _selectedItems.length != 1) {
      return null;
    }
    final e = _selectedElements.firstOrNull;
    return e is FlowNode ? e : null;
  }

  /// Four handles in the middle of the selected block's borders: pulling to another block creates the arrow;
  /// dropping on empty space creates a new connected block and opens its text right away.
  List<Widget> _connectorHandles() {
    final no = _blockWithHandles;
    if (no == null) return const [];
    return [
      Positioned.fill(
        child: IgnorePointer(
          child: ListenableBuilder(
            listenable: _live,
            builder: (_, _) => CustomPaint(painter: _PullPainter(_pulling, _camera)),
          ),
        ),
      ),
      for (final edge in [
        no.retangulo.topCenter,
        no.retangulo.centerRight,
        no.retangulo.bottomCenter,
        no.retangulo.centerLeft,
      ])
        ListenableBuilder(
          listenable: _cameraChanged,
          builder: (context, _) {
            final c =
                _camera.toScreen(edge) +
                (_camera.toScreen(edge) - _camera.toScreen(no.retangulo.center)) /
                    max(1, (edge - no.retangulo.center).distance) *
                    14;
            return Positioned(
              left: c.dx - 12,
              top: c.dy - 12,
              child: Tooltip(
                message: 'Arraste até outro bloco (ou para o vazio, criando um novo)',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (d) => _pulling = (no, _camera.toWorld(c)),
                  onPanUpdate: (d) {
                    final current = _pulling;
                    if (current == null) return;
                    _pulling = (current.$1, current.$2 + d.delta / _camera.scale);
                    _live.avisar();
                  },
                  onPanEnd: (_) => _dropPull(),
                  onPanCancel: () {
                    _pulling = null;
                    _live.avisar();
                  },
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: const Icon(Icons.add, size: 16, color: Colors.white),
                  ),
                ),
              ),
            );
          },
        ),
    ];
  }

  Future<void> _dropPull() async {
    final pull = _pulling;
    _pulling = null;
    _live.avisar();
    if (pull == null) return;
    final (origin, tip) = pull;
    if (origin.retangulo.inflate(8).contains(tip)) return;
    final target = _editor.elements.reversed
        .whereType<FlowNode>()
        .where((n) => n.id != origin.id && n.retangulo.inflate(12 / _camera.scale).contains(tip))
        .firstOrNull;
    final isNew = target == null
        ? FlowNode(
            _newId(),
            type: NodeKind.processo,
            text: 'Nova etapa',
            a: tip - const Offset(95, 40),
            b: tip + const Offset(95, 40),
            color: flowColors[NodeKind.processo]!,
            flow: origin.flow,
          )
        : null;
    final seta = Connector(
      _newId(),
      de: origin.id,
      to: target?.id ?? isNew!.id,
      a: Offset.zero,
      b: Offset.zero,
      color: const Color(0xFF37474F),
      flow: origin.flow,
      orthogonal: true,
    );
    _editor.addMany([?isNew, seta]);
    if (isNew != null) {
      setState(() => _selectedItems = {isNew.id});
      await _editSelectedText();
    } else if (origin.type == NodeKind.decisao) {
      // A decision exit almost always has a label (Sim/Não).
      final r = await _ask('Rótulo da seta (ex.: Sim, Não)', '');
      if (r != null && r.trim().isNotEmpty) {
        final current = _editor.elements.whereType<Connector>().where((l) => l.id == seta.id).firstOrNull;
        if (current != null) {
          _editor.replace({seta.id: current.copy(label: r.trim())});
        }
      }
    }
  }

  Future<String?> _ask(String title, String initial) =>
      editFormattedText(context, title: title, initial: initial, confirm: 'OK', format: false);

  List<String>? _flowProviders;

  /// AI flow: describe, send code or adjust the flow of the selection (or the board's last one).
  Future<void> _aiFlow() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      _flowProviders ??= await _editor.api.flowProviders();
    } catch (_) {
      _flowProviders = null;
      messenger.showSnackBar(const SnackBar(content: Text('Sem conexão com o servidor para a IA.')));
      return;
    }
    if (!mounted || _flowProviders!.isEmpty) return;
    final selectedItem = _selectedElements.whereType<FlowNode>().where((n) => n.flow.isNotEmpty).firstOrNull;
    final last = _editor.elements.whereType<FlowNode>().where((n) => n.flow.isNotEmpty).lastOrNull;
    final currentId = (selectedItem ?? last)?.flow;
    final request = await requestFlow(context, hasFlow: currentId != null, providers: _flowProviders!);
    if (request == null || !mounted) return;
    final fit = request.mode == FlowMode.fit && currentId != null;
    var cancelled = false;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        content: const Row(
          spacing: 16,
          children: [
            CircularProgressIndicator(),
            Expanded(child: Text('A IA está montando o fluxo…')),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              Navigator.pop(c);
            },
            child: const Text('Cancelar'),
          ),
        ],
      ),
    );
    try {
      final flow = await _editor.api.generateFlow(
        request: request.request,
        code: request.code,
        file: request.file,
        current: fit ? boardFlow(_editor.elements, currentId) : null,
        provider: request.provider,
        cancelled: () => cancelled,
      );
      if (!mounted || cancelled) return;
      Navigator.of(context).pop();
      final oldItems = {
        for (final e in _editor.elements)
          if (fit && ((e is FlowNode && e.flow == currentId) || (e is Connector && e.flow == currentId))) e.id,
      };
      final oldBounds = boundsOf(_editor.elements.where((e) => oldItems.contains(e.id)));
      final rest = boundsOf(_editor.elements.where((e) => !oldItems.contains(e.id)));
      final origin = oldBounds?.topLeft ?? (rest == null ? Offset.zero : Offset(rest.right + 200, rest.top));
      final newItems = flowElements(flow, origin, fit ? currentId : _newId());
      _editor.swapGroup(oldItems, newItems);
      setState(() => _selectedItems = {});
      _moverCamera(() => _camera.frame(boundsOf(newItems), _screen));
    } catch (e) {
      if (!mounted || cancelled) return;
      Navigator.of(context).pop();
      messenger.showSnackBar(SnackBar(content: Text(e is ApiErro ? e.mensagem : 'A IA falhou: $e')));
    }
  }

  Future<void> _rename() async {
    final controle = TextEditingController(text: _editor.title);
    final title = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Nome do quadro'),
        content: TextField(controller: controle, autofocus: true, onSubmitted: (v) => Navigator.pop(c, v)),
        actions: [FilledButton(onPressed: () => Navigator.pop(c, controle.text), child: const Text('Salvar'))],
      ),
    );
    controle.dispose();
    if (title == null || title.trim().isEmpty) return;
    await _editor.api.edit(_editor.id, title: title.trim());
    setState(() => _editor.title = title.trim());
  }

  Future<void> _changeBackground(Background f) async {
    setState(() => _editor.background = f);
    await _editor.api.edit(_editor.id, background: f);
  }

  void _toggleProjection() {
    setState(() => _projection = !_projection);
    SystemChrome.setEnabledSystemUIMode(_projection ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
  }

  Map<ShortcutActivator, VoidCallback> get _shortcuts => {
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _editor.undo,
    const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _editor.undo,
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true): _editor.redo,
    const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true): _editor.redo,
    const SingleActivator(LogicalKeyboardKey.keyY, control: true): _editor.redo,
    const SingleActivator(LogicalKeyboardKey.keyS, control: true): _editor.save,
    for (final f in Tool.values) CharacterActivator(f.shortcut): () => _toolbox.tool = f,
    const CharacterActivator('f'): _toggleProjection,
    const CharacterActivator('0'): _frame,
    const CharacterActivator('+'): () => _zoomCenter(1.25),
    const CharacterActivator('='): () => _zoomCenter(1.25),
    const CharacterActivator('-'): () => _zoomCenter(0.8),
    const SingleActivator(LogicalKeyboardKey.keyA, control: true): _selectAll,
    const SingleActivator(LogicalKeyboardKey.keyD, control: true): _duplicateSelection,
    const SingleActivator(LogicalKeyboardKey.keyG, control: true): _group,
    const SingleActivator(LogicalKeyboardKey.keyG, control: true, shift: true): _ungroup,
    const SingleActivator(LogicalKeyboardKey.keyC, control: true): _copySelection,
    const SingleActivator(LogicalKeyboardKey.keyC, meta: true): _copySelection,
    const SingleActivator(LogicalKeyboardKey.keyV, control: true): _paste,
    const SingleActivator(LogicalKeyboardKey.keyV, meta: true): _paste,
    const SingleActivator(LogicalKeyboardKey.bracketRight, control: true): () => _moveLayer(1),
    const SingleActivator(LogicalKeyboardKey.bracketLeft, control: true): () => _moveLayer(-1),
    const SingleActivator(LogicalKeyboardKey.bracketRight, control: true, shift: true): () => _moveLayer(2),
    const SingleActivator(LogicalKeyboardKey.bracketLeft, control: true, shift: true): () => _moveLayer(-2),
    const SingleActivator(LogicalKeyboardKey.delete): _deleteSelection,
    const SingleActivator(LogicalKeyboardKey.backspace): _deleteSelection,
    const SingleActivator(LogicalKeyboardKey.escape): () {
      if (_selectedItems.isNotEmpty) {
        setState(() => _selectedItems = {});
      } else if (_projection) {
        _toggleProjection();
      }
    },
  };

  MouseCursor get _cursor => switch (_toolbox.tool) {
    Tool.hand => _panning.isEmpty ? SystemMouseCursors.grab : SystemMouseCursors.grabbing,
    Tool.text => SystemMouseCursors.text,
    Tool.eraser => SystemMouseCursors.none,
    Tool.selection => SystemMouseCursors.basic,
    _ => SystemMouseCursors.precise,
  };

  // ---------- montagem ----------

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_editor, _toolbox]),
    builder: (context, _) => PopScope(
      onPopInvokedWithResult: (_, _) => _editor.save(),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        // While typing (on the board or in a field like the image search), the keys belong to the field:
        // Backspace must not erase the block nor a letter switch the tool.
        onKeyEvent: (_, event) {
          if (_typing != null || _inTextField) return KeyEventResult.ignored;
          for (final MapEntry(key: shortcut, value: action) in _shortcuts.entries) {
            if (shortcut.accepts(event, HardwareKeyboard.instance)) {
              action();
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: Focus(
          focusNode: _boardFocus,
          autofocus: true,
          child: LayoutBuilder(
            builder: (context, c) {
              _onPageChanged();
              // PC/laptop: shapes and style pinned to the sides (like draw.io); phone and tablet: drawers.
              final largo = c.maxWidth >= 1100 && !_projection;
              // ClipRect: the drawing outside the board area must not cover the side panels.
              final area = ClipRect(
                child: Stack(
                  children: [
                    Positioned.fill(child: _shapesTarget(_board())),
                    ..._connectorHandles(),
                    ..._arrowHandles(),
                    if (_typing != null) _boardField(),
                    if (_box != null)
                      Positioned(
                        top: _barSide == _Side.cima && !_barHidden ? 72 : 8,
                        left: 8,
                        right: 8,
                        child: Center(child: _selectionBar(context)),
                      ),
                    Positioned.fill(child: _positionedBar(context)),
                    Positioned(
                      right: _barSide == _Side.direita ? 76 : 12,
                      top: _projection ? 12 : null,
                      bottom: _projection ? null : (_barSide == _Side.baixo ? 76 : 12),
                      child: _zoom(context),
                    ),
                    if (_penMenu != null)
                      Positioned.fill(
                        child: PenRadialMenu(
                          center: _penMenu!,
                          toolbox: _toolbox,
                          undo: _editor.canUndo ? _editor.undo : null,
                          redo: _editor.canRedo ? _editor.redo : null,
                          moreColors: _moreColors,
                          close: () => setState(() => _penMenu = null),
                        ),
                      ),
                    if (_showImages && !_projection)
                      Positioned(
                        top: 0,
                        bottom: 0,
                        right: 0,
                        width: min(340, c.maxWidth * 0.85),
                        child: Material(
                          elevation: 6,
                          child: ImagesPanel(
                            api: _editor.api,
                            insert: _insertImage,
                            close: () => setState(() => _showImages = false),
                          ),
                        ),
                      ),
                  ],
                ),
              );
              return Scaffold(
                appBar: _projection ? null : _topBar(context, largo: largo),
                drawer: largo || _projection
                    ? null
                    : Drawer(width: 280, child: SafeArea(child: _shapesPanel(close: true))),
                endDrawer: largo || _projection ? null : Drawer(width: 300, child: SafeArea(child: _stylePanel())),
                bottomNavigationBar: _projection ? null : PagesBar(editor: _editor),
                body: largo
                    ? Row(
                        children: [
                          if (_showShapes) ...[
                            SizedBox(width: 236, child: _shapesPanel()),
                            const VerticalDivider(width: 1),
                          ],
                          Expanded(child: area),
                          if (_showStyle) ...[
                            const VerticalDivider(width: 1),
                            SizedBox(width: 280, child: _stylePanel()),
                          ],
                        ],
                      )
                    : area,
              );
            },
          ),
        ),
      ),
    ),
  );

  Widget _board() => LayoutBuilder(
    builder: (context, c) {
      _screen = c.biggest;
      if (!_framed) {
        _framed = true;
        _camera.frame(_editor.bounds, _screen);
      }
      return Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _tap,
        onPointerMove: _mover,
        onPointerUp: _drop,
        onPointerCancel: _drop,
        onPointerHover: _hover,
        onPointerSignal: _scroll,
        onPointerPanZoomStart: (_) => _trackpadScale = 1,
        onPointerPanZoomUpdate: _trackpad,
        child: MouseRegion(
          cursor: _cursor,
          onExit: (_) {
            _ring = null;
            _live.avisar();
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                child: CustomPaint(
                  painter: BoardPainter(
                    elements: _typing is FlowNode
                        ? [
                            for (final e in _editor.elements)
                              e is FlowNode && e.id == _typing!.id ? e.withText('') : e,
                          ]
                        : _editor.elements,
                    camera: _camera,
                    background: _editor.background,
                    role: _editor.role,
                    dark: _dark,
                    hiddenItems: _typing is BoardText ? {..._hidden, _typing!.id} : _hidden,
                    repaint: Listenable.merge([_cameraChanged, BoardImageCache.instance]),
                  ),
                ),
              ),
              CustomPaint(
                painter: LivePainter(
                  live: () => _liveElement,
                  laser: () => _laser,
                  camera: _camera,
                  dark: _dark,
                  eraser: () => _ring,
                  dragged: () => _dragged,
                  lasso: () => _lasso,
                  box: () => _box,
                  repaint: Listenable.merge([_live, _cameraChanged]),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  String _seenPage = '';

  /// Changed page: the selection was from the other page and the camera frames the new one.
  void _onPageChanged() {
    if (_seenPage == _editor.currentPage) return;
    final first = _seenPage.isEmpty && !_framed;
    _seenPage = _editor.currentPage;
    if (first) return;
    _selectedItems = {};
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _frame();
    });
  }

  Widget _shapesPanel({bool close = false}) => Builder(
    builder: (context) => ShapesPanel(
      insert: (t) {
        if (close) Navigator.of(context).pop();
        _insertBlock(t);
      },
      // In the drawer (portrait phone/tablet), its scrim covers the board and swallows the drop: closes on grab.
      onDrag: close ? () => Navigator.of(context).pop() : null,
      tool: (f) {
        if (close) Navigator.of(context).pop();
        _toolbox.tool = f;
      },
    ),
  );

  Widget _stylePanel() => DefaultTabController(
    length: 2,
    child: Column(
      children: [
        const TabBar(
          tabs: [
            Tab(text: 'Estilo', height: 40),
            Tab(text: 'Camadas', height: 40),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              _style(),
              LayersPanel(
                elements: _editor.elements,
                selectedItems: _selectedItems,
                select: (id, add) {
                  _toolbox.tool = Tool.selection;
                  setState(
                    () => _selectedItems = !add
                        ? {id}
                        : _selectedItems.contains(id)
                        ? ({..._selectedItems}..remove(id))
                        : {..._selectedItems, id},
                  );
                },
                reorder: _editor.reorder,
                moveLayer: _moveLayer,
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _style() => StylePanel(
    selectedItems: _selectedElements,
    apply: (newItems) => _editor.replace(newItems),
    editText: _editSelectedText,
    format: _typing == null ? null : _format,
    recent: _toolbox.recent,
    background: _editor.background,
    changeBackground: _changeBackground,
    export: [
      ('Imagem PNG', Icons.image_outlined, () => _export(ExportFormat.png)),
      ('PDF', Icons.picture_as_pdf_outlined, () => _export(ExportFormat.pdf)),
      ('draw.io (.drawio)', Icons.account_tree_outlined, _exportDrawio),
    ],
  );

  /// Dropping a shape dragged from the panel: creates the block where the finger/cursor was released.
  Widget _shapesTarget(Widget child) => DragTarget<NodeKind>(
    onAcceptWithDetails: (d) {
      final box = context.findRenderObject() as RenderBox?;
      final board = _boardKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || board == null) return;
      // the Draggable feedback is the 110×70 thumbnail: its center is where the block is born
      final local = board.globalToLocal(d.offset + const Offset(55, 35));
      _insertBlock(d.data, em: _camera.toWorld(local));
    },
    builder: (_, _, _) => DragTarget<DraggedImage>(
      onAcceptWithDetails: (d) async {
        final board = _boardKey.currentContext?.findRenderObject() as RenderBox?;
        if (board == null) return;
        // the dragged feedback is the 100×100 thumbnail: the image is born centered on it
        final em = _camera.toWorld(board.globalToLocal(d.offset + const Offset(50, 50)));
        final messenger = ScaffoldMessenger.of(context);
        try {
          await _insertImage(d.data.result, em: em);
        } catch (e) {
          messenger.showSnackBar(SnackBar(content: Text('Não deu para usar a imagem: $e')));
        }
      },
      builder: (_, _, _) => KeyedSubtree(key: _boardKey, child: child),
    ),
  );

  final _boardKey = GlobalKey();

  Future<void> _exportDrawio() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _editor.save();
      final bytes = await _editor.api.downloadDrawio(_editor.id);
      final name = _editor.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
      final saved = await FilePicker.saveFile(
        fileName: '${name.isEmpty ? 'quadro' : name}.drawio',
        bytes: bytes,
        mimeType: 'application/xml',
      );
      if (saved != null) messenger.showSnackBar(const SnackBar(content: Text('.drawio exportado')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Não exportou: ${e is ApiErro ? e.mensagem : e}')));
    }
  }

  PreferredSizeWidget _topBar(BuildContext context, {bool largo = false}) {
    // Portrait phone and tablet: the board buttons go down to a second scrollable line; on top stays
    // only title, saved, undo/redo and the ⋮ menu (otherwise the bar overflows and the menu disappears).
    final compact = MediaQuery.sizeOf(context).width < 900;
    final tools = <Widget>[
      if (largo) ...[
        IconButton(
          tooltip: _showShapes ? 'Ocultar painel de formas' : 'Mostrar painel de formas',
          isSelected: _showShapes,
          icon: const Icon(Icons.vertical_split_outlined),
          onPressed: () => setState(() => _showShapes = !_showShapes),
        ),
        IconButton(
          tooltip: _showStyle ? 'Ocultar painel de estilo' : 'Mostrar painel de estilo',
          isSelected: _showStyle,
          icon: Transform.flip(flipX: true, child: const Icon(Icons.vertical_split_outlined)),
          onPressed: () => setState(() => _showStyle = !_showStyle),
        ),
      ],
      if (!largo)
        Builder(
          builder: (c) => IconButton(
            tooltip: 'Formas',
            icon: const Icon(Icons.category_outlined),
            onPressed: () => Scaffold.of(c).openDrawer(),
          ),
        ),
      if (!largo)
        Builder(
          builder: (c) => IconButton(
            tooltip: 'Estilo',
            icon: const Icon(Icons.palette_outlined),
            onPressed: () => Scaffold.of(c).openEndDrawer(),
          ),
        ),
      ...widget.actions,
    ];
    final extras = <Widget>[
      IconButton(
        tooltip: _toolbox.fingerDraws ? 'Dedo desenha (toque para só a caneta)' : 'Só a caneta desenha; dedo move',
        onPressed: () => _toolbox.fingerDraws = !_toolbox.fingerDraws,
        icon: Icon(_toolbox.fingerDraws ? Icons.touch_app : Icons.do_not_touch_outlined),
      ),
      IconButton(
        tooltip: 'Quadro escuro',
        onPressed: () => setState(() => _dark = !_dark),
        icon: Icon(_dark ? Icons.dark_mode : Icons.light_mode_outlined),
      ),
      IconButton(tooltip: 'Fluxo com IA', onPressed: _aiFlow, icon: const Icon(Icons.auto_awesome)),
      IconButton(
        tooltip: 'Imagens, ícones e figuras (Google Imagens)',
        isSelected: _showImages,
        onPressed: () => setState(() => _showImages = !_showImages),
        icon: const Icon(Icons.image_search),
      ),
      IconButton(tooltip: 'Projeção (F)', onPressed: _toggleProjection, icon: const Icon(Icons.present_to_all)),
    ];
    return AppBar(
      title: InkWell(
        onTap: _rename,
        child: Text(_editor.title, overflow: TextOverflow.ellipsis),
      ),
      bottom: compact
          ? PreferredSize(
              preferredSize: const Size.fromHeight(48),
              child: Align(
                alignment: Alignment.centerLeft,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(children: [...tools, ...extras]),
                ),
              ),
            )
          : null,
      actions: [
        if (!compact) ...tools,
        _SavedIndicator(_editor),
        IconButton(
          tooltip: 'Desfazer (Ctrl+Z)',
          onPressed: _editor.canUndo ? _editor.undo : null,
          icon: const Icon(Icons.undo),
        ),
        IconButton(
          tooltip: 'Refazer (Ctrl+Shift+Z)',
          onPressed: _editor.canRedo ? _editor.redo : null,
          icon: const Icon(Icons.redo),
        ),
        if (!compact) ...extras,
        PopupMenuButton<VoidCallback>(
          onSelected: (action) => action(),
          itemBuilder: (_) => [
            for (final f in Background.values)
              CheckedPopupMenuItem(
                value: () => _changeBackground(f),
                checked: _editor.background == f,
                child: Text('Fundo: ${f.label}'),
              ),
            const PopupMenuDivider(),
            PopupMenuItem(value: _frame, child: const Text('Ver tudo (0)')),
            PopupMenuItem(value: _selectAll, child: const Text('Selecionar tudo (Ctrl+A)')),
            PopupMenuItem(value: _insertTable, child: const Text('Inserir tabela')),
            PopupMenuItem(
              value: () => setState(() => _showImages = true),
              child: const Text('Inserir imagem (Google Imagens)'),
            ),
            PopupMenuItem(value: () => _export(ExportFormat.png), child: const Text('Exportar PNG')),
            PopupMenuItem(value: () => _export(ExportFormat.pdf), child: const Text('Exportar PDF')),
            PopupMenuItem(value: _exportDrawio, child: const Text('Exportar draw.io (.drawio)')),
            PopupMenuItem(value: _editor.clear, child: const Text('Limpar a página')),
          ],
        ),
      ],
    );
  }

  /// In projection the bar only has what is used while explaining: pen, highlighter, laser, eraser and move.
  Widget _toolbar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tools = _projection
        ? const [Tool.caneta, Tool.marcador, Tool.laser, Tool.eraser, Tool.hand]
        : Tool.values;
    final current = _toolbox.tool;
    final vertical = _barSide == _Side.esquerda || _barSide == _Side.direita;
    final axis = vertical ? Axis.vertical : Axis.horizontal;
    final divisor = vertical
        ? const SizedBox(width: 24, child: Divider())
        : const SizedBox(height: 24, child: VerticalDivider());
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(28),
      color: scheme.surfaceContainerHigh,
      child: SingleChildScrollView(
        scrollDirection: axis,
        padding: vertical
            ? const EdgeInsets.symmetric(horizontal: 4, vertical: 8)
            : const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Flex(
          direction: axis,
          mainAxisSize: MainAxisSize.min,
          children: [
            _barHandle(),
            for (final f in tools)
              IconButton(
                tooltip: f.label,
                isSelected: f == current,
                style: IconButton.styleFrom(
                  backgroundColor: f == current ? scheme.primaryContainer : null,
                  foregroundColor: f == current ? scheme.onPrimaryContainer : null,
                ),
                onPressed: () => _toolbox.tool = f,
                icon: Icon(f.icone),
              ),
            if (current.usesColor || _box != null) ...[
              divisor,
              for (final c in {...quickColors, ..._toolbox.recent.take(2)})
                _ColorSwatch(c, selected: current.usesColor && _toolbox.color == c, onItemTap: () => _useColor(c)),
              IconButton(tooltip: 'Mais cores', onPressed: _moreColors, icon: const Icon(Icons.palette_outlined)),
            ],
            if (current.usesThickness)
              RotatedBox(
                quarterTurns: vertical ? 3 : 0,
                // Fixed height: the Slider alone takes all the free height and the bar covered the screen.
                child: SizedBox(
                  width: 120,
                  height: 40,
                  child: Slider(
                    value: _toolbox.thickness.clamp(1, 60),
                    min: 1,
                    max: 60,
                    onChanged: (v) => _toolbox.thickness = v,
                  ),
                ),
              ),
            if (_projection) ...[
              IconButton(onPressed: _editor.canUndo ? _editor.undo : null, icon: const Icon(Icons.undo)),
              IconButton(
                tooltip: 'Quadro escuro',
                onPressed: () => setState(() => _dark = !_dark),
                icon: Icon(_dark ? Icons.dark_mode : Icons.light_mode_outlined),
              ),
              IconButton(
                tooltip: 'Sair da projeção (Esc)',
                onPressed: _toggleProjection,
                icon: const Icon(Icons.close),
              ),
            ],
            IconButton(
              tooltip: 'Ocultar ferramentas',
              onPressed: () => _fitBar(hidden: true),
              icon: Icon(switch (_barSide) {
                _Side.baixo => Icons.keyboard_arrow_down,
                _Side.cima => Icons.keyboard_arrow_up,
                _Side.esquerda => Icons.keyboard_arrow_left,
                _Side.direita => Icons.keyboard_arrow_right,
              }),
            ),
          ],
        ),
      ),
    );
  }

  /// Bar (or, hidden, only the current tool button) pinned to the chosen side; follows the finger while
  /// dragging by the handle.
  Widget _positionedBar(BuildContext context) => Align(
    key: _barAreaKey,
    alignment: switch (_barSide) {
      _Side.baixo => Alignment.bottomCenter,
      _Side.cima => Alignment.topCenter,
      _Side.esquerda => Alignment.centerLeft,
      _Side.direita => Alignment.centerRight,
    },
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Transform.translate(
        offset: _barDrag,
        child: KeyedSubtree(
          key: _barKey,
          child: _barHidden
              ? GestureDetector(
                  onPanUpdate: (d) => setState(() => _barDrag += d.delta),
                  onPanEnd: (_) => _dropBar(),
                  child: IconButton.filledTonal(
                    tooltip: 'Mostrar ferramentas (arraste para mudar de lado)',
                    onPressed: () => _fitBar(hidden: false),
                    icon: Icon(_toolbox.tool.icone),
                  ),
                )
              : _toolbar(context),
        ),
      ),
    ),
  );

  /// Dragging moves the bar to any side; tapping opens the side choice.
  Widget _barHandle() => GestureDetector(
    onPanUpdate: (d) => setState(() => _barDrag += d.delta),
    onPanEnd: (_) => _dropBar(),
    child: PopupMenuButton<_Side>(
      tooltip: 'Arraste para mover a barra ou toque para escolher o lado',
      icon: const Icon(Icons.drag_indicator),
      initialValue: _barSide,
      onSelected: (l) => _fitBar(side: l),
      itemBuilder: (_) => [for (final l in _Side.values) PopupMenuItem(value: l, child: Text(l.label))],
    ),
  );

  void _dropBar() {
    final area = _barAreaKey.currentContext?.findRenderObject() as RenderBox?;
    final bar = _barKey.currentContext?.findRenderObject() as RenderBox?;
    if (area == null || bar == null) {
      setState(() => _barDrag = Offset.zero);
      return;
    }
    final c = area.globalToLocal(bar.localToGlobal(bar.size.center(Offset.zero)));
    final s = area.size;
    final distances = {
      _Side.cima: c.dy,
      _Side.baixo: s.height - c.dy,
      _Side.esquerda: c.dx,
      _Side.direita: s.width - c.dx,
    };
    _fitBar(side: distances.entries.reduce((a, b) => a.value <= b.value ? a : b).key);
  }

  void _fitBar({_Side? side, bool? hidden}) {
    setState(() {
      _barDrag = Offset.zero;
      if (side != null) _barSide = side;
      if (hidden != null) _barHidden = hidden;
    });
    unawaited(
      SharedPreferences.getInstance().then((p) async {
        await p.setString(_prefSide, _barSide.name);
        await p.setBool(_prefHidden, _barHidden);
      }),
    );
  }

  /// Focus on a text field (image search, board name…): the board shortcuts stay quiet.
  static bool get _inTextField =>
      FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null;

  Widget _selectionBar(BuildContext context) => Material(
    elevation: 4,
    borderRadius: BorderRadius.circular(24),
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text('${_selectedItems.length} selecionados'),
          ),
          if (_selectedElements.length == 1 &&
              (_selectedElements.first is BoardText ||
                  _selectedElements.first is FlowNode ||
                  _selectedElements.first is Connector ||
                  _selectedElements.first is BoardTable))
            IconButton(
              tooltip: _selectedElements.first is BoardTable
                  ? 'Editar tabela (linhas, colunas, células e cores)'
                  : 'Editar texto (negrito, itálico, sublinhado, marcador)',
              onPressed: _editSelectedText,
              icon: const Icon(Icons.edit_note),
            ),
          if (_selectedElements.whereType<FlowNode>().length == 2)
            IconButton(
              tooltip: 'Ligar os dois blocos com uma seta',
              onPressed: _connectSelected,
              icon: const Icon(Icons.trending_flat),
            ),
          if (_selectedItems.length > 1)
            IconButton(tooltip: 'Agrupar (Ctrl+G)', onPressed: _group, icon: const Icon(Icons.join_full)),
          if (_selectedElements.any((e) => e.group.isNotEmpty))
            IconButton(
              tooltip: 'Desagrupar (Ctrl+Shift+G)',
              onPressed: _ungroup,
              icon: const Icon(Icons.join_inner),
            ),
          IconButton(
            tooltip: 'Duplicar (Ctrl+D)',
            onPressed: _duplicateSelection,
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(tooltip: 'Copiar (Ctrl+C)', onPressed: _copySelection, icon: const Icon(Icons.content_copy)),
          if (_copied.isNotEmpty)
            IconButton(tooltip: 'Colar (Ctrl+V)', onPressed: _paste, icon: const Icon(Icons.content_paste)),
          IconButton(
            tooltip: 'Trazer para a frente (Ctrl+Shift+])',
            onPressed: () => _moveLayer(2),
            icon: const Icon(Icons.flip_to_front),
          ),
          IconButton(
            tooltip: 'Enviar para trás (Ctrl+Shift+[)',
            onPressed: () => _moveLayer(-2),
            icon: const Icon(Icons.flip_to_back),
          ),
          IconButton(
            tooltip: 'Exportar seleção (PNG)',
            onPressed: () => _export(ExportFormat.png, selectionOnly: true),
            icon: const Icon(Icons.image_outlined),
          ),
          IconButton(
            tooltip: 'Exportar seleção (PDF)',
            onPressed: () => _export(ExportFormat.pdf, selectionOnly: true),
            icon: const Icon(Icons.picture_as_pdf_outlined),
          ),
          IconButton(tooltip: 'Excluir (Delete)', onPressed: _deleteSelection, icon: const Icon(Icons.delete_outline)),
          IconButton(
            tooltip: 'Desmarcar (Esc)',
            onPressed: () => setState(() => _selectedItems = {}),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    ),
  );

  Widget _zoom(BuildContext context) => ListenableBuilder(
    listenable: _cameraChanged,
    builder: (context, _) =>
        ActionChip(tooltip: 'Ver tudo (0)', onPressed: _frame, label: Text('${(_camera.scale * 100).round()}%')),
  );
}

enum _Side {
  baixo('Embaixo'),
  cima('Em cima'),
  esquerda('À esquerda'),
  direita('À direita');

  const _Side(this.label);
  final String label;
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch(this.color, {required this.selected, required this.onItemTap});

  final Color color;
  final bool selected;
  final VoidCallback onItemTap;

  @override
  Widget build(BuildContext context) => InkResponse(
    onTap: onItemTap,
    radius: 18,
    child: Container(
      margin: const EdgeInsets.all(4),
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? Theme.of(context).colorScheme.primary : Colors.black26,
          width: selected ? 3 : 1,
        ),
      ),
    ),
  );
}

class _SavedIndicator extends StatelessWidget {
  const _SavedIndicator(this.editor);

  final BoardEditor editor;

  @override
  Widget build(BuildContext context) => switch (editor.state) {
    SaveState.saved => const Tooltip(message: 'Salvo', child: Icon(Icons.cloud_done_outlined)),
    SaveState.pending ||
    SaveState.saving => const Tooltip(message: 'Salvando…', child: Icon(Icons.cloud_upload_outlined)),
    SaveState.error => IconButton(
      tooltip: editor.offline
          ? 'Sem conexão: guardado no aparelho, envia quando voltar'
          : 'Não salvou; toque para tentar de novo',
      onPressed: editor.save,
      icon: Icon(Icons.cloud_off, color: Theme.of(context).colorScheme.error),
    ),
  };
}

/// Dashed line from the handle to the finger/cursor while the arrow is pulled.
class _PullPainter extends CustomPainter {
  _PullPainter(this.pulling, this.camera);

  final (FlowNode, Offset)? pulling;
  final Camera camera;

  @override
  void paint(Canvas canvas, Size size) {
    final p = pulling;
    if (p == null) return;
    final de = camera.toScreen(p.$1.edge(p.$2)), ate = camera.toScreen(p.$2);
    final brush = Paint()
      ..color = const Color(0xFF1E88E5)
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final d = ate - de;
    final n = (d.distance / 10).floor();
    for (var i = 0; i < n; i += 2) {
      canvas.drawLine(de + d * (i / n), de + d * ((i + 1) / n), brush);
    }
    canvas.drawCircle(ate, 5, brush);
  }

  @override
  bool shouldRepaint(_PullPainter old) => true;
}
