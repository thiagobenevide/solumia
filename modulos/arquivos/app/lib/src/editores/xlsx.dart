/// Planilha XLSX lida e gravada direto no zip (sem o pacote `excel`, incompatível com xml 7).
///
/// Na gravação só o XML das abas alteradas é reescrito; estilos, gráficos, imagens e o resto do
/// pacote ficam como estavam. Linhas e colunas são 0-based na API (`refCelula(0, 0)` = `A1`).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

const maxLinhas = 1048576;
const maxColunas = 16384;

/// XLSX que não dá para abrir; [mensagem] em português para mostrar ao usuário.
class XlsxInvalido implements Exception {
  XlsxInvalido(this.mensagem);

  final String mensagem;

  @override
  String toString() => mensagem;
}

/// `0` → `A`, `27` → `AB`.
String letrasDaColuna(int coluna) {
  var n = coluna + 1;
  var s = '';
  while (n > 0) {
    s = String.fromCharCode(65 + (n - 1) % 26) + s;
    n = (n - 1) ~/ 26;
  }
  return s;
}

/// `A` → `0`, `AB` → `27`.
int colunaDeLetras(String letras) {
  if (letras.isEmpty) throw const FormatException('Coluna vazia');
  var n = 0;
  for (final u in letras.toUpperCase().codeUnits) {
    if (u < 65 || u > 90) throw FormatException('Coluna inválida: $letras');
    n = n * 26 + (u - 64);
  }
  return n - 1;
}

/// `(2, 1)` → `B3`.
String refCelula(int linha, int coluna) => '${letrasDaColuna(coluna)}${linha + 1}';

final _reRefSimples = RegExp(r'^\$?([A-Za-z]{1,3})\$?(\d+)$');

/// `B3` (ou `$B$3`) → `(2, 1)`.
(int, int) lerRef(String ref) {
  final m = _reRefSimples.firstMatch(ref.trim());
  if (m == null) throw FormatException('Referência inválida: $ref');
  return (int.parse(m[2]!) - 1, colunaDeLetras(m[1]!));
}

/// Pasta de trabalho: abas na ordem do workbook e o zip original para regravar.
class Pasta {
  Pasta._(this._zip, this.abas, this._workbook, this._relsWorkbook);

  final Archive _zip;
  final String _workbook;
  final String _relsWorkbook;
  final List<Aba> abas;

  bool get alterada => abas.any((a) => a.alterada);

  static Pasta ler(Uint8List bytes) {
    final Archive zip;
    try {
      zip = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw XlsxInvalido('O arquivo não é um XLSX válido (zip corrompido ou protegido por senha).');
    }
    String? texto(String caminho) {
      final f = zip.find(caminho);
      return f == null ? null : utf8.decode(f.content, allowMalformed: true);
    }

    XmlDocument xml(String caminho) {
      final t = texto(caminho);
      if (t == null) throw XlsxInvalido('XLSX incompleto: falta $caminho.');
      try {
        return XmlDocument.parse(t);
      } on XmlException {
        throw XlsxInvalido('XLSX com XML inválido em $caminho.');
      }
    }

    var workbook = 'xl/workbook.xml';
    if (zip.find('_rels/.rels') != null) {
      for (final r in _relacoes(xml('_rels/.rels'))) {
        if (r.tipo.endsWith('/officeDocument')) workbook = _resolver('', r.alvo);
      }
    }
    if (zip.find(workbook) == null) throw XlsxInvalido('O arquivo não é uma planilha XLSX (falta o workbook).');
    final pasta = workbook.contains('/') ? workbook.substring(0, workbook.lastIndexOf('/') + 1) : '';
    final relsWorkbook = '${pasta}_rels/${workbook.substring(pasta.length)}.rels';
    final rels = zip.find(relsWorkbook) == null ? <_Relacao>[] : _relacoes(xml(relsWorkbook));

    final compartilhadas = <String>[];
    for (final r in rels.where((r) => r.tipo.endsWith('/sharedStrings'))) {
      final doc = xml(_resolver(pasta, r.alvo));
      compartilhadas.addAll(doc.rootElement.findElements('si', namespaceUri: '*').map(_textoRico));
    }

    final abas = <Aba>[];
    for (final s in xml(workbook).findAllElements('sheet', namespaceUri: '*')) {
      final id = s.getAttribute('id', namespaceUri: '*');
      final rel = rels.where((r) => r.id == id && r.tipo.endsWith('/worksheet')).firstOrNull;
      if (rel == null) continue; // aba de gráfico ou de macro: fica no zip, sem editor
      final caminho = _resolver(pasta, rel.alvo);
      final t = texto(caminho);
      if (t == null) throw XlsxInvalido('XLSX incompleto: falta $caminho.');
      abas.add(Aba._(s.getAttribute('name') ?? 'Planilha${abas.length + 1}', caminho, t, compartilhadas));
    }
    if (abas.isEmpty) throw XlsxInvalido('A planilha não tem nenhuma aba de células.');
    final p = Pasta._(zip, abas, workbook, relsWorkbook);
    for (final a in abas) {
      a._pasta = p;
    }
    return p;
  }

  /// Zip novo: abas alteradas reescritas; com qualquer alteração sai o `calcChain.xml` e o
  /// workbook pede recálculo ao abrir (os valores em cache das fórmulas ficaram velhos).
  Uint8List gravar() {
    final trocas = <String, String>{for (final a in abas.where((a) => a.alterada)) a._caminho: a._gerarXml()};
    final remover = <String>{};
    if (trocas.isNotEmpty) {
      final pasta = _workbook.substring(0, _workbook.lastIndexOf('/') + 1);
      final rels = _textoDe(_relsWorkbook);
      if (rels != null) {
        final doc = XmlDocument.parse(rels);
        for (final r in doc.findAllElements('Relationship', namespaceUri: '*').toList()) {
          if ((r.getAttribute('Type') ?? '').endsWith('/calcChain')) {
            remover.add(_resolver(pasta, r.getAttribute('Target') ?? ''));
            r.remove();
          }
        }
        if (remover.isNotEmpty) trocas[_relsWorkbook] = doc.toXmlString();
      }
      final tipos = _textoDe('[Content_Types].xml');
      if (tipos != null && remover.isNotEmpty) {
        final doc = XmlDocument.parse(tipos);
        for (final o in doc.findAllElements('Override', namespaceUri: '*').toList()) {
          if (remover.contains((o.getAttribute('PartName') ?? '').replaceFirst(RegExp('^/'), ''))) o.remove();
        }
        trocas['[Content_Types].xml'] = doc.toXmlString();
      }
      trocas[_workbook] = _recalcularAoAbrir(_textoDe(_workbook)!);
    }
    final novo = Archive();
    for (final f in _zip.files) {
      if (remover.contains(f.name)) continue;
      final t = trocas[f.name];
      novo.add(t == null ? f : ArchiveFile.bytes(f.name, utf8.encode(t)));
    }
    return ZipEncoder().encodeBytes(novo);
  }

  String? _textoDe(String caminho) {
    final f = _zip.find(caminho);
    return f == null ? null : utf8.decode(f.content, allowMalformed: true);
  }

  static String _recalcularAoAbrir(String xml) {
    final doc = XmlDocument.parse(xml);
    final raiz = doc.rootElement;
    final calc = raiz.findElements('calcPr', namespaceUri: '*').firstOrNull;
    if (calc != null) {
      calc.setAttribute('fullCalcOnLoad', '1');
    } else {
      // Ordem do esquema: calcPr vem logo depois de sheets/functionGroups/externalReferences/definedNames.
      const antes = {'sheets', 'functionGroups', 'externalReferences', 'definedNames'};
      final ancora = raiz.childElements.where((e) => antes.contains(e.localName)).lastOrNull;
      final p = raiz.name.prefix;
      final novo = XmlDocumentFragment.parse('<${p == null ? '' : '$p:'}calcPr fullCalcOnLoad="1"/>').firstElementChild!.copy();
      if (ancora == null) {
        raiz.children.add(novo);
      } else {
        raiz.children.insert(raiz.children.indexOf(ancora) + 1, novo);
      }
    }
    return doc.toXmlString();
  }
}

/// Uma aba de células. O XML é interpretado só no primeiro acesso.
class Aba {
  Aba._(this.nome, this._caminho, this._xmlOriginal, this._compartilhadas);

  final String nome;
  final String _caminho;
  final String _xmlOriginal;
  final List<String> _compartilhadas;
  late final Pasta _pasta;
  bool alterada = false;

  final _grade = <_Linha?>[];
  final _operacoes = <_Operacao>[];
  bool _carregada = false;
  int? _linhasCache;
  int? _colunasCache;

  /// Linhas até a última com conteúdo.
  int get linhas {
    _carregar();
    return _linhasCache ??= () {
      for (var i = _grade.length - 1; i >= 0; i--) {
        if (_grade[i]?.celulas.any((c) => c != null) ?? false) return i + 1;
      }
      return 0;
    }();
  }

  /// Colunas até a última com conteúdo em qualquer linha.
  int get colunas {
    _carregar();
    return _colunasCache ??= _grade.fold<int>(0, (n, l) {
      if (l == null) return n;
      for (var c = l.celulas.length - 1; c >= n; c--) {
        if (l.celulas[c] != null) return c + 1;
      }
      return n;
    });
  }

  /// Valor exibido (cache da fórmula; booleano como VERDADEIRO/FALSO; data como número).
  String celula(int linha, int coluna) => _em(linha, coluna)?.exibido ?? '';

  /// O que se edita: `=FÓRMULA` ou o valor.
  String conteudo(int linha, int coluna) {
    final c = _em(linha, coluna);
    if (c == null) return '';
    return c.formula != null ? '=${c.formula}' : c.exibido;
  }

  /// Fórmula sem o `=`, ou `null`.
  String? formula(int linha, int coluna) => _em(linha, coluna)?.formula;

  /// Texto começando com `=` vira fórmula; número (ponto ou vírgula decimal) vira número; vazio
  /// limpa o valor mas mantém o estilo da célula.
  void definir(int linha, int coluna, String valor) {
    _validar(linha, coluna);
    if (conteudo(linha, coluna) == valor) return;
    final estilo = _em(linha, coluna)?.estilo;
    final _Celula? nova;
    if (valor.isEmpty) {
      nova = estilo == null ? null : _Celula(exibido: '', estilo: estilo);
    } else if (valor.length > 1 && valor.startsWith('=')) {
      nova = _Celula(exibido: valor, formula: valor.substring(1), estilo: estilo);
    } else if (_numero(valor) case final n?) {
      nova = _Celula(exibido: n, estilo: estilo, numero: true);
    } else {
      nova = _Celula(exibido: valor, estilo: estilo);
    }
    while (_grade.length <= linha) {
      _grade.add(null);
    }
    final l = _grade[linha] ??= _Linha({});
    while (l.celulas.length <= coluna) {
      l.celulas.add(null);
    }
    l.celulas[coluna] = nova;
    _mudou();
  }

  void inserirLinha(int linha) => _estrutura(_Operacao(true, linha, 1));
  void excluirLinha(int linha) => _estrutura(_Operacao(true, linha, -1));
  void inserirColuna(int coluna) => _estrutura(_Operacao(false, coluna, 1));
  void excluirColuna(int coluna) => _estrutura(_Operacao(false, coluna, -1));

  // ---------------------------------------------------------------- interno

  _Celula? _em(int linha, int coluna) {
    _carregar();
    if (linha < 0 || linha >= _grade.length) return null;
    final l = _grade[linha];
    return l == null || coluna < 0 || coluna >= l.celulas.length ? null : l.celulas[coluna];
  }

  void _validar(int linha, int coluna) {
    RangeError.checkValueInInterval(linha, 0, maxLinhas - 1, 'linha');
    RangeError.checkValueInInterval(coluna, 0, maxColunas - 1, 'coluna');
  }

  void _mudou() {
    alterada = true;
    _linhasCache = null;
    _colunasCache = null;
  }

  void _estrutura(_Operacao op) {
    _carregar();
    _validar(op.linha ? op.indice : 0, op.linha ? 0 : op.indice);
    if (op.linha) {
      if (op.delta > 0) {
        if (op.indice < _grade.length) _grade.insert(op.indice, null);
      } else if (op.indice < _grade.length) {
        _grade.removeAt(op.indice);
      }
    } else {
      for (final l in _grade) {
        if (l == null || op.indice >= l.celulas.length) continue;
        op.delta > 0 ? l.celulas.insert(op.indice, null) : l.celulas.removeAt(op.indice);
      }
    }
    _operacoes.add(op);
    _mudou();
    // Fórmulas desta aba (referências sem aba ou com o nome dela) e das outras que apontam para cá.
    for (final a in _pasta.abas) {
      a._carregar();
      var mexeu = false;
      for (final l in a._grade) {
        for (final c in l?.celulas ?? const <_Celula?>[]) {
          if (c?.formula == null) continue;
          final f = _trocarRefs(c!.formula!, (aba) => aba == null ? identical(a, this) : _mesmoNome(aba, nome), op.mapear);
          if (c.matriz != null) c.matriz = _mapearIntervalos(c.matriz!, op.mapear) ?? c.matriz;
          if (f != c.formula) {
            c.formula = f;
            mexeu = true;
          }
        }
      }
      if (mexeu && !identical(a, this)) a._mudou();
    }
  }

  void _carregar() {
    if (_carregada) return;
    _carregada = true;
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(_xmlOriginal);
    } on XmlException {
      throw XlsxInvalido('XLSX com XML inválido em $_caminho.');
    }
    final dados = doc.rootElement.findElements('sheetData', namespaceUri: '*').firstOrNull;
    if (dados == null) return;
    // Fórmulas compartilhadas: a primeira célula (mestre) tem o texto; as outras só o `si`.
    final mestres = <String, (String, int, int)>{};
    final pendentes = <(_Celula, String, int, int)>[];
    var linha = -1;
    for (final row in dados.findElements('row', namespaceUri: '*')) {
      final r = int.tryParse(row.getAttribute('r') ?? '');
      linha = r != null ? r - 1 : linha + 1;
      if (linha < 0 || linha >= maxLinhas) continue;
      final atributos = {
        for (final a in row.attributes)
          if (a.localName != 'r' && a.localName != 'spans') a.name.qualified: a.value,
      };
      final l = _Linha(atributos);
      var coluna = -1;
      for (final c in row.findElements('c', namespaceUri: '*')) {
        final ref = c.getAttribute('r');
        coluna = ref == null ? coluna + 1 : (_tentarRef(ref)?.$2 ?? coluna + 1);
        if (coluna >= maxColunas) continue;
        final celula = _lerCelula(c);
        final f = c.findElements('f', namespaceUri: '*').firstOrNull;
        if (f != null && f.getAttribute('t') == 'shared') {
          final si = f.getAttribute('si') ?? '';
          if (f.innerText.isNotEmpty) {
            mestres[si] = (f.innerText, linha, coluna);
          } else {
            pendentes.add((celula, si, linha, coluna));
          }
        }
        while (l.celulas.length <= coluna) {
          l.celulas.add(null);
        }
        l.celulas[coluna] = celula;
      }
      while (_grade.length <= linha) {
        _grade.add(null);
      }
      _grade[linha] = l;
    }
    for (final (celula, si, linha, coluna) in pendentes) {
      final m = mestres[si];
      if (m == null) continue;
      final (texto, ml, mc) = m;
      celula.formula = _trocarRefs(texto, (_) => true, (a, b, ehLinha) {
        final d = ehLinha ? linha - ml : coluna - mc;
        return (a + d, b + d);
      }, relativas: true);
    }
  }

  _Celula _lerCelula(XmlElement c) {
    final tipo = c.getAttribute('t');
    final v = c.findElements('v', namespaceUri: '*').firstOrNull?.innerText ?? '';
    final f = c.findElements('f', namespaceUri: '*').firstOrNull;
    final i = int.tryParse(v) ?? -1;
    final exibido = switch (tipo) {
      's' => i >= 0 && i < _compartilhadas.length ? _compartilhadas[i] : '',
      'inlineStr' => c.findElements('is', namespaceUri: '*').map(_textoRico).join(),
      'b' => v == '1' ? 'VERDADEIRO' : 'FALSO',
      _ => v,
    };
    return _Celula(
      exibido: exibido,
      estilo: c.getAttribute('s'),
      xml: c,
      formula: f == null || f.getAttribute('t') == 'dataTable' ? null : f.innerText,
      tabelaDados: f?.getAttribute('t') == 'dataTable',
      matriz: f?.getAttribute('t') == 'array' ? f!.getAttribute('ref') : null,
    );
  }

  /// XML da aba com o `sheetData` refeito do modelo e as referências fixas da aba (mesclas,
  /// colunas, links, validações) ajustadas às linhas/colunas inseridas e excluídas.
  String _gerarXml() {
    _carregar();
    final doc = XmlDocument.parse(_xmlOriginal);
    final raiz = doc.rootElement;
    final p = raiz.name.prefix;
    String tag(String n) => p == null ? n : '$p:$n';
    var dados = raiz.findElements('sheetData', namespaceUri: '*').firstOrNull;
    if (dados == null) {
      dados = XmlDocumentFragment.parse('<${tag('sheetData')}/>').firstElementChild!.copy();
      raiz.children.add(dados);
    }
    const removiveis = {'mergeCell', 'hyperlink', 'conditionalFormatting', 'dataValidation', 'protectedRange', 'ignoredError', 'autoFilter'};
    if (_operacoes.isNotEmpty) {
      for (final e in raiz.descendantElements.toList()) {
        if (e.localName == 'sheetData' || e.localName == 'dimension') continue;
        if (e.ancestorElements.any((a) => a.localName == 'sheetData')) continue;
        if (e.localName == 'col') {
          var faixa = (int.tryParse(e.getAttribute('min') ?? '') ?? 1) - 1;
          var fim = (int.tryParse(e.getAttribute('max') ?? '') ?? 1) - 1;
          (int, int)? r = (faixa, fim);
          for (final op in _operacoes.where((o) => !o.linha)) {
            r = r == null ? null : op.mapear(r.$1, r.$2, false);
          }
          if (r == null) {
            e.remove();
          } else {
            (faixa, fim) = r;
            e.setAttribute('min', '${faixa + 1}');
            e.setAttribute('max', '${fim + 1}');
          }
          continue;
        }
        for (final atributo in ['ref', 'sqref', 'activeCell']) {
          final valor = e.getAttribute(atributo);
          if (valor == null) continue;
          String? novo = valor;
          for (final op in _operacoes) {
            novo = novo == null ? null : _mapearIntervalos(novo, op.mapear);
          }
          if (novo != null) {
            e.setAttribute(atributo, novo);
          } else if (removiveis.contains(e.localName)) {
            e.remove();
          } else {
            e.setAttribute(atributo, 'A1');
          }
        }
      }
      for (final m in raiz.findElements('mergeCells', namespaceUri: '*').toList()) {
        final n = m.findElements('mergeCell', namespaceUri: '*').length;
        n == 0 ? m.remove() : m.setAttribute('count', '$n');
      }
    }
    final dimensao = raiz.findElements('dimension', namespaceUri: '*').firstOrNull;
    final (ls, cs) = (linhas, colunas);
    dimensao?.setAttribute('ref', ls == 0 || cs == 0 ? 'A1' : 'A1:${refCelula(ls - 1, cs - 1)}');

    final corpo = StringBuffer();
    for (var i = 0; i < _grade.length; i++) {
      final l = _grade[i];
      if (l == null) continue;
      final celulas = StringBuffer();
      for (var c = 0; c < l.celulas.length; c++) {
        final cel = l.celulas[c];
        if (cel != null) celulas.write(_xmlCelula(cel, refCelula(i, c), tag));
      }
      if (celulas.isEmpty && l.atributos.isEmpty) continue;
      corpo.write('<${tag('row')} r="${i + 1}"');
      l.atributos.forEach((k, v) => corpo.write(' $k="${_escapar(v)}"'));
      corpo.write(celulas.isEmpty ? '/>' : '>$celulas</${tag('row')}>');
    }
    dados.children.clear();
    dados.children.add(XmlComment('__planilha__'));
    return doc.toXmlString().replaceFirst('<!--__planilha__-->', corpo.toString());
  }

  String _xmlCelula(_Celula c, String ref, String Function(String) tag) {
    final original = c.xml;
    if (original != null) {
      final copia = original.copy()..setAttribute('r', ref);
      final f = copia.findElements('f', namespaceUri: '*').firstOrNull;
      if (f != null && c.formula != null && !c.tabelaDados) {
        // Fórmula compartilhada vira explícita: a mestre pode ter mudado ou saído do lugar.
        f.innerText = c.formula!;
        for (final a in ['si', 'ref']) {
          f.removeAttribute(a);
        }
        if (c.matriz != null) {
          f.setAttribute('ref', c.matriz);
        } else {
          f.removeAttribute('t');
        }
      }
      return copia.toXmlString();
    }
    final atributos = ' r="$ref"${c.estilo == null ? '' : ' s="${c.estilo}"'}';
    if (c.formula != null) return '<${tag('c')}$atributos><${tag('f')}>${_escapar(c.formula!)}</${tag('f')}></${tag('c')}>';
    if (c.exibido.isEmpty) return '<${tag('c')}$atributos/>';
    if (c.numero) return '<${tag('c')}$atributos><${tag('v')}>${c.exibido}</${tag('v')}></${tag('c')}>';
    return '<${tag('c')}$atributos t="inlineStr"><${tag('is')}><${tag('t')} xml:space="preserve">'
        '${_escapar(c.exibido)}</${tag('t')}></${tag('is')}></${tag('c')}>';
  }
}

class _Linha {
  _Linha(this.atributos);

  /// Atributos do `<row>` (altura, oculta, estilo), sem `r` e `spans`.
  final Map<String, String> atributos;
  final celulas = <_Celula?>[];
}

class _Celula {
  _Celula({required this.exibido, this.estilo, this.xml, this.formula, this.matriz, this.numero = false, this.tabelaDados = false});

  final String exibido;
  final String? estilo;

  /// Elemento original, regravado como veio (só `r` e a fórmula ajustados); `null` = célula editada.
  final XmlElement? xml;
  String? formula;
  String? matriz;
  final bool numero;
  final bool tabelaDados;
}

/// Inserção (`delta` 1) ou exclusão (`-1`) de uma linha ou coluna em [indice].
class _Operacao {
  _Operacao(this.linha, this.indice, this.delta);

  final bool linha;
  final int indice;
  final int delta;

  /// Novo intervalo `[a, b]` no eixo afetado; `null` quando ele some inteiro.
  (int, int)? mapear(int a, int b, bool ehLinha) {
    if (ehLinha != linha) return (a, b);
    final p = indice;
    if (delta > 0) return (a >= p ? a + 1 : a, b >= p ? b + 1 : b);
    if (p < a) return (a - 1, b - 1);
    if (p > b) return (a, b);
    return a == b ? null : (a, b - 1);
  }
}

typedef _Mapa = (int, int)? Function(int a, int b, bool ehLinha);

// Literal de texto (ignorado) | prefixo de aba opcional + A1 ou A1:B2. Nome de função como LOG10(
// não casa por causa do lookahead.
final _reFormula = RegExp(
  r'''("(?:[^"]|"")*")|((?:'(?:[^']|'')+'|[A-Za-z_\\][\w.\\]*)!)?(?<![\w.$])(\$?)([A-Z]{1,3})(\$?)(\d+)(?::(\$?)([A-Z]{1,3})(\$?)(\d+))?(?![\w(!])''',
);

/// Reescreve as referências A1 de [formula] cujo prefixo de aba passa em [alvo] (`null` = sem
/// prefixo). Com [relativas], só as partes sem `$` mudam (cópia de fórmula compartilhada).
String _trocarRefs(String formula, bool Function(String? aba) alvo, _Mapa mapa, {bool relativas = false}) {
  return formula.replaceAllMapped(_reFormula, (m) {
    if (m[1] != null) return m[0]!;
    final prefixo = m[2];
    if (!alvo(prefixo?.substring(0, prefixo.length - 1))) return m[0]!;
    final c1 = colunaDeLetras(m[4]!), l1 = int.parse(m[6]!) - 1;
    final temFim = m[8] != null;
    final c2 = temFim ? colunaDeLetras(m[8]!) : c1, l2 = temFim ? int.parse(m[10]!) - 1 : l1;
    if (c1 >= maxColunas || c2 >= maxColunas) return m[0]!;
    int? nc1 = c1, nc2 = c2, nl1 = l1, nl2 = l2;
    if (relativas) {
      final dc = mapa(0, 0, false)!.$1, dl = mapa(0, 0, true)!.$1;
      if (m[3]!.isEmpty) nc1 = c1 + dc;
      if (m[5]!.isEmpty) nl1 = l1 + dl;
      if (temFim && m[7]!.isEmpty) nc2 = c2 + dc;
      if (temFim && m[9]!.isEmpty) nl2 = l2 + dl;
    } else {
      final cs = mapa(c1, c2, false), ls = mapa(l1, l2, true);
      if (cs == null || ls == null) return '${prefixo ?? ''}#REF!';
      (nc1, nc2, nl1, nl2) = (cs.$1, cs.$2, ls.$1, ls.$2);
    }
    if ([nc1, nc2].any((c) => c < 0 || c >= maxColunas) || [nl1, nl2].any((l) => l < 0 || l >= maxLinhas)) {
      return '${prefixo ?? ''}#REF!';
    }
    final inicio = '${m[3]}${letrasDaColuna(nc1)}${m[5]}${nl1 + 1}';
    final fim = temFim ? ':${m[7]}${letrasDaColuna(nc2)}${m[9]}${nl2 + 1}' : '';
    return '${prefixo ?? ''}$inicio$fim';
  });
}

/// `A1:B2 C3` com cada intervalo mapeado; os que somem saem. `null` se não sobrar nenhum.
String? _mapearIntervalos(String sqref, _Mapa mapa) {
  final novos = <String>[];
  for (final parte in sqref.split(' ').where((p) => p.isNotEmpty)) {
    final pontas = parte.split(':');
    final a = _tentarRef(pontas.first), b = _tentarRef(pontas.last);
    if (a == null || b == null) {
      novos.add(parte);
      continue;
    }
    final ls = mapa(a.$1, b.$1, true), cs = mapa(a.$2, b.$2, false);
    if (ls == null || cs == null) continue;
    final inicio = refCelula(ls.$1, cs.$1);
    novos.add(pontas.length == 1 ? inicio : '$inicio:${refCelula(ls.$2, cs.$2)}');
  }
  return novos.isEmpty ? null : novos.join(' ');
}

(int, int)? _tentarRef(String ref) {
  try {
    return lerRef(ref);
  } on FormatException {
    return null;
  }
}

bool _mesmoNome(String prefixo, String nome) {
  final p = prefixo.startsWith("'") && prefixo.endsWith("'") ? prefixo.substring(1, prefixo.length - 1).replaceAll("''", "'") : prefixo;
  return p.toLowerCase() == nome.toLowerCase();
}

final _reNumero = RegExp(r'^-?\d+([.,]\d+)?([eE][-+]?\d+)?$');

/// Número como o Excel grava em `<v>` (ponto decimal), aceitando vírgula; `null` se não é número.
String? _numero(String valor) {
  final v = valor.trim();
  if (!_reNumero.hasMatch(v)) return null;
  final n = v.replaceFirst(',', '.');
  return double.tryParse(n) == null ? null : n;
}

final _reEscapeOoxml = RegExp(r'_x([0-9A-Fa-f]{4})_');

/// Texto de `<si>`/`<is>`: `<t>` direto ou as partes `<r><t>` do texto rico, sem a fonética (`rPh`).
String _textoRico(XmlElement e) => e
    .findAllElements('t', namespaceUri: '*')
    .where((t) => t.parentElement?.localName != 'rPh')
    .map((t) => t.innerText)
    .join()
    .replaceAllMapped(_reEscapeOoxml, (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)));

final _reInvalidoXml = RegExp('[\u0000-\u0008\u000B\u000C\u000E-\u001F]');

String _escapar(String s) => s
    .replaceAll(_reInvalidoXml, '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

class _Relacao {
  _Relacao(this.id, this.tipo, this.alvo);

  final String id;
  final String tipo;
  final String alvo;
}

List<_Relacao> _relacoes(XmlDocument doc) => [
  for (final r in doc.findAllElements('Relationship', namespaceUri: '*'))
    if (r.getAttribute('TargetMode') != 'External')
      _Relacao(r.getAttribute('Id') ?? '', r.getAttribute('Type') ?? '', r.getAttribute('Target') ?? ''),
];

/// Caminho no zip de um alvo de relação relativo a [pasta] (`xl/`); `/xl/...` é absoluto.
String _resolver(String pasta, String alvo) {
  if (alvo.startsWith('/')) return alvo.substring(1);
  final partes = <String>[...pasta.split('/').where((p) => p.isNotEmpty)];
  for (final p in alvo.split('/')) {
    if (p == '..') {
      if (partes.isNotEmpty) partes.removeLast();
    } else if (p.isNotEmpty && p != '.') {
      partes.add(p);
    }
  }
  return partes.join('/');
}
