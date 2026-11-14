import 'dart:math';
import 'dart:ui' show Offset, Rect;

/// 1.27 mm grid (50 mil). All coordinates are integers in micrometers (µm).
const grade = 1270;

/// Integer point in µm (exact equality: that is how pin and wire connect).
class P {
  const P(this.x, this.y);

  final int x, y;

  factory P.json(List<dynamic> j) => P((j[0] as num).toInt(), (j[1] as num).toInt());

  List<int> toJson() => [x, y];

  Offset get offset => Offset(x.toDouble(), y.toDouble());

  P operator +(P o) => P(x + o.x, y + o.y);

  P operator -(P o) => P(x - o.x, y - o.y);

  @override
  bool operator ==(Object other) => other is P && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'P($x, $y)';
}

/// The grid point of [step] nearest to [world].
P snapToGrid(Offset world, [int step = grade]) =>
    P((world.dx / step).round() * step, (world.dy / step).round() * step);

/// Mirrors in x and rotates [rot] degrees (90° steps, clockwise on screen) — same as the backend `posicao_pino`.
P transform(P local, int rot, bool mirrored) {
  var x = mirrored ? -local.x : local.x, y = local.y;
  for (var i = 0; i < rot ~/ 90; i++) {
    (x, y) = (-y, x);
  }
  return P(x, y);
}

String _newId() {
  final r = Random();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

// ---------- Biblioteca ----------

/// Direction of the pin leg, from the tip to the body.
enum Direction {
  d(P(1, 0)),
  e(P(-1, 0)),
  c(P(0, -1)),
  b(P(0, 1));

  const Direction(this.vector);
  final P vector;
}

class Pin {
  const Pin({
    required this.n,
    required this.name,
    required this.pos,
    required this.dir,
    required this.comp,
    required this.type,
    this.hidden = false,
  });

  final String n, name, type;
  final P pos;
  final Direction dir;
  final int comp;

  /// Pin hidden in KiCad (e.g. the GND symbol one): connects, but is not drawn.
  final bool hidden;

  factory Pin.fromJson(Map<String, dynamic> j) => Pin(
    n: '${j['n']}',
    name: j['nome'] as String? ?? '',
    pos: P((j['x'] as num).toInt(), (j['y'] as num).toInt()),
    dir: Direction.values.byName(j['dir'] as String),
    comp: (j['comp'] as num).toInt(),
    type: j['tipo'] as String? ?? 'passivo',
    hidden: j['oculto'] as bool? ?? false,
  );

  /// Where the leg touches the body (symbol coordinates).
  P get end => P(pos.x + dir.vector.x * comp, pos.y + dir.vector.y * comp);
}

class Symbol {
  Symbol({
    required this.id,
    required this.name,
    required this.category,
    required this.prefix,
    required this.type,
    required this.value,
    required this.footprint,
    required this.drawing,
    required this.pins,
    required this.refField,
    required this.valueField,
    required this.pinNames,
    bool? pinNumbers,
    this.descricao = '',
  }) : pinNumbers = pinNumbers ?? pinNames,
       bounds = _bounds(drawing, pins);

  final String id, name, category, prefix, type, value, footprint, descricao;

  /// Primitives as they come from the backend (`linha`, `ret`, `circ`, `arco`, `texto`); see `biblioteca.py`.
  final List<Map<String, dynamic>> drawing;
  final List<Pin> pins;
  final P refField, valueField;
  final bool pinNames, pinNumbers;

  /// Box of the drawing and the pins (symbol coordinates), for selection.
  final Rect bounds;

  bool get supply => type == 'alimentacao';

  /// Came from a KiCad library (`<lib>:<nome>[:<unidade>]`); the base ones have no `:`.
  bool get imported => id.contains(':');

  /// Drawing in place of a symbol that vanished (library removed): a "?" without pins.
  factory Symbol.missing(String id) => Symbol(
    id: id,
    name: '$id (não encontrado)',
    category: '',
    prefix: 'U',
    type: 'componente',
    value: '',
    footprint: '',
    drawing: [
      {'t': 'ret', 'a': [-2540, -2540], 'b': [2540, 2540], 'cheio': false},
      {'t': 'texto', 'p': [0, 0], 's': '?'},
    ],
    pins: const [],
    refField: const P(0, -3810),
    valueField: const P(0, 3810),
    pinNames: false,
  );

  factory Symbol.fromJson(Map<String, dynamic> j) {
    final fields = j['campos'] as Map<String, dynamic>;
    return Symbol(
      id: j['id'] as String,
      name: j['nome'] as String,
      category: j['categoria'] as String,
      prefix: j['prefixo'] as String,
      type: j['tipo'] as String,
      value: j['valor'] as String? ?? '',
      footprint: j['encapsulamento'] as String? ?? '',
      drawing: [for (final d in j['desenho'] as List) d as Map<String, dynamic>],
      pins: [for (final p in j['pinos'] as List) Pin.fromJson(p as Map<String, dynamic>)],
      refField: P.json(fields['ref'] as List),
      valueField: P.json(fields['valor'] as List),
      pinNames: j['nomes_pinos'] as bool? ?? false,
      pinNumbers: j['numeros_pinos'] as bool?,
      descricao: j['descricao'] as String? ?? '',
    );
  }

  static Rect _bounds(List<Map<String, dynamic>> drawing, List<Pin> pins) {
    final pts = <Offset>[for (final p in pins) p.pos.offset];
    for (final d in drawing) {
      switch (d['t']) {
        case 'linha':
          pts.addAll([for (final q in d['p'] as List) P.json(q as List).offset]);
        case 'ret':
          pts.addAll([P.json(d['a'] as List).offset, P.json(d['b'] as List).offset]);
        case 'circ' || 'arco':
          final c = P.json(d['c'] as List).offset, r = (d['r'] as num).toDouble();
          pts.addAll([c - Offset(r, r), c + Offset(r, r)]);
        case 'texto':
          pts.add(P.json(d['p'] as List).offset);
      }
    }
    if (pts.isEmpty) return Rect.zero;
    var r = Rect.fromPoints(pts.first, pts.first);
    for (final p in pts) {
      r = r.expandToInclude(Rect.fromPoints(p, p));
    }
    return r.inflate(300);
  }
}

/// Base symbols (always) and the imported ones already brought from the server (search or project load).
class Library {
  Library(List<Symbol> symbols) : byId = {for (final s in symbols) s.id: s};

  final Map<String, Symbol> byId;

  Iterable<Symbol> get base => byId.values.where((s) => !s.imported);

  List<String> get categories => {for (final s in base) s.category}.toList();

  Symbol de(String id) => byId[id] ?? Symbol.missing(id);

  void adicionar(Iterable<Symbol> newItems) {
    for (final s in newItems) {
      byId[s.id] = s;
    }
  }

  /// Local search, only in the base (imported ones are searched on the server).
  List<Symbol> search(String text, {String? category}) {
    final t = text.trim().toLowerCase();
    return [
      for (final s in base)
        if ((category == null || s.category == category) &&
            (t.isEmpty || s.name.toLowerCase().contains(t) || s.value.toLowerCase().contains(t) || s.id.contains(t)))
          s,
    ];
  }
}

// ---------- Schematic items ----------

sealed class Item {
  Item(this.id, this.sheet);

  final String id;
  String sheet;

  Map<String, dynamic> toJson();
}

class Component extends Item {
  Component({
    String? id,
    required String sheet,
    required this.symbol,
    required this.ref,
    required this.value,
    required this.footprint,
    required this.pos,
    this.rot = 0,
    this.mirrored = false,
  }) : super(id ?? _newId(), sheet);

  final String symbol;
  String ref, value, footprint;
  P pos;
  int rot;
  bool mirrored;

  factory Component.fromJson(Map<String, dynamic> j) => Component(
    id: j['id'] as String,
    sheet: j['folha'] as String,
    symbol: j['simbolo'] as String,
    ref: j['ref'] as String? ?? '?',
    value: j['valor'] as String? ?? '',
    footprint: j['encapsulamento'] as String? ?? '',
    pos: P((j['x'] as num).toInt(), (j['y'] as num).toInt()),
    rot: (j['rot'] as num?)?.toInt() ?? 0,
    mirrored: j['espelho'] as bool? ?? false,
  );

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'folha': sheet,
    'simbolo': symbol,
    'ref': ref,
    'valor': value,
    'encapsulamento': footprint,
    'x': pos.x,
    'y': pos.y,
    'rot': rot,
    'espelho': mirrored,
  };

  P local(P p) => pos + transform(p, rot, mirrored);

  P pinPosition(Pin p) => local(p.pos);

  /// Box of the already rotated/mirrored symbol, in world coordinates.
  Rect bounds(Symbol s) {
    final r = s.bounds;
    final cantos = [
      for (final c in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight])
        local(P(c.dx.round(), c.dy.round())).offset,
    ];
    return Rect.fromPoints(cantos[0], cantos[3]).expandToInclude(Rect.fromPoints(cantos[1], cantos[2]));
  }
}

class Wire extends Item {
  Wire({String? id, required String sheet, required this.points}) : super(id ?? _newId(), sheet);

  List<P> points;

  factory Wire.fromJson(Map<String, dynamic> j) => Wire(
    id: j['id'] as String,
    sheet: j['folha'] as String,
    points: [for (final p in j['pontos'] as List) P.json(p as List)],
  );

  @override
  Map<String, dynamic> toJson() => {'id': id, 'folha': sheet, 'pontos': [for (final p in points) p.toJson()]};

  /// Does some segment pass through [p] (tips included)?
  bool passesThrough(P p) {
    for (var i = 0; i < points.length - 1; i++) {
      if (onSegment(p, points[i], points[i + 1])) return true;
    }
    return false;
  }
}

/// Net name at a point: labels with the same name connect, including across sheets.
class NetLabel extends Item {
  NetLabel({String? id, required String sheet, required this.name, required this.pos}) : super(id ?? _newId(), sheet);

  String name;
  P pos;

  factory NetLabel.fromJson(Map<String, dynamic> j) => NetLabel(
    id: j['id'] as String,
    sheet: j['folha'] as String,
    name: j['nome'] as String,
    pos: P((j['x'] as num).toInt(), (j['y'] as num).toInt()),
  );

  @override
  Map<String, dynamic> toJson() => {'id': id, 'folha': sheet, 'nome': name, 'x': pos.x, 'y': pos.y};
}

class CadText extends Item {
  CadText({String? id, required String sheet, required this.text, required this.pos, this.size = grade})
    : super(id ?? _newId(), sheet);

  String text;
  P pos;
  int size;

  factory CadText.fromJson(Map<String, dynamic> j) => CadText(
    id: j['id'] as String,
    sheet: j['folha'] as String,
    text: j['texto'] as String? ?? '',
    pos: P((j['x'] as num).toInt(), (j['y'] as num).toInt()),
    size: (j['tamanho'] as num?)?.toInt() ?? grade,
  );

  @override
  Map<String, dynamic> toJson() => {'id': id, 'folha': sheet, 'texto': text, 'x': pos.x, 'y': pos.y, 'tamanho': size};
}

/// Simulator probe: `v` measures the voltage of the net it touches; `i`, the current of component [ref].
/// The color is the one of its position in the project list (up to 8), the same as the signal in the oscilloscope.
class Probe extends Item {
  Probe({String? id, required String sheet, required this.type, required this.pos, this.ref = ''}) : super(id ?? _newId(), sheet);

  final String type;
  P pos;
  String ref;

  static const maximum = 8;

  factory Probe.fromJson(Map<String, dynamic> j) => Probe(
    id: j['id'] as String,
    sheet: j['folha'] as String,
    type: j['tipo'] as String,
    pos: P((j['x'] as num).toInt(), (j['y'] as num).toInt()),
    ref: j['ref'] as String? ?? '',
  );

  @override
  Map<String, dynamic> toJson() => {'id': id, 'folha': sheet, 'tipo': type, 'x': pos.x, 'y': pos.y, if (type == 'i') 'ref': ref};
}

class Sheet {
  Sheet({required this.id, required this.name});

  final String id;
  String name;

  factory Sheet.fromJson(Map<String, dynamic> j) => Sheet(id: j['id'] as String, name: j['nome'] as String);

  Map<String, dynamic> toJson() => {'id': id, 'nome': name};
}

class ProjectSummary {
  const ProjectSummary({required this.id, required this.title, required this.version, required this.updated, required this.total});

  final String id, title, updated;
  final int version, total;

  factory ProjectSummary.fromJson(Map<String, dynamic> j) => ProjectSummary(
    id: j['id'] as String,
    title: j['titulo'] as String,
    version: (j['versao'] as num).toInt(),
    updated: j['atualizado'] as String,
    total: (j['total'] as num?)?.toInt() ?? 0,
  );
}

class Project {
  Project({
    required this.id,
    required this.title,
    required this.version,
    required this.sheets,
    required this.components,
    required this.wires,
    required this.labels,
    required this.texts,
    List<Probe>? probes,
  }) : probes = probes ?? [];

  final String id;
  String title;
  int version;
  List<Sheet> sheets;
  List<Component> components;
  List<Wire> wires;
  List<NetLabel> labels;
  List<CadText> texts;
  List<Probe> probes;

  factory Project.fromJson(Map<String, dynamic> j) => Project(
    id: j['id'] as String,
    title: j['titulo'] as String,
    version: (j['versao'] as num).toInt(),
    sheets: [for (final f in j['folhas'] as List) Sheet.fromJson(f as Map<String, dynamic>)],
    components: [for (final c in j['componentes'] as List? ?? []) Component.fromJson(c as Map<String, dynamic>)],
    wires: [for (final f in j['fios'] as List? ?? []) Wire.fromJson(f as Map<String, dynamic>)],
    labels: [for (final r in j['rotulos'] as List? ?? []) NetLabel.fromJson(r as Map<String, dynamic>)],
    texts: [for (final t in j['textos'] as List? ?? []) CadText.fromJson(t as Map<String, dynamic>)],
    probes: [for (final s in j['sondas'] as List? ?? []) Probe.fromJson(s as Map<String, dynamic>)],
  );

  Map<String, dynamic> schematicJson() => {
    'folhas': [for (final f in sheets) f.toJson()],
    'componentes': [for (final c in components) c.toJson()],
    'fios': [for (final f in wires) f.toJson()],
    'rotulos': [for (final r in labels) r.toJson()],
    'textos': [for (final t in texts) t.toJson()],
    'sondas': [for (final s in probes) s.toJson()],
  };

  /// Swaps the content for that of [j] (undo/redo and reload after a conflict).
  void restore(Map<String, dynamic> j) {
    final p = Project.fromJson({'id': id, 'titulo': title, 'versao': version, ...j});
    sheets = p.sheets;
    components = p.components;
    wires = p.wires;
    labels = p.labels;
    texts = p.texts;
    probes = p.probes;
  }

  Iterable<Item> itens(String sheet) => <Item>[...components, ...wires, ...labels, ...texts, ...probes].where((i) => i.sheet == sheet);
}

// ---------- Geometria ----------

bool onSegment(P p, P a, P b) {
  if ((b.x - a.x) * (p.y - a.y) != (b.y - a.y) * (p.x - a.x)) return false;
  return min(a.x, b.x) <= p.x && p.x <= max(a.x, b.x) && min(a.y, b.y) <= p.y && p.y <= max(a.y, b.y);
}

double segmentDistance(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final l2 = ab.distanceSquared;
  if (l2 == 0) return (p - a).distance;
  final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / l2).clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

/// L-shaped path from [from] to [to]: first horizontal (or vertical) and then the other direction.
List<P> orthogonalRoute(P de, P ate, {bool horizontalFirst = true}) {
  final canto = horizontalFirst ? P(ate.x, de.y) : P(de.x, ate.y);
  return [de, if (canto != de && canto != ate) canto, ate];
}

/// Removes repeated points and corners in the middle of a straight line.
List<P> simplify(List<P> points) {
  final s = <P>[];
  for (final p in points) {
    if (s.isNotEmpty && s.last == p) continue;
    if (s.length >= 2 && onSegment(s.last, s[s.length - 2], p)) s.removeLast();
    s.add(p);
  }
  return s;
}

/// Next free reference of [prefix] (R1, R2…) among [components].
String nextRef(String prefix, Iterable<Component> components) {
  var larger = 0;
  final standard = RegExp('^${RegExp.escape(prefix)}(\\d+)\$');
  for (final c in components) {
    final m = standard.firstMatch(c.ref);
    if (m != null) larger = max(larger, int.parse(m.group(1)!));
  }
  return '$prefix${larger + 1}';
}

/// Points with three or more connections (wire tips/corners, pins, wire middle): get the junction dot.
Set<P> juncoes(Iterable<Wire> wires, Iterable<P> pins) {
  final counts = <P, int>{};
  final items = wires.toList();
  void sum(P p, int n) => counts[p] = (counts[p] ?? 0) + n;
  for (final f in items) {
    for (var i = 0; i < f.points.length; i++) {
      sum(f.points[i], i == 0 || i == f.points.length - 1 ? 1 : 2);
    }
  }
  for (final p in pins) {
    sum(p, 1);
  }
  // A tip touching the middle of another wire counts two more (the wire goes both ways).
  for (final p in counts.keys.toList()) {
    for (final f in items) {
      if (f.points.contains(p)) continue;
      if (f.passesThrough(p)) sum(p, 2);
    }
  }
  return {for (final e in counts.entries) if (e.value >= 3) e.key};
}
