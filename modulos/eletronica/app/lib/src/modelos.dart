import 'dart:math';
import 'dart:ui' show Offset, Rect;

/// Grade de 1,27 mm (50 mil). Todas as coordenadas são inteiros em micrômetros (µm).
const grade = 1270;

/// Ponto inteiro em µm (igualdade exata: é assim que pino e fio se ligam).
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

/// O ponto da grade de [passo] mais perto de [mundo].
P encaixar(Offset mundo, [int passo = grade]) =>
    P((mundo.dx / passo).round() * passo, (mundo.dy / passo).round() * passo);

/// Espelha em x e gira [rot] graus (passos de 90°, horário na tela) — igual a `posicao_pino` do backend.
P transformar(P local, int rot, bool espelho) {
  var x = espelho ? -local.x : local.x, y = local.y;
  for (var i = 0; i < rot ~/ 90; i++) {
    (x, y) = (-y, x);
  }
  return P(x, y);
}

String _novoId() {
  final r = Random();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

// ---------- Biblioteca ----------

/// Direção da perna do pino, da ponta para o corpo.
enum Direcao {
  d(P(1, 0)),
  e(P(-1, 0)),
  c(P(0, -1)),
  b(P(0, 1));

  const Direcao(this.vetor);
  final P vetor;
}

class Pino {
  const Pino({
    required this.n,
    required this.nome,
    required this.pos,
    required this.dir,
    required this.comp,
    required this.tipo,
    this.oculto = false,
  });

  final String n, nome, tipo;
  final P pos;
  final Direcao dir;
  final int comp;

  /// Pino escondido no KiCad (ex.: o do símbolo de GND): liga, mas não se desenha.
  final bool oculto;

  factory Pino.fromJson(Map<String, dynamic> j) => Pino(
    n: '${j['n']}',
    nome: j['nome'] as String? ?? '',
    pos: P((j['x'] as num).toInt(), (j['y'] as num).toInt()),
    dir: Direcao.values.byName(j['dir'] as String),
    comp: (j['comp'] as num).toInt(),
    tipo: j['tipo'] as String? ?? 'passivo',
    oculto: j['oculto'] as bool? ?? false,
  );

  /// Onde a perna encosta no corpo (coordenadas do símbolo).
  P get fim => P(pos.x + dir.vetor.x * comp, pos.y + dir.vetor.y * comp);
}

class Simbolo {
  Simbolo({
    required this.id,
    required this.nome,
    required this.categoria,
    required this.prefixo,
    required this.tipo,
    required this.valor,
    required this.encapsulamento,
    required this.desenho,
    required this.pinos,
    required this.campoRef,
    required this.campoValor,
    required this.nomesPinos,
    bool? numerosPinos,
    this.descricao = '',
  }) : numerosPinos = numerosPinos ?? nomesPinos,
       limites = _limites(desenho, pinos);

  final String id, nome, categoria, prefixo, tipo, valor, encapsulamento, descricao;

  /// Primitivas como vêm do backend (`linha`, `ret`, `circ`, `arco`, `texto`); ver `biblioteca.py`.
  final List<Map<String, dynamic>> desenho;
  final List<Pino> pinos;
  final P campoRef, campoValor;
  final bool nomesPinos, numerosPinos;

  /// Caixa do desenho e dos pinos (coordenadas do símbolo), para seleção.
  final Rect limites;

  bool get alimentacao => tipo == 'alimentacao';

  /// Veio de uma biblioteca do KiCad (`<lib>:<nome>[:<unidade>]`); os da base não têm `:`.
  bool get importado => id.contains(':');

  /// Desenho no lugar de um símbolo que sumiu (biblioteca removida): um "?" sem pinos.
  factory Simbolo.faltando(String id) => Simbolo(
    id: id,
    nome: '$id (não encontrado)',
    categoria: '',
    prefixo: 'U',
    tipo: 'componente',
    valor: '',
    encapsulamento: '',
    desenho: [
      {'t': 'ret', 'a': [-2540, -2540], 'b': [2540, 2540], 'cheio': false},
      {'t': 'texto', 'p': [0, 0], 's': '?'},
    ],
    pinos: const [],
    campoRef: const P(0, -3810),
    campoValor: const P(0, 3810),
    nomesPinos: false,
  );

  factory Simbolo.fromJson(Map<String, dynamic> j) {
    final campos = j['campos'] as Map<String, dynamic>;
    return Simbolo(
      id: j['id'] as String,
      nome: j['nome'] as String,
      categoria: j['categoria'] as String,
      prefixo: j['prefixo'] as String,
      tipo: j['tipo'] as String,
      valor: j['valor'] as String? ?? '',
      encapsulamento: j['encapsulamento'] as String? ?? '',
      desenho: [for (final d in j['desenho'] as List) d as Map<String, dynamic>],
      pinos: [for (final p in j['pinos'] as List) Pino.fromJson(p as Map<String, dynamic>)],
      campoRef: P.json(campos['ref'] as List),
      campoValor: P.json(campos['valor'] as List),
      nomesPinos: j['nomes_pinos'] as bool? ?? false,
      numerosPinos: j['numeros_pinos'] as bool?,
      descricao: j['descricao'] as String? ?? '',
    );
  }

  static Rect _limites(List<Map<String, dynamic>> desenho, List<Pino> pinos) {
    final pts = <Offset>[for (final p in pinos) p.pos.offset];
    for (final d in desenho) {
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

/// Símbolos da base (sempre) e os importados já trazidos do servidor (busca ou abertura do projeto).
class Biblioteca {
  Biblioteca(List<Simbolo> simbolos) : porId = {for (final s in simbolos) s.id: s};

  final Map<String, Simbolo> porId;

  Iterable<Simbolo> get base => porId.values.where((s) => !s.importado);

  List<String> get categorias => {for (final s in base) s.categoria}.toList();

  Simbolo de(String id) => porId[id] ?? Simbolo.faltando(id);

  void adicionar(Iterable<Simbolo> novos) {
    for (final s in novos) {
      porId[s.id] = s;
    }
  }

  /// Busca local, só na base (as importadas são buscadas no servidor).
  List<Simbolo> buscar(String texto, {String? categoria}) {
    final t = texto.trim().toLowerCase();
    return [
      for (final s in base)
        if ((categoria == null || s.categoria == categoria) &&
            (t.isEmpty || s.nome.toLowerCase().contains(t) || s.valor.toLowerCase().contains(t) || s.id.contains(t)))
          s,
    ];
  }
}

// ---------- Itens do esquemático ----------

sealed class Item {
  Item(this.id, this.folha);

  final String id;
  String folha;

  Map<String, dynamic> toJson();
}

class Componente extends Item {
  Componente({
    String? id,
    required String folha,
    required this.simbolo,
    required this.ref,
    required this.valor,
    required this.encapsulamento,
    required this.pos,
    this.rot = 0,
    this.espelho = false,
  }) : super(id ?? _novoId(), folha);

  final String simbolo;
  String ref, valor, encapsulamento;
  P pos;
  int rot;
  bool espelho;

  factory Componente.fromJson(Map<String, dynamic> j) => Componente(
    id: j['id'] as String,
    folha: j['folha'] as String,
    simbolo: j['simbolo'] as String,
    ref: j['ref'] as String? ?? '?',
    valor: j['valor'] as String? ?? '',
    encapsulamento: j['encapsulamento'] as String? ?? '',
    pos: P((j['x'] as num).toInt(), (j['y'] as num).toInt()),
    rot: (j['rot'] as num?)?.toInt() ?? 0,
    espelho: j['espelho'] as bool? ?? false,
  );

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'folha': folha,
    'simbolo': simbolo,
    'ref': ref,
    'valor': valor,
    'encapsulamento': encapsulamento,
    'x': pos.x,
    'y': pos.y,
    'rot': rot,
    'espelho': espelho,
  };

  P local(P p) => pos + transformar(p, rot, espelho);

  P posicaoPino(Pino p) => local(p.pos);

  /// Caixa do símbolo já girado/espelhado, em coordenadas do mundo.
  Rect limites(Simbolo s) {
    final r = s.limites;
    final cantos = [
      for (final c in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight])
        local(P(c.dx.round(), c.dy.round())).offset,
    ];
    return Rect.fromPoints(cantos[0], cantos[3]).expandToInclude(Rect.fromPoints(cantos[1], cantos[2]));
  }
}

class Fio extends Item {
  Fio({String? id, required String folha, required this.pontos}) : super(id ?? _novoId(), folha);

  List<P> pontos;

  factory Fio.fromJson(Map<String, dynamic> j) => Fio(
    id: j['id'] as String,
    folha: j['folha'] as String,
    pontos: [for (final p in j['pontos'] as List) P.json(p as List)],
  );

  @override
  Map<String, dynamic> toJson() => {'id': id, 'folha': folha, 'pontos': [for (final p in pontos) p.toJson()]};

  /// Algum trecho passa por [p] (pontas incluídas)?
  bool passaPor(P p) {
    for (var i = 0; i < pontos.length - 1; i++) {
      if (noSegmento(p, pontos[i], pontos[i + 1])) return true;
    }
    return false;
  }
}

/// Nome de rede num ponto: rótulos com o mesmo nome se ligam, inclusive entre folhas.
class Rotulo extends Item {
  Rotulo({String? id, required String folha, required this.nome, required this.pos}) : super(id ?? _novoId(), folha);

  String nome;
  P pos;

  factory Rotulo.fromJson(Map<String, dynamic> j) => Rotulo(
    id: j['id'] as String,
    folha: j['folha'] as String,
    nome: j['nome'] as String,
    pos: P((j['x'] as num).toInt(), (j['y'] as num).toInt()),
  );

  @override
  Map<String, dynamic> toJson() => {'id': id, 'folha': folha, 'nome': nome, 'x': pos.x, 'y': pos.y};
}

class TextoCad extends Item {
  TextoCad({String? id, required String folha, required this.texto, required this.pos, this.tamanho = grade})
    : super(id ?? _novoId(), folha);

  String texto;
  P pos;
  int tamanho;

  factory TextoCad.fromJson(Map<String, dynamic> j) => TextoCad(
    id: j['id'] as String,
    folha: j['folha'] as String,
    texto: j['texto'] as String? ?? '',
    pos: P((j['x'] as num).toInt(), (j['y'] as num).toInt()),
    tamanho: (j['tamanho'] as num?)?.toInt() ?? grade,
  );

  @override
  Map<String, dynamic> toJson() => {'id': id, 'folha': folha, 'texto': texto, 'x': pos.x, 'y': pos.y, 'tamanho': tamanho};
}

/// Ponta de prova do simulador: `v` mede a tensão da rede onde encosta; `i`, a corrente do componente [ref].
/// A cor é a da posição na lista do projeto (até 8), a mesma do sinal no osciloscópio.
class Sonda extends Item {
  Sonda({String? id, required String folha, required this.tipo, required this.pos, this.ref = ''}) : super(id ?? _novoId(), folha);

  final String tipo;
  P pos;
  String ref;

  static const maximo = 8;

  factory Sonda.fromJson(Map<String, dynamic> j) => Sonda(
    id: j['id'] as String,
    folha: j['folha'] as String,
    tipo: j['tipo'] as String,
    pos: P((j['x'] as num).toInt(), (j['y'] as num).toInt()),
    ref: j['ref'] as String? ?? '',
  );

  @override
  Map<String, dynamic> toJson() => {'id': id, 'folha': folha, 'tipo': tipo, 'x': pos.x, 'y': pos.y, if (tipo == 'i') 'ref': ref};
}

class Folha {
  Folha({required this.id, required this.nome});

  final String id;
  String nome;

  factory Folha.fromJson(Map<String, dynamic> j) => Folha(id: j['id'] as String, nome: j['nome'] as String);

  Map<String, dynamic> toJson() => {'id': id, 'nome': nome};
}

class ResumoProjeto {
  const ResumoProjeto({required this.id, required this.titulo, required this.versao, required this.atualizado, required this.total});

  final String id, titulo, atualizado;
  final int versao, total;

  factory ResumoProjeto.fromJson(Map<String, dynamic> j) => ResumoProjeto(
    id: j['id'] as String,
    titulo: j['titulo'] as String,
    versao: (j['versao'] as num).toInt(),
    atualizado: j['atualizado'] as String,
    total: (j['total'] as num?)?.toInt() ?? 0,
  );
}

class Projeto {
  Projeto({
    required this.id,
    required this.titulo,
    required this.versao,
    required this.folhas,
    required this.componentes,
    required this.fios,
    required this.rotulos,
    required this.textos,
    List<Sonda>? sondas,
  }) : sondas = sondas ?? [];

  final String id;
  String titulo;
  int versao;
  List<Folha> folhas;
  List<Componente> componentes;
  List<Fio> fios;
  List<Rotulo> rotulos;
  List<TextoCad> textos;
  List<Sonda> sondas;

  factory Projeto.fromJson(Map<String, dynamic> j) => Projeto(
    id: j['id'] as String,
    titulo: j['titulo'] as String,
    versao: (j['versao'] as num).toInt(),
    folhas: [for (final f in j['folhas'] as List) Folha.fromJson(f as Map<String, dynamic>)],
    componentes: [for (final c in j['componentes'] as List? ?? []) Componente.fromJson(c as Map<String, dynamic>)],
    fios: [for (final f in j['fios'] as List? ?? []) Fio.fromJson(f as Map<String, dynamic>)],
    rotulos: [for (final r in j['rotulos'] as List? ?? []) Rotulo.fromJson(r as Map<String, dynamic>)],
    textos: [for (final t in j['textos'] as List? ?? []) TextoCad.fromJson(t as Map<String, dynamic>)],
    sondas: [for (final s in j['sondas'] as List? ?? []) Sonda.fromJson(s as Map<String, dynamic>)],
  );

  Map<String, dynamic> esquematicoJson() => {
    'folhas': [for (final f in folhas) f.toJson()],
    'componentes': [for (final c in componentes) c.toJson()],
    'fios': [for (final f in fios) f.toJson()],
    'rotulos': [for (final r in rotulos) r.toJson()],
    'textos': [for (final t in textos) t.toJson()],
    'sondas': [for (final s in sondas) s.toJson()],
  };

  /// Troca o conteúdo pelo de [j] (desfazer/refazer e recarga após conflito).
  void restaurar(Map<String, dynamic> j) {
    final p = Projeto.fromJson({'id': id, 'titulo': titulo, 'versao': versao, ...j});
    folhas = p.folhas;
    componentes = p.componentes;
    fios = p.fios;
    rotulos = p.rotulos;
    textos = p.textos;
    sondas = p.sondas;
  }

  Iterable<Item> itens(String folha) => <Item>[...componentes, ...fios, ...rotulos, ...textos, ...sondas].where((i) => i.folha == folha);
}

// ---------- Geometria ----------

bool noSegmento(P p, P a, P b) {
  if ((b.x - a.x) * (p.y - a.y) != (b.y - a.y) * (p.x - a.x)) return false;
  return min(a.x, b.x) <= p.x && p.x <= max(a.x, b.x) && min(a.y, b.y) <= p.y && p.y <= max(a.y, b.y);
}

double distanciaSegmento(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final l2 = ab.distanceSquared;
  if (l2 == 0) return (p - a).distance;
  final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / l2).clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

/// Caminho em L de [de] até [ate]: primeiro na horizontal (ou na vertical) e depois na outra direção.
List<P> rotaOrtogonal(P de, P ate, {bool horizontalPrimeiro = true}) {
  final canto = horizontalPrimeiro ? P(ate.x, de.y) : P(de.x, ate.y);
  return [de, if (canto != de && canto != ate) canto, ate];
}

/// Tira pontos repetidos e cantos no meio de uma reta.
List<P> simplificar(List<P> pontos) {
  final s = <P>[];
  for (final p in pontos) {
    if (s.isNotEmpty && s.last == p) continue;
    if (s.length >= 2 && noSegmento(s.last, s[s.length - 2], p)) s.removeLast();
    s.add(p);
  }
  return s;
}

/// Próxima referência livre do [prefixo] (R1, R2…) entre [componentes].
String proximaRef(String prefixo, Iterable<Componente> componentes) {
  var maior = 0;
  final padrao = RegExp('^${RegExp.escape(prefixo)}(\\d+)\$');
  for (final c in componentes) {
    final m = padrao.firstMatch(c.ref);
    if (m != null) maior = max(maior, int.parse(m.group(1)!));
  }
  return '$prefixo${maior + 1}';
}

/// Pontos com três ou mais ligações (pontas/cantos de fio, pinos, meio de fio): ganham a bolinha de junção.
Set<P> juncoes(Iterable<Fio> fios, Iterable<P> pinos) {
  final contagem = <P, int>{};
  final lista = fios.toList();
  void somar(P p, int n) => contagem[p] = (contagem[p] ?? 0) + n;
  for (final f in lista) {
    for (var i = 0; i < f.pontos.length; i++) {
      somar(f.pontos[i], i == 0 || i == f.pontos.length - 1 ? 1 : 2);
    }
  }
  for (final p in pinos) {
    somar(p, 1);
  }
  // Ponta encostada no meio de outro fio vale dois a mais (o fio passa pelos dois lados).
  for (final p in contagem.keys.toList()) {
    for (final f in lista) {
      if (f.pontos.contains(p)) continue;
      if (f.passaPor(p)) somar(p, 2);
    }
  }
  return {for (final e in contagem.entries) if (e.value >= 3) e.key};
}
