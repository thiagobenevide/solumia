import 'dart:math' as math;
import 'dart:ui';

/// Wireframe legend: blue = already exists, amber = proposed, red = divergence.
enum WfState {
  existe('Existe'),
  proposto('Proposto'),
  divergencia('Divergência');

  const WfState(this.label);
  final String label;

  static WfState de(Object? s) => values.firstWhere((e) => e.name == s, orElse: () => existe);
}

/// Item of a screen's side panel (component, click, endpoint), linked to the components by [n].
class StickyNote {
  StickyNote(this.n, {this.state = WfState.existe, this.title = '', this.linhas = const []});

  factory StickyNote.fromJson(Map<String, dynamic> j) => StickyNote(
    j['n'] as int? ?? 0,
    state: WfState.de(j['estado']),
    title: '${j['titulo'] ?? ''}',
    linhas: [
      for (final l in j['linhas'] as List? ?? const []) ('${(l as Map)['rotulo'] ?? ''}', '${l['texto'] ?? ''}'),
    ],
  );

  int n;
  WfState state;
  String title;

  /// (label, text); empty label = running text.
  List<(String, String)> linhas;

  Map<String, dynamic> toJson() => {
    'n': n,
    'estado': state.name,
    'titulo': title,
    'linhas': [for (final (r, t) in linhas) {'rotulo': r, 'texto': t}],
  };

  /// One line per item; `Label: text` becomes a label, the rest is running text.
  String get textLines => [for (final (r, t) in linhas) r.isEmpty ? t : '$r: $t'].join('\n');

  set textLines(String s) => linhas = [
    for (final l in s.split('\n'))
      if (l.trim().isNotEmpty)
        switch (RegExp(r'^([^:]{1,30}):\s(.*)$').firstMatch(l)) {
          final m? => (m[1]!.trim(), m[2]!.trim()),
          null => ('', l.trim()),
        },
  ];
}

/// A screen of the wireframe (a "page" of the document on the server).
class WfScreen {
  WfScreen.fromJson(Map<String, dynamic> j)
    : id = '${j['id']}',
      name = '${j['nome'] ?? ''}',
      code = '${j['codigo'] ?? ''}',
      subtitle = '${j['subtitulo'] ?? ''}',
      path = [for (final c in j['caminho'] as List? ?? const []) '$c'],
      width = (j['largura'] as num? ?? 1280).toDouble(),
      height = (j['altura'] as num? ?? 1080).toDouble(),
      notas = [for (final n in j['notas'] as List? ?? const []) StickyNote.fromJson(n as Map<String, dynamic>)],
      _json = j;

  final String id;
  String name, code, subtitle;
  List<String> path;
  double width, height;
  List<StickyNote> notas;
  final Map<String, dynamic> _json;

  Map<String, dynamic> toJson() => {
    ..._json,
    'id': id,
    'nome': name,
    'codigo': code,
    'subtitulo': subtitle,
    'caminho': path,
    'largura': width,
    'altura': height,
    'notas': [for (final n in notas) n.toJson()],
  };
}

/// Component placed in the usable area of the window. [props] follow the catalog of `wireframe_ia.py`.
class WfComponent {
  WfComponent({
    required this.id,
    required this.type,
    required this.page,
    required this.box,
    this.state = WfState.existe,
    Map<String, dynamic>? props,
  }) : props = props ?? {};

  factory WfComponent.fromJson(Map<String, dynamic> j) => WfComponent(
    id: '${j['id']}',
    type: '${j['tipo']}',
    page: '${j['pagina'] ?? ''}',
    box: Rect.fromLTWH(
      (j['x'] as num? ?? 0).toDouble(),
      (j['y'] as num? ?? 0).toDouble(),
      (j['w'] as num? ?? 0).toDouble(),
      (j['h'] as num? ?? 0).toDouble(),
    ),
    state: WfState.de(j['estado']),
    props: Map<String, dynamic>.of(j['props'] as Map<String, dynamic>? ?? const {}),
  );

  final String id, type;
  String page;
  Rect box;
  WfState state;
  Map<String, dynamic> props;

  int? get nota => props['nota'] as int?;

  Map<String, dynamic> toJson() => {
    'id': id,
    'tipo': type,
    'pagina': page,
    'x': box.left,
    'y': box.top,
    'w': box.width,
    'h': box.height,
    'estado': state.name,
    'props': props,
  };

  WfComponent copyItems({String? id, Offset shift = Offset.zero}) => WfComponent.fromJson(
    toJson()..addAll({'id': ?id, 'x': box.left + shift.dx, 'y': box.top + shift.dy}),
  )..props = _deepCopy(props) as Map<String, dynamic>;
}

Object? _deepCopy(Object? v) => switch (v) {
  final Map m => {for (final e in m.entries) '${e.key}': _deepCopy(e.value)},
  final List l => [for (final x in l) _deepCopy(x)],
  _ => v,
};

/// Catalog types: label, initial size and initial props (the same keys as the schema).
const catalog = <String, (String, Size, Map<String, dynamic>)>{
  'texto': ('Texto', Size(320, 24), {'texto': 'Título da tela', 'tamanho': 18, 'negrito': true, 'cor': 'tinta'}),
  'botao': ('Botão', Size(120, 32), {'texto': 'Salvar', 'variante': 'primario', 'icone': ''}),
  'botao_icone': ('Botão ícone', Size(32, 32), {'icone': '⟳'}),
  'campo': (
    'Campo',
    Size(240, 46),
    {'rotulo': 'Rótulo', 'valor': '', 'somente_leitura': false, 'busca': false, 'combo': false, 'obrigatorio': false},
  ),
  'caixa': ('Caixa de marcação', Size(160, 20), {'marcado': false, 'texto': 'Opção'}),
  'selo': ('Selo', Size(110, 18), {'texto': '01 Aprovada', 'cor': 'azul'}),
  'abas': (
    'Abas',
    Size(600, 36),
    {
      'itens': [
        {'texto': 'Aba 1', 'estado': 'existe'},
        {'texto': 'Aba 2', 'estado': 'existe'},
      ],
      'ativa': 0,
    },
  ),
  'cartoes': (
    'Cartões',
    Size(800, 66),
    {
      'itens': [
        {'rotulo': 'Total', 'valor': 'R\$ 0,00'},
        {'rotulo': 'Saldo', 'valor': 'R\$ 0,00'},
      ],
    },
  ),
  'tabela': (
    'Tabela',
    Size(400, 90),
    {
      'colunas': [
        {'titulo': 'Código', 'largura': 120},
        {'titulo': 'Descrição', 'largura': 200},
        {'titulo': 'Status', 'largura': 80},
      ],
      'linhas': [
        ['000001', 'Item', {'texto': 'Ativo', 'selo': 'verde'}],
        ['000002', 'Item', {'texto': 'Inativo', 'selo': 'cinza'}],
      ],
      'destaque': null,
      'altura_linha': 30,
    },
  ),
  'paginador': ('Paginador', Size(410, 26), {'info': 'Página 1 de 1 · 2 registros'}),
  'menu': (
    'Menu',
    Size(240, 72),
    {
      'itens': [
        {'texto': 'Editar', 'estado': 'existe'},
        {'texto': 'Excluir', 'estado': 'existe'},
      ],
    },
  ),
  'modal': ('Modal', Size(640, 420), {'titulo': 'Título do modal'}),
  'painel': ('Painel', Size(400, 200), {'titulo': '', 'fundo': 'branco'}),
  'seta': (
    'Seta',
    Size(120, 40),
    {
      'pontos': [
        [0, 0],
        [120, 40],
      ],
      'cor': 'suave',
    },
  ),
};

/// Options of the closed-list props (dropdown in the properties panel).
const propOptions = <String, List<String>>{
  'variante': ['primario', 'secundario', 'perigo', 'sucesso', 'fantasma'],
  'cor': ['tinta', 'suave', 'branco', 'azul', 'ambar', 'vermelho', 'verde', 'roxo', 'ciano', 'cinza'],
  'selo': ['azul', 'ambar', 'vermelho', 'verde', 'roxo', 'ciano', 'cinza'],
  'fundo': ['branco', 'cinza', 'azul', 'ambar', 'vermelho', 'verde', 'roxo', 'ciano'],
};

/// Table, menu and arrow have a content-driven size: fixes the [WfComponent.box] after editing.
void fitSize(WfComponent c) {
  final p = c.props;
  final o = c.box.topLeft;
  switch (c.type) {
    case 'tabela':
      final cols = p['colunas'] as List? ?? const [];
      final w = cols.fold<double>(0, (s, col) => s + ((col as Map)['largura'] as num? ?? 0).toDouble());
      final h = (p['altura_linha'] as num? ?? 30).toDouble() * ((p['linhas'] as List? ?? const []).length + 1);
      c.box = Rect.fromLTWH(o.dx, o.dy, w, h);
    case 'menu':
      c.box = Rect.fromLTWH(o.dx, o.dy, c.box.width, 32.0 * (p['itens'] as List? ?? const []).length + 8);
    case 'seta':
      final pts = [for (final q in p['pontos'] as List? ?? const []) Offset(((q as List)[0] as num).toDouble(), (q[1] as num).toDouble())];
      if (pts.isEmpty) return;
      final w = pts.map((q) => q.dx).reduce(math.max), h = pts.map((q) => q.dy).reduce(math.max);
      c.box = Rect.fromLTWH(o.dx, o.dy, math.max(w, 8), math.max(h, 8));
  }
}

class Wireframe {
  Wireframe.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      title = '${j['titulo'] ?? ''}',
      version = j['versao'] as int? ?? 1,
      screens = [for (final p in j['paginas'] as List? ?? const []) WfScreen.fromJson(p as Map<String, dynamic>)],
      components = [for (final e in j['elementos'] as List? ?? const []) WfComponent.fromJson(e as Map<String, dynamic>)] {
    if (screens.isEmpty) screens.add(WfScreen.fromJson({'id': 'tela-1', 'nome': 'Tela 1', 'codigo': 'WF-01'}));
    // Sem `pagina` = primeira tela (mesma regra dos quadros).
    for (final c in components) {
      if (c.page.isEmpty) c.page = screens.first.id;
    }
  }

  final String id;
  String title;
  int version;
  final List<WfScreen> screens;
  final List<WfComponent> components;
}
