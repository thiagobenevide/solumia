import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Conversão DOCX ⇄ Delta do Quill para o editor simples de texto rico.
///
/// Lê parágrafos (títulos, alinhamento, listas, recuo), runs (negrito, itálico, sublinhado,
/// tachado, fonte, tamanho, cor, realce, sobrescrito/subscrito), tabs, quebras, hyperlinks,
/// controle de alterações (`w:ins`/`w:del` com autor e data → [atributoInsercao]/[atributoExclusao])
/// e comentários (`comments.xml` → [Comentario], trecho marcado com [atributoComentario]).
/// Ao gravar troca só o corpo de `word/document.xml` (o `w:sectPr` final fica) e mexe no mínimo em
/// styles/numbering/rels/comments/settings; o resto do zip fica igual.

const _nsW = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const _nsR = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _nsRels = 'http://schemas.openxmlformats.org/package/2006/relationships';
const _nsTipos = 'http://schemas.openxmlformats.org/package/2006/content-types';
const _relLink = '$_nsR/hyperlink';
const _relNumeracao = '$_nsR/numbering';
const _relComentarios = '$_nsR/comments';
const _tipoNumeracao = 'application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml';
const _tipoComentarios = 'application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml';

const _caminhoDoc = 'word/document.xml';
const _caminhoEstilos = 'word/styles.xml';
const _caminhoNumeracao = 'word/numbering.xml';
const _caminhoComentarios = 'word/comments.xml';
const _caminhoAjustes = 'word/settings.xml';
const _caminhoRels = 'word/_rels/document.xml.rels';
const _caminhoTipos = '[Content_Types].xml';

const _avisoAlteracoes = 'alterações de formatação rastreadas (ficam aceitas)';

/// Atributos do Delta para revisões: valor = [marcaRevisao] (`autor|data ISO`).
const atributoInsercao = 'rev_ins';
const atributoExclusao = 'rev_del';

/// Ids dos comentários que cobrem o trecho, separados por vírgula.
const atributoComentario = 'comentario';

String marcaRevisao(String autor, DateTime data) => '$autor|${_dataWord(data)}';

/// Autor e data de uma marca de revisão.
({String autor, DateTime? data}) lerMarca(String marca) {
  final i = marca.lastIndexOf('|');
  if (i < 0) return (autor: marca, data: null);
  return (autor: marca.substring(0, i), data: DateTime.tryParse(marca.substring(i + 1)));
}

List<String> idsComentario(Object? valor) =>
    valor is String ? valor.split(',').where((s) => s.isNotEmpty).toList() : const [];

String _dataWord(DateTime d) => '${d.toUtc().toIso8601String().split('.').first.replaceAll('Z', '')}Z';

/// Comentário do Word (do orientador, do revisor ou meu).
class Comentario {
  Comentario({required this.id, required this.autor, required this.texto, DateTime? data, String? iniciais})
    : data = data ?? DateTime.now(),
      iniciais = iniciais ?? _iniciais(autor);

  final String id;
  final String autor;
  final String texto;
  final DateTime data;
  final String iniciais;

  Comentario comTexto(String novo) => Comentario(id: id, autor: autor, texto: novo, data: data, iniciais: iniciais);

  static String _iniciais(String autor) =>
      autor.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).map((p) => p[0].toUpperCase()).take(3).join();
}

/// Arquivo que não é um .docx legível.
class DocxInvalido implements Exception {
  DocxInvalido(this.mensagem);

  final String mensagem;

  @override
  String toString() => mensagem;
}

class DocumentoDocx {
  DocumentoDocx._(this._zip, this.delta, this.avisos, this.comentarios, this.rastreando);

  final Archive _zip;

  /// Ops do Quill (`insert` + `attributes`), sempre terminando em `\n`.
  final List<Map<String, dynamic>> delta;

  /// O que o editor simples não preserva e se perde ao salvar daqui ("tabelas", "imagens"…).
  final List<String> avisos;

  /// Comentários de `word/comments.xml`, na ordem do arquivo.
  final List<Comentario> comentarios;

  /// O documento pede "Controlar alterações" ligado (`w:trackRevisions` em settings.xml).
  final bool rastreando;

  static DocumentoDocx ler(Uint8List bytes) {
    final Archive zip;
    try {
      zip = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw DocxInvalido('Não é um .docx válido (o arquivo não é um pacote zip). .doc, .odt e .rtf não abrem aqui.');
    }
    final doc = _lerXml(zip, _caminhoDoc) ?? (throw DocxInvalido('Não é um .docx válido: falta word/document.xml.'));
    final raiz = doc.rootElement;
    if (raiz.name.namespaceUri != _nsW) {
      throw DocxInvalido('Formato de .docx não suportado (OOXML "Strict" ou outro). Use "Abrir com…".');
    }
    final corpo = raiz.getElement('body', namespaceUri: _nsW);
    final leitor = _Leitor(
      estilos: _nomesEstilos(_lerXml(zip, _caminhoEstilos)),
      numeracao: _formatosLista(_lerXml(zip, _caminhoNumeracao)),
      links: _alvosLinks(_lerXml(zip, _caminhoRels)),
    );
    if (corpo != null) leitor.bloco(corpo);
    final secoes = corpo?.findElements('sectPr', namespaceUri: _nsW).length ?? 0;
    if (secoes > 1) leitor.avisos.add('seções múltiplas');
    final ajustes = _lerXml(zip, _caminhoAjustes);
    final rastreando = ajustes?.rootElement.getElement('trackRevisions', namespaceUri: _nsW) != null;
    return DocumentoDocx._(zip, leitor.fechar(), leitor.avisos.toList(), _lerComentarios(zip), rastreando);
  }

  /// Novo .docx: o original com o corpo trocado pelo [delta]. [comentarios] substitui `comments.xml`
  /// (padrão: os lidos); [rastrear] liga/desliga o "Controlar alterações" do Word.
  Uint8List gravar(List<Map<String, dynamic>> delta, {List<Comentario>? comentarios, bool? rastrear}) {
    final doc = _lerXml(_zip, _caminhoDoc)!;
    final raiz = doc.rootElement;
    _declararW(raiz);
    var corpo = raiz.getElement('body', namespaceUri: _nsW);
    if (corpo == null) {
      corpo = _elemento('<w:body/>');
      raiz.children.add(corpo);
    }
    final lista = comentarios ?? this.comentarios;
    final escritor = _Escritor(
      zip: _zip,
      prefixoR: _garantirPrefixo(raiz, 'r', _nsR),
      comentarios: {for (final c in lista) c.id},
      primeiroId: lista.map((c) => int.tryParse(c.id) ?? 0).fold(0, (a, b) => a > b ? a : b) + 1,
    );
    final xmlCorpo = escritor.corpo(_linhas(delta));
    final secao = corpo.childElements.where((e) => e.name.local == 'sectPr').lastOrNull?.copy();
    corpo.children.clear();
    corpo.children.addAll(_elementos(xmlCorpo, prefixoR: escritor.prefixoR));
    if (secao != null) corpo.children.add(secao);
    if (lista.isNotEmpty || _zip.findFile(_caminhoComentarios) != null) escritor.gravarComentarios(lista);
    if (rastrear != null) escritor.rastrear(rastrear);

    final trocados = <String, String>{_caminhoDoc: doc.toXmlString(), ...escritor.trocados()};
    final saida = Archive();
    for (final f in _zip.files) {
      if (!f.isFile || escritor.removidos.contains(f.name)) continue;
      final novo = trocados.remove(f.name);
      saida.add(ArchiveFile.bytes(f.name, novo != null ? utf8.encode(novo) : f.content));
    }
    trocados.forEach((nome, xml) => saida.add(ArchiveFile.bytes(nome, utf8.encode(xml))));
    return ZipEncoder().encodeBytes(saida);
  }
}

// ---------------------------------------------------------------- utilidades XML

XmlDocument? _lerXml(Archive zip, String nome) {
  final f = zip.findFile(nome);
  if (f == null) return null;
  try {
    return XmlDocument.parse(utf8.decode(f.content, allowMalformed: true));
  } on XmlException catch (e) {
    throw DocxInvalido('Não é um .docx válido: XML quebrado em $nome ($e).');
  }
}

XmlElement? _w(XmlElement? e, String nome) => e?.getElement(nome, namespaceUri: _nsW);

String? _val(XmlElement? e) => e?.getAttribute('val', namespaceUri: _nsW);

/// Propriedade liga/desliga do Word (`<w:b/>`, `<w:b w:val="0"/>`).
bool _liga(XmlElement? e) => e != null && !const {'0', 'false', 'off', 'none'}.contains(_val(e));

/// Prefixo declarado na raiz para [ns]; declara [sugerido] se faltar.
String _garantirPrefixo(XmlElement raiz, String sugerido, String ns) {
  for (final a in raiz.attributes) {
    if (a.name.prefix == 'xmlns' && a.value == ns) return a.name.local;
  }
  raiz.attributes.add(XmlAttribute(XmlName.qualified('xmlns:$sugerido'), ns));
  return sugerido;
}

/// Garante `xmlns:w` na raiz: os trechos gerados usam sempre o prefixo `w`.
void _declararW(XmlElement raiz) {
  if (raiz.getAttribute('xmlns:w') == null) raiz.attributes.add(XmlAttribute(XmlName.qualified('xmlns:w'), _nsW));
}

/// Elementos de um trecho XML com prefixos `w`/`r` (os namespaces são resolvidos na leitura).
List<XmlElement> _elementos(String xml, {String prefixoR = 'r'}) => XmlDocument.parse(
  '<x xmlns:w="$_nsW" xmlns:$prefixoR="$_nsR">$xml</x>',
).rootElement.childElements.map((e) => e.copy()).toList();

XmlElement _elemento(String xml) => _elementos(xml).single;

String _esc(String s) => s
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String _semAcento(String s) => s
    .replaceAll(RegExp('[áàâã]'), 'a')
    .replaceAll(RegExp('[éê]'), 'e')
    .replaceAll('í', 'i')
    .replaceAll(RegExp('[óôõ]'), 'o')
    .replaceAll('ú', 'u')
    .replaceAll('ç', 'c');

/// styleId → nome do estilo (minúsculo).
Map<String, String> _nomesEstilos(XmlDocument? estilos) {
  final nomes = <String, String>{};
  for (final s in estilos?.rootElement.findElements('style', namespaceUri: _nsW) ?? const <XmlElement>[]) {
    final id = s.getAttribute('styleId', namespaceUri: _nsW);
    if (id != null) nomes[id] = (_val(_w(s, 'name')) ?? id).toLowerCase();
  }
  return nomes;
}

/// Nível de título (1..6) pelo nome ou id do estilo; `Title` vira título 1.
int? _nivelTitulo(String? id, Map<String, String> estilos) {
  if (id == null) return null;
  for (final nome in [estilos[id], id.toLowerCase()]) {
    if (nome == null) continue;
    final n = _semAcento(nome).replaceAll(' ', '');
    if (n == 'title' || n == 'titulo' || n == 'ttulo') return 1;
    final m = RegExp(r'^(heading|titulo|ttulo)(\d)$').firstMatch(n);
    if (m != null) return int.parse(m[2]!).clamp(1, 6);
  }
  return null;
}

/// Formato da lista por numId → ilvl → numFmt (`bullet`, `decimal`…).
Map<String, Map<String, String>> _formatosLista(XmlDocument? numeracao) {
  if (numeracao == null) return {};
  final raiz = numeracao.rootElement;
  final abstratos = {
    for (final a in raiz.findElements('abstractNum', namespaceUri: _nsW))
      a.getAttribute('abstractNumId', namespaceUri: _nsW): {
        for (final l in a.findElements('lvl', namespaceUri: _nsW))
          l.getAttribute('ilvl', namespaceUri: _nsW) ?? '0': _val(_w(l, 'numFmt')) ?? 'decimal',
      },
  };
  return {
    for (final n in raiz.findElements('num', namespaceUri: _nsW))
      n.getAttribute('numId', namespaceUri: _nsW) ?? '': abstratos[_val(_w(n, 'abstractNumId'))] ?? const {},
  };
}

List<Comentario> _lerComentarios(Archive zip) {
  final xml = _lerXml(zip, _caminhoComentarios);
  if (xml == null) return [];
  return [
    for (final c in xml.rootElement.findElements('comment', namespaceUri: _nsW))
      Comentario(
        id: c.getAttribute('id', namespaceUri: _nsW) ?? '',
        autor: c.getAttribute('author', namespaceUri: _nsW) ?? 'Autor desconhecido',
        iniciais: c.getAttribute('initials', namespaceUri: _nsW),
        data: DateTime.tryParse(c.getAttribute('date', namespaceUri: _nsW) ?? ''),
        texto: c
            .findElements('p', namespaceUri: _nsW)
            .map(
              (p) => p.descendantElements
                  .where((t) => t.name.local == 't' && t.name.namespaceUri == _nsW)
                  .map((t) => t.innerText)
                  .join(),
            )
            .join('\n')
            .trim(),
      ),
  ];
}

/// Realce do Word (`w:highlight`) → cor RGB.
const _realces = {
  'yellow': 'FFFF00', 'green': '00FF00', 'cyan': '00FFFF', 'magenta': 'FF00FF', 'blue': '0000FF',
  'red': 'FF0000', 'darkBlue': '000080', 'darkCyan': '008080', 'darkGreen': '008000',
  'darkMagenta': '800080', 'darkRed': '800000', 'darkYellow': '808000', 'darkGray': '808080',
  'lightGray': 'C0C0C0', 'black': '000000', 'white': 'FFFFFF',
};

/// `#RRGGBB`/`#AARRGGBB` do Quill → `RRGGBB` do Word (null se não for cor).
String? _hex(Object? cor) {
  if (cor is! String) return null;
  var h = cor.replaceAll('#', '').toUpperCase();
  if (h.length == 8) h = h.substring(2);
  return RegExp(r'^[0-9A-F]{6}$').hasMatch(h) ? h : null;
}

/// Tamanho do Quill (pontos ou small/large/huge) → meios-pontos do Word.
int? _meiosPontos(Object? tamanho) {
  final pt = switch (tamanho) {
    'small' => 9.0,
    'large' => 18.0,
    'huge' => 24.0,
    num n => n.toDouble(),
    String s => double.tryParse(s),
    _ => null,
  };
  return pt == null || pt <= 0 ? null : (pt * 2).round().clamp(2, 3276);
}

/// rId → alvo dos hyperlinks.
Map<String, String> _alvosLinks(XmlDocument? rels) => {
  for (final r in rels?.rootElement.childElements ?? const <XmlElement>[])
    if (r.getAttribute('Type') == _relLink && r.getAttribute('Id') != null) r.getAttribute('Id')!: r.getAttribute('Target') ?? '',
};

// ---------------------------------------------------------------- leitura

class _Leitor {
  _Leitor({required this.estilos, required this.numeracao, required this.links});

  final Map<String, String> estilos;
  final Map<String, Map<String, String>> numeracao;
  final Map<String, String> links;
  final avisos = <String>{};
  final _ops = <Map<String, dynamic>>[];

  /// Comentários abertos (`commentRangeStart` sem o `End` ainda) — atravessam parágrafos.
  final _comentarios = <String>{};

  /// Revisão em curso: (atributo, marca) do `w:ins`/`w:del` que envolve o conteúdo.
  (String, String)? _revisao;

  void _comRevisao(String atributo, XmlElement e, void Function() ler) {
    final antes = _revisao;
    final autor = e.getAttribute('author', namespaceUri: _nsW) ?? 'Autor desconhecido';
    final data = DateTime.tryParse(e.getAttribute('date', namespaceUri: _nsW) ?? '');
    _revisao = (atributo, data == null ? autor : marcaRevisao(autor, data));
    ler();
    _revisao = antes;
  }

  void _inserir(String texto, Map<String, dynamic> atributos) {
    if (texto.isEmpty) return;
    final ultimo = _ops.lastOrNull;
    if (ultimo != null && _mesmos(ultimo['attributes'] as Map<String, dynamic>?, atributos)) {
      ultimo['insert'] = (ultimo['insert'] as String) + texto;
      return;
    }
    _ops.add({'insert': texto, if (atributos.isNotEmpty) 'attributes': Map<String, dynamic>.of(atributos)});
  }

  static bool _mesmos(Map<String, dynamic>? a, Map<String, dynamic> b) {
    a ??= const {};
    return a.length == b.length && a.entries.every((e) => b[e.key] == e.value);
  }

  List<Map<String, dynamic>> fechar() {
    if (_ops.isEmpty) _ops.add({'insert': '\n'});
    return _ops;
  }

  /// Conteúdo de bloco: corpo, célula de tabela, controle de conteúdo.
  void bloco(XmlElement pai) {
    for (final e in pai.childElements) {
      if (e.name.namespaceUri != _nsW) {
        if (e.name.local == 'oMathPara') avisos.add('equações');
        continue;
      }
      switch (e.name.local) {
        case 'p':
          _paragrafo(e);
        case 'tbl':
          // O texto das células vira parágrafos soltos; a grade se perde.
          avisos.add('tabelas');
          for (final linha in e.findElements('tr', namespaceUri: _nsW)) {
            for (final celula in linha.findElements('tc', namespaceUri: _nsW)) {
              bloco(celula);
            }
          }
        case 'sdt':
          final c = _w(e, 'sdtContent');
          if (c != null) bloco(c);
        case 'customXml':
          bloco(e);
        case 'ins' || 'moveTo':
          _comRevisao(atributoInsercao, e, () => bloco(e));
        case 'del' || 'moveFrom':
          _comRevisao(atributoExclusao, e, () => bloco(e));
        case 'altChunk':
          avisos.add('conteúdo incorporado');
      }
    }
  }

  void _paragrafo(XmlElement p) {
    final pPr = _w(p, 'pPr');
    final blocoAttr = <String, dynamic>{};
    if (pPr != null) {
      if (_w(pPr, 'sectPr') != null) avisos.add('seções múltiplas');
      if (_w(pPr, 'pPrChange') != null) avisos.add(_avisoAlteracoes);
      final estilo = _val(_w(pPr, 'pStyle'));
      final nivel = _nivelTitulo(estilo, estilos);
      if (nivel != null) blocoAttr['header'] = nivel;
      final jc = _val(_w(pPr, 'jc'));
      switch (jc) {
        case 'center':
          blocoAttr['align'] = 'center';
        case 'right' || 'end':
          blocoAttr['align'] = 'right';
        case 'both' || 'distribute':
          blocoAttr['align'] = 'justify';
      }
      final numPr = _w(pPr, 'numPr');
      final numId = _val(_w(numPr, 'numId'));
      final ilvl = int.tryParse(_val(_w(numPr, 'ilvl')) ?? '') ?? 0;
      final nomeEstilo = estilos[estilo] ?? '';
      if (numId != null && numId != '0') {
        final formatos = numeracao[numId];
        final fmt = formatos == null ? 'bullet' : (formatos['$ilvl'] ?? formatos['0'] ?? 'decimal');
        blocoAttr['list'] = fmt == 'bullet' ? 'bullet' : 'ordered';
        if (ilvl > 0) blocoAttr['indent'] = ilvl.clamp(1, 8);
      } else if (nomeEstilo.startsWith('list bullet')) {
        blocoAttr['list'] = 'bullet';
      } else if (nomeEstilo.startsWith('list number')) {
        blocoAttr['list'] = 'ordered';
      } else {
        final ind = _w(pPr, 'ind');
        final esquerda = int.tryParse(
          ind?.getAttribute('left', namespaceUri: _nsW) ?? ind?.getAttribute('start', namespaceUri: _nsW) ?? '',
        );
        if (esquerda != null && esquerda >= 600) blocoAttr['indent'] = (esquerda / 720).round().clamp(1, 8);
      }
    }
    _conteudo(p, null, blocoAttr);
    _inserir('\n', blocoAttr);
  }

  /// Conteúdo de parágrafo: runs, hyperlinks e envoltórios.
  void _conteudo(XmlElement pai, String? link, Map<String, dynamic> blocoAttr) {
    for (final e in pai.childElements) {
      if (e.name.namespaceUri != _nsW) {
        if (e.name.local == 'oMath') avisos.add('equações');
        continue;
      }
      switch (e.name.local) {
        case 'r':
          _run(e, link, blocoAttr);
        case 'hyperlink':
          final id = e.getAttribute('id', namespaceUri: _nsR);
          _conteudo(e, id == null ? link : (links[id] ?? link), blocoAttr);
        case 'ins' || 'moveTo':
          _comRevisao(atributoInsercao, e, () => _conteudo(e, link, blocoAttr));
        case 'del' || 'moveFrom':
          _comRevisao(atributoExclusao, e, () => _conteudo(e, link, blocoAttr));
        case 'fldSimple':
          avisos.add('campos automáticos (sumário, numeração de página…)');
          _conteudo(e, link, blocoAttr);
        case 'smartTag' || 'customXml':
          _conteudo(e, link, blocoAttr);
        case 'sdt':
          final c = _w(e, 'sdtContent');
          if (c != null) _conteudo(c, link, blocoAttr);
        case 'commentRangeStart':
          _comentarios.add(e.getAttribute('id', namespaceUri: _nsW) ?? '');
        case 'commentRangeEnd':
          _comentarios.remove(e.getAttribute('id', namespaceUri: _nsW) ?? '');
      }
    }
  }

  void _run(XmlElement r, String? link, Map<String, dynamic> blocoAttr) {
    final rPr = _w(r, 'rPr');
    final attr = <String, dynamic>{};
    if (rPr != null) {
      if (_liga(_w(rPr, 'b'))) attr['bold'] = true;
      if (_liga(_w(rPr, 'i'))) attr['italic'] = true;
      if (_liga(_w(rPr, 'u'))) attr['underline'] = true;
      if (_liga(_w(rPr, 'strike')) || _liga(_w(rPr, 'dstrike'))) attr['strike'] = true;
      if (_w(rPr, 'rPrChange') != null) avisos.add(_avisoAlteracoes);
      final fontes = _w(rPr, 'rFonts');
      final fonte = fontes?.getAttribute('ascii', namespaceUri: _nsW) ?? fontes?.getAttribute('hAnsi', namespaceUri: _nsW);
      if (fonte != null && fonte.isNotEmpty) attr['font'] = fonte;
      final sz = int.tryParse(_val(_w(rPr, 'sz')) ?? '');
      if (sz != null && sz > 0) attr['size'] = sz.isEven ? '${sz ~/ 2}' : '${sz / 2}';
      final cor = _hex(_val(_w(rPr, 'color')));
      if (cor != null && cor != '000000') attr['color'] = '#$cor';
      final realce = _realces[_val(_w(rPr, 'highlight'))] ?? _hex(_w(rPr, 'shd')?.getAttribute('fill', namespaceUri: _nsW));
      if (realce != null && realce != 'FFFFFF') attr['background'] = '#$realce';
      switch (_val(_w(rPr, 'vertAlign'))) {
        case 'superscript':
          attr['script'] = 'super';
        case 'subscript':
          attr['script'] = 'sub';
      }
    }
    if (link != null && link.isNotEmpty) attr['link'] = link;
    if (_revisao case (final chave, final marca)) attr[chave] = marca;
    if (_comentarios.isNotEmpty) attr[atributoComentario] = (_comentarios.toList()..sort()).join(',');
    for (final c in r.childElements) {
      if (c.name.namespaceUri != _nsW) {
        if (c.name.local == 'AlternateContent') _midia(c);
        continue;
      }
      switch (c.name.local) {
        case 't' || 'delText':
          _inserir(c.innerText.replaceAll('\r', '').replaceAll('\n', ' '), attr);
        case 'tab':
          _inserir('\t', attr);
        case 'br' || 'cr':
          // O Quill não tem quebra de linha suave: a quebra vira um parágrafo novo.
          final tipo = c.getAttribute('type', namespaceUri: _nsW);
          if (tipo == 'page' || tipo == 'column') avisos.add('quebras de página');
          _inserir('\n', blocoAttr);
        case 'noBreakHyphen':
          _inserir('-', attr);
        case 'drawing' || 'pict' || 'object':
          _midia(c);
        case 'footnoteReference':
          avisos.add('notas de rodapé');
        case 'endnoteReference':
          avisos.add('notas de fim');
        case 'fldChar':
          avisos.add('campos automáticos (sumário, numeração de página…)');
      }
    }
  }

  void _midia(XmlElement e) {
    final caixa = e.descendantElements.any((d) => d.name.local == 'txbxContent');
    avisos.add(caixa ? 'caixas de texto' : 'imagens e objetos');
  }
}

// ---------------------------------------------------------------- gravação

typedef _Trecho = (String texto, Map<String, dynamic> attr);
typedef _Linha = (List<_Trecho> trechos, Map<String, dynamic> bloco);

List<_Linha> _linhas(List<Map<String, dynamic>> delta) {
  final linhas = <_Linha>[];
  var atual = <_Trecho>[];
  for (final op in delta) {
    final ins = op['insert'];
    if (ins is! String) continue; // embeds (imagem, fórmula) não existem no editor simples
    final attr = (op['attributes'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    final partes = ins.split('\n');
    for (var i = 0; i < partes.length; i++) {
      if (partes[i].isNotEmpty) atual.add((partes[i], attr));
      if (i < partes.length - 1) {
        linhas.add((atual, attr));
        atual = [];
      }
    }
  }
  if (atual.isNotEmpty) linhas.add((atual, const {}));
  return linhas;
}

class _Escritor {
  _Escritor({required this.zip, required this.prefixoR, required this.comentarios, required int primeiroId})
    : _idAnotacao = primeiroId;

  final Archive zip;
  final String prefixoR;

  /// Ids de comentário que existem (marcas no texto de comentários apagados são ignoradas).
  final Set<String> comentarios;

  /// Partes do zip que saem (extensões de comentário que apontariam para parágrafos que não existem mais).
  final removidos = <String>{};

  // w:id de ins/del: únicos entre as anotações, depois dos ids dos comentários.
  int _idAnotacao;
  final _abertos = <String>{};
  XmlDocument? _ajustes;

  XmlDocument? _estilos;
  XmlDocument? _numeracao;
  XmlDocument? _rels;
  XmlDocument? _tipos;
  bool _estilosMudou = false, _numeracaoMudou = false, _relsMudou = false, _tiposMudou = false;
  bool _estilosLidos = false;

  // Listas: numId base de cada tipo e numIds de reinício (ordered) já usados nesta gravação.
  final _numBase = <String, String>{};
  var _blocosNumerados = 0;
  String? _tipoAnterior;

  /// XML dos parágrafos (sem o `w:sectPr`).
  String corpo(List<_Linha> linhas) {
    final s = StringBuffer();
    for (var k = 0; k < linhas.length; k++) {
      final (trechos, bloco) = linhas[k];
      s.write('<w:p>');
      s.write(_pPr(bloco));
      _runs(s, trechos);
      // Fecha no fim do parágrafo os comentários que não continuam no próximo.
      final seguinte = k + 1 < linhas.length ? linhas[k + 1].$1.firstOrNull?.$2 : null;
      _comentariosAte(s, seguinte == null ? const {} : _idsValidos(seguinte));
      s.write('</w:p>');
    }
    return s.toString();
  }

  Set<String> _idsValidos(Map<String, dynamic> attr) =>
      idsComentario(attr[atributoComentario]).where(comentarios.contains).toSet();

  /// Abre/fecha marcas de comentário para que fiquem abertos exatamente [ids].
  void _comentariosAte(StringBuffer s, Set<String> ids) {
    for (final id in _abertos.difference(ids).toList()..sort()) {
      s.write('<w:commentRangeEnd w:id="${_esc(id)}"/><w:r><w:commentReference w:id="${_esc(id)}"/></w:r>');
      _abertos.remove(id);
    }
    for (final id in ids.difference(_abertos).toList()..sort()) {
      s.write('<w:commentRangeStart w:id="${_esc(id)}"/>');
      _abertos.add(id);
    }
  }

  Map<String, String> trocados() => {
    if (_estilosMudou) _caminhoEstilos: _estilos!.toXmlString(),
    if (_numeracaoMudou) _caminhoNumeracao: _numeracao!.toXmlString(),
    if (_relsMudou) _caminhoRels: _rels!.toXmlString(),
    if (_tiposMudou) _caminhoTipos: _tipos!.toXmlString(),
    _caminhoComentarios: ?_comentariosXml,
    if (_ajustes != null) _caminhoAjustes: _ajustes!.toXmlString(),
  };

  String? _comentariosXml;

  /// Reescreve `comments.xml` (cria a parte, a relação e o tipo se faltarem). As extensões
  /// (commentsExtended/Ids/Extensible: respostas e "resolvido") saem, porque citam parágrafos antigos.
  void gravarComentarios(List<Comentario> lista) {
    final s = StringBuffer('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:comments xmlns:w="$_nsW">');
    for (final c in lista) {
      s.write(
        '<w:comment w:id="${_esc(c.id)}" w:author="${_esc(c.autor)}" w:date="${_dataWord(c.data)}" '
        'w:initials="${_esc(c.iniciais)}">',
      );
      final linhas = c.texto.split('\n');
      for (var i = 0; i < linhas.length; i++) {
        s.write('<w:p>');
        if (i == 0) s.write('<w:r><w:annotationRef/></w:r>');
        s.write('<w:r><w:t xml:space="preserve">${_esc(linhas[i])}</w:t></w:r></w:p>');
      }
      s.write('</w:comment>');
    }
    s.write('</w:comments>');
    _comentariosXml = s.toString();

    final raiz = _docRels.rootElement;
    if (!raiz.childElements.any((r) => r.getAttribute('Type') == _relComentarios)) {
      _novaRelacao(_relComentarios, 'comments.xml');
      _sobrescreverTipo('/$_caminhoComentarios', _tipoComentarios);
    }
    for (final r in raiz.childElements.toList()) {
      final tipo = r.getAttribute('Type') ?? '';
      if (!RegExp(r'/(commentsExtended|commentsIds|commentsExtensible)$').hasMatch(tipo)) continue;
      final alvo = 'word/${r.getAttribute('Target') ?? ''}';
      removidos.add(alvo);
      raiz.children.remove(r);
      _relsMudou = true;
      final tipos = _docTipos;
      final override = tipos?.rootElement.childElements.where((e) => e.getAttribute('PartName') == '/$alvo').firstOrNull;
      if (override != null) {
        tipos!.rootElement.children.remove(override);
        _tiposMudou = true;
      }
    }
  }

  void _sobrescreverTipo(String parte, String tipo) {
    final tipos = _docTipos;
    if (tipos == null || tipos.rootElement.childElements.any((e) => e.getAttribute('PartName') == parte)) return;
    tipos.rootElement.children.add(
      XmlElement(XmlName.qualified('Override', namespaceUri: _nsTipos), [
        XmlAttribute(XmlName.qualified('PartName'), parte),
        XmlAttribute(XmlName.qualified('ContentType'), tipo),
      ]),
    );
    _tiposMudou = true;
  }

  // Elementos de w:settings que vêm antes de w:trackRevisions pelo esquema.
  static const _antesDoRastreio = {
    'writeProtection', 'view', 'zoom', 'removePersonalInformation', 'removeDateAndTime',
    'doNotDisplayPageBoundaries', 'displayBackgroundShape', 'printPostScriptOverText',
    'printFractionalCharacterWidth', 'printFormsData', 'embedTrueTypeFonts', 'embedSystemFonts',
    'saveSubsetFonts', 'saveFormsData', 'mirrorMargins', 'alignBordersAndEdges',
    'bordersDoNotSurroundHeader', 'bordersDoNotSurroundFooter', 'gutterAtTop', 'hideSpellingErrors',
    'hideGrammaticalErrors', 'activeWritingStyle', 'proofState', 'formsDesign', 'attachedTemplate',
    'linkStyles', 'stylePaneFormatFilter', 'stylePaneSortMethod', 'documentType', 'mailMerge', 'revisionView',
  };

  /// Liga/desliga `w:trackRevisions` (o Word continua marcando as alterações de quem abrir lá).
  void rastrear(bool ligar) {
    final ajustes = _lerXml(zip, _caminhoAjustes);
    if (ajustes == null) return; // sem settings.xml não vale criar a parte só por isso
    final raiz = ajustes.rootElement;
    final atual = raiz.getElement('trackRevisions', namespaceUri: _nsW);
    if ((atual != null) == ligar) return;
    if (ligar) {
      _declararW(raiz);
      final antes = raiz.childElements.where((e) => _antesDoRastreio.contains(e.name.local)).lastOrNull;
      final novo = _elemento('<w:trackRevisions/>');
      raiz.children.insert(antes == null ? 0 : raiz.children.indexOf(antes) + 1, novo);
    } else {
      raiz.children.remove(atual);
    }
    _ajustes = ajustes;
  }

  String _pPr(Map<String, dynamic> bloco) {
    final s = StringBuffer();
    final header = bloco['header'];
    if (header is int && header >= 1) s.write('<w:pStyle w:val="${_esc(_estiloTitulo(header.clamp(1, 6)))}"/>');
    final lista = bloco['list'];
    final nivel = (bloco['indent'] is int ? bloco['indent'] as int : 0).clamp(0, 8);
    final tipo = switch (lista) {
      'ordered' => 'ordered',
      'bullet' || 'checked' || 'unchecked' => 'bullet',
      _ => null,
    };
    if (tipo != null) {
      final numId = _numLista(tipo, novoBloco: tipo == 'ordered' && _tipoAnterior != 'ordered');
      s.write('<w:numPr><w:ilvl w:val="$nivel"/><w:numId w:val="$numId"/></w:numPr>');
    } else if (nivel > 0) {
      s.write('<w:ind w:left="${720 * nivel}"/>');
    }
    _tipoAnterior = tipo;
    final jc = switch (bloco['align']) {
      'center' => 'center',
      'right' => 'right',
      'justify' => 'both',
      _ => null,
    };
    if (jc != null) s.write('<w:jc w:val="$jc"/>');
    return s.isEmpty ? '' : '<w:pPr>$s</w:pPr>';
  }

  static int _ate(List<_Trecho> trechos, int i, bool Function(Map<String, dynamic>) igual) {
    var fim = i + 1;
    while (fim < trechos.length && igual(trechos[fim].$2)) {
      fim++;
    }
    return fim;
  }

  static String? _linkDe(Map<String, dynamic> attr) {
    final l = attr['link'];
    return l is String && l.isNotEmpty ? l : null;
  }

  /// (tag, marca) da revisão do trecho: `ins`, `del` ou nenhuma.
  static (String?, String?) _revisaoDe(Map<String, dynamic> attr) {
    final del = attr[atributoExclusao];
    if (del is String) return ('del', del);
    final ins = attr[atributoInsercao];
    if (ins is String) return ('ins', ins);
    return (null, null);
  }

  void _runs(StringBuffer s, List<_Trecho> trechos) {
    var i = 0;
    while (i < trechos.length) {
      final link = _linkDe(trechos[i].$2);
      final fim = _ate(trechos, i, (a) => _linkDe(a) == link);
      if (link != null) s.write('<w:hyperlink $prefixoR:id="${_idLink(link)}" w:history="1">');
      _revisoes(s, trechos.sublist(i, fim), link: link != null);
      if (link != null) s.write('</w:hyperlink>');
      i = fim;
    }
  }

  void _revisoes(StringBuffer s, List<_Trecho> trechos, {required bool link}) {
    var i = 0;
    while (i < trechos.length) {
      final rev = _revisaoDe(trechos[i].$2);
      final fim = _ate(trechos, i, (a) => _revisaoDe(a) == rev);
      final (tag, marca) = rev;
      if (tag != null) {
        final (:autor, :data) = lerMarca(marca!);
        s.write('<w:$tag w:id="${_idAnotacao++}" w:author="${_esc(autor)}"');
        if (data != null) s.write(' w:date="${_dataWord(data)}"');
        s.write('>');
      }
      for (var j = i; j < fim; j++) {
        _comentariosAte(s, _idsValidos(trechos[j].$2));
        _run(s, trechos[j], link: link, excluido: tag == 'del');
      }
      if (tag != null) s.write('</w:$tag>');
      i = fim;
    }
  }

  void _run(StringBuffer s, _Trecho trecho, {bool link = false, bool excluido = false}) {
    final (texto, attr) = trecho;
    final rPr = StringBuffer();
    final estiloLink = link ? _idEstilo('hyperlink', tipo: 'character') : null;
    if (estiloLink != null) rPr.write('<w:rStyle w:val="${_esc(estiloLink)}"/>');
    final fonte = attr['font'];
    if (fonte is String && fonte.isNotEmpty) {
      final f = _esc(fonte);
      rPr.write('<w:rFonts w:ascii="$f" w:hAnsi="$f" w:cs="$f"/>');
    }
    if (attr['bold'] == true) rPr.write('<w:b/>');
    if (attr['italic'] == true) rPr.write('<w:i/>');
    if (attr['strike'] == true) rPr.write('<w:strike/>');
    final cor = _hex(attr['color']);
    if (cor != null) {
      rPr.write('<w:color w:val="$cor"/>');
    } else if (link && estiloLink == null) {
      rPr.write('<w:color w:val="0563C1"/>');
    }
    final sz = _meiosPontos(attr['size']);
    if (sz != null) rPr.write('<w:sz w:val="$sz"/><w:szCs w:val="$sz"/>');
    final fundo = _hex(attr['background']);
    final realce = fundo == null ? null : _realces.entries.where((e) => e.value == fundo).firstOrNull?.key;
    if (realce != null) rPr.write('<w:highlight w:val="$realce"/>');
    if (attr['underline'] == true || (link && estiloLink == null)) rPr.write('<w:u w:val="single"/>');
    if (fundo != null && realce == null) rPr.write('<w:shd w:val="clear" w:color="auto" w:fill="$fundo"/>');
    switch (attr['script']) {
      case 'super':
        rPr.write('<w:vertAlign w:val="superscript"/>');
      case 'sub':
        rPr.write('<w:vertAlign w:val="subscript"/>');
    }
    s.write('<w:r>');
    if (rPr.isNotEmpty) s.write('<w:rPr>$rPr</w:rPr>');
    final tag = excluido ? 'w:delText' : 'w:t';
    final partes = texto.split('\t');
    for (var i = 0; i < partes.length; i++) {
      if (i > 0) s.write('<w:tab/>');
      if (partes[i].isNotEmpty) s.write('<$tag xml:space="preserve">${_esc(partes[i])}</$tag>');
    }
    s.write('</w:r>');
  }

  // ---- estilos

  XmlDocument? get _docEstilos {
    if (!_estilosLidos) {
      _estilos = _lerXml(zip, _caminhoEstilos);
      _estilosLidos = true;
    }
    return _estilos;
  }

  String? _idEstilo(String nome, {String tipo = 'paragraph'}) {
    for (final st in _docEstilos?.rootElement.findElements('style', namespaceUri: _nsW) ?? const <XmlElement>[]) {
      if ((st.getAttribute('type', namespaceUri: _nsW) ?? 'paragraph') == tipo &&
          (_val(_w(st, 'name')) ?? '').toLowerCase() == nome) {
        return st.getAttribute('styleId', namespaceUri: _nsW);
      }
    }
    return null;
  }

  String _estiloTitulo(int n) {
    final existente = _idEstilo('heading $n');
    if (existente != null) return existente;
    final id = 'Heading$n';
    final estilos = _docEstilos;
    if (estilos != null) {
      // Estilo mínimo para o título não virar parágrafo normal no Word.
      const tamanhos = {1: 32, 2: 28, 3: 26, 4: 24, 5: 22, 6: 22};
      final raiz = estilos.rootElement;
      _declararW(raiz);
      const w = 'w';
      raiz.children.add(
        _elemento(
          '<$w:style $w:type="paragraph" $w:styleId="$id"><$w:name $w:val="heading $n"/>'
          '<$w:basedOn $w:val="Normal"/><$w:next $w:val="Normal"/><$w:qFormat/>'
          '<$w:pPr><$w:keepNext/><$w:spacing $w:before="240" $w:after="60"/><$w:outlineLvl $w:val="${n - 1}"/></$w:pPr>'
          '<$w:rPr><$w:b/><$w:sz $w:val="${tamanhos[n]}"/></$w:rPr></$w:style>',
        ),
      );
      _estilosMudou = true;
    }
    return id;
  }

  // ---- listas

  XmlDocument get _docNumeracao {
    if (_numeracao != null) return _numeracao!;
    final existente = _lerXml(zip, _caminhoNumeracao);
    if (existente != null) return _numeracao = existente;
    // Documento sem numbering.xml: cria a parte, a relação e o tipo de conteúdo.
    _numeracaoMudou = true;
    _novaRelacao(_relNumeracao, 'numbering.xml');
    final tipos = _docTipos;
    if (tipos != null &&
        !tipos.rootElement.childElements.any((e) => e.getAttribute('PartName') == '/$_caminhoNumeracao')) {
      tipos.rootElement.children.add(
        XmlElement(XmlName.qualified('Override', namespaceUri: _nsTipos), [
          XmlAttribute(XmlName.qualified('PartName'), '/$_caminhoNumeracao'),
          XmlAttribute(XmlName.qualified('ContentType'), _tipoNumeracao),
        ]),
      );
      _tiposMudou = true;
    }
    return _numeracao = XmlDocument.parse(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:numbering xmlns:w="$_nsW"/>',
    );
  }

  /// numId para um parágrafo de lista. Cada bloco numerado depois do primeiro recomeça em 1 por
  /// um `w:num` com `startOverride`, reaproveitando os que já existem para não acumular a cada gravação.
  String _numLista(String tipo, {required bool novoBloco}) {
    final base = _numBase[tipo] ??= _acharOuCriarNum(tipo);
    if (tipo != 'ordered' || !novoBloco) return base;
    final bloco = _blocosNumerados++;
    if (bloco == 0) return base;
    final raiz = _docNumeracao.rootElement;
    final abstrato = _abstratoDe(base);
    final reinicios = raiz
        .findElements('num', namespaceUri: _nsW)
        .where((n) {
          final id = n.getAttribute('numId', namespaceUri: _nsW);
          return id != base &&
              _val(_w(n, 'abstractNumId')) == abstrato &&
              n
                  .findElements('lvlOverride', namespaceUri: _nsW)
                  .any((o) => o.getAttribute('ilvl', namespaceUri: _nsW) == '0' && _val(_w(o, 'startOverride')) == '1');
        })
        .map((n) => n.getAttribute('numId', namespaceUri: _nsW)!)
        .toList();
    if (bloco - 1 < reinicios.length) return reinicios[bloco - 1];
    return _novoNum(abstrato!, reiniciar: true);
  }

  String? _abstratoDe(String numId) => _val(
    _w(
      _docNumeracao.rootElement
          .findElements('num', namespaceUri: _nsW)
          .firstWhere((n) => n.getAttribute('numId', namespaceUri: _nsW) == numId),
      'abstractNumId',
    ),
  );

  String _acharOuCriarNum(String tipo) {
    final raiz = _docNumeracao.rootElement;
    final formatos = {
      for (final a in raiz.findElements('abstractNum', namespaceUri: _nsW))
        a.getAttribute('abstractNumId', namespaceUri: _nsW): _val(
          _w(
            a.findElements('lvl', namespaceUri: _nsW).where((l) => l.getAttribute('ilvl', namespaceUri: _nsW) == '0').firstOrNull,
            'numFmt',
          ),
        ),
    };
    for (final n in raiz.findElements('num', namespaceUri: _nsW)) {
      final fmt = formatos[_val(_w(n, 'abstractNumId'))];
      if (fmt == null) continue;
      final ehMarcador = fmt == 'bullet';
      if ((tipo == 'bullet') == ehMarcador && fmt != 'none') return n.getAttribute('numId', namespaceUri: _nsW)!;
    }
    return _novoNum(_novoAbstrato(tipo, raiz));
  }

  String _novoAbstrato(String tipo, XmlElement raiz) {
    _declararW(raiz);
    const w = 'w';
    final ids = raiz
        .findElements('abstractNum', namespaceUri: _nsW)
        .map((a) => int.tryParse(a.getAttribute('abstractNumId', namespaceUri: _nsW) ?? '') ?? 0);
    final id = ids.fold(-1, (a, b) => a > b ? a : b) + 1;
    const marcadores = ['•', '◦', '▪'];
    const formatos = ['decimal', 'lowerLetter', 'lowerRoman'];
    final niveis = StringBuffer();
    for (var i = 0; i < 9; i++) {
      final (fmt, texto) = tipo == 'bullet' ? ('bullet', marcadores[i % 3]) : (formatos[i % 3], '%${i + 1}.');
      niveis.write(
        '<$w:lvl $w:ilvl="$i"><$w:start $w:val="1"/><$w:numFmt $w:val="$fmt"/><$w:lvlText $w:val="$texto"/>'
        '<$w:lvlJc $w:val="left"/><$w:pPr><$w:ind $w:left="${720 * (i + 1)}" $w:hanging="360"/></$w:pPr></$w:lvl>',
      );
    }
    final novo = _elemento(
      '<$w:abstractNum $w:abstractNumId="$id"><$w:multiLevelType $w:val="hybridMultilevel"/>$niveis</$w:abstractNum>',
    );
    // Pelo esquema os abstractNum vêm antes de todos os num.
    final primeiroNum = raiz.findElements('num', namespaceUri: _nsW).firstOrNull;
    if (primeiroNum != null) {
      raiz.children.insert(raiz.children.indexOf(primeiroNum), novo);
    } else {
      raiz.children.add(novo);
    }
    _numeracaoMudou = true;
    return '$id';
  }

  String _novoNum(String abstrato, {bool reiniciar = false}) {
    final raiz = _docNumeracao.rootElement;
    _declararW(raiz);
    const w = 'w';
    final ids = raiz
        .findElements('num', namespaceUri: _nsW)
        .map((n) => int.tryParse(n.getAttribute('numId', namespaceUri: _nsW) ?? '') ?? 0);
    final id = ids.fold(0, (a, b) => a > b ? a : b) + 1;
    final reinicio = reiniciar ? '<$w:lvlOverride $w:ilvl="0"><$w:startOverride $w:val="1"/></$w:lvlOverride>' : '';
    final novo = _elemento('<$w:num $w:numId="$id"><$w:abstractNumId $w:val="$abstrato"/>$reinicio</$w:num>');
    final limpeza = raiz.getElement('numIdMacAtCleanup', namespaceUri: _nsW);
    if (limpeza != null) {
      raiz.children.insert(raiz.children.indexOf(limpeza), novo);
    } else {
      raiz.children.add(novo);
    }
    _numeracaoMudou = true;
    return '$id';
  }

  // ---- relações e tipos

  XmlDocument get _docRels => _rels ??=
      _lerXml(zip, _caminhoRels) ??
      (() {
        _relsMudou = true;
        return XmlDocument.parse(
          '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="$_nsRels"/>',
        );
      })();

  XmlDocument? get _docTipos => _tipos ??= _lerXml(zip, _caminhoTipos);

  String _idLink(String alvo) {
    for (final r in _docRels.rootElement.childElements) {
      if (r.getAttribute('Type') == _relLink && r.getAttribute('Target') == alvo) return r.getAttribute('Id')!;
    }
    return _novaRelacao(_relLink, alvo, externo: true);
  }

  String _novaRelacao(String tipo, String alvo, {bool externo = false}) {
    final raiz = _docRels.rootElement;
    final usados = raiz.childElements.map((r) => r.getAttribute('Id')).toSet();
    var n = usados.length + 1;
    while (usados.contains('rId$n')) {
      n++;
    }
    raiz.children.add(
      XmlElement(XmlName.qualified('Relationship', namespaceUri: _nsRels), [
        XmlAttribute(XmlName.qualified('Id'), 'rId$n'),
        XmlAttribute(XmlName.qualified('Type'), tipo),
        XmlAttribute(XmlName.qualified('Target'), alvo),
        if (externo) XmlAttribute(XmlName.qualified('TargetMode'), 'External'),
      ]),
    );
    _relsMudou = true;
    return 'rId$n';
  }
}
