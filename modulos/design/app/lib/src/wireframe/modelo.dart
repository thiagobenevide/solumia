import 'dart:math' as math;
import 'dart:ui';

/// Legenda dos wireframes: azul = já existe, âmbar = proposto, vermelho = divergência.
enum EstadoWf {
  existe('Existe'),
  proposto('Proposto'),
  divergencia('Divergência');

  const EstadoWf(this.rotulo);
  final String rotulo;

  static EstadoWf de(Object? s) => values.firstWhere((e) => e.name == s, orElse: () => existe);
}

/// Item do painel lateral de uma tela (componente, clique, endpoint), ligado aos componentes por [n].
class Nota {
  Nota(this.n, {this.estado = EstadoWf.existe, this.titulo = '', this.linhas = const []});

  factory Nota.fromJson(Map<String, dynamic> j) => Nota(
    j['n'] as int? ?? 0,
    estado: EstadoWf.de(j['estado']),
    titulo: '${j['titulo'] ?? ''}',
    linhas: [
      for (final l in j['linhas'] as List? ?? const []) ('${(l as Map)['rotulo'] ?? ''}', '${l['texto'] ?? ''}'),
    ],
  );

  int n;
  EstadoWf estado;
  String titulo;

  /// (rótulo, texto); rótulo vazio = texto corrido.
  List<(String, String)> linhas;

  Map<String, dynamic> toJson() => {
    'n': n,
    'estado': estado.name,
    'titulo': titulo,
    'linhas': [for (final (r, t) in linhas) {'rotulo': r, 'texto': t}],
  };

  /// Uma linha por item; `Rótulo: texto` vira rótulo, o resto é texto corrido.
  String get linhasTexto => [for (final (r, t) in linhas) r.isEmpty ? t : '$r: $t'].join('\n');

  set linhasTexto(String s) => linhas = [
    for (final l in s.split('\n'))
      if (l.trim().isNotEmpty)
        switch (RegExp(r'^([^:]{1,30}):\s(.*)$').firstMatch(l)) {
          final m? => (m[1]!.trim(), m[2]!.trim()),
          null => ('', l.trim()),
        },
  ];
}

/// Uma tela do wireframe (uma "página" do documento no servidor).
class TelaWf {
  TelaWf.fromJson(Map<String, dynamic> j)
    : id = '${j['id']}',
      nome = '${j['nome'] ?? ''}',
      codigo = '${j['codigo'] ?? ''}',
      subtitulo = '${j['subtitulo'] ?? ''}',
      caminho = [for (final c in j['caminho'] as List? ?? const []) '$c'],
      largura = (j['largura'] as num? ?? 1280).toDouble(),
      altura = (j['altura'] as num? ?? 1080).toDouble(),
      notas = [for (final n in j['notas'] as List? ?? const []) Nota.fromJson(n as Map<String, dynamic>)],
      _json = j;

  final String id;
  String nome, codigo, subtitulo;
  List<String> caminho;
  double largura, altura;
  List<Nota> notas;
  final Map<String, dynamic> _json;

  Map<String, dynamic> toJson() => {
    ..._json,
    'id': id,
    'nome': nome,
    'codigo': codigo,
    'subtitulo': subtitulo,
    'caminho': caminho,
    'largura': largura,
    'altura': altura,
    'notas': [for (final n in notas) n.toJson()],
  };
}

/// Componente posicionado na área útil da janela. [props] seguem o catálogo de `wireframe_ia.py`.
class Componente {
  Componente({
    required this.id,
    required this.tipo,
    required this.pagina,
    required this.caixa,
    this.estado = EstadoWf.existe,
    Map<String, dynamic>? props,
  }) : props = props ?? {};

  factory Componente.fromJson(Map<String, dynamic> j) => Componente(
    id: '${j['id']}',
    tipo: '${j['tipo']}',
    pagina: '${j['pagina'] ?? ''}',
    caixa: Rect.fromLTWH(
      (j['x'] as num? ?? 0).toDouble(),
      (j['y'] as num? ?? 0).toDouble(),
      (j['w'] as num? ?? 0).toDouble(),
      (j['h'] as num? ?? 0).toDouble(),
    ),
    estado: EstadoWf.de(j['estado']),
    props: Map<String, dynamic>.of(j['props'] as Map<String, dynamic>? ?? const {}),
  );

  final String id, tipo;
  String pagina;
  Rect caixa;
  EstadoWf estado;
  Map<String, dynamic> props;

  int? get nota => props['nota'] as int?;

  Map<String, dynamic> toJson() => {
    'id': id,
    'tipo': tipo,
    'pagina': pagina,
    'x': caixa.left,
    'y': caixa.top,
    'w': caixa.width,
    'h': caixa.height,
    'estado': estado.name,
    'props': props,
  };

  Componente copiar({String? id, Offset deslocar = Offset.zero}) => Componente.fromJson(
    toJson()..addAll({'id': ?id, 'x': caixa.left + deslocar.dx, 'y': caixa.top + deslocar.dy}),
  )..props = _copiaFunda(props) as Map<String, dynamic>;
}

Object? _copiaFunda(Object? v) => switch (v) {
  final Map m => {for (final e in m.entries) '${e.key}': _copiaFunda(e.value)},
  final List l => [for (final x in l) _copiaFunda(x)],
  _ => v,
};

/// Tipos do catálogo: rótulo, tamanho inicial e props iniciais (as mesmas chaves do schema).
const catalogo = <String, (String, Size, Map<String, dynamic>)>{
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

/// Opções das props de lista fechada (dropdown no painel de propriedades).
const opcoesProps = <String, List<String>>{
  'variante': ['primario', 'secundario', 'perigo', 'sucesso', 'fantasma'],
  'cor': ['tinta', 'suave', 'branco', 'azul', 'ambar', 'vermelho', 'verde', 'roxo', 'ciano', 'cinza'],
  'selo': ['azul', 'ambar', 'vermelho', 'verde', 'roxo', 'ciano', 'cinza'],
  'fundo': ['branco', 'cinza', 'azul', 'ambar', 'vermelho', 'verde', 'roxo', 'ciano'],
};

/// Tabela, menu e seta têm tamanho ditado pelo conteúdo: acerta a [Componente.caixa] depois de editar.
void ajustarTamanho(Componente c) {
  final p = c.props;
  final o = c.caixa.topLeft;
  switch (c.tipo) {
    case 'tabela':
      final cols = p['colunas'] as List? ?? const [];
      final w = cols.fold<double>(0, (s, col) => s + ((col as Map)['largura'] as num? ?? 0).toDouble());
      final h = (p['altura_linha'] as num? ?? 30).toDouble() * ((p['linhas'] as List? ?? const []).length + 1);
      c.caixa = Rect.fromLTWH(o.dx, o.dy, w, h);
    case 'menu':
      c.caixa = Rect.fromLTWH(o.dx, o.dy, c.caixa.width, 32.0 * (p['itens'] as List? ?? const []).length + 8);
    case 'seta':
      final pts = [for (final q in p['pontos'] as List? ?? const []) Offset(((q as List)[0] as num).toDouble(), (q[1] as num).toDouble())];
      if (pts.isEmpty) return;
      final w = pts.map((q) => q.dx).reduce(math.max), h = pts.map((q) => q.dy).reduce(math.max);
      c.caixa = Rect.fromLTWH(o.dx, o.dy, math.max(w, 8), math.max(h, 8));
  }
}

class Wireframe {
  Wireframe.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      titulo = '${j['titulo'] ?? ''}',
      versao = j['versao'] as int? ?? 1,
      telas = [for (final p in j['paginas'] as List? ?? const []) TelaWf.fromJson(p as Map<String, dynamic>)],
      componentes = [for (final e in j['elementos'] as List? ?? const []) Componente.fromJson(e as Map<String, dynamic>)] {
    if (telas.isEmpty) telas.add(TelaWf.fromJson({'id': 'tela-1', 'nome': 'Tela 1', 'codigo': 'WF-01'}));
    // Sem `pagina` = primeira tela (mesma regra dos quadros).
    for (final c in componentes) {
      if (c.pagina.isEmpty) c.pagina = telas.first.id;
    }
  }

  final String id;
  String titulo;
  int versao;
  final List<TelaWf> telas;
  final List<Componente> componentes;
}
