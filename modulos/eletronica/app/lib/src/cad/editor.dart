import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Offset, Rect;

import 'package:agent_core/agent_core.dart';
import 'package:flutter/foundation.dart';

import '../electronics_api.dart';
import '../models.dart';

enum Tool { select, component, wire, label, text, probe }

enum Layer {
  components('Componentes'),
  fields('Referências e valores'),
  wires('Fios'),
  labels('Rótulos de rede'),
  texts('Textos'),
  probes('Pontas de prova'),
  grade('Grade');

  const Layer(this.name);
  final String name;
}

Layer layerOf(Item i) => switch (i) {
  Component() => Layer.components,
  Wire() => Layer.wires,
  NetLabel() => Layer.labels,
  CadText() => Layer.texts,
  Probe() => Layer.probes,
};

/// State of the open schematic: tool, selection, undo/redo and autosave (1.5 s after
/// the last change). 409 becomes [conflict]: the screen asks whether to reload or overwrite.
class Editor extends ChangeNotifier {
  Editor({required this.api, required this.project, required this.library}) : sheet = project.sheets.first.id;

  final ElectronicsApi api;
  final Project project;
  final Library library;

  String sheet;
  Tool tool = Tool.select;
  Symbol? symbol;
  int previewRotation = 0;
  bool previewMirror = false;
  final Set<String> selection = {};
  List<P>? wire;
  bool horizontalFirst = true;
  P? cursor;
  int step = grade;
  final Set<Layer> hidden = {};
  final Set<Layer> locked = {};

  /// Reading of each probe (id → text, e.g. "2,5 V") from the last simulated operating point.
  Map<String, String> readings = {};

  final List<String> _undo = [], _redo = [];
  String? _batch;
  Timer? _timer;
  bool saving = false, pending = false, conflict = false;
  String? error;

  // ---------- Consulta ----------

  Iterable<Component> get components => project.components.where((c) => c.sheet == sheet);
  Iterable<Wire> get wires => project.wires.where((f) => f.sheet == sheet);
  Iterable<NetLabel> get labels => project.labels.where((r) => r.sheet == sheet);
  Iterable<CadText> get texts => project.texts.where((t) => t.sheet == sheet);
  Iterable<Probe> get probes => project.probes.where((s) => s.sheet == sheet);

  /// Probe position in the project list = color position in the signal palette.
  int probeIndex(Probe s) => project.probes.indexOf(s);

  Symbol symbolOf(Component c) => library.de(c.symbol);

  Iterable<P> sheetPins() sync* {
    for (final c in components) {
      for (final p in symbolOf(c).pins) {
        yield c.pinPosition(p);
      }
    }
  }

  List<Item> get selected => [for (final i in project.itens(sheet)) if (selection.contains(i.id)) i];

  bool canUndo() => _undo.isNotEmpty;
  bool canRedo() => _redo.isNotEmpty;

  bool _visible(Item i) => !hidden.contains(layerOf(i)) && !locked.contains(layerOf(i));

  /// Item under [world] with a [tol] µm slack; the topmost (last drawn) wins.
  Item? fix(Offset world, double tol) {
    Item? found;
    for (final i in project.itens(sheet)) {
      if (!_visible(i)) continue;
      final touches = switch (i) {
        Component c => c.bounds(symbolOf(c)).inflate(tol).contains(world),
        Wire f => [
          for (var k = 0; k < f.points.length - 1; k++) segmentDistance(world, f.points[k].offset, f.points[k + 1].offset),
        ].any((d) => d <= tol),
        NetLabel r => _labelBox(r).inflate(tol).contains(world),
        CadText t => _textBox(t).inflate(tol).contains(world),
        Probe s => (s.pos.offset - world).distance <= tol + 900,
      };
      if (touches) found = i;
    }
    return found;
  }

  Rect _labelBox(NetLabel r) => Rect.fromLTWH(r.pos.x.toDouble(), r.pos.y - 1400.0, r.name.length * 800.0 + 600, 1400);
  Rect _textBox(CadText t) =>
      Rect.fromLTWH(t.pos.x.toDouble(), t.pos.y - t.size.toDouble(), t.text.length * t.size * 0.62, t.size * 1.3);

  /// Whole items inside [area] (window, as in AutoCAD).
  void selectArea(Rect area, {bool sum = false}) {
    if (!sum) selection.clear();
    for (final i in project.itens(sheet)) {
      if (!_visible(i)) continue;
      final inside = switch (i) {
        Component c => _contains(area, c.bounds(symbolOf(c))),
        Wire f => f.points.every((p) => area.contains(p.offset)),
        NetLabel r => area.contains(r.pos.offset),
        CadText t => area.contains(t.pos.offset),
        Probe s => area.contains(s.pos.offset),
      };
      if (inside) selection.add(i.id);
    }
    notifyListeners();
  }

  static bool _contains(Rect fora, Rect inside) => fora.contains(inside.topLeft) && fora.contains(inside.bottomRight);

  // ---------- Changes ----------

  String _photo() => jsonEncode(project.schematicJson());

  /// Applies [edit] keeping the previous state for undo.
  void change(void Function() edit) {
    final antes = _photo();
    edit();
    if (_photo() == antes) return;
    _undo.add(antes);
    if (_undo.length > 200) _undo.removeAt(0);
    _redo.clear();
    _changed();
  }

  /// Drags: [startBatch] stores the state once, [changeLive] changes without the stack, [endBatch] pushes it.
  void startBatch() => _batch ??= _photo();

  void changeLive(void Function() edit) {
    edit();
    notifyListeners();
  }

  void endBatch() {
    final antes = _batch;
    _batch = null;
    if (antes == null || antes == _photo()) return;
    _undo.add(antes);
    _redo.clear();
    _changed();
  }

  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(_photo());
    project.restore(jsonDecode(_undo.removeLast()) as Map<String, dynamic>);
    _afterRestore();
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(_photo());
    project.restore(jsonDecode(_redo.removeLast()) as Map<String, dynamic>);
    _afterRestore();
  }

  void _afterRestore() {
    if (!project.sheets.any((f) => f.id == sheet)) sheet = project.sheets.first.id;
    selection.removeWhere((id) => !project.itens(sheet).any((i) => i.id == id));
    _changed();
  }

  void _changed() {
    pending = true;
    notifyListeners();
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 1500), save);
  }

  // ---------- Ferramentas ----------

  void pick(Tool f, {Symbol? s}) {
    tool = f;
    if (s != null) {
      symbol = s;
      previewRotation = 0;
      previewMirror = false;
    }
    wire = null;
    if (f != Tool.select) selection.clear();
    notifyListeners();
  }

  void moverCursor(P? p) {
    if (p == cursor) return;
    cursor = p;
    notifyListeners();
  }

  /// `/`: the wire in progress bends first in the other direction.
  void flipCorner() {
    horizontalFirst = !horizontalFirst;
    notifyListeners();
  }

  void changeStep(int isNew) {
    step = isNew;
    notifyListeners();
  }

  Component? placeComponent(P pos) {
    final s = symbol;
    if (s == null) return null;
    final c = Component(
      sheet: sheet,
      symbol: s.id,
      ref: nextRef(s.prefix, project.components),
      value: s.value,
      footprint: s.footprint,
      pos: pos,
      rot: previewRotation,
      mirrored: previewMirror,
    );
    change(() => project.components.add(c));
    return c;
  }

  /// Point where something already connects (pin, tip or wire middle): clicking it ends the wire.
  bool isConnection(P p) => sheetPins().contains(p) || wires.any((f) => f.passesThrough(p)) || labels.any((r) => r.pos == p);

  void wirePoint(P p) {
    final current = wire;
    if (current == null) {
      wire = [p];
      notifyListeners();
      return;
    }
    final route = orthogonalRoute(current.last, p, horizontalFirst: horizontalFirst);
    wire = [...current, ...route.skip(1)];
    if (isConnection(p) && wire!.length > 1) {
      finishWire();
    } else {
      notifyListeners();
    }
  }

  void finishWire() {
    final points = simplify(wire ?? const []);
    wire = null;
    if (points.length >= 2) {
      change(() => project.wires.add(Wire(sheet: sheet, points: points)));
    } else {
      notifyListeners();
    }
  }

  void placeLabel(P pos, String name) =>
      change(() => project.labels.add(NetLabel(sheet: sheet, name: name.trim(), pos: pos)));

  /// Current probe on top of a component; otherwise, voltage probe at the point. Returns the warning when it does not fit.
  String? placeProbe(P pos, Offset world, double tol) {
    if (project.probes.length >= Probe.maximum) return 'No máximo ${Probe.maximum} pontas de prova.';
    final target = fix(world, tol);
    final s = target is Component
        ? Probe(sheet: sheet, type: 'i', pos: pos, ref: target.ref)
        : Probe(sheet: sheet, type: 'v', pos: pos);
    change(() => project.probes.add(s));
    readings = {};
    return null;
  }

  void readProbes(Map<String, String> novas) {
    readings = novas;
    notifyListeners();
  }

  void placeText(P pos, String text) => change(() => project.texts.add(CadText(sheet: sheet, text: text, pos: pos)));

  /// R: rotates the preview (with the component tool) or the selection by 90° around its own point.
  void rotate() {
    if (tool == Tool.component) {
      previewRotation = (previewRotation + 90) % 360;
      notifyListeners();
      return;
    }
    change(() {
      for (final c in selected.whereType<Component>()) {
        c.rot = (c.rot + 90) % 360;
      }
    });
  }

  void mirror() {
    if (tool == Tool.component) {
      previewMirror = !previewMirror;
      notifyListeners();
      return;
    }
    change(() {
      for (final c in selected.whereType<Component>()) {
        c.mirrored = !c.mirrored;
      }
    });
  }

  void deleteSelection() {
    if (selection.isEmpty) return;
    change(() {
      project.components.removeWhere((i) => selection.contains(i.id));
      project.wires.removeWhere((i) => selection.contains(i.id));
      project.labels.removeWhere((i) => selection.contains(i.id));
      project.texts.removeWhere((i) => selection.contains(i.id));
      project.probes.removeWhere((i) => selection.contains(i.id));
      selection.clear();
    });
  }

  /// Ctrl+D: copy of the selection offset by two grids, with new references.
  void duplicateSelection() {
    final itens = selected;
    if (itens.isEmpty) return;
    const d = P(2 * grade, 2 * grade);
    change(() {
      selection.clear();
      for (final i in itens) {
        final Item isNew = switch (i) {
          Component c => Component(
            sheet: sheet,
            symbol: c.symbol,
            ref: nextRef(symbolOf(c).prefix, project.components),
            value: c.value,
            footprint: c.footprint,
            pos: c.pos + d,
            rot: c.rot,
            mirrored: c.mirrored,
          )..let(project.components.add),
          Wire f => Wire(sheet: sheet, points: [for (final p in f.points) p + d])..let(project.wires.add),
          NetLabel r => NetLabel(sheet: sheet, name: r.name, pos: r.pos + d)..let(project.labels.add),
          CadText t => CadText(sheet: sheet, text: t.text, pos: t.pos + d, size: t.size)..let(project.texts.add),
          // A probe is not duplicated (each one has its own color); the original stays selected.
          Probe s => s,
        };
        selection.add(isNew.id);
      }
    });
  }

  /// Moves the selection by [d]; wire tips attached to pins of moved components go along (rubber band).
  void moveSelection(P d) {
    final itens = selected;
    final pins = <P>{
      for (final c in itens.whereType<Component>())
        for (final p in symbolOf(c).pins) c.pinPosition(p),
    };
    for (final f in wires) {
      if (selection.contains(f.id)) continue;
      for (final k in [0, f.points.length - 1]) {
        if (pins.contains(f.points[k])) f.points[k] = f.points[k] + d;
      }
    }
    for (final i in itens) {
      switch (i) {
        case Component c:
          c.pos = c.pos + d;
        case Wire f:
          f.points = [for (final p in f.points) p + d];
        case NetLabel r:
          r.pos = r.pos + d;
        case CadText t:
          t.pos = t.pos + d;
        case Probe s:
          s.pos = s.pos + d;
      }
    }
  }

  void toggleLayer(Layer c, {bool lock = false}) {
    final group = lock ? locked : hidden;
    group.contains(c) ? group.remove(c) : group.add(c);
    selection.removeWhere((id) => project.itens(sheet).any((i) => i.id == id && !_visible(i)));
    notifyListeners();
  }

  // ---------- Folhas ----------

  void goTo(String id) {
    sheet = id;
    selection.clear();
    wire = null;
    notifyListeners();
  }

  void newSheet() {
    var n = project.sheets.length + 1;
    while (project.sheets.any((f) => f.id == 'f$n')) {
      n++;
    }
    final f = Sheet(id: 'f$n', name: 'Folha $n');
    change(() => project.sheets.add(f));
    goTo(f.id);
  }

  void renameSheet(String id, String name) => change(() => project.sheets.firstWhere((f) => f.id == id).name = name);

  void deleteSheet(String id) {
    if (project.sheets.length <= 1) return;
    change(() {
      project.sheets.removeWhere((f) => f.id == id);
      project.components.removeWhere((i) => i.sheet == id);
      project.wires.removeWhere((i) => i.sheet == id);
      project.labels.removeWhere((i) => i.sheet == id);
      project.texts.removeWhere((i) => i.sheet == id);
      project.probes.removeWhere((i) => i.sheet == id);
    });
    if (sheet == id) goTo(project.sheets.first.id);
  }

  // ---------- Saving ----------

  Future<void> save({bool onTop = false}) async {
    _timer?.cancel();
    if (saving || (!pending && !onTop)) return;
    saving = true;
    notifyListeners();
    try {
      if (onTop) project.version = (await api.fetch(project.id)).version;
      final r = await api.save(project, project.version);
      project.version = r.version;
      pending = false;
      conflict = false;
      error = null;
    } on ApiErro catch (e) {
      if (e.status == 409) {
        conflict = true;
      } else {
        error = e.mensagem;
        _timer = Timer(const Duration(seconds: 15), save);
      }
    } catch (e) {
      error = '$e';
      _timer = Timer(const Duration(seconds: 15), save);
    } finally {
      saving = false;
      notifyListeners();
    }
  }

  /// Discards what was not saved and reads the server version.
  Future<void> reload() async {
    final p = await api.fetch(project.id);
    project
      ..version = p.version
      ..restore(p.schematicJson());
    _timer?.cancel();
    pending = conflict = false;
    _undo.clear();
    _redo.clear();
    if (!project.sheets.any((f) => f.id == sheet)) sheet = project.sheets.first.id;
    selection.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    // Without notifying: the editor already left the screen.
    if (pending && !conflict && !saving) unawaited(api.save(project, project.version).then((_) {}, onError: (_) {}));
    super.dispose();
  }
}

extension _Let<T> on T {
  void let(void Function(T) f) => f(this);
}
