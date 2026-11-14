import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// PPTX para o editor de apresentações: slides na ordem de `presentation.xml`, formas com texto
/// (posição herdada do layout/mestre quando o slide não traz), imagens e o resto como caixa
/// cinza. Edita texto, estilo da caixa, posição/tamanho, cria/exclui caixas e duplica, exclui e
/// reordena slides; ao gravar só as partes mexidas mudam no zip.

const _nsP = 'http://schemas.openxmlformats.org/presentationml/2006/main';
const _nsA = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const _nsR = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _nsRels = 'http://schemas.openxmlformats.org/package/2006/relationships';
const _nsTipos = 'http://schemas.openxmlformats.org/package/2006/content-types';
const _relSlide = '$_nsR/slide';
const _relLayout = '$_nsR/slideLayout';
const _relMestre = '$_nsR/slideMaster';
const _relNotas = '$_nsR/notesSlide';
const _tipoSlide = 'application/vnd.openxmlformats-officedocument.presentationml.slide+xml';

const _caminhoApresentacao = 'ppt/presentation.xml';
const _caminhoTipos = '[Content_Types].xml';

/// 1 pt em EMU.
const emuPorPonto = 12700.0;

class PptxInvalido implements Exception {
  PptxInvalido(this.mensagem);

  final String mensagem;

  @override
  String toString() => mensagem;
}

String _relsDe(String parte) {
  final i = parte.lastIndexOf('/');
  return '${parte.substring(0, i)}/_rels/${parte.substring(i + 1)}.rels';
}

/// Alvo relativo de uma relação → caminho no zip.
String _resolver(String base, String alvo) {
  if (alvo.startsWith('/')) return alvo.substring(1);
  final partes = base.split('/')..removeLast();
  for (final p in alvo.split('/')) {
    if (p == '..') {
      if (partes.isNotEmpty) partes.removeLast();
    } else if (p != '.') {
      partes.add(p);
    }
  }
  return partes.join('/');
}

String _esc(String s) => s
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

XmlElement _elemento(String xml) => XmlDocument.parse(
  '<x xmlns:a="$_nsA" xmlns:p="$_nsP" xmlns:r="$_nsR">$xml</x>',
).rootElement.childElements.single.copy();

XmlElement? _a(XmlElement? e, String nome) => e?.getElement(nome, namespaceUri: _nsA);
XmlElement? _p(XmlElement? e, String nome) => e?.getElement(nome, namespaceUri: _nsP);

class Apresentacao {
  Apresentacao._(this._zip, this.largura, this.altura);

  final Archive _zip;

  /// Tamanho do slide em EMU.
  final double largura;
  final double altura;

  final slides = <Slide>[];
  final _xml = <String, XmlDocument>{};
  final _mexidos = <String>{};
  final _removidos = <String>{};
  bool alterada = false;

  static Apresentacao ler(Uint8List bytes) {
    final Archive zip;
    try {
      zip = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw PptxInvalido('Não é um .pptx válido (não é um pacote zip). .ppt e .odp não abrem aqui.');
    }
    if (zip.findFile(_caminhoApresentacao) == null) throw PptxInvalido('Não é um .pptx válido: falta $_caminhoApresentacao.');
    final provisoria = Apresentacao._(zip, 0, 0);
    final pres = provisoria._doc(_caminhoApresentacao)!.rootElement;
    final tam = _p(pres, 'sldSz');
    final ap = Apresentacao._(
      zip,
      double.tryParse(tam?.getAttribute('cx') ?? '') ?? 12192000,
      double.tryParse(tam?.getAttribute('cy') ?? '') ?? 6858000,
    );
    final rels = ap._rels(_caminhoApresentacao);
    for (final id in _p(ap._doc(_caminhoApresentacao)!.rootElement, 'sldIdLst')?.childElements ?? const <XmlElement>[]) {
      final alvo = rels[id.getAttribute('id', namespaceUri: _nsR)];
      if (alvo == null || ap._doc(alvo) == null) continue;
      ap.slides.add(Slide._(ap, alvo));
    }
    return ap;
  }

  XmlDocument? _doc(String caminho) {
    if (_xml.containsKey(caminho)) return _xml[caminho];
    final f = _zip.findFile(caminho);
    if (f == null) return null;
    try {
      return _xml[caminho] = XmlDocument.parse(utf8.decode(f.content, allowMalformed: true));
    } on XmlException catch (e) {
      throw PptxInvalido('XML quebrado em $caminho ($e).');
    }
  }

  Uint8List? bytes(String caminho) {
    if (_removidos.contains(caminho)) return null;
    return _zip.findFile(caminho)?.content;
  }

  /// rId → caminho no zip; [tipos] guarda o tipo de cada relação.
  Map<String, String> _rels(String parte, {Map<String, String>? tipos}) {
    final doc = _doc(_relsDe(parte));
    final r = <String, String>{};
    for (final e in doc?.rootElement.childElements ?? const <XmlElement>[]) {
      final id = e.getAttribute('Id');
      final alvo = e.getAttribute('Target');
      if (id == null || alvo == null || e.getAttribute('TargetMode') == 'External') continue;
      r[id] = _resolver(parte, alvo);
      tipos?[id] = e.getAttribute('Type') ?? '';
    }
    return r;
  }

  String? _relDoTipo(String parte, String tipo) {
    final tipos = <String, String>{};
    final rels = _rels(parte, tipos: tipos);
    return rels.entries.where((e) => tipos[e.key] == tipo).firstOrNull?.value;
  }

  void _mexeu(String caminho) {
    _mexidos.add(caminho);
    alterada = true;
  }

  XmlElement get _listaIds => _p(_doc(_caminhoApresentacao)!.rootElement, 'sldIdLst')!;

  /// Duplica o slide [i] logo depois dele. [vazio] tira o texto e as formas que não são do layout.
  Slide duplicar(int i, {bool vazio = false}) {
    final origem = slides[i];
    final usados = _zip.files.map((f) => f.name).toSet()..addAll(_xml.keys);
    var n = slides.length + 1;
    while (usados.contains('ppt/slides/slide$n.xml')) {
      n++;
    }
    final caminho = 'ppt/slides/slide$n.xml';
    _xml[caminho] = XmlDocument.parse(origem.xml.toXmlString());
    final relsOrigem = _doc(_relsDe(origem.caminho));
    final rels = relsOrigem == null
        ? XmlDocument.parse('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="$_nsRels"/>')
        : XmlDocument.parse(relsOrigem.toXmlString());
    // As notas pertencem a um slide só: a cópia sai sem elas.
    rels.rootElement.children.removeWhere((e) => e is XmlElement && e.getAttribute('Type') == _relNotas);
    _xml[_relsDe(caminho)] = rels;
    _mexeu(caminho);
    _mexeu(_relsDe(caminho));

    final tipos = _doc(_caminhoTipos)!;
    tipos.rootElement.children.add(
      XmlElement(XmlName.qualified('Override', namespaceUri: _nsTipos), [
        XmlAttribute(XmlName.qualified('PartName'), '/$caminho'),
        XmlAttribute(XmlName.qualified('ContentType'), _tipoSlide),
      ]),
    );
    _mexeu(_caminhoTipos);

    final relsPres = _doc(_relsDe(_caminhoApresentacao))!;
    final ids = relsPres.rootElement.childElements.map((e) => e.getAttribute('Id')).toSet();
    var r = ids.length + 1;
    while (ids.contains('rId$r')) {
      r++;
    }
    relsPres.rootElement.children.add(
      XmlElement(XmlName.qualified('Relationship', namespaceUri: _nsRels), [
        XmlAttribute(XmlName.qualified('Id'), 'rId$r'),
        XmlAttribute(XmlName.qualified('Type'), _relSlide),
        XmlAttribute(XmlName.qualified('Target'), 'slides/slide$n.xml'),
      ]),
    );
    _mexeu(_relsDe(_caminhoApresentacao));

    final lista = _listaIds;
    final maior = lista.childElements.map((e) => int.tryParse(e.getAttribute('id') ?? '') ?? 255).fold(255, (a, b) => a > b ? a : b);
    final novoId = _elemento('<p:sldId id="${maior + 1}" r:id="rId$r"/>');
    final elementos = lista.childElements.toList();
    lista.children.insert(lista.children.indexOf(elementos[i]) + 1, novoId);
    _mexeu(_caminhoApresentacao);

    final novo = Slide._(this, caminho);
    if (vazio) {
      for (final f in novo.formas.toList()) {
        if (f.placeholder) {
          f.texto = '';
        } else {
          novo.excluir(f);
        }
      }
    }
    slides.insert(i + 1, novo);
    return novo;
  }

  void excluir(int i) {
    if (slides.length <= 1) return;
    final s = slides.removeAt(i);
    final lista = _listaIds;
    final elemento = lista.childElements.toList()[i];
    final rId = elemento.getAttribute('id', namespaceUri: _nsR);
    lista.children.remove(elemento);
    _mexeu(_caminhoApresentacao);
    final relsPres = _doc(_relsDe(_caminhoApresentacao))!;
    relsPres.rootElement.children.removeWhere((e) => e is XmlElement && e.getAttribute('Id') == rId);
    _mexeu(_relsDe(_caminhoApresentacao));
    final notas = _relDoTipo(s.caminho, _relNotas);
    final tipos = _doc(_caminhoTipos)!;
    for (final parte in [s.caminho, ?notas]) {
      _removidos.addAll([parte, _relsDe(parte)]);
      tipos.rootElement.children.removeWhere((e) => e is XmlElement && e.getAttribute('PartName') == '/$parte');
    }
    _mexeu(_caminhoTipos);
  }

  void mover(int de, int para) {
    if (para < 0 || para >= slides.length || de == para) return;
    final lista = _listaIds;
    final elementos = lista.childElements.toList();
    final e = elementos[de];
    lista.children.remove(e);
    final restantes = lista.childElements.toList();
    if (para >= restantes.length) {
      lista.children.add(e);
    } else {
      lista.children.insert(lista.children.indexOf(restantes[para]), e);
    }
    slides.insert(para, slides.removeAt(de));
    _mexeu(_caminhoApresentacao);
  }

  Uint8List gravar() {
    final saida = Archive();
    final nomes = <String>{};
    for (final f in _zip.files) {
      if (!f.isFile || _removidos.contains(f.name)) continue;
      nomes.add(f.name);
      final doc = _mexidos.contains(f.name) ? _xml[f.name] : null;
      saida.add(ArchiveFile.bytes(f.name, doc != null ? utf8.encode(doc.toXmlString()) : f.content));
    }
    for (final c in _mexidos) {
      if (nomes.contains(c) || _removidos.contains(c)) continue;
      saida.add(ArchiveFile.bytes(c, utf8.encode(_xml[c]!.toXmlString())));
    }
    alterada = false;
    return ZipEncoder().encodeBytes(saida);
  }
}

class Slide {
  Slide._(this._ap, this.caminho) {
    _lerFormas();
  }

  final Apresentacao _ap;
  final String caminho;
  final formas = <Forma>[];

  XmlDocument get xml => _ap._doc(caminho)!;

  XmlElement? get _arvore => _p(_p(xml.rootElement, 'cSld'), 'spTree');

  /// Cor de fundo própria do slide (`RRGGBB`), se houver.
  String? get fundo => _a(
    _a(_p(_p(_p(xml.rootElement, 'cSld'), 'bg'), 'bgPr'), 'solidFill'),
    'srgbClr',
  )?.getAttribute('val');

  void _lerFormas() {
    final arvore = _arvore;
    if (arvore == null) return;
    final layout = _ap._relDoTipo(caminho, _relLayout);
    final mestre = layout == null ? null : _ap._relDoTipo(layout, _relMestre);
    final rels = _ap._rels(caminho);
    for (final e in arvore.childElements) {
      if (e.name.namespaceUri != _nsP) continue;
      switch (e.name.local) {
        case 'sp' || 'pic' || 'graphicFrame' || 'grpSp' || 'cxnSp':
          formas.add(Forma._(this, e, layout: layout, mestre: mestre, rels: rels));
      }
    }
  }

  void _mexeu() => _ap._mexeu(caminho);

  /// Caixa de texto nova (no meio do slide).
  Forma novaCaixa() {
    final ids = xml.rootElement.descendantElements
        .where((e) => e.name.local == 'cNvPr')
        .map((e) => int.tryParse(e.getAttribute('id') ?? '') ?? 0);
    final id = ids.fold(1, (a, b) => a > b ? a : b) + 1;
    final w = (_ap.largura * 0.5).round(), h = (_ap.altura * 0.15).round();
    final x = ((_ap.largura - w) / 2).round(), y = ((_ap.altura - h) / 2).round();
    final sp = _elemento(
      '<p:sp><p:nvSpPr><p:cNvPr id="$id" name="Caixa de texto $id"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>'
      '<p:spPr><a:xfrm><a:off x="$x" y="$y"/><a:ext cx="$w" cy="$h"/></a:xfrm>'
      '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>'
      '<p:txBody><a:bodyPr wrap="square" rtlCol="0"><a:spAutoFit/></a:bodyPr><a:lstStyle/>'
      '<a:p><a:r><a:rPr lang="pt-BR" sz="2400" dirty="0"/><a:t>Texto</a:t></a:r></a:p></p:txBody></p:sp>',
    );
    _arvore!.children.add(sp);
    _mexeu();
    final f = Forma._(this, sp, rels: const {});
    formas.add(f);
    return f;
  }

  void excluir(Forma f) {
    f._e.parent?.children.remove(f._e);
    formas.remove(f);
    _mexeu();
  }
}

class Forma {
  Forma._(this._slide, this._e, {String? layout, String? mestre, required Map<String, String> rels}) {
    final ph = _p(_p(_nv, 'nvPr'), 'ph');
    placeholder = ph != null;
    tipoPlaceholder = ph?.getAttribute('type') ?? (ph != null ? 'body' : null);
    var xfrm = _xfrm(_e);
    if (xfrm == null && ph != null) {
      for (final parte in [layout, mestre]) {
        if (parte == null) continue;
        xfrm = _xfrmDoPlaceholder(parte, ph);
        if (xfrm != null) break;
      }
    }
    final off = _a(xfrm, 'off'), ext = _a(xfrm, 'ext');
    _x = double.tryParse(off?.getAttribute('x') ?? '');
    _y = double.tryParse(off?.getAttribute('y') ?? '');
    _w = double.tryParse(ext?.getAttribute('cx') ?? '');
    _h = double.tryParse(ext?.getAttribute('cy') ?? '');
    final blip = _e.descendantElements.where((d) => d.name.local == 'blip').firstOrNull;
    final embed = blip?.getAttribute('embed', namespaceUri: _nsR);
    imagem = embed == null ? null : rels[embed];
  }

  final Slide _slide;
  final XmlElement _e;
  late final bool placeholder;
  late final String? tipoPlaceholder;
  double? _x, _y, _w, _h;

  /// Caminho da imagem no zip (`p:pic`).
  String? imagem;

  XmlElement? get _nv => _e.childElements.where((c) => c.name.local.startsWith('nv')).firstOrNull;

  /// Tipo do que não é caixa de texto nem imagem ("tabela/gráfico", "grupo"…), para a caixa cinza.
  String? get outro => switch (_e.name.local) {
    'graphicFrame' => 'tabela/gráfico',
    'grpSp' => 'grupo de formas',
    'cxnSp' => 'conector',
    _ => null,
  };

  bool get titulo => tipoPlaceholder == 'title' || tipoPlaceholder == 'ctrTitle';

  XmlElement? get _corpo => _p(_e, 'txBody');

  bool get temTexto => _e.name.local == 'sp';

  /// Posição/tamanho em EMU; sem nenhuma informação, uma faixa padrão.
  double get x => _x ?? _slide._ap.largura * 0.08;
  double get y => _y ?? (titulo ? _slide._ap.altura * 0.05 : _slide._ap.altura * 0.28);
  double get w => _w ?? _slide._ap.largura * 0.84;
  double get h => _h ?? (titulo ? _slide._ap.altura * 0.18 : _slide._ap.altura * 0.6);

  static XmlElement? _xfrm(XmlElement e) {
    final spPr = e.childElements.where((c) => c.name.local == 'spPr' || c.name.local == 'grpSpPr').firstOrNull;
    return _a(spPr, 'xfrm') ?? e.getElement('xfrm', namespaceUri: _nsP);
  }

  XmlElement? _xfrmDoPlaceholder(String parte, XmlElement ph) {
    final doc = _slide._ap._doc(parte);
    if (doc == null) return null;
    final tipo = ph.getAttribute('type') ?? 'body';
    final idx = ph.getAttribute('idx');
    XmlElement? porTipo;
    for (final sp in doc.rootElement.descendantElements.where((d) => d.name.local == 'sp' && d.name.namespaceUri == _nsP)) {
      final outro = sp.descendantElements.where((d) => d.name.local == 'ph').firstOrNull;
      if (outro == null) continue;
      final xfrm = _xfrm(sp);
      if (xfrm == null) continue;
      if (idx != null && outro.getAttribute('idx') == idx) return xfrm;
      final t = outro.getAttribute('type') ?? 'body';
      if (t == tipo || (tipo == 'ctrTitle' && t == 'title') || (tipo == 'subTitle' && t == 'body')) porTipo ??= xfrm;
    }
    return porTipo;
  }

  /// Move/redimensiona (EMU); cria o `a:xfrm` no slide quando a posição vinha do layout.
  void posicionar(double x, double y, double w, double h) {
    _x = x;
    _y = y;
    _w = w.clamp(emuPorPonto * 10, double.infinity);
    _h = h.clamp(emuPorPonto * 10, double.infinity);
    var spPr = _e.childElements.where((c) => c.name.local == 'spPr' || c.name.local == 'grpSpPr').firstOrNull;
    if (spPr == null) {
      spPr = _elemento('<p:spPr/>');
      _e.children.insert(_e.children.indexOf(_nv!) + 1, spPr);
    }
    var xfrm = _a(spPr, 'xfrm');
    if (xfrm == null) {
      xfrm = _elemento('<a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/></a:xfrm>');
      spPr.children.insert(0, xfrm);
    }
    _a(xfrm, 'off')!
      ..setAttribute('x', '${_x!.round()}')
      ..setAttribute('y', '${_y!.round()}');
    _a(xfrm, 'ext')!
      ..setAttribute('cx', '${_w!.round()}')
      ..setAttribute('cy', '${_h!.round()}');
    _slide._mexeu();
  }

  Iterable<XmlElement> get _paragrafos => _corpo?.findElements('p', namespaceUri: _nsA) ?? const [];

  /// Texto da caixa: um parágrafo por linha.
  String get texto => _paragrafos
      .map(
        (p) => p.childElements
            .map(
              (c) => switch (c.name.local) {
                'r' || 'fld' => _a(c, 't')?.innerText ?? '',
                'br' => '\n', // quebra suave vira parágrafo ao regravar
                _ => '',
              },
            )
            .join(),
      )
      .join('\n');

  /// Troca o texto; cada linha vira um parágrafo com a formatação do primeiro (pPr/rPr).
  set texto(String novo) {
    final corpo = _corpo;
    if (corpo == null) return;
    final ps = _paragrafos.toList();
    final pPr = _a(ps.firstOrNull, 'pPr')?.copy();
    final rPr = (ps.firstOrNull?.descendantElements.where((d) => d.name.local == 'rPr').firstOrNull ??
            ps.firstOrNull?.descendantElements.where((d) => d.name.local == 'endParaRPr').firstOrNull)
        ?.copy();
    for (final p in ps) {
      corpo.children.remove(p);
    }
    final atributosR = rPr == null
        ? ' lang="pt-BR" dirty="0"'
        : rPr.attributes.map((a) => ' ${a.name.qualified}="${_esc(a.value)}"').join();
    final filhosR = rPr?.children.map((c) => c.toXmlString()).join() ?? '';
    for (final linha in novo.split('\n')) {
      final p = _elemento('<a:p/>');
      if (pPr != null) p.children.add(pPr.copy());
      if (linha.isNotEmpty) {
        p.children.add(_elemento('<a:r><a:rPr$atributosR>$filhosR</a:rPr><a:t>${_esc(linha)}</a:t></a:r>'));
      }
      p.children.add(_elemento('<a:endParaRPr$atributosR/>'));
      corpo.children.add(p);
    }
    _slide._mexeu();
  }

  Iterable<XmlElement> get _rPrs =>
      _corpo?.descendantElements.where((d) => d.name.local == 'rPr' || d.name.local == 'endParaRPr') ?? const [];

  XmlElement? get _primeiroRPr => _rPrs.firstOrNull;

  /// Tamanho da fonte em pt (o do primeiro trecho; sem, um padrão de título/corpo).
  double get tamanho {
    final sz = double.tryParse(_primeiroRPr?.getAttribute('sz') ?? '');
    return sz != null ? sz / 100 : (titulo ? 40 : 20);
  }

  bool get negrito => _primeiroRPr?.getAttribute('b') == '1';
  bool get italico => _primeiroRPr?.getAttribute('i') == '1';
  bool get sublinhado => (_primeiroRPr?.getAttribute('u') ?? 'none') != 'none';

  /// Cor do texto (`RRGGBB`) se for RGB explícito.
  String? get cor => _a(_a(_primeiroRPr, 'solidFill'), 'srgbClr')?.getAttribute('val');

  /// Alinhamento do primeiro parágrafo: `l`, `ctr`, `r`, `just`.
  String get alinhamento => _a(_paragrafos.firstOrNull, 'pPr')?.getAttribute('algn') ?? (titulo ? 'ctr' : 'l');

  /// Aplica o estilo a todos os trechos da caixa.
  void estilo({double? tamanho, bool? negrito, bool? italico, bool? sublinhado, String? cor, String? alinhamento}) {
    for (final r in _rPrs) {
      if (tamanho != null) r.setAttribute('sz', '${(tamanho * 100).round()}');
      if (negrito != null) r.setAttribute('b', negrito ? '1' : '0');
      if (italico != null) r.setAttribute('i', italico ? '1' : '0');
      if (sublinhado != null) r.setAttribute('u', sublinhado ? 'sng' : 'none');
      if (cor != null) {
        r.children.removeWhere((c) => c is XmlElement && const {'solidFill', 'noFill', 'gradFill'}.contains(c.name.local));
        // Pelo esquema de a:rPr o preenchimento vem logo depois do a:ln (se houver).
        final ln = _a(r, 'ln');
        r.children.insert(ln == null ? 0 : r.children.indexOf(ln) + 1, _elemento('<a:solidFill><a:srgbClr val="$cor"/></a:solidFill>'));
      }
    }
    if (alinhamento != null) {
      for (final p in _paragrafos) {
        var pPr = _a(p, 'pPr');
        if (pPr == null) {
          pPr = _elemento('<a:pPr/>');
          p.children.insert(0, pPr);
        }
        pPr.setAttribute('algn', alinhamento);
      }
    }
    _slide._mexeu();
  }
}
