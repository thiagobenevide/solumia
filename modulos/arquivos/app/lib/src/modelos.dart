import 'dart:math';
import 'dart:ui';

/// Um arquivo da biblioteca (`/api/arquivos`).
/// Formatos com visualização própria; o resto (planilhas, extratos…) cai em [outros].
enum Formato {
  pdf('PDF', ['pdf']),
  docx('DOCX', ['docx', 'doc', 'odt', 'rtf']),
  pptx('PPTX', ['pptx', 'ppt', 'odp']),
  xlsx('XLSX', ['xlsx', 'xls', 'ods']),
  csv('CSV', ['csv']),
  xml('XML', ['xml']),
  outros('Outros', []);

  const Formato(this.rotulo, this.extensoes);

  final String rotulo;
  final List<String> extensoes;

  static Formato daExtensao(String ext) =>
      values.firstWhere((f) => f.extensoes.contains(ext.toLowerCase()), orElse: () => outros);
}

class Arquivo {
  Arquivo({
    required this.id,
    required this.titulo,
    required this.nomeOriginal,
    required this.extensao,
    required this.tipo,
    required this.tamanho,
    this.sha256 = '',
    required this.pasta,
    required this.tags,
    required this.status,
    required this.erro,
    required this.destaques,
    required this.atualizado,
  });

  factory Arquivo.fromJson(Map<String, dynamic> j) => Arquivo(
    id: j['id'] as String,
    titulo: j['titulo'] as String,
    nomeOriginal: j['nome_original'] as String,
    extensao: j['extensao'] as String,
    tipo: j['tipo'] as String,
    tamanho: j['tamanho'] as int,
    sha256: j['sha256'] as String? ?? '',
    pasta: j['pasta'] as String? ?? '',
    tags: [...(j['tags'] as List? ?? const []).cast<String>()],
    status: j['status'] as String,
    erro: j['erro'] as String?,
    destaques: j['destaques'] as int? ?? 0,
    atualizado: DateTime.parse(j['atualizado'] as String),
  );

  final String id;
  final String titulo;
  final String nomeOriginal;
  final String extensao;

  /// `pdf`, `documento`, `apresentacao`, `planilha`, `extrato` (os dois vêm do Finanças) ou `xml` (sem PDF).
  final String tipo;
  final int tamanho;

  /// Muda quando o original é editado (no app, num editor de fora ou em outro aparelho).
  final String sha256;
  final String pasta;
  final List<String> tags;

  /// `pronto`, `convertendo` ou `erro`.
  final String status;
  final String? erro;
  final int destaques;
  final DateTime atualizado;

  bool get pronto => status == 'pronto';

  /// Grupo da extensão usado no filtro da biblioteca e para escolher o visualizador.
  Formato get formato => Formato.daExtensao(extensao);

  Map<String, dynamic> toJson() => {
    'id': id,
    'titulo': titulo,
    'nome_original': nomeOriginal,
    'extensao': extensao,
    'tipo': tipo,
    'tamanho': tamanho,
    'sha256': sha256,
    'pasta': pasta,
    'tags': tags,
    'status': status,
    'erro': erro,
    'destaques': destaques,
    'atualizado': atualizado.toIso8601String(),
  };
}

/// Pincéis de desenho livre. O nome é o que vai para o JSON.
enum Pincel { caneta, lapis, caligrafia, marcador }

/// Ponto de um traço em pontos PDF da página (origem no canto superior esquerdo, como exibida) e
/// pressão de 0 a 1.
class PontoTinta {
  const PontoTinta(this.x, this.y, this.p);

  final double x;
  final double y;
  final double p;

  Offset get offset => Offset(x, y);
}

/// Elemento das anotações: tudo que se salva tem `id` e `pagina` (0 = primeira).
abstract class Elemento {
  String get id;
  int get pagina;

  /// Projetos de leitura (módulo Estudos) a que o elemento pertence.
  List<String> get projetos;
  Elemento comProjetos(List<String> projetos);
  Map<String, dynamic> toJson();
}

List<String> _projetos(Map<String, dynamic> j) => [...(j['projetos'] as List? ?? const []).cast<String>()];

class Traco implements Elemento {
  Traco({
    required this.id,
    required this.pagina,
    required this.pincel,
    required this.cor,
    required this.espessura,
    required this.pontos,
    this.projetos = const [],
  });

  factory Traco.fromJson(Map<String, dynamic> j) {
    final p = (j['pontos'] as List).cast<num>();
    return Traco(
      id: j['id'] as String,
      pagina: j['pagina'] as int,
      pincel: Pincel.values.asNameMap()[j['pincel']] ?? Pincel.caneta,
      cor: Color(j['cor'] as int),
      espessura: (j['espessura'] as num).toDouble(),
      pontos: [
        for (var i = 0; i + 2 < p.length; i += 3) PontoTinta(p[i].toDouble(), p[i + 1].toDouble(), p[i + 2].toDouble()),
      ],
      projetos: _projetos(j),
    );
  }

  @override
  final String id;
  @override
  final int pagina;
  final Pincel pincel;
  final Color cor;
  final double espessura;
  final List<PontoTinta> pontos;
  @override
  final List<String> projetos;

  @override
  Traco comProjetos(List<String> projetos) =>
      Traco(id: id, pagina: pagina, pincel: pincel, cor: cor, espessura: espessura, pontos: pontos, projetos: projetos);

  /// Retângulo que contém o traço, com a espessura.
  Rect get limites {
    if (pontos.isEmpty) return Rect.zero;
    var r = Rect.fromPoints(pontos.first.offset, pontos.first.offset);
    for (final p in pontos) {
      r = r.expandToInclude(Rect.fromPoints(p.offset, p.offset));
    }
    return r.inflate(espessura);
  }

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'pagina': pagina,
    'pincel': pincel.name,
    'cor': cor.toARGB32(),
    'espessura': espessura,
    // Lista plana x, y, pressão com duas casas: um traço longo fica com poucos KB.
    'pontos': [
      for (final p in pontos) ...[_arred(p.x), _arred(p.y), _arred(p.p)],
    ],
    if (projetos.isNotEmpty) 'projetos': projetos,
  };
}

/// Trecho marcado com o marca-texto inteligente: guarda o texto para virar referência de nota.
class Destaque implements Elemento {
  Destaque({
    required this.id,
    required this.pagina,
    required this.texto,
    required this.cor,
    required this.retangulos,
    this.comentario = '',
    this.traducao = '',
    required this.criado,
    this.projetos = const [],
  });

  factory Destaque.fromJson(Map<String, dynamic> j) => Destaque(
    id: j['id'] as String,
    pagina: j['pagina'] as int,
    texto: j['texto'] as String? ?? '',
    cor: Color(j['cor'] as int),
    retangulos: [
      for (final r in (j['retangulos'] as List? ?? const []).cast<List>())
        Rect.fromLTRB(
          (r[0] as num).toDouble(),
          (r[1] as num).toDouble(),
          (r[2] as num).toDouble(),
          (r[3] as num).toDouble(),
        ),
    ],
    comentario: j['comentario'] as String? ?? '',
    traducao: j['traducao'] as String? ?? '',
    criado: DateTime.tryParse(j['criado'] as String? ?? '') ?? DateTime.now(),
    projetos: _projetos(j),
  );

  @override
  final String id;
  @override
  final int pagina;
  final String texto;
  final Color cor;
  final List<Rect> retangulos;
  final String comentario;

  /// Tradução para o português (o trecho original costuma estar em inglês).
  final String traducao;
  final DateTime criado;
  @override
  final List<String> projetos;

  Destaque copiar({String? comentario, String? traducao, List<String>? projetos}) => Destaque(
    id: id,
    pagina: pagina,
    texto: texto,
    cor: cor,
    retangulos: retangulos,
    comentario: comentario ?? this.comentario,
    traducao: traducao ?? this.traducao,
    criado: criado,
    projetos: projetos ?? this.projetos,
  );

  Destaque comComentario(String c) => copiar(comentario: c);

  @override
  Destaque comProjetos(List<String> projetos) => copiar(projetos: projetos);

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'pagina': pagina,
    'texto': texto,
    'cor': cor.toARGB32(),
    'retangulos': [
      for (final r in retangulos) [_arred(r.left), _arred(r.top), _arred(r.right), _arred(r.bottom)],
    ],
    'comentario': comentario,
    if (traducao.isNotEmpty) 'traducao': traducao,
    'criado': criado.toUtc().toIso8601String(),
    if (projetos.isNotEmpty) 'projetos': projetos,
  };
}

/// Caixa de texto escrita sobre a página.
class TextoAnotado implements Elemento {
  TextoAnotado({
    required this.id,
    required this.pagina,
    required this.posicao,
    required this.texto,
    required this.cor,
    required this.tamanho,
    this.projetos = const [],
  });

  factory TextoAnotado.fromJson(Map<String, dynamic> j) => TextoAnotado(
    id: j['id'] as String,
    pagina: j['pagina'] as int,
    posicao: Offset((j['x'] as num).toDouble(), (j['y'] as num).toDouble()),
    texto: j['texto'] as String,
    cor: Color(j['cor'] as int),
    tamanho: (j['tamanho'] as num).toDouble(),
    projetos: _projetos(j),
  );

  @override
  final String id;
  @override
  final int pagina;
  final Offset posicao;
  final String texto;
  final Color cor;
  final double tamanho;
  @override
  final List<String> projetos;

  TextoAnotado comTexto(String t) =>
      TextoAnotado(id: id, pagina: pagina, posicao: posicao, texto: t, cor: cor, tamanho: tamanho, projetos: projetos);

  @override
  TextoAnotado comProjetos(List<String> projetos) => TextoAnotado(
    id: id,
    pagina: pagina,
    posicao: posicao,
    texto: texto,
    cor: cor,
    tamanho: tamanho,
    projetos: projetos,
  );

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'pagina': pagina,
    'x': _arred(posicao.dx),
    'y': _arred(posicao.dy),
    'texto': texto,
    'cor': cor.toARGB32(),
    'tamanho': tamanho,
    if (projetos.isNotEmpty) 'projetos': projetos,
  };
}

/// Estado imutável das anotações de um arquivo. Cada edição gera um novo (o que dá o desfazer de
/// graça e permite mesclar com o servidor comparando com a última versão sincronizada).
class Anotacoes {
  const Anotacoes({this.versao = 0, this.tracos = const [], this.destaques = const [], this.textos = const []});

  factory Anotacoes.fromJson(Map<String, dynamic> j) => Anotacoes(
    versao: j['versao'] as int? ?? 0,
    tracos: [for (final t in (j['tracos'] as List? ?? const [])) Traco.fromJson(t as Map<String, dynamic>)],
    destaques: [for (final d in (j['destaques'] as List? ?? const [])) Destaque.fromJson(d as Map<String, dynamic>)],
    textos: [for (final t in (j['textos'] as List? ?? const [])) TextoAnotado.fromJson(t as Map<String, dynamic>)],
  );

  final int versao;
  final List<Traco> tracos;
  final List<Destaque> destaques;
  final List<TextoAnotado> textos;

  Map<String, dynamic> toJson({required int versaoBase}) => {
    'versao_base': versaoBase,
    'tracos': [for (final t in tracos) t.toJson()],
    'destaques': [for (final d in destaques) d.toJson()],
    'textos': [for (final t in textos) t.toJson()],
  };

  Anotacoes copiar({int? versao, List<Traco>? tracos, List<Destaque>? destaques, List<TextoAnotado>? textos}) =>
      Anotacoes(
        versao: versao ?? this.versao,
        tracos: tracos ?? this.tracos,
        destaques: destaques ?? this.destaques,
        textos: textos ?? this.textos,
      );

  Anotacoes adicionar(Elemento e) => switch (e) {
    Traco t => copiar(tracos: [...tracos, t]),
    Destaque d => copiar(destaques: [...destaques, d]),
    TextoAnotado t => copiar(textos: [...textos, t]),
    _ => this,
  };

  Anotacoes substituir(Elemento e) => switch (e) {
    Traco t => copiar(tracos: [for (final x in tracos) x.id == t.id ? t : x]),
    Destaque d => copiar(destaques: [for (final x in destaques) x.id == d.id ? d : x]),
    TextoAnotado t => copiar(textos: [for (final x in textos) x.id == t.id ? t : x]),
    _ => this,
  };

  Anotacoes remover(Set<String> ids) => copiar(
    tracos: [
      for (final t in tracos)
        if (!ids.contains(t.id)) t,
    ],
    destaques: [
      for (final d in destaques)
        if (!ids.contains(d.id)) d,
    ],
    textos: [
      for (final t in textos)
        if (!ids.contains(t.id)) t,
    ],
  );

  /// Junta o que mudou aqui desde [base] (a última versão sincronizada) com o que veio do
  /// [servidor]: adições e edições locais entram, remoções locais saem, o resto é do servidor.
  static Anotacoes mesclar(Anotacoes base, Anotacoes local, Anotacoes servidor) {
    List<T> lista<T extends Elemento>(List<T> b, List<T> l, List<T> s) {
      final idsBase = {for (final e in b) e.id: e};
      final locais = {for (final e in l) e.id: e};
      final removidos = idsBase.keys.where((id) => !locais.containsKey(id)).toSet();
      final mudados = {
        for (final e in l)
          if (!identical(idsBase[e.id], e)) e.id: e,
      };
      final resultado = [
        for (final e in s)
          if (!removidos.contains(e.id)) mudados.remove(e.id) ?? e,
      ];
      return [...resultado, ...mudados.values];
    }

    return Anotacoes(
      versao: servidor.versao,
      tracos: lista(base.tracos, local.tracos, servidor.tracos),
      destaques: lista(base.destaques, local.destaques, servidor.destaques),
      textos: lista(base.textos, local.textos, servidor.textos),
    );
  }
}

/// Destaque de qualquer arquivo, como `/api/arquivos/destaques` devolve.
class Referencia {
  Referencia({required this.destaque, required this.arquivoId, required this.arquivoTitulo, required this.citacao});

  factory Referencia.fromJson(Map<String, dynamic> j) => Referencia(
    destaque: Destaque.fromJson(j),
    arquivoId: j['arquivo_id'] as String,
    arquivoTitulo: j['arquivo_titulo'] as String,
    citacao: j['referencia'] as String,
  );

  /// Mesmo formato da citação que o servidor monta (`referencia()` em `arquivos/biblioteca.py`).
  factory Referencia.de(Destaque d, Arquivo a) {
    final texto = d.texto.split(RegExp(r'\s+')).join(' ').trim();
    return Referencia(
      destaque: d,
      arquivoId: a.id,
      arquivoTitulo: a.titulo,
      citacao: '${texto.isEmpty ? '' : '> $texto\n'}— [[${a.titulo}]], p. ${d.pagina + 1}',
    );
  }

  final Destaque destaque;
  final String arquivoId;
  final String arquivoTitulo;

  /// Citação Markdown pronta (`> trecho\n— [[Título]], p. N`).
  final String citacao;
}

final _aleatorio = Random();

/// Id curto e único o bastante para os elementos de um arquivo.
String novoId() =>
    DateTime.now().microsecondsSinceEpoch.toRadixString(36) + _aleatorio.nextInt(1 << 20).toRadixString(36);

double _arred(double v) => (v * 100).roundToDouble() / 100;
