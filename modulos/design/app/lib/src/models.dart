import 'dart:math';
import 'dart:ui';

import 'routing.dart';

/// Board background (same values as `FUNDOS` in the backend).
enum Background {
  liso('Liso'),
  pontos('Pontos'),
  grade('Grade'),
  linhas('Linhas');

  const Background(this.label);

  final String label;

  static Background de(String? name) => values.firstWhere((f) => f.name == name, orElse: () => pontos);
}

/// Point of a stroke in world coordinates; [p] is the normalized pressure (0–1).
class StrokePoint {
  const StrokePoint(this.x, this.y, this.p);

  factory StrokePoint.fromJson(List<dynamic> j) =>
      StrokePoint((j[0] as num).toDouble(), (j[1] as num).toDouble(), j.length > 2 ? (j[2] as num).toDouble() : 0.5);

  final double x, y, p;

  Offset get offset => Offset(x, y);

  // Two decimals are enough (the world is in logical pixels) and the JSON gets much smaller.
  List<num> toJson() => [_round(x), _round(y), _round(p)];
}

num _round(double v) => (v * 100).roundToDouble() / 100;

Color _color(Object? v) => Color(v is int ? v : 0xFF111111);

/// Board element. The backend only looks at `id` and `tipo`.
sealed class Elemento {
  const Elemento(this.id, {this.group = ''});

  final String id;

  /// Group (Ctrl+G): elements with the same non-empty [group] are selected and moved together.
  final String group;

  Rect get bounds;

  /// Does point [q] touch the element (with slack [radius])? Used by the eraser.
  bool touches(Offset q, double radius);

  /// Points that represent the element in the lasso test.
  List<Offset> get samples;

  /// Copy with each point passed through [f] (move, resize), thickness/size × [factor] and,
  /// if given, another [id] (duplicate), another [color] or another [group] ('' = no group).
  Elemento transform(Offset Function(Offset) f, {double factor = 1, String? id, Color? color, String? group});

  /// The lasso (polygon in the world) grabs the element when it embraces at least half of the samples.
  bool insideLasso(List<Offset> lasso) {
    final a = samples;
    if (a.isEmpty || lasso.length < 3) return false;
    return a.where((p) => pointInPolygon(p, lasso)).length * 2 >= a.length;
  }

  Elemento withGroup(String g) => transform((q) => q, group: g);

  Map<String, dynamic> toJson();

  static Elemento? fromJson(Map<String, dynamic> j) {
    final e = switch (j['tipo']) {
      'traco' => Traco.fromJson(j),
      'forma' => Forma.fromJson(j),
      'texto' => BoardText.fromJson(j),
      'no' => FlowNode.fromJson(j),
      'ligacao' => Connector.fromJson(j),
      'tabela' => BoardTable.fromJson(j),
      'imagem' => BoardImage.fromJson(j),
      _ => null,
    };
    final g = j['grupo'];
    return e != null && g is String && g.isNotEmpty ? e.withGroup(g) : e;
  }
}

enum Pincel { caneta, marcador }

class Traco extends Elemento {
  const Traco(super.id, {super.group, required this.brush, required this.color, required this.thickness, required this.pontos});

  factory Traco.fromJson(Map<String, dynamic> j) => Traco(
    j['id'] as String,
    brush: Pincel.values.firstWhere((p) => p.name == j['pincel'], orElse: () => Pincel.caneta),
    color: _color(j['cor']),
    thickness: (j['espessura'] as num? ?? 3).toDouble(),
    pontos: [for (final p in j['pontos'] as List? ?? const []) StrokePoint.fromJson(p as List)],
  );

  final Pincel brush;
  final Color color;
  final double thickness;
  final List<StrokePoint> pontos;

  @override
  Rect get bounds {
    if (pontos.isEmpty) return Rect.zero;
    var r = Rect.fromLTRB(pontos.first.x, pontos.first.y, pontos.first.x, pontos.first.y);
    for (final p in pontos) {
      r = r.expandToInclude(Rect.fromLTRB(p.x, p.y, p.x, p.y));
    }
    return r.inflate(thickness);
  }

  @override
  bool touches(Offset q, double radius) {
    if (!bounds.inflate(radius).contains(q)) return false;
    final slack = radius + thickness / 2;
    if (pontos.length == 1) return (pontos.first.offset - q).distance <= slack;
    for (var i = 1; i < pontos.length; i++) {
      if (distanceToSegment(q, pontos[i - 1].offset, pontos[i].offset) <= slack) return true;
    }
    return false;
  }

  @override
  List<Offset> get samples => [for (final p in pontos) p.offset];

  @override
  Traco transform(Offset Function(Offset) f, {double factor = 1, String? id, Color? color, String? group}) => Traco(
    id ?? this.id,
    group: group ?? this.group,
    brush: brush,
    color: color ?? this.color,
    thickness: thickness * factor,
    pontos: [
      for (final p in pontos)
        if (f(p.offset) case final q) StrokePoint(q.dx, q.dy, p.p),
    ],
  );

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    if (group.isNotEmpty) 'grupo': group,
    'tipo': 'traco',
    'pincel': brush.name,
    'cor': color.toARGB32(),
    'espessura': thickness,
    'pontos': [for (final p in pontos) p.toJson()],
  };
}

enum ShapeKind { reta, seta, retangulo, elipse }

class Forma extends Elemento {
  const Forma(
    super.id, {
    super.group,
    required this.shape,
    required this.a,
    required this.b,
    required this.color,
    required this.thickness,
  });

  factory Forma.fromJson(Map<String, dynamic> j) => Forma(
    j['id'] as String,
    shape: ShapeKind.values.firstWhere((f) => f.name == j['forma'], orElse: () => ShapeKind.reta),
    a: StrokePoint.fromJson(j['a'] as List).offset,
    b: StrokePoint.fromJson(j['b'] as List).offset,
    color: _color(j['cor']),
    thickness: (j['espessura'] as num? ?? 3).toDouble(),
  );

  final ShapeKind shape;
  final Offset a, b;
  final Color color;
  final double thickness;

  @override
  Rect get bounds => Rect.fromPoints(a, b).inflate(thickness * 4);

  @override
  bool touches(Offset q, double radius) {
    final slack = radius + thickness / 2;
    final r = Rect.fromPoints(a, b);
    return switch (shape) {
      ShapeKind.reta || ShapeKind.seta => distanceToSegment(q, a, b) <= slack,
      ShapeKind.retangulo => [
        (r.topLeft, r.topRight),
        (r.topRight, r.bottomRight),
        (r.bottomRight, r.bottomLeft),
        (r.bottomLeft, r.topLeft),
      ].any((l) => distanceToSegment(q, l.$1, l.$2) <= slack),
      ShapeKind.elipse => _onEllipse(q, r, slack),
    };
  }

  static bool _onEllipse(Offset q, Rect r, double slack) {
    final rx = r.width / 2, ry = r.height / 2;
    if (rx < 1 || ry < 1) return r.inflate(slack).contains(q);
    final d = q - r.center;
    // Approximate distance to the border: deviation of the "normalized radius" times the average radius.
    final n = sqrt(pow(d.dx / rx, 2) + pow(d.dy / ry, 2));
    return (n - 1).abs() * (rx + ry) / 2 <= slack;
  }

  @override
  List<Offset> get samples => [a, b, Rect.fromPoints(a, b).center];

  @override
  Forma transform(Offset Function(Offset) f, {double factor = 1, String? id, Color? color, String? group}) =>
      Forma(id ?? this.id, group: group ?? this.group, shape: shape, a: f(a), b: f(b), color: color ?? this.color, thickness: thickness * factor);

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    if (group.isNotEmpty) 'grupo': group,
    'tipo': 'forma',
    'forma': shape.name,
    'a': [_round(a.dx), _round(a.dy)],
    'b': [_round(b.dx), _round(b.dy)],
    'cor': color.toARGB32(),
    'espessura': thickness,
  };
}

class BoardText extends Elemento {
  const BoardText(super.id, {super.group, required this.position, required this.text, required this.color, required this.size});

  factory BoardText.fromJson(Map<String, dynamic> j) => BoardText(
    j['id'] as String,
    position: StrokePoint.fromJson(j['posicao'] as List).offset,
    text: j['texto'] as String? ?? '',
    color: _color(j['cor']),
    size: (j['tamanho'] as num? ?? 24).toDouble(),
  );

  final Offset position;
  final String text;
  final Color color;
  final double size;

  // Estimate without text layout (the painting uses the real TextPainter).
  @override
  Rect get bounds {
    final linhas = text.split('\n');
    final width = linhas.map((l) => l.length).fold(1, max) * size * 0.6;
    return position & Size(width, linhas.length * size * 1.25);
  }

  @override
  bool touches(Offset q, double radius) => bounds.inflate(radius).contains(q);

  @override
  List<Offset> get samples => [bounds.topLeft, bounds.bottomRight, bounds.center];

  @override
  BoardText transform(Offset Function(Offset) f, {double factor = 1, String? id, Color? color, String? group}) =>
      BoardText(id ?? this.id, group: group ?? this.group, position: f(position), text: text, color: color ?? this.color, size: size * factor);

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    if (group.isNotEmpty) 'grupo': group,
    'tipo': 'texto',
    'posicao': [_round(position.dx), _round(position.dy)],
    'texto': text,
    'cor': color.toARGB32(),
    'tamanho': size,
  };
}

/// Image (photo, icon or figure from Google Images) between corners [a] and [b]; [image] is the id of the
/// file copied to the server (`/api/design/imagens/<id>`).
class BoardImage extends Elemento {
  const BoardImage(super.id, {super.group, required this.a, required this.b, required this.image, this.title = ''});

  factory BoardImage.fromJson(Map<String, dynamic> j) => BoardImage(
    j['id'] as String,
    a: StrokePoint.fromJson(j['a'] as List).offset,
    b: StrokePoint.fromJson(j['b'] as List).offset,
    image: j['imagem'] as String? ?? '',
    title: j['titulo'] as String? ?? '',
  );

  final Offset a, b;
  final String image;
  final String title;

  Rect get retangulo => Rect.fromPoints(a, b);

  @override
  Rect get bounds => retangulo;

  @override
  bool touches(Offset q, double radius) => retangulo.inflate(radius).contains(q);

  @override
  List<Offset> get samples => [retangulo.topLeft, retangulo.bottomRight, retangulo.center];

  // No own color: recoloring the selection does not change the image.
  @override
  BoardImage transform(Offset Function(Offset) f, {double factor = 1, String? id, Color? color, String? group}) =>
      BoardImage(id ?? this.id, group: group ?? this.group, a: f(a), b: f(b), image: image, title: title);

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    if (group.isNotEmpty) 'grupo': group,
    'tipo': 'imagem',
    'a': [_round(a.dx), _round(a.dy)],
    'b': [_round(b.dx), _round(b.dy)],
    'imagem': image,
    if (title.isNotEmpty) 'titulo': title,
  };
}

/// Flowchart block (business rule); the same draw.io ones the app draws.
enum NodeKind {
  inicio('Início / fim'),
  fim('Fim'),
  processo('Processo'),
  decisao('Decisão'),
  dado('Entrada/saída'),
  subprocesso('Subprocesso'),
  quadrado('Retângulo'),
  circulo('Círculo / conector'),
  documento('Documento'),
  banco('Banco de dados'),
  nota('Nota'),
  hexagono('Hexágono'),
  container('Contêiner / raia');

  const NodeKind(this.label);

  final String label;

  static NodeKind de(String? name) => values.firstWhere((t) => t.name == name, orElse: () => processo);
}

Color? _optionalColor(Object? v) => v is int ? Color(v) : null;

/// Block of a flowchart: rectangle [a]–[b] in the world with the [text] centered (on the container, at the top).
/// [color] is the border; empty [background] and [textColor] = derived from the border. [flow] groups the blocks and
/// connectors generated together (so the AI can adjust the whole flow).
class FlowNode extends Elemento {
  const FlowNode(
    super.id, {
    super.group,
    required this.type,
    required this.text,
    required this.a,
    required this.b,
    required this.color,
    this.background,
    this.textColor,
    this.esquerda = false,
    this.flow = '',
  });

  factory FlowNode.fromJson(Map<String, dynamic> j) => FlowNode(
    j['id'] as String,
    type: NodeKind.de(j['no'] as String?),
    text: j['texto'] as String? ?? '',
    a: StrokePoint.fromJson(j['a'] as List).offset,
    b: StrokePoint.fromJson(j['b'] as List).offset,
    color: _color(j['cor']),
    background: _optionalColor(j['fundo']),
    textColor: _optionalColor(j['cor_texto']),
    esquerda: j['esquerda'] == true,
    flow: j['fluxo'] as String? ?? '',
  );

  final NodeKind type;

  /// Left-aligned text (draw.io technical blocks); otherwise, centered.
  final bool esquerda;
  final String text;
  final Offset a, b;
  final Color color;
  final Color? background, textColor;
  final String flow;

  Rect get retangulo => Rect.fromPoints(a, b);

  /// Container title band (where it is grabbed to move; the middle lets selecting what is inside).
  static const titleHeight = 28.0;

  @override
  Rect get bounds => retangulo.inflate(4);

  @override
  bool touches(Offset q, double radius) {
    final r = retangulo;
    if (type != NodeKind.container) return r.inflate(radius).contains(q);
    final band = Rect.fromLTWH(r.left, r.top, r.width, titleHeight);
    return band.inflate(radius).contains(q) || (r.inflate(radius).contains(q) && !r.deflate(radius + 4).contains(q));
  }

  @override
  List<Offset> get samples => [retangulo.topLeft, retangulo.bottomRight, retangulo.center];

  FlowNode copy({
    NodeKind? type,
    String? text,
    Offset? a,
    Offset? b,
    Color? color,
    Color? background,
    Color? textColor,
    bool noBackground = false,
    bool noTextColor = false,
    bool? esquerda,
    String? id,
    String? group,
  }) => FlowNode(
    id ?? this.id,
    group: group ?? this.group,
    type: type ?? this.type,
    text: text ?? this.text,
    a: a ?? this.a,
    b: b ?? this.b,
    color: color ?? this.color,
    background: noBackground ? null : (background ?? this.background),
    textColor: noTextColor ? null : (textColor ?? this.textColor),
    esquerda: esquerda ?? this.esquerda,
    flow: flow,
  );

  @override
  FlowNode transform(Offset Function(Offset) f, {double factor = 1, String? id, Color? color, String? group}) =>
      copy(id: id, a: f(a), b: f(b), color: color, group: group);

  FlowNode withText(String isNew) => copy(text: isNew);

  FlowNode withRect(Rect r) => copy(a: r.topLeft, b: r.bottomRight);

  /// Point on the block border in the direction of [target] (diamond for decision, ellipse for circle, rectangle
  /// nos demais).
  Offset edge(Offset target) {
    final r = retangulo, c = r.center, d = target - c;
    if (d.distance < 1) return c;
    final hw = r.width / 2, hh = r.height / 2;
    final t = switch (type) {
      NodeKind.decisao => 1 / (d.dx.abs() / hw + d.dy.abs() / hh),
      NodeKind.circulo => 1 / sqrt(pow(d.dx / hw, 2) + pow(d.dy / hh, 2)),
      _ => 1 / max(d.dx.abs() / hw, d.dy.abs() / hh),
    };
    return c + d * t;
  }

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    if (group.isNotEmpty) 'grupo': group,
    'tipo': 'no',
    'no': type.name,
    'texto': text,
    'a': [_round(a.dx), _round(a.dy)],
    'b': [_round(b.dx), _round(b.dy)],
    'cor': color.toARGB32(),
    if (background != null) 'fundo': background!.toARGB32(),
    if (textColor != null) 'cor_texto': textColor!.toARGB32(),
    if (esquerda) 'esquerda': true,
    'fluxo': flow,
  };
}

enum LineKind {
  continua('Contínua'),
  tracejada('Tracejada'),
  pontilhada('Pontilhada');

  const LineKind(this.label);

  final String label;

  static LineKind de(String? name) => values.where((t) => t.name == name).firstOrNull ?? continua;
}

/// Figure at the arrow tip; the "vazadas" ones have only the outline.
enum TipKind {
  nenhuma('Nenhuma'),
  seta('Seta'),
  setaVazada('Seta vazada'),
  aberta('Seta aberta'),
  circulo('Círculo'),
  circuloVazado('Círculo vazado'),
  losango('Losango'),
  losangoVazado('Losango vazado');

  const TipKind(this.label);

  final String label;

  static TipKind de(String? name, TipKind standard) => values.where((t) => t.name == name).firstOrNull ?? standard;
}

/// Sides of a block where the arrow can leave/arrive (index = the side of [orthogonalRoute]).
const blockSides = ['Cima', 'Direita', 'Baixo', 'Esquerda'];

/// Arrow from a block [from] to another [to], with [label] ("Sim", "Não"…). [a]/[b] are the tips already
/// computed on the block borders; [reconnect] redoes them when a block moves. [orthogonal]: at a
/// right angle (like draw.io), leaving from the middle of a side of the block.
class Connector extends Elemento {
  const Connector(
    super.id, {
    super.group,
    required this.de,
    required this.to,
    required this.a,
    required this.b,
    required this.color,
    this.label = '',
    this.flow = '',
    this.orthogonal = false,
    this.line = LineKind.continua,
    this.thickness = 2,
    this.startTip = TipKind.nenhuma,
    this.endTip = TipKind.seta,
    this.sideOf,
    this.sideTo,
    this.pontos = const [],
  });

  factory Connector.fromJson(Map<String, dynamic> j) => Connector(
    j['id'] as String,
    de: j['de'] as String? ?? '',
    to: j['para'] as String? ?? '',
    a: StrokePoint.fromJson(j['a'] as List).offset,
    b: StrokePoint.fromJson(j['b'] as List).offset,
    color: _color(j['cor']),
    label: j['rotulo'] as String? ?? '',
    flow: j['fluxo'] as String? ?? '',
    orthogonal: j['ortogonal'] == true,
    line: j['linha'] == null && j['tracejada'] == true ? LineKind.tracejada : LineKind.de(j['linha'] as String?),
    thickness: (j['espessura'] as num? ?? 2).toDouble(),
    startTip: TipKind.de(j['ponta_inicio'] as String?, TipKind.nenhuma),
    endTip: TipKind.de(j['ponta_fim'] as String?, TipKind.seta),
    sideOf: j['lado_de'] as int?,
    sideTo: j['lado_para'] as int?,
    pontos: [for (final p in j['pontos'] as List? ?? const []) StrokePoint.fromJson(p as List).offset],
  );

  final String de, to, label, flow;
  final Offset a, b;
  final Color color;
  final bool orthogonal;
  final LineKind line;
  final double thickness;
  final TipKind startTip, endTip;

  /// Fixed exit/arrival side (0 top, 1 right, 2 bottom, 3 left); null = automatic.
  final int? sideOf, sideTo;

  bool get tracejada => line != LineKind.continua;

  /// Bends of the route that avoids the blocks (between [a] and [b]); empty = simple route.
  final List<Offset> pontos;

  /// Path points: the route computed by [reconnect] (avoids the blocks), or straight (a, b), or
  /// L/Z when [orthogonal] without a route.
  List<Offset> get path {
    if (orthogonal && pontos.isNotEmpty) return [a, ...pontos, b];
    if (!orthogonal || a.dx == b.dx || a.dy == b.dy) return [a, b];
    final d = b - a;
    if (d.dy.abs() >= d.dx.abs()) {
      final y = (a.dy + b.dy) / 2;
      return [a, Offset(a.dx, y), Offset(b.dx, y), b];
    }
    final x = (a.dx + b.dx) / 2;
    return [a, Offset(x, a.dy), Offset(x, b.dy), b];
  }

  /// Where the label goes: in the middle of the longest straight segment (near the exit, if the arrow is short).
  Offset get middle {
    final c = path;
    if (c.length == 2) return a + (b - a) * 0.45;
    var larger = 0;
    for (var i = 1; i < c.length - 1; i++) {
      if ((c[i + 1] - c[i]).distance > (c[larger + 1] - c[larger]).distance) larger = i;
    }
    return (c[larger] + c[larger + 1]) / 2;
  }

  @override
  Rect get bounds => path.skip(1).fold(Rect.fromPoints(a, a), (r, p) => r.expandToInclude(Rect.fromPoints(p, p))).inflate(16);

  @override
  bool touches(Offset q, double radius) {
    final c = path;
    for (var i = 0; i < c.length - 1; i++) {
      if (distanceToSegment(q, c[i], c[i + 1]) <= radius + 3) return true;
    }
    return false;
  }

  @override
  List<Offset> get samples => [a, b, middle];

  Connector copy({
    String? id,
    String? de,
    String? to,
    Offset? a,
    Offset? b,
    Color? color,
    String? label,
    bool? orthogonal,
    LineKind? line,
    double? thickness,
    TipKind? startTip,
    TipKind? endTip,
    int? sideOf,
    int? sideTo,
    bool autoSideOf = false,
    bool autoSideTo = false,
    List<Offset>? pontos,
    String? group,
  }) =>
      Connector(
        id ?? this.id,
        group: group ?? this.group,
        de: de ?? this.de,
        to: to ?? this.to,
        a: a ?? this.a,
        b: b ?? this.b,
        color: color ?? this.color,
        label: label ?? this.label,
        flow: flow,
        orthogonal: orthogonal ?? this.orthogonal,
        line: line ?? this.line,
        thickness: thickness ?? this.thickness,
        startTip: startTip ?? this.startTip,
        endTip: endTip ?? this.endTip,
        sideOf: autoSideOf ? null : sideOf ?? this.sideOf,
        sideTo: autoSideTo ? null : sideTo ?? this.sideTo,
        pontos: pontos ?? this.pontos,
      );

  @override
  Connector transform(Offset Function(Offset) f, {double factor = 1, String? id, Color? color, String? group}) =>
      copy(id: id, a: f(a), b: f(b), color: color, group: group, pontos: [for (final p in pontos) f(p)]);

  Connector withTips(Offset na, Offset nb, [List<Offset> route = const []]) => copy(a: na, b: nb, pontos: route);

  Connector withBlocks(String nde, String npara) => copy(de: nde, to: npara);

  /// The same arrow in the opposite direction (tips, sides and figures swap together).
  Connector inverted() => Connector(
    id,
    group: group,
    de: to,
    to: de,
    a: b,
    b: a,
    color: color,
    label: label,
    flow: flow,
    orthogonal: orthogonal,
    line: line,
    thickness: thickness,
    startTip: endTip,
    endTip: startTip,
    sideOf: sideTo,
    sideTo: sideOf,
    pontos: pontos.reversed.toList(),
  );

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    if (group.isNotEmpty) 'grupo': group,
    'tipo': 'ligacao',
    'de': de,
    'para': to,
    'rotulo': label,
    'a': [_round(a.dx), _round(a.dy)],
    'b': [_round(b.dx), _round(b.dy)],
    'cor': color.toARGB32(),
    'fluxo': flow,
    if (orthogonal) 'ortogonal': true,
    if (tracejada) 'tracejada': true,
    if (line != LineKind.continua) 'linha': line.name,
    if (thickness != 2) 'espessura': thickness,
    if (startTip != TipKind.nenhuma) 'ponta_inicio': startTip.name,
    if (endTip != TipKind.seta) 'ponta_fim': endTip.name,
    if (sideOf != null) 'lado_de': sideOf,
    if (sideTo != null) 'lado_para': sideTo,
    if (pontos.isNotEmpty) 'pontos': [for (final p in pontos) [_round(p.dx), _round(p.dy)]],
  };
}

/// Cell of the [BoardTable]. null [background]/[textColor] = default (on the header row, gray and bold);
/// [alinhamento]: 0 esquerda, 1 centro, 2 direita.
class Cell {
  const Cell({this.text = '', this.background, this.textColor, this.bold = false, this.alignmentMode = 0});

  factory Cell.fromJson(Map<String, dynamic> j) => Cell(
    text: j['texto'] as String? ?? '',
    background: _optionalColor(j['fundo']),
    textColor: _optionalColor(j['cor_texto']),
    bold: j['negrito'] == true,
    alignmentMode: j['alinhamento'] as int? ?? 0,
  );

  final String text;
  final Color? background, textColor;
  final bool bold;
  final int alignmentMode;

  Cell copy({String? text, Color? background, Color? textColor, bool noBackground = false, bool noTextColor = false, bool? bold, int? alignmentMode}) =>
      Cell(
        text: text ?? this.text,
        background: noBackground ? null : background ?? this.background,
        textColor: noTextColor ? null : textColor ?? this.textColor,
        bold: bold ?? this.bold,
        alignmentMode: alignmentMode ?? this.alignmentMode,
      );

  Map<String, dynamic> toJson() => {
    if (text.isNotEmpty) 'texto': text,
    if (background != null) 'fundo': background!.toARGB32(),
    if (textColor != null) 'cor_texto': textColor!.toARGB32(),
    if (bold) 'negrito': true,
    if (alignmentMode != 0) 'alinhamento': alignmentMode,
  };
}

/// Table on the board: corner [origin], column [widths], row [heights] and [cells]
/// (`[row][column]`). [color] is the grid; [header] highlights the first row.
class BoardTable extends Elemento {
  const BoardTable(
    super.id, {
    super.group,
    required this.origin,
    required this.widths,
    required this.heights,
    required this.cells,
    required this.color,
    this.size = 16,
    this.header = true,
  });

  /// Empty table of [lines] × [columns] already at the minimum size.
  factory BoardTable.nova(String id, Offset origin, int linhas, int columns, {Color color = const Color(0xFF455A64)}) =>
      BoardTable(
        id,
        origin: origin,
        widths: List.filled(columns, 0),
        heights: List.filled(linhas, 0),
        cells: [for (var l = 0; l < linhas; l++) List.filled(columns, const Cell())],
        color: color,
      ).fitted();

  factory BoardTable.fromJson(Map<String, dynamic> j) {
    final cells = [
      for (final l in j['celulas'] as List? ?? const [])
        [for (final c in l as List) Cell.fromJson(c as Map<String, dynamic>)],
    ];
    final columns = cells.isEmpty ? 0 : cells.first.length;
    List<double> sizes(Object? v, int n, double standard) {
      final items = [for (final x in v as List? ?? const []) (x as num).toDouble()];
      return [for (var i = 0; i < n; i++) i < items.length ? items[i] : standard];
    }

    return BoardTable(
      j['id'] as String,
      origin: StrokePoint.fromJson(j['origem'] as List).offset,
      widths: sizes(j['larguras'], columns, 100),
      heights: sizes(j['alturas'], cells.length, 32),
      cells: [for (final l in cells) [for (var c = 0; c < columns; c++) c < l.length ? l[c] : const Cell()]],
      color: _color(j['cor']),
      size: (j['tamanho'] as num? ?? 16).toDouble(),
      header: j['cabecalho'] as bool? ?? true,
    );
  }

  final Offset origin;
  final List<double> widths, heights;
  final List<List<Cell>> cells;
  final Color color;
  final double size;
  final bool header;

  int get linhas => heights.length;
  int get columns => widths.length;

  Rect get retangulo => origin & Size(widths.fold(0.0, (a, b) => a + b), heights.fold(0.0, (a, b) => a + b));

  /// Rectangle of cell [l],[c] in the world.
  Rect cell(int l, int c) {
    var x = origin.dx, y = origin.dy;
    for (var i = 0; i < c; i++) {
      x += widths[i];
    }
    for (var i = 0; i < l; i++) {
      y += heights[i];
    }
    return Rect.fromLTWH(x, y, widths[c], heights[l]);
  }

  @override
  Rect get bounds => retangulo.inflate(2);

  @override
  bool touches(Offset q, double radius) => retangulo.inflate(radius).contains(q);

  @override
  List<Offset> get samples => [retangulo.topLeft, retangulo.bottomRight, retangulo.center];

  BoardTable copy({
    String? id,
    String? group,
    Offset? origin,
    List<double>? widths,
    List<double>? heights,
    List<List<Cell>>? cells,
    Color? color,
    double? size,
    bool? header,
  }) => BoardTable(
    id ?? this.id,
    group: group ?? this.group,
    origin: origin ?? this.origin,
    widths: widths ?? this.widths,
    heights: heights ?? this.heights,
    cells: cells ?? this.cells,
    color: color ?? this.color,
    size: size ?? this.size,
    header: header ?? this.header,
  );

  /// Widths and heights that fit the text of each column/row (estimate without layout, as in [BoardText]).
  BoardTable fitted() {
    final slack = size * 0.8;
    double width(String t) => t.split('\n').map((l) => l.length).fold(0, max) * size * 0.62 + slack * 2;
    double height(String t) => '\n'.allMatches(t).length.toDouble() * size * 1.3 + size * 1.3 + slack;
    return copy(
      widths: [
        for (var c = 0; c < columns; c++)
          cells.map((l) => width(l[c].text)).fold(size * 5, max),
      ],
      heights: [for (final l in cells) l.map((c) => height(c.text)).fold(size * 2, max)],
    );
  }

  @override
  BoardTable transform(Offset Function(Offset) f, {double factor = 1, String? id, Color? color, String? group}) => copy(
    id: id,
    group: group,
    color: color,
    origin: f(origin),
    widths: factor == 1 ? null : [for (final w in widths) w * factor],
    heights: factor == 1 ? null : [for (final h in heights) h * factor],
    size: size * factor,
  );

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    if (group.isNotEmpty) 'grupo': group,
    'tipo': 'tabela',
    'origem': [_round(origin.dx), _round(origin.dy)],
    'larguras': [for (final w in widths) _round(w)],
    'alturas': [for (final h in heights) _round(h)],
    'celulas': [
      for (final l in cells) [for (final c in l) c.toJson()],
    ],
    'cor': color.toARGB32(),
    'tamanho': size,
    if (!header) 'cabecalho': false,
  };
}

/// Orthogonal arrow tips: middle of the side of each block facing the other (top/bottom if the
/// vertical distance dominates, otherwise left/right).
(Offset, Offset) _orthogonalTips(FlowNode de, FlowNode to) {
  final r1 = de.retangulo, r2 = to.retangulo;
  final d = r2.center - r1.center;
  if (d.dy.abs() >= d.dx.abs()) {
    return d.dy >= 0 ? (r1.bottomCenter, r2.topCenter) : (r1.topCenter, r2.bottomCenter);
  }
  return d.dx >= 0 ? (r1.centerRight, r2.centerLeft) : (r1.centerLeft, r2.centerRight);
}

/// Redoes the connector tips from the current block positions and drops those that lost one of the
/// blocks (erased). The orthogonal ones get the route that avoids the other blocks ([orthogonalRoute]).
/// With [blocksOnly], only the arrows connected to those blocks are recomputed (live drag). With
/// [keepReady], arrows that already have tips stay as they were saved (only those without tips are computed).
List<Elemento> reconnect(List<Elemento> elements, {Set<String>? blocksOnly, bool keepReady = false}) {
  if (!elements.any((e) => e is Connector)) return elements;
  final nos = {for (final e in elements.whereType<FlowNode>()) e.id: e};
  // Containers and lanes are not obstacles: arrows go through them.
  final obstacles = [for (final n in nos.values) if (n.type != NodeKind.container) n];
  final exit = <Elemento>[];
  for (final e in elements) {
    if (e is! Connector) {
      exit.add(e);
      continue;
    }
    final de = nos[e.de], to = nos[e.to];
    if (de == null || to == null) continue;
    if ((keepReady && e.a != e.b) ||
        (blocksOnly != null && !blocksOnly.contains(e.de) && !blocksOnly.contains(e.to))) {
      exit.add(e);
      continue;
    }
    if (e.orthogonal) {
      final others = [
        for (final o in obstacles)
          if (o.id != de.id && o.id != to.id && !_contains(o, de) && !_contains(o, to)) o.retangulo,
      ];
      final route = orthogonalRoute(
        de.retangulo,
        to.retangulo,
        others,
        straightFrom: _straightSides(de),
        straightTo: _straightSides(to),
        sideOf: e.sideOf,
        sideTo: e.sideTo,
      );
      if (route != null && route.length >= 2) {
        exit.add(e.withTips(route.first, route.last, route.sublist(1, route.length - 1)));
        continue;
      }
      final (na, nb) = _orthogonalTips(de, to);
      exit.add(e.withTips(_side(de, e.sideOf) ?? na, _side(to, e.sideTo) ?? nb));
      continue;
    }
    final na = _side(de, e.sideOf) ?? de.edge(to.retangulo.center);
    final nb = _side(to, e.sideTo) ?? to.edge(de.retangulo.center);
    exit.add(na == e.a && nb == e.b && e.pontos.isEmpty ? e : e.withTips(na, nb));
  }
  return exit;
}

/// Middle of the block [side] (null = automatic).
Offset? _side(FlowNode n, int? side) => switch (side) {
  0 => n.retangulo.topCenter,
  1 => n.retangulo.centerRight,
  2 => n.retangulo.bottomCenter,
  3 => n.retangulo.centerLeft,
  _ => null,
};

bool _straightSides(FlowNode n) => switch (n.type) {
  NodeKind.decisao || NodeKind.circulo || NodeKind.hexagono || NodeKind.dado => false,
  _ => true,
};

/// Does [outer] wrap [inside]? (a block inside another is not an obstacle for its own arrows)
bool _contains(FlowNode fora, FlowNode inside) =>
    fora.retangulo.contains(inside.retangulo.topLeft) && fora.retangulo.contains(inside.retangulo.bottomRight);

/// Elements entirely inside container [c] (they go along when it moves).
Iterable<Elemento> inside(FlowNode c, Iterable<Elemento> elements) => elements.where(
  (e) => e.id != c.id && e is! Connector && c.retangulo.inflate(1).contains(e.bounds.deflate(4).topLeft) &&
      c.retangulo.inflate(1).contains(e.bounds.deflate(4).bottomRight),
);

/// Even-odd rule: counts how many edges a horizontal ray from [q] crosses.
bool pointInPolygon(Offset q, List<Offset> polygon) {
  var inside = false;
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final a = polygon[i], b = polygon[j];
    if ((a.dy > q.dy) != (b.dy > q.dy) && q.dx < (b.dx - a.dx) * (q.dy - a.dy) / (b.dy - a.dy) + a.dx) {
      inside = !inside;
    }
  }
  return inside;
}

/// Union of the bounds (null when empty).
Rect? boundsOf(Iterable<Elemento> elements) =>
    elements.isEmpty ? null : elements.map((e) => e.bounds).reduce((a, b) => a.expandToInclude(b));

double distanceToSegment(Offset q, Offset a, Offset b) {
  final ab = b - a;
  final lengthSquared = ab.dx * ab.dx + ab.dy * ab.dy;
  if (lengthSquared == 0) return (q - a).distance;
  final t = (((q - a).dx * ab.dx + (q - a).dy * ab.dy) / lengthSquared).clamp(0.0, 1.0);
  return (q - (a + ab * t)).distance;
}

/// Gallery row (without the elements).
class BoardSummary {
  BoardSummary.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      title = j['titulo'] as String? ?? '',
      background = Background.de(j['fundo'] as String?),
      pasta = j['pasta'] as String? ?? '',
      updated = DateTime.tryParse(j['atualizado'] as String? ?? '')?.toLocal(),
      version = j['versao'] as int? ?? 1,
      total = j['total'] as int? ?? (j['elementos'] as List?)?.length ?? 0,
      thumbnail = j['miniatura'] as bool? ?? false,
      pages = [
        for (final p in j['paginas'] as List? ?? const [])
          BoardPage(
            '${(p as Map)['id']}',
            '${p['nome']}',
            color: p['cor'] is int ? Color(p['cor'] as int) : null,
            role: p['papel'] is Map ? Paper.fromJson((p['papel'] as Map).cast<String, dynamic>()) : null,
          ),
      ],
      _json = j;

  final String id, title, pasta;

  /// Board tabs (like draw.io pages); empty = a single page.
  final List<BoardPage> pages;
  final Background background;
  final DateTime? updated;
  final int version, total;
  final bool thumbnail;
  final Map<String, dynamic> _json;

  /// As it came from the server, without the elements (for the offline cache).
  Map<String, dynamic> toJson() => {..._json}..remove('elementos');
}

class Board {
  Board.fromJson(Map<String, dynamic> j)
    : summary = BoardSummary.fromJson(j),
      elements = [for (final e in j['elementos'] as List? ?? const []) ?Elemento.fromJson(e as Map<String, dynamic>)],
      pageOf = elementPages(j['elementos'] as List? ?? const []);

  final BoardSummary summary;
  final List<Elemento> elements;

  /// Page of each element (id → page id); those not here stay on the first one.
  final Map<String, String> pageOf;
}

/// Tab of a board.
class BoardPage {
  const BoardPage(this.id, this.name, {this.color, this.role});

  final String id, name;

  /// Tab marking color (null = no color).
  final Color? color;

  /// Notebook sheet of this page (null on boards: infinite board).
  final Paper? role;

  BoardPage copy({String? name, Color? color, bool noColor = false, Paper? role}) =>
      BoardPage(id, name ?? this.name, color: noColor ? null : color ?? this.color, role: role ?? this.role);

  Map<String, dynamic> toJson() => {
    'id': id,
    'nome': name,
    if (color != null) 'cor': color!.toARGB32(),
    if (role != null) 'papel': role!.toJson(),
  };
}

/// Notebook sheet: ruling ([background]), distance between lines/dots, size (world, logical px at
/// 96 dpi: A4 = 794 × 1123), paper color and margin line.
class Paper {
  const Paper({
    this.background = Background.linhas,
    this.space = 28,
    this.width = 794,
    this.height = 1123,
    this.color = const Color(0xFFFFFFFF),
    this.margin = true,
  });

  factory Paper.fromJson(Map<String, dynamic> j) => Paper(
    background: Background.de(j['fundo'] as String?),
    space: (j['espaco'] as num? ?? 28).toDouble().clamp(8, 120),
    width: (j['largura'] as num? ?? 794).toDouble().clamp(200, 6000),
    height: (j['altura'] as num? ?? 1123).toDouble().clamp(200, 6000),
    color: j['cor'] is int ? Color(j['cor'] as int) : const Color(0xFFFFFFFF),
    margin: j['margem'] as bool? ?? true,
  );

  final Background background;
  final double space, width, height;
  final Color color;
  final bool margin;

  Rect get retangulo => Rect.fromLTWH(0, 0, width, height);

  /// Indent of the left margin and the header (where writing starts).
  double get indent => margin ? space * 2.5 : space;

  Paper copy({Background? background, double? space, double? width, double? height, Color? color, bool? margin}) => Paper(
    background: background ?? this.background,
    space: space ?? this.space,
    width: width ?? this.width,
    height: height ?? this.height,
    color: color ?? this.color,
    margin: margin ?? this.margin,
  );

  Map<String, dynamic> toJson() => {
    'fundo': background.name,
    'espaco': space,
    'largura': width,
    'altura': height,
    'cor': color.toARGB32(),
    'margem': margin,
  };

  @override
  bool operator ==(Object other) =>
      other is Paper &&
      other.background == background &&
      other.space == space &&
      other.width == width &&
      other.height == height &&
      other.color == color &&
      other.margin == margin;

  @override
  int get hashCode => Object.hash(background, space, width, height, color, margin);
}

/// The element JSON with its page (elements do not know their own page: the editor keeps it).
Map<String, dynamic> jsonWithPage(Elemento e, Map<String, String> pageOf) {
  final j = e.toJson();
  final p = pageOf[e.id];
  if (p != null && p.isNotEmpty) j['pagina'] = p;
  return j;
}

Map<String, String> elementPages(List<dynamic> raw) => {
  for (final e in raw)
    if (e is Map && e['pagina'] is String && (e['pagina'] as String).isNotEmpty) '${e['id']}': e['pagina'] as String,
};

/// Merges what this device has with the version another device saved: everything that is
/// local stays, plus what only exists remotely and was not erased here ([erasedHere]).
List<Elemento> merge(List<Elemento> local, List<Elemento> remote, Set<String> erasedHere) {
  final ids = {for (final e in local) e.id};
  return [...remote.where((e) => !ids.contains(e.id) && !erasedHere.contains(e.id)), ...local];
}
