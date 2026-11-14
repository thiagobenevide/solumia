import 'dart:math';
import 'dart:ui';

import 'rotas.dart';

/// Fundo do quadro (mesmos valores de `FUNDOS` no backend).
enum Fundo {
  liso('Liso'),
  pontos('Pontos'),
  grade('Grade'),
  linhas('Linhas');

  const Fundo(this.rotulo);

  final String rotulo;

  static Fundo de(String? nome) => values.firstWhere((f) => f.name == nome, orElse: () => pontos);
}

/// Ponto de um traço em coordenadas do mundo; [p] é a pressão normalizada (0–1).
class Ponto {
  const Ponto(this.x, this.y, this.p);

  factory Ponto.fromJson(List<dynamic> j) =>
      Ponto((j[0] as num).toDouble(), (j[1] as num).toDouble(), j.length > 2 ? (j[2] as num).toDouble() : 0.5);

  final double x, y, p;

  Offset get offset => Offset(x, y);

  // Duas casas bastam (o mundo está em pixels lógicos) e o JSON fica bem menor.
  List<num> toJson() => [_arredondar(x), _arredondar(y), _arredondar(p)];
}

num _arredondar(double v) => (v * 100).roundToDouble() / 100;

Color _cor(Object? v) => Color(v is int ? v : 0xFF111111);

/// Elemento do quadro. O backend só olha `id` e `tipo`.
sealed class Elemento {
  const Elemento(this.id, {this.grupo = ''});

  final String id;

  /// Grupo (Ctrl+G): elementos com o mesmo [grupo] não vazio são selecionados e movidos juntos.
  final String grupo;

  Rect get limites;

  /// O ponto [q] encosta no elemento (com folga [raio])? Usado pela borracha.
  bool toca(Offset q, double raio);

  /// Pontos que representam o elemento no teste do laço.
  List<Offset> get amostras;

  /// Cópia com cada ponto passado por [f] (mover, redimensionar), espessura/tamanho × [fator] e,
  /// se dados, outro [id] (duplicar), outra [cor] ou outro [grupo] ('' = sem grupo).
  Elemento transformar(Offset Function(Offset) f, {double fator = 1, String? id, Color? cor, String? grupo});

  /// O laço (polígono no mundo) pega o elemento quando abraça ao menos metade das amostras.
  bool dentroDoLaco(List<Offset> laco) {
    final a = amostras;
    if (a.isEmpty || laco.length < 3) return false;
    return a.where((p) => pontoNoPoligono(p, laco)).length * 2 >= a.length;
  }

  Elemento comGrupo(String g) => transformar((q) => q, grupo: g);

  Map<String, dynamic> toJson();

  static Elemento? fromJson(Map<String, dynamic> j) {
    final e = switch (j['tipo']) {
      'traco' => Traco.fromJson(j),
      'forma' => Forma.fromJson(j),
      'texto' => Texto.fromJson(j),
      'no' => NoFluxo.fromJson(j),
      'ligacao' => Ligacao.fromJson(j),
      'tabela' => Tabela.fromJson(j),
      'imagem' => Imagem.fromJson(j),
      _ => null,
    };
    final g = j['grupo'];
    return e != null && g is String && g.isNotEmpty ? e.comGrupo(g) : e;
  }
}

enum Pincel { caneta, marcador }

class Traco extends Elemento {
  const Traco(super.id, {super.grupo, required this.pincel, required this.cor, required this.espessura, required this.pontos});

  factory Traco.fromJson(Map<String, dynamic> j) => Traco(
    j['id'] as String,
    pincel: Pincel.values.firstWhere((p) => p.name == j['pincel'], orElse: () => Pincel.caneta),
    cor: _cor(j['cor']),
    espessura: (j['espessura'] as num? ?? 3).toDouble(),
    pontos: [for (final p in j['pontos'] as List? ?? const []) Ponto.fromJson(p as List)],
  );

  final Pincel pincel;
  final Color cor;
  final double espessura;
  final List<Ponto> pontos;

  @override
  Rect get limites {
    if (pontos.isEmpty) return Rect.zero;
    var r = Rect.fromLTRB(pontos.first.x, pontos.first.y, pontos.first.x, pontos.first.y);
    for (final p in pontos) {
      r = r.expandToInclude(Rect.fromLTRB(p.x, p.y, p.x, p.y));
    }
    return r.inflate(espessura);
  }

  @override
  bool toca(Offset q, double raio) {
    if (!limites.inflate(raio).contains(q)) return false;
    final folga = raio + espessura / 2;
    if (pontos.length == 1) return (pontos.first.offset - q).distance <= folga;
    for (var i = 1; i < pontos.length; i++) {
      if (distanciaAoSegmento(q, pontos[i - 1].offset, pontos[i].offset) <= folga) return true;
    }
    return false;
  }

  @override
  List<Offset> get amostras => [for (final p in pontos) p.offset];

  @override
  Traco transformar(Offset Function(Offset) f, {double fator = 1, String? id, Color? cor, String? grupo}) => Traco(
    id ?? this.id,
    grupo: grupo ?? this.grupo,
    pincel: pincel,
    cor: cor ?? this.cor,
    espessura: espessura * fator,
    pontos: [
      for (final p in pontos)
        if (f(p.offset) case final q) Ponto(q.dx, q.dy, p.p),
    ],
  );

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    if (grupo.isNotEmpty) 'grupo': grupo,
    'tipo': 'traco',
    'pincel': pincel.name,
    'cor': cor.toARGB32(),
    'espessura': espessura,
    'pontos': [for (final p in pontos) p.toJson()],
  };
}

enum TipoForma { reta, seta, retangulo, elipse }

class Forma extends Elemento {
  const Forma(
    super.id, {
    super.grupo,
    required this.forma,
    required this.a,
    required this.b,
    required this.cor,
    required this.espessura,
  });

  factory Forma.fromJson(Map<String, dynamic> j) => Forma(
    j['id'] as String,
    forma: TipoForma.values.firstWhere((f) => f.name == j['forma'], orElse: () => TipoForma.reta),
    a: Ponto.fromJson(j['a'] as List).offset,
    b: Ponto.fromJson(j['b'] as List).offset,
    cor: _cor(j['cor']),
    espessura: (j['espessura'] as num? ?? 3).toDouble(),
  );

  final TipoForma forma;
  final Offset a, b;
  final Color cor;
  final double espessura;

  @override
  Rect get limites => Rect.fromPoints(a, b).inflate(espessura * 4);

  @override
  bool toca(Offset q, double raio) {
    final folga = raio + espessura / 2;
    final r = Rect.fromPoints(a, b);
    return switch (forma) {
      TipoForma.reta || TipoForma.seta => distanciaAoSegmento(q, a, b) <= folga,
      TipoForma.retangulo => [
        (r.topLeft, r.topRight),
        (r.topRight, r.bottomRight),
        (r.bottomRight, r.bottomLeft),
        (r.bottomLeft, r.topLeft),
      ].any((l) => distanciaAoSegmento(q, l.$1, l.$2) <= folga),
      TipoForma.elipse => _naElipse(q, r, folga),
    };
  }

  static bool _naElipse(Offset q, Rect r, double folga) {
    final rx = r.width / 2, ry = r.height / 2;
    if (rx < 1 || ry < 1) return r.inflate(folga).contains(q);
    final d = q - r.center;
    // Distância aproximada à borda: desvio do "raio normalizado" vezes o raio médio.
    final n = sqrt(pow(d.dx / rx, 2) + pow(d.dy / ry, 2));
    return (n - 1).abs() * (rx + ry) / 2 <= folga;
  }

  @override
  List<Offset> get amostras => [a, b, Rect.fromPoints(a, b).center];

  @override
  Forma transformar(Offset Function(Offset) f, {double fator = 1, String? id, Color? cor, String? grupo}) =>
      Forma(id ?? this.id, grupo: grupo ?? this.grupo, forma: forma, a: f(a), b: f(b), cor: cor ?? this.cor, espessura: espessura * fator);

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    if (grupo.isNotEmpty) 'grupo': grupo,
    'tipo': 'forma',
    'forma': forma.name,
    'a': [_arredondar(a.dx), _arredondar(a.dy)],
    'b': [_arredondar(b.dx), _arredondar(b.dy)],
    'cor': cor.toARGB32(),
    'espessura': espessura,
  };
}

class Texto extends Elemento {
  const Texto(super.id, {super.grupo, required this.posicao, required this.texto, required this.cor, required this.tamanho});

  factory Texto.fromJson(Map<String, dynamic> j) => Texto(
    j['id'] as String,
    posicao: Ponto.fromJson(j['posicao'] as List).offset,
    texto: j['texto'] as String? ?? '',
    cor: _cor(j['cor']),
    tamanho: (j['tamanho'] as num? ?? 24).toDouble(),
  );

  final Offset posicao;
  final String texto;
  final Color cor;
  final double tamanho;

  // Estimativa sem layout de texto (a pintura usa o TextPainter de verdade).
  @override
  Rect get limites {
    final linhas = texto.split('\n');
    final largura = linhas.map((l) => l.length).fold(1, max) * tamanho * 0.6;
    return posicao & Size(largura, linhas.length * tamanho * 1.25);
  }

  @override
  bool toca(Offset q, double raio) => limites.inflate(raio).contains(q);

  @override
  List<Offset> get amostras => [limites.topLeft, limites.bottomRight, limites.center];

  @override
  Texto transformar(Offset Function(Offset) f, {double fator = 1, String? id, Color? cor, String? grupo}) =>
      Texto(id ?? this.id, grupo: grupo ?? this.grupo, posicao: f(posicao), texto: texto, cor: cor ?? this.cor, tamanho: tamanho * fator);

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    if (grupo.isNotEmpty) 'grupo': grupo,
    'tipo': 'texto',
    'posicao': [_arredondar(posicao.dx), _arredondar(posicao.dy)],
    'texto': texto,
    'cor': cor.toARGB32(),
    'tamanho': tamanho,
  };
}

/// Imagem (foto, ícone ou figura do Google Imagens) entre os cantos [a] e [b]; [imagem] é o id do
/// arquivo copiado para o servidor (`/api/design/imagens/<id>`).
class Imagem extends Elemento {
  const Imagem(super.id, {super.grupo, required this.a, required this.b, required this.imagem, this.titulo = ''});

  factory Imagem.fromJson(Map<String, dynamic> j) => Imagem(
    j['id'] as String,
    a: Ponto.fromJson(j['a'] as List).offset,
    b: Ponto.fromJson(j['b'] as List).offset,
    imagem: j['imagem'] as String? ?? '',
    titulo: j['titulo'] as String? ?? '',
  );

  final Offset a, b;
  final String imagem;
  final String titulo;

  Rect get retangulo => Rect.fromPoints(a, b);

  @override
  Rect get limites => retangulo;

  @override
  bool toca(Offset q, double raio) => retangulo.inflate(raio).contains(q);

  @override
  List<Offset> get amostras => [retangulo.topLeft, retangulo.bottomRight, retangulo.center];

  // Sem cor própria: recolorir a seleção não muda a imagem.
  @override
  Imagem transformar(Offset Function(Offset) f, {double fator = 1, String? id, Color? cor, String? grupo}) =>
      Imagem(id ?? this.id, grupo: grupo ?? this.grupo, a: f(a), b: f(b), imagem: imagem, titulo: titulo);

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    if (grupo.isNotEmpty) 'grupo': grupo,
    'tipo': 'imagem',
    'a': [_arredondar(a.dx), _arredondar(a.dy)],
    'b': [_arredondar(b.dx), _arredondar(b.dy)],
    'imagem': imagem,
    if (titulo.isNotEmpty) 'titulo': titulo,
  };
}

/// Bloco de fluxograma (regra de negócio); os mesmos do draw.io que o app desenha.
enum TipoNo {
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

  const TipoNo(this.rotulo);

  final String rotulo;

  static TipoNo de(String? nome) => values.firstWhere((t) => t.name == nome, orElse: () => processo);
}

Color? _corOpcional(Object? v) => v is int ? Color(v) : null;

/// Bloco de um fluxograma: retângulo [a]–[b] no mundo com o [texto] centrado (no contêiner, no topo).
/// [cor] é a borda; [fundo] e [corTexto] vazios = derivados da borda. [fluxo] agrupa os blocos e
/// ligações gerados juntos (para a IA ajustar o fluxo inteiro).
class NoFluxo extends Elemento {
  const NoFluxo(
    super.id, {
    super.grupo,
    required this.tipo,
    required this.texto,
    required this.a,
    required this.b,
    required this.cor,
    this.fundo,
    this.corTexto,
    this.esquerda = false,
    this.fluxo = '',
  });

  factory NoFluxo.fromJson(Map<String, dynamic> j) => NoFluxo(
    j['id'] as String,
    tipo: TipoNo.de(j['no'] as String?),
    texto: j['texto'] as String? ?? '',
    a: Ponto.fromJson(j['a'] as List).offset,
    b: Ponto.fromJson(j['b'] as List).offset,
    cor: _cor(j['cor']),
    fundo: _corOpcional(j['fundo']),
    corTexto: _corOpcional(j['cor_texto']),
    esquerda: j['esquerda'] == true,
    fluxo: j['fluxo'] as String? ?? '',
  );

  final TipoNo tipo;

  /// Texto alinhado à esquerda (blocos técnicos do draw.io); senão, centrado.
  final bool esquerda;
  final String texto;
  final Offset a, b;
  final Color cor;
  final Color? fundo, corTexto;
  final String fluxo;

  Rect get retangulo => Rect.fromPoints(a, b);

  /// Faixa do título do contêiner (onde se pega para mover; o meio deixa selecionar o que está dentro).
  static const alturaTitulo = 28.0;

  @override
  Rect get limites => retangulo.inflate(4);

  @override
  bool toca(Offset q, double raio) {
    final r = retangulo;
    if (tipo != TipoNo.container) return r.inflate(raio).contains(q);
    final faixa = Rect.fromLTWH(r.left, r.top, r.width, alturaTitulo);
    return faixa.inflate(raio).contains(q) || (r.inflate(raio).contains(q) && !r.deflate(raio + 4).contains(q));
  }

  @override
  List<Offset> get amostras => [retangulo.topLeft, retangulo.bottomRight, retangulo.center];

  NoFluxo copia({
    TipoNo? tipo,
    String? texto,
    Offset? a,
    Offset? b,
    Color? cor,
    Color? fundo,
    Color? corTexto,
    bool semFundo = false,
    bool semCorTexto = false,
    bool? esquerda,
    String? id,
    String? grupo,
  }) => NoFluxo(
    id ?? this.id,
    grupo: grupo ?? this.grupo,
    tipo: tipo ?? this.tipo,
    texto: texto ?? this.texto,
    a: a ?? this.a,
    b: b ?? this.b,
    cor: cor ?? this.cor,
    fundo: semFundo ? null : (fundo ?? this.fundo),
    corTexto: semCorTexto ? null : (corTexto ?? this.corTexto),
    esquerda: esquerda ?? this.esquerda,
    fluxo: fluxo,
  );

  @override
  NoFluxo transformar(Offset Function(Offset) f, {double fator = 1, String? id, Color? cor, String? grupo}) =>
      copia(id: id, a: f(a), b: f(b), cor: cor, grupo: grupo);

  NoFluxo comTexto(String novo) => copia(texto: novo);

  NoFluxo comRetangulo(Rect r) => copia(a: r.topLeft, b: r.bottomRight);

  /// Ponto da borda do bloco na direção de [alvo] (losango na decisão, elipse no círculo, retângulo
  /// nos demais).
  Offset borda(Offset alvo) {
    final r = retangulo, c = r.center, d = alvo - c;
    if (d.distance < 1) return c;
    final hw = r.width / 2, hh = r.height / 2;
    final t = switch (tipo) {
      TipoNo.decisao => 1 / (d.dx.abs() / hw + d.dy.abs() / hh),
      TipoNo.circulo => 1 / sqrt(pow(d.dx / hw, 2) + pow(d.dy / hh, 2)),
      _ => 1 / max(d.dx.abs() / hw, d.dy.abs() / hh),
    };
    return c + d * t;
  }

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    if (grupo.isNotEmpty) 'grupo': grupo,
    'tipo': 'no',
    'no': tipo.name,
    'texto': texto,
    'a': [_arredondar(a.dx), _arredondar(a.dy)],
    'b': [_arredondar(b.dx), _arredondar(b.dy)],
    'cor': cor.toARGB32(),
    if (fundo != null) 'fundo': fundo!.toARGB32(),
    if (corTexto != null) 'cor_texto': corTexto!.toARGB32(),
    if (esquerda) 'esquerda': true,
    'fluxo': fluxo,
  };
}

enum TipoLinha {
  continua('Contínua'),
  tracejada('Tracejada'),
  pontilhada('Pontilhada');

  const TipoLinha(this.rotulo);

  final String rotulo;

  static TipoLinha de(String? nome) => values.where((t) => t.name == nome).firstOrNull ?? continua;
}

/// Figura na ponta da seta; as "vazadas" têm só o contorno.
enum TipoPonta {
  nenhuma('Nenhuma'),
  seta('Seta'),
  setaVazada('Seta vazada'),
  aberta('Seta aberta'),
  circulo('Círculo'),
  circuloVazado('Círculo vazado'),
  losango('Losango'),
  losangoVazado('Losango vazado');

  const TipoPonta(this.rotulo);

  final String rotulo;

  static TipoPonta de(String? nome, TipoPonta padrao) => values.where((t) => t.name == nome).firstOrNull ?? padrao;
}

/// Lados de um bloco onde a seta pode sair/chegar (índice = o lado do [rotaOrtogonal]).
const ladosDoBloco = ['Cima', 'Direita', 'Baixo', 'Esquerda'];

/// Seta de um bloco [de] a outro [para], com [rotulo] ("Sim", "Não"…). [a]/[b] são as pontas já
/// calculadas nas bordas dos blocos; [religar] as refaz quando um bloco se move. [ortogonal]: em
/// ângulo reto (como o draw.io), saindo do meio de um lado do bloco.
class Ligacao extends Elemento {
  const Ligacao(
    super.id, {
    super.grupo,
    required this.de,
    required this.para,
    required this.a,
    required this.b,
    required this.cor,
    this.rotulo = '',
    this.fluxo = '',
    this.ortogonal = false,
    this.linha = TipoLinha.continua,
    this.espessura = 2,
    this.pontaInicio = TipoPonta.nenhuma,
    this.pontaFim = TipoPonta.seta,
    this.ladoDe,
    this.ladoPara,
    this.pontos = const [],
  });

  factory Ligacao.fromJson(Map<String, dynamic> j) => Ligacao(
    j['id'] as String,
    de: j['de'] as String? ?? '',
    para: j['para'] as String? ?? '',
    a: Ponto.fromJson(j['a'] as List).offset,
    b: Ponto.fromJson(j['b'] as List).offset,
    cor: _cor(j['cor']),
    rotulo: j['rotulo'] as String? ?? '',
    fluxo: j['fluxo'] as String? ?? '',
    ortogonal: j['ortogonal'] == true,
    linha: j['linha'] == null && j['tracejada'] == true ? TipoLinha.tracejada : TipoLinha.de(j['linha'] as String?),
    espessura: (j['espessura'] as num? ?? 2).toDouble(),
    pontaInicio: TipoPonta.de(j['ponta_inicio'] as String?, TipoPonta.nenhuma),
    pontaFim: TipoPonta.de(j['ponta_fim'] as String?, TipoPonta.seta),
    ladoDe: j['lado_de'] as int?,
    ladoPara: j['lado_para'] as int?,
    pontos: [for (final p in j['pontos'] as List? ?? const []) Ponto.fromJson(p as List).offset],
  );

  final String de, para, rotulo, fluxo;
  final Offset a, b;
  final Color cor;
  final bool ortogonal;
  final TipoLinha linha;
  final double espessura;
  final TipoPonta pontaInicio, pontaFim;

  /// Lado fixo de saída/chegada (0 cima, 1 direita, 2 baixo, 3 esquerda); null = automático.
  final int? ladoDe, ladoPara;

  bool get tracejada => linha != TipoLinha.continua;

  /// Curvas da rota que desvia dos blocos (entre [a] e [b]); vazio = rota simples.
  final List<Offset> pontos;

  /// Pontos do caminho: a rota calculada por [religar] (desvia dos blocos), ou reto (a, b), ou em
  /// L/Z quando [ortogonal] sem rota.
  List<Offset> get caminho {
    if (ortogonal && pontos.isNotEmpty) return [a, ...pontos, b];
    if (!ortogonal || a.dx == b.dx || a.dy == b.dy) return [a, b];
    final d = b - a;
    if (d.dy.abs() >= d.dx.abs()) {
      final y = (a.dy + b.dy) / 2;
      return [a, Offset(a.dx, y), Offset(b.dx, y), b];
    }
    final x = (a.dx + b.dx) / 2;
    return [a, Offset(x, a.dy), Offset(x, b.dy), b];
  }

  /// Onde o rótulo fica: no meio do maior trecho reto (perto da saída, se a seta é curta).
  Offset get meio {
    final c = caminho;
    if (c.length == 2) return a + (b - a) * 0.45;
    var maior = 0;
    for (var i = 1; i < c.length - 1; i++) {
      if ((c[i + 1] - c[i]).distance > (c[maior + 1] - c[maior]).distance) maior = i;
    }
    return (c[maior] + c[maior + 1]) / 2;
  }

  @override
  Rect get limites => caminho.skip(1).fold(Rect.fromPoints(a, a), (r, p) => r.expandToInclude(Rect.fromPoints(p, p))).inflate(16);

  @override
  bool toca(Offset q, double raio) {
    final c = caminho;
    for (var i = 0; i < c.length - 1; i++) {
      if (distanciaAoSegmento(q, c[i], c[i + 1]) <= raio + 3) return true;
    }
    return false;
  }

  @override
  List<Offset> get amostras => [a, b, meio];

  Ligacao copia({
    String? id,
    String? de,
    String? para,
    Offset? a,
    Offset? b,
    Color? cor,
    String? rotulo,
    bool? ortogonal,
    TipoLinha? linha,
    double? espessura,
    TipoPonta? pontaInicio,
    TipoPonta? pontaFim,
    int? ladoDe,
    int? ladoPara,
    bool ladoDeAuto = false,
    bool ladoParaAuto = false,
    List<Offset>? pontos,
    String? grupo,
  }) =>
      Ligacao(
        id ?? this.id,
        grupo: grupo ?? this.grupo,
        de: de ?? this.de,
        para: para ?? this.para,
        a: a ?? this.a,
        b: b ?? this.b,
        cor: cor ?? this.cor,
        rotulo: rotulo ?? this.rotulo,
        fluxo: fluxo,
        ortogonal: ortogonal ?? this.ortogonal,
        linha: linha ?? this.linha,
        espessura: espessura ?? this.espessura,
        pontaInicio: pontaInicio ?? this.pontaInicio,
        pontaFim: pontaFim ?? this.pontaFim,
        ladoDe: ladoDeAuto ? null : ladoDe ?? this.ladoDe,
        ladoPara: ladoParaAuto ? null : ladoPara ?? this.ladoPara,
        pontos: pontos ?? this.pontos,
      );

  @override
  Ligacao transformar(Offset Function(Offset) f, {double fator = 1, String? id, Color? cor, String? grupo}) =>
      copia(id: id, a: f(a), b: f(b), cor: cor, grupo: grupo, pontos: [for (final p in pontos) f(p)]);

  Ligacao comPontas(Offset na, Offset nb, [List<Offset> rota = const []]) => copia(a: na, b: nb, pontos: rota);

  Ligacao comBlocos(String nde, String npara) => copia(de: nde, para: npara);

  /// A mesma seta no sentido contrário (pontas, lados e figuras trocam junto).
  Ligacao invertida() => Ligacao(
    id,
    grupo: grupo,
    de: para,
    para: de,
    a: b,
    b: a,
    cor: cor,
    rotulo: rotulo,
    fluxo: fluxo,
    ortogonal: ortogonal,
    linha: linha,
    espessura: espessura,
    pontaInicio: pontaFim,
    pontaFim: pontaInicio,
    ladoDe: ladoPara,
    ladoPara: ladoDe,
    pontos: pontos.reversed.toList(),
  );

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    if (grupo.isNotEmpty) 'grupo': grupo,
    'tipo': 'ligacao',
    'de': de,
    'para': para,
    'rotulo': rotulo,
    'a': [_arredondar(a.dx), _arredondar(a.dy)],
    'b': [_arredondar(b.dx), _arredondar(b.dy)],
    'cor': cor.toARGB32(),
    'fluxo': fluxo,
    if (ortogonal) 'ortogonal': true,
    if (tracejada) 'tracejada': true,
    if (linha != TipoLinha.continua) 'linha': linha.name,
    if (espessura != 2) 'espessura': espessura,
    if (pontaInicio != TipoPonta.nenhuma) 'ponta_inicio': pontaInicio.name,
    if (pontaFim != TipoPonta.seta) 'ponta_fim': pontaFim.name,
    if (ladoDe != null) 'lado_de': ladoDe,
    if (ladoPara != null) 'lado_para': ladoPara,
    if (pontos.isNotEmpty) 'pontos': [for (final p in pontos) [_arredondar(p.dx), _arredondar(p.dy)]],
  };
}

/// Célula da [Tabela]. [fundo]/[corTexto] null = padrão (na linha de cabeçalho, cinza e negrito);
/// [alinhamento]: 0 esquerda, 1 centro, 2 direita.
class Celula {
  const Celula({this.texto = '', this.fundo, this.corTexto, this.negrito = false, this.alinhamento = 0});

  factory Celula.fromJson(Map<String, dynamic> j) => Celula(
    texto: j['texto'] as String? ?? '',
    fundo: _corOpcional(j['fundo']),
    corTexto: _corOpcional(j['cor_texto']),
    negrito: j['negrito'] == true,
    alinhamento: j['alinhamento'] as int? ?? 0,
  );

  final String texto;
  final Color? fundo, corTexto;
  final bool negrito;
  final int alinhamento;

  Celula copia({String? texto, Color? fundo, Color? corTexto, bool semFundo = false, bool semCorTexto = false, bool? negrito, int? alinhamento}) =>
      Celula(
        texto: texto ?? this.texto,
        fundo: semFundo ? null : fundo ?? this.fundo,
        corTexto: semCorTexto ? null : corTexto ?? this.corTexto,
        negrito: negrito ?? this.negrito,
        alinhamento: alinhamento ?? this.alinhamento,
      );

  Map<String, dynamic> toJson() => {
    if (texto.isNotEmpty) 'texto': texto,
    if (fundo != null) 'fundo': fundo!.toARGB32(),
    if (corTexto != null) 'cor_texto': corTexto!.toARGB32(),
    if (negrito) 'negrito': true,
    if (alinhamento != 0) 'alinhamento': alinhamento,
  };
}

/// Tabela no quadro: canto [origem], [larguras] das colunas, [alturas] das linhas e [celulas]
/// (`[linha][coluna]`). [cor] é a grade; [cabecalho] destaca a primeira linha.
class Tabela extends Elemento {
  const Tabela(
    super.id, {
    super.grupo,
    required this.origem,
    required this.larguras,
    required this.alturas,
    required this.celulas,
    required this.cor,
    this.tamanho = 16,
    this.cabecalho = true,
  });

  /// Tabela vazia de [linhas] × [colunas] já no tamanho mínimo.
  factory Tabela.nova(String id, Offset origem, int linhas, int colunas, {Color cor = const Color(0xFF455A64)}) =>
      Tabela(
        id,
        origem: origem,
        larguras: List.filled(colunas, 0),
        alturas: List.filled(linhas, 0),
        celulas: [for (var l = 0; l < linhas; l++) List.filled(colunas, const Celula())],
        cor: cor,
      ).ajustada();

  factory Tabela.fromJson(Map<String, dynamic> j) {
    final celulas = [
      for (final l in j['celulas'] as List? ?? const [])
        [for (final c in l as List) Celula.fromJson(c as Map<String, dynamic>)],
    ];
    final colunas = celulas.isEmpty ? 0 : celulas.first.length;
    List<double> medidas(Object? v, int n, double padrao) {
      final lista = [for (final x in v as List? ?? const []) (x as num).toDouble()];
      return [for (var i = 0; i < n; i++) i < lista.length ? lista[i] : padrao];
    }

    return Tabela(
      j['id'] as String,
      origem: Ponto.fromJson(j['origem'] as List).offset,
      larguras: medidas(j['larguras'], colunas, 100),
      alturas: medidas(j['alturas'], celulas.length, 32),
      celulas: [for (final l in celulas) [for (var c = 0; c < colunas; c++) c < l.length ? l[c] : const Celula()]],
      cor: _cor(j['cor']),
      tamanho: (j['tamanho'] as num? ?? 16).toDouble(),
      cabecalho: j['cabecalho'] as bool? ?? true,
    );
  }

  final Offset origem;
  final List<double> larguras, alturas;
  final List<List<Celula>> celulas;
  final Color cor;
  final double tamanho;
  final bool cabecalho;

  int get linhas => alturas.length;
  int get colunas => larguras.length;

  Rect get retangulo => origem & Size(larguras.fold(0.0, (a, b) => a + b), alturas.fold(0.0, (a, b) => a + b));

  /// Retângulo da célula [l],[c] no mundo.
  Rect celula(int l, int c) {
    var x = origem.dx, y = origem.dy;
    for (var i = 0; i < c; i++) {
      x += larguras[i];
    }
    for (var i = 0; i < l; i++) {
      y += alturas[i];
    }
    return Rect.fromLTWH(x, y, larguras[c], alturas[l]);
  }

  @override
  Rect get limites => retangulo.inflate(2);

  @override
  bool toca(Offset q, double raio) => retangulo.inflate(raio).contains(q);

  @override
  List<Offset> get amostras => [retangulo.topLeft, retangulo.bottomRight, retangulo.center];

  Tabela copia({
    String? id,
    String? grupo,
    Offset? origem,
    List<double>? larguras,
    List<double>? alturas,
    List<List<Celula>>? celulas,
    Color? cor,
    double? tamanho,
    bool? cabecalho,
  }) => Tabela(
    id ?? this.id,
    grupo: grupo ?? this.grupo,
    origem: origem ?? this.origem,
    larguras: larguras ?? this.larguras,
    alturas: alturas ?? this.alturas,
    celulas: celulas ?? this.celulas,
    cor: cor ?? this.cor,
    tamanho: tamanho ?? this.tamanho,
    cabecalho: cabecalho ?? this.cabecalho,
  );

  /// Larguras e alturas que cabem o texto de cada coluna/linha (estimativa sem layout, como no [Texto]).
  Tabela ajustada() {
    final folga = tamanho * 0.8;
    double largura(String t) => t.split('\n').map((l) => l.length).fold(0, max) * tamanho * 0.62 + folga * 2;
    double altura(String t) => '\n'.allMatches(t).length.toDouble() * tamanho * 1.3 + tamanho * 1.3 + folga;
    return copia(
      larguras: [
        for (var c = 0; c < colunas; c++)
          celulas.map((l) => largura(l[c].texto)).fold(tamanho * 5, max),
      ],
      alturas: [for (final l in celulas) l.map((c) => altura(c.texto)).fold(tamanho * 2, max)],
    );
  }

  @override
  Tabela transformar(Offset Function(Offset) f, {double fator = 1, String? id, Color? cor, String? grupo}) => copia(
    id: id,
    grupo: grupo,
    cor: cor,
    origem: f(origem),
    larguras: fator == 1 ? null : [for (final w in larguras) w * fator],
    alturas: fator == 1 ? null : [for (final h in alturas) h * fator],
    tamanho: tamanho * fator,
  );

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    if (grupo.isNotEmpty) 'grupo': grupo,
    'tipo': 'tabela',
    'origem': [_arredondar(origem.dx), _arredondar(origem.dy)],
    'larguras': [for (final w in larguras) _arredondar(w)],
    'alturas': [for (final h in alturas) _arredondar(h)],
    'celulas': [
      for (final l in celulas) [for (final c in l) c.toJson()],
    ],
    'cor': cor.toARGB32(),
    'tamanho': tamanho,
    if (!cabecalho) 'cabecalho': false,
  };
}

/// Pontas da seta ortogonal: meio do lado de cada bloco virado para o outro (em cima/embaixo se a
/// distância vertical domina, senão esquerda/direita).
(Offset, Offset) _pontasOrtogonais(NoFluxo de, NoFluxo para) {
  final r1 = de.retangulo, r2 = para.retangulo;
  final d = r2.center - r1.center;
  if (d.dy.abs() >= d.dx.abs()) {
    return d.dy >= 0 ? (r1.bottomCenter, r2.topCenter) : (r1.topCenter, r2.bottomCenter);
  }
  return d.dx >= 0 ? (r1.centerRight, r2.centerLeft) : (r1.centerLeft, r2.centerRight);
}

/// Refaz as pontas das ligações pelas posições atuais dos blocos e descarta as que perderam um dos
/// blocos (apagado). As ortogonais ganham a rota que desvia dos outros blocos ([rotaOrtogonal]).
/// Com [soDosBlocos], só as setas ligadas a esses blocos são recalculadas (arrasto ao vivo). Com
/// [manterProntas], as setas que já têm pontas ficam como foram salvas (só as sem pontas são calculadas).
List<Elemento> religar(List<Elemento> elementos, {Set<String>? soDosBlocos, bool manterProntas = false}) {
  if (!elementos.any((e) => e is Ligacao)) return elementos;
  final nos = {for (final e in elementos.whereType<NoFluxo>()) e.id: e};
  // Contêineres e raias não são obstáculo: as setas passam por dentro deles.
  final obstaculos = [for (final n in nos.values) if (n.tipo != TipoNo.container) n];
  final saida = <Elemento>[];
  for (final e in elementos) {
    if (e is! Ligacao) {
      saida.add(e);
      continue;
    }
    final de = nos[e.de], para = nos[e.para];
    if (de == null || para == null) continue;
    if ((manterProntas && e.a != e.b) ||
        (soDosBlocos != null && !soDosBlocos.contains(e.de) && !soDosBlocos.contains(e.para))) {
      saida.add(e);
      continue;
    }
    if (e.ortogonal) {
      final outros = [
        for (final o in obstaculos)
          if (o.id != de.id && o.id != para.id && !_contem(o, de) && !_contem(o, para)) o.retangulo,
      ];
      final rota = rotaOrtogonal(
        de.retangulo,
        para.retangulo,
        outros,
        retoDe: _ladosRetos(de),
        retoPara: _ladosRetos(para),
        ladoDe: e.ladoDe,
        ladoPara: e.ladoPara,
      );
      if (rota != null && rota.length >= 2) {
        saida.add(e.comPontas(rota.first, rota.last, rota.sublist(1, rota.length - 1)));
        continue;
      }
      final (na, nb) = _pontasOrtogonais(de, para);
      saida.add(e.comPontas(_lado(de, e.ladoDe) ?? na, _lado(para, e.ladoPara) ?? nb));
      continue;
    }
    final na = _lado(de, e.ladoDe) ?? de.borda(para.retangulo.center);
    final nb = _lado(para, e.ladoPara) ?? para.borda(de.retangulo.center);
    saida.add(na == e.a && nb == e.b && e.pontos.isEmpty ? e : e.comPontas(na, nb));
  }
  return saida;
}

/// Meio do [lado] do bloco (null = automático).
Offset? _lado(NoFluxo n, int? lado) => switch (lado) {
  0 => n.retangulo.topCenter,
  1 => n.retangulo.centerRight,
  2 => n.retangulo.bottomCenter,
  3 => n.retangulo.centerLeft,
  _ => null,
};

bool _ladosRetos(NoFluxo n) => switch (n.tipo) {
  TipoNo.decisao || TipoNo.circulo || TipoNo.hexagono || TipoNo.dado => false,
  _ => true,
};

/// [fora] envolve [dentro]? (bloco dentro de outro não vira obstáculo para as setas dele)
bool _contem(NoFluxo fora, NoFluxo dentro) =>
    fora.retangulo.contains(dentro.retangulo.topLeft) && fora.retangulo.contains(dentro.retangulo.bottomRight);

/// Elementos que estão inteiros dentro do contêiner [c] (vão junto quando ele se move).
Iterable<Elemento> dentroDe(NoFluxo c, Iterable<Elemento> elementos) => elementos.where(
  (e) => e.id != c.id && e is! Ligacao && c.retangulo.inflate(1).contains(e.limites.deflate(4).topLeft) &&
      c.retangulo.inflate(1).contains(e.limites.deflate(4).bottomRight),
);

/// Regra par-ímpar: conta quantas arestas um raio horizontal a partir de [q] cruza.
bool pontoNoPoligono(Offset q, List<Offset> poligono) {
  var dentro = false;
  for (var i = 0, j = poligono.length - 1; i < poligono.length; j = i++) {
    final a = poligono[i], b = poligono[j];
    if ((a.dy > q.dy) != (b.dy > q.dy) && q.dx < (b.dx - a.dx) * (q.dy - a.dy) / (b.dy - a.dy) + a.dx) {
      dentro = !dentro;
    }
  }
  return dentro;
}

/// União dos limites (null quando vazio).
Rect? limitesDe(Iterable<Elemento> elementos) =>
    elementos.isEmpty ? null : elementos.map((e) => e.limites).reduce((a, b) => a.expandToInclude(b));

double distanciaAoSegmento(Offset q, Offset a, Offset b) {
  final ab = b - a;
  final comprimento2 = ab.dx * ab.dx + ab.dy * ab.dy;
  if (comprimento2 == 0) return (q - a).distance;
  final t = (((q - a).dx * ab.dx + (q - a).dy * ab.dy) / comprimento2).clamp(0.0, 1.0);
  return (q - (a + ab * t)).distance;
}

/// Linha da galeria (sem os elementos).
class ResumoQuadro {
  ResumoQuadro.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      titulo = j['titulo'] as String? ?? '',
      fundo = Fundo.de(j['fundo'] as String?),
      pasta = j['pasta'] as String? ?? '',
      atualizado = DateTime.tryParse(j['atualizado'] as String? ?? '')?.toLocal(),
      versao = j['versao'] as int? ?? 1,
      total = j['total'] as int? ?? (j['elementos'] as List?)?.length ?? 0,
      miniatura = j['miniatura'] as bool? ?? false,
      paginas = [
        for (final p in j['paginas'] as List? ?? const [])
          Pagina(
            '${(p as Map)['id']}',
            '${p['nome']}',
            cor: p['cor'] is int ? Color(p['cor'] as int) : null,
            papel: p['papel'] is Map ? Papel.fromJson((p['papel'] as Map).cast<String, dynamic>()) : null,
          ),
      ],
      _json = j;

  final String id, titulo, pasta;

  /// Abas do quadro (como as páginas do draw.io); vazio = uma página só.
  final List<Pagina> paginas;
  final Fundo fundo;
  final DateTime? atualizado;
  final int versao, total;
  final bool miniatura;
  final Map<String, dynamic> _json;

  /// Como veio do servidor, sem os elementos (para o cache offline).
  Map<String, dynamic> toJson() => {..._json}..remove('elementos');
}

class Quadro {
  Quadro.fromJson(Map<String, dynamic> j)
    : resumo = ResumoQuadro.fromJson(j),
      elementos = [for (final e in j['elementos'] as List? ?? const []) ?Elemento.fromJson(e as Map<String, dynamic>)],
      paginaDe = paginasDosElementos(j['elementos'] as List? ?? const []);

  final ResumoQuadro resumo;
  final List<Elemento> elementos;

  /// Página de cada elemento (id → id da página); quem não está aqui fica na primeira.
  final Map<String, String> paginaDe;
}

/// Aba de um quadro.
class Pagina {
  const Pagina(this.id, this.nome, {this.cor, this.papel});

  final String id, nome;

  /// Cor de marcação da aba (null = sem cor).
  final Color? cor;

  /// Folha de caderno desta página (null nos quadros: quadro infinito).
  final Papel? papel;

  Pagina copia({String? nome, Color? cor, bool semCor = false, Papel? papel}) =>
      Pagina(id, nome ?? this.nome, cor: semCor ? null : cor ?? this.cor, papel: papel ?? this.papel);

  Map<String, dynamic> toJson() => {
    'id': id,
    'nome': nome,
    if (cor != null) 'cor': cor!.toARGB32(),
    if (papel != null) 'papel': papel!.toJson(),
  };
}

/// Folha do caderno: pauta ([fundo]), distância entre linhas/pontos, tamanho (mundo, px lógicos a
/// 96 dpi: A4 = 794 × 1123), cor do papel e linha de margem.
class Papel {
  const Papel({
    this.fundo = Fundo.linhas,
    this.espaco = 28,
    this.largura = 794,
    this.altura = 1123,
    this.cor = const Color(0xFFFFFFFF),
    this.margem = true,
  });

  factory Papel.fromJson(Map<String, dynamic> j) => Papel(
    fundo: Fundo.de(j['fundo'] as String?),
    espaco: (j['espaco'] as num? ?? 28).toDouble().clamp(8, 120),
    largura: (j['largura'] as num? ?? 794).toDouble().clamp(200, 6000),
    altura: (j['altura'] as num? ?? 1123).toDouble().clamp(200, 6000),
    cor: j['cor'] is int ? Color(j['cor'] as int) : const Color(0xFFFFFFFF),
    margem: j['margem'] as bool? ?? true,
  );

  final Fundo fundo;
  final double espaco, largura, altura;
  final Color cor;
  final bool margem;

  Rect get retangulo => Rect.fromLTWH(0, 0, largura, altura);

  /// Recuo da margem esquerda e do cabeçalho (onde começa a escrita).
  double get recuo => margem ? espaco * 2.5 : espaco;

  Papel copia({Fundo? fundo, double? espaco, double? largura, double? altura, Color? cor, bool? margem}) => Papel(
    fundo: fundo ?? this.fundo,
    espaco: espaco ?? this.espaco,
    largura: largura ?? this.largura,
    altura: altura ?? this.altura,
    cor: cor ?? this.cor,
    margem: margem ?? this.margem,
  );

  Map<String, dynamic> toJson() => {
    'fundo': fundo.name,
    'espaco': espaco,
    'largura': largura,
    'altura': altura,
    'cor': cor.toARGB32(),
    'margem': margem,
  };

  @override
  bool operator ==(Object other) =>
      other is Papel &&
      other.fundo == fundo &&
      other.espaco == espaco &&
      other.largura == largura &&
      other.altura == altura &&
      other.cor == cor &&
      other.margem == margem;

  @override
  int get hashCode => Object.hash(fundo, espaco, largura, altura, cor, margem);
}

/// O JSON do elemento com a página dele (os elementos não sabem a própria página: o editor guarda).
Map<String, dynamic> jsonComPagina(Elemento e, Map<String, String> paginaDe) {
  final j = e.toJson();
  final p = paginaDe[e.id];
  if (p != null && p.isNotEmpty) j['pagina'] = p;
  return j;
}

Map<String, String> paginasDosElementos(List<dynamic> brutos) => {
  for (final e in brutos)
    if (e is Map && e['pagina'] is String && (e['pagina'] as String).isNotEmpty) '${e['id']}': e['pagina'] as String,
};

/// Junta o que este aparelho tem com a versão que outro aparelho gravou: fica tudo o que é
/// local, mais o que só existe no remoto e não foi apagado aqui ([apagadosAqui]).
List<Elemento> mesclar(List<Elemento> local, List<Elemento> remoto, Set<String> apagadosAqui) {
  final ids = {for (final e in local) e.id};
  return [...remoto.where((e) => !ids.contains(e.id) && !apagadosAqui.contains(e.id)), ...local];
}
