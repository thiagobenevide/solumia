import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// PPTX for the presentation editor: slides in `presentation.xml` order, shapes with text
/// (position inherited from the layout/master when the slide does not bring it), images and the rest as a gray
/// box. Edits text, box style, position/size, creates/deletes boxes and duplicates, deletes and
/// reorders slides; on save only the touched parts change in the zip.

const _nsP = 'http://schemas.openxmlformats.org/presentationml/2006/main';
const _nsA = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const _nsR = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _nsRels = 'http://schemas.openxmlformats.org/package/2006/relationships';
const _nsTipos = 'http://schemas.openxmlformats.org/package/2006/content-types';
const _slideRel = '$_nsR/slide';
const _layoutRel = '$_nsR/slideLayout';
const _masterRel = '$_nsR/slideMaster';
const _notesRel = '$_nsR/notesSlide';
const _slideType = 'application/vnd.openxmlformats-officedocument.presentationml.slide+xml';

const _presentationPath = 'ppt/presentation.xml';
const _typesPath = '[Content_Types].xml';

/// 1 pt in EMU.
const emuPerPoint = 12700.0;

class InvalidPptx implements Exception {
  InvalidPptx(this.mensagem);

  final String mensagem;

  @override
  String toString() => mensagem;
}

String _relsOf(String part) {
  final i = part.lastIndexOf('/');
  return '${part.substring(0, i)}/_rels/${part.substring(i + 1)}.rels';
}

/// Relative target of a relationship → path in the zip.
String _resolver(String base, String target) {
  if (target.startsWith('/')) return target.substring(1);
  final parts = base.split('/')..removeLast();
  for (final p in target.split('/')) {
    if (p == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else if (p != '.') {
      parts.add(p);
    }
  }
  return parts.join('/');
}

String _esc(String s) => s
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

XmlElement _element(String xml) => XmlDocument.parse(
  '<x xmlns:a="$_nsA" xmlns:p="$_nsP" xmlns:r="$_nsR">$xml</x>',
).rootElement.childElements.single.copy();

XmlElement? _a(XmlElement? e, String name) => e?.getElement(name, namespaceUri: _nsA);
XmlElement? _p(XmlElement? e, String name) => e?.getElement(name, namespaceUri: _nsP);

class Presentation {
  Presentation._(this._zip, this.width, this.height);

  final Archive _zip;

  /// Slide size in EMU.
  final double width;
  final double height;

  final slides = <Slide>[];
  final _xml = <String, XmlDocument>{};
  final _touchedItems = <String>{};
  final _removed = <String>{};
  bool changedFlag = false;

  static Presentation read(Uint8List bytes) {
    final Archive zip;
    try {
      zip = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw InvalidPptx('Não é um .pptx válido (não é um pacote zip). .ppt e .odp não abrem aqui.');
    }
    if (zip.findFile(_presentationPath) == null) throw InvalidPptx('Não é um .pptx válido: falta $_presentationPath.');
    final provisional = Presentation._(zip, 0, 0);
    final pres = provisional._doc(_presentationPath)!.rootElement;
    final tam = _p(pres, 'sldSz');
    final ap = Presentation._(
      zip,
      double.tryParse(tam?.getAttribute('cx') ?? '') ?? 12192000,
      double.tryParse(tam?.getAttribute('cy') ?? '') ?? 6858000,
    );
    final rels = ap._rels(_presentationPath);
    for (final id in _p(ap._doc(_presentationPath)!.rootElement, 'sldIdLst')?.childElements ?? const <XmlElement>[]) {
      final target = rels[id.getAttribute('id', namespaceUri: _nsR)];
      if (target == null || ap._doc(target) == null) continue;
      ap.slides.add(Slide._(ap, target));
    }
    return ap;
  }

  XmlDocument? _doc(String path) {
    if (_xml.containsKey(path)) return _xml[path];
    final f = _zip.findFile(path);
    if (f == null) return null;
    try {
      return _xml[path] = XmlDocument.parse(utf8.decode(f.content, allowMalformed: true));
    } on XmlException catch (e) {
      throw InvalidPptx('XML quebrado em $path ($e).');
    }
  }

  Uint8List? bytes(String path) {
    if (_removed.contains(path)) return null;
    return _zip.findFile(path)?.content;
  }

  /// rId → path in the zip; [types] stores the type of each relationship.
  Map<String, String> _rels(String part, {Map<String, String>? types}) {
    final doc = _doc(_relsOf(part));
    final r = <String, String>{};
    for (final e in doc?.rootElement.childElements ?? const <XmlElement>[]) {
      final id = e.getAttribute('Id');
      final target = e.getAttribute('Target');
      if (id == null || target == null || e.getAttribute('TargetMode') == 'External') continue;
      r[id] = _resolver(part, target);
      types?[id] = e.getAttribute('Type') ?? '';
    }
    return r;
  }

  String? _relOfType(String part, String type) {
    final types = <String, String>{};
    final rels = _rels(part, types: types);
    return rels.entries.where((e) => types[e.key] == type).firstOrNull?.value;
  }

  void _touched(String path) {
    _touchedItems.add(path);
    changedFlag = true;
  }

  XmlElement get _listIds => _p(_doc(_presentationPath)!.rootElement, 'sldIdLst')!;

  /// Duplicates slide [i] right after it. [empty] removes the text and the shapes that are not from the layout.
  Slide duplicate(int i, {bool empty = false}) {
    final origin = slides[i];
    final usedItems = _zip.files.map((f) => f.name).toSet()..addAll(_xml.keys);
    var n = slides.length + 1;
    while (usedItems.contains('ppt/slides/slide$n.xml')) {
      n++;
    }
    final path = 'ppt/slides/slide$n.xml';
    _xml[path] = XmlDocument.parse(origin.xml.toXmlString());
    final sourceRels = _doc(_relsOf(origin.path));
    final rels = sourceRels == null
        ? XmlDocument.parse('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="$_nsRels"/>')
        : XmlDocument.parse(sourceRels.toXmlString());
    // Notes belong to a single slide: the copy comes out without them.
    rels.rootElement.children.removeWhere((e) => e is XmlElement && e.getAttribute('Type') == _notesRel);
    _xml[_relsOf(path)] = rels;
    _touched(path);
    _touched(_relsOf(path));

    final types = _doc(_typesPath)!;
    types.rootElement.children.add(
      XmlElement(XmlName.qualified('Override', namespaceUri: _nsTipos), [
        XmlAttribute(XmlName.qualified('PartName'), '/$path'),
        XmlAttribute(XmlName.qualified('ContentType'), _slideType),
      ]),
    );
    _touched(_typesPath);

    final presentationRels = _doc(_relsOf(_presentationPath))!;
    final ids = presentationRels.rootElement.childElements.map((e) => e.getAttribute('Id')).toSet();
    var r = ids.length + 1;
    while (ids.contains('rId$r')) {
      r++;
    }
    presentationRels.rootElement.children.add(
      XmlElement(XmlName.qualified('Relationship', namespaceUri: _nsRels), [
        XmlAttribute(XmlName.qualified('Id'), 'rId$r'),
        XmlAttribute(XmlName.qualified('Type'), _slideRel),
        XmlAttribute(XmlName.qualified('Target'), 'slides/slide$n.xml'),
      ]),
    );
    _touched(_relsOf(_presentationPath));

    final items = _listIds;
    final larger = items.childElements.map((e) => int.tryParse(e.getAttribute('id') ?? '') ?? 255).fold(255, (a, b) => a > b ? a : b);
    final newId = _element('<p:sldId id="${larger + 1}" r:id="rId$r"/>');
    final elements = items.childElements.toList();
    items.children.insert(items.children.indexOf(elements[i]) + 1, newId);
    _touched(_presentationPath);

    final isNew = Slide._(this, path);
    if (empty) {
      for (final f in isNew.shapes.toList()) {
        if (f.placeholder) {
          f.text = '';
        } else {
          isNew.delete(f);
        }
      }
    }
    slides.insert(i + 1, isNew);
    return isNew;
  }

  void delete(int i) {
    if (slides.length <= 1) return;
    final s = slides.removeAt(i);
    final items = _listIds;
    final element = items.childElements.toList()[i];
    final rId = element.getAttribute('id', namespaceUri: _nsR);
    items.children.remove(element);
    _touched(_presentationPath);
    final presentationRels = _doc(_relsOf(_presentationPath))!;
    presentationRels.rootElement.children.removeWhere((e) => e is XmlElement && e.getAttribute('Id') == rId);
    _touched(_relsOf(_presentationPath));
    final notes = _relOfType(s.path, _notesRel);
    final types = _doc(_typesPath)!;
    for (final part in [s.path, ?notes]) {
      _removed.addAll([part, _relsOf(part)]);
      types.rootElement.children.removeWhere((e) => e is XmlElement && e.getAttribute('PartName') == '/$part');
    }
    _touched(_typesPath);
  }

  void move(int de, int to) {
    if (to < 0 || to >= slides.length || de == to) return;
    final items = _listIds;
    final elements = items.childElements.toList();
    final e = elements[de];
    items.children.remove(e);
    final remainingItems = items.childElements.toList();
    if (to >= remainingItems.length) {
      items.children.add(e);
    } else {
      items.children.insert(items.children.indexOf(remainingItems[to]), e);
    }
    slides.insert(to, slides.removeAt(de));
    _touched(_presentationPath);
  }

  Uint8List save() {
    final expense = Archive();
    final names = <String>{};
    for (final f in _zip.files) {
      if (!f.isFile || _removed.contains(f.name)) continue;
      names.add(f.name);
      final doc = _touchedItems.contains(f.name) ? _xml[f.name] : null;
      expense.add(ArchiveFile.bytes(f.name, doc != null ? utf8.encode(doc.toXmlString()) : f.content));
    }
    for (final c in _touchedItems) {
      if (names.contains(c) || _removed.contains(c)) continue;
      expense.add(ArchiveFile.bytes(c, utf8.encode(_xml[c]!.toXmlString())));
    }
    changedFlag = false;
    return ZipEncoder().encodeBytes(expense);
  }
}

class Slide {
  Slide._(this._ap, this.path) {
    _readShapes();
  }

  final Presentation _ap;
  final String path;
  final shapes = <SlideShape>[];

  XmlDocument get xml => _ap._doc(path)!;

  XmlElement? get _tree => _p(_p(xml.rootElement, 'cSld'), 'spTree');

  /// The slide's own background color (`RRGGBB`), if any.
  String? get background => _a(
    _a(_p(_p(_p(xml.rootElement, 'cSld'), 'bg'), 'bgPr'), 'solidFill'),
    'srgbClr',
  )?.getAttribute('val');

  void _readShapes() {
    final tree = _tree;
    if (tree == null) return;
    final layout = _ap._relOfType(path, _layoutRel);
    final master = layout == null ? null : _ap._relOfType(layout, _masterRel);
    final rels = _ap._rels(path);
    for (final e in tree.childElements) {
      if (e.name.namespaceUri != _nsP) continue;
      switch (e.name.local) {
        case 'sp' || 'pic' || 'graphicFrame' || 'grpSp' || 'cxnSp':
          shapes.add(SlideShape._(this, e, layout: layout, master: master, rels: rels));
      }
    }
  }

  void _touched() => _ap._touched(path);

  /// New text box (in the middle of the slide).
  SlideShape newBox() {
    final ids = xml.rootElement.descendantElements
        .where((e) => e.name.local == 'cNvPr')
        .map((e) => int.tryParse(e.getAttribute('id') ?? '') ?? 0);
    final id = ids.fold(1, (a, b) => a > b ? a : b) + 1;
    final w = (_ap.width * 0.5).round(), h = (_ap.height * 0.15).round();
    final x = ((_ap.width - w) / 2).round(), y = ((_ap.height - h) / 2).round();
    final sp = _element(
      '<p:sp><p:nvSpPr><p:cNvPr id="$id" name="Caixa de texto $id"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>'
      '<p:spPr><a:xfrm><a:off x="$x" y="$y"/><a:ext cx="$w" cy="$h"/></a:xfrm>'
      '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>'
      '<p:txBody><a:bodyPr wrap="square" rtlCol="0"><a:spAutoFit/></a:bodyPr><a:lstStyle/>'
      '<a:p><a:r><a:rPr lang="pt-BR" sz="2400" dirty="0"/><a:t>Texto</a:t></a:r></a:p></p:txBody></p:sp>',
    );
    _tree!.children.add(sp);
    _touched();
    final f = SlideShape._(this, sp, rels: const {});
    shapes.add(f);
    return f;
  }

  void delete(SlideShape f) {
    f._e.parent?.children.remove(f._e);
    shapes.remove(f);
    _touched();
  }
}

class SlideShape {
  SlideShape._(this._slide, this._e, {String? layout, String? master, required Map<String, String> rels}) {
    final ph = _p(_p(_nv, 'nvPr'), 'ph');
    placeholder = ph != null;
    placeholderType = ph?.getAttribute('type') ?? (ph != null ? 'body' : null);
    var xfrm = _xfrm(_e);
    if (xfrm == null && ph != null) {
      for (final part in [layout, master]) {
        if (part == null) continue;
        xfrm = _placeholderXfrm(part, ph);
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
    image = embed == null ? null : rels[embed];
  }

  final Slide _slide;
  final XmlElement _e;
  late final bool placeholder;
  late final String? placeholderType;
  double? _x, _y, _w, _h;

  /// Image path in the zip (`p:pic`).
  String? image;

  XmlElement? get _nv => _e.childElements.where((c) => c.name.local.startsWith('nv')).firstOrNull;

  /// Type of what is neither a text box nor an image ("tabela/gráfico", "grupo"…), for the gray box.
  String? get another => switch (_e.name.local) {
    'graphicFrame' => 'tabela/gráfico',
    'grpSp' => 'grupo de formas',
    'cxnSp' => 'conector',
    _ => null,
  };

  bool get title => placeholderType == 'title' || placeholderType == 'ctrTitle';

  XmlElement? get _body => _p(_e, 'txBody');

  bool get hasText => _e.name.local == 'sp';

  /// Position/size in EMU; without any information, a default band.
  double get x => _x ?? _slide._ap.width * 0.08;
  double get y => _y ?? (title ? _slide._ap.height * 0.05 : _slide._ap.height * 0.28);
  double get w => _w ?? _slide._ap.width * 0.84;
  double get h => _h ?? (title ? _slide._ap.height * 0.18 : _slide._ap.height * 0.6);

  static XmlElement? _xfrm(XmlElement e) {
    final spPr = e.childElements.where((c) => c.name.local == 'spPr' || c.name.local == 'grpSpPr').firstOrNull;
    return _a(spPr, 'xfrm') ?? e.getElement('xfrm', namespaceUri: _nsP);
  }

  XmlElement? _placeholderXfrm(String part, XmlElement ph) {
    final doc = _slide._ap._doc(part);
    if (doc == null) return null;
    final type = ph.getAttribute('type') ?? 'body';
    final idx = ph.getAttribute('idx');
    XmlElement? byType;
    for (final sp in doc.rootElement.descendantElements.where((d) => d.name.local == 'sp' && d.name.namespaceUri == _nsP)) {
      final another = sp.descendantElements.where((d) => d.name.local == 'ph').firstOrNull;
      if (another == null) continue;
      final xfrm = _xfrm(sp);
      if (xfrm == null) continue;
      if (idx != null && another.getAttribute('idx') == idx) return xfrm;
      final t = another.getAttribute('type') ?? 'body';
      if (t == type || (type == 'ctrTitle' && t == 'title') || (type == 'subTitle' && t == 'body')) byType ??= xfrm;
    }
    return byType;
  }

  /// Moves/resizes (EMU); creates the `a:xfrm` on the slide when the position came from the layout.
  void placeAt(double x, double y, double w, double h) {
    _x = x;
    _y = y;
    _w = w.clamp(emuPerPoint * 10, double.infinity);
    _h = h.clamp(emuPerPoint * 10, double.infinity);
    var spPr = _e.childElements.where((c) => c.name.local == 'spPr' || c.name.local == 'grpSpPr').firstOrNull;
    if (spPr == null) {
      spPr = _element('<p:spPr/>');
      _e.children.insert(_e.children.indexOf(_nv!) + 1, spPr);
    }
    var xfrm = _a(spPr, 'xfrm');
    if (xfrm == null) {
      xfrm = _element('<a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/></a:xfrm>');
      spPr.children.insert(0, xfrm);
    }
    _a(xfrm, 'off')!
      ..setAttribute('x', '${_x!.round()}')
      ..setAttribute('y', '${_y!.round()}');
    _a(xfrm, 'ext')!
      ..setAttribute('cx', '${_w!.round()}')
      ..setAttribute('cy', '${_h!.round()}');
    _slide._touched();
  }

  Iterable<XmlElement> get _paragraphs => _body?.findElements('p', namespaceUri: _nsA) ?? const [];

  /// Box text: one paragraph per line.
  String get text => _paragraphs
      .map(
        (p) => p.childElements
            .map(
              (c) => switch (c.name.local) {
                'r' || 'fld' => _a(c, 't')?.innerText ?? '',
                'br' => '\n', // a soft break becomes a paragraph on rewrite
                _ => '',
              },
            )
            .join(),
      )
      .join('\n');

  /// Swaps the text; each line becomes a paragraph with the formatting of the first one (pPr/rPr).
  set text(String isNew) {
    final body = _body;
    if (body == null) return;
    final ps = _paragraphs.toList();
    final pPr = _a(ps.firstOrNull, 'pPr')?.copy();
    final rPr = (ps.firstOrNull?.descendantElements.where((d) => d.name.local == 'rPr').firstOrNull ??
            ps.firstOrNull?.descendantElements.where((d) => d.name.local == 'endParaRPr').firstOrNull)
        ?.copy();
    for (final p in ps) {
      body.children.remove(p);
    }
    final runAttributes = rPr == null
        ? ' lang="pt-BR" dirty="0"'
        : rPr.attributes.map((a) => ' ${a.name.qualified}="${_esc(a.value)}"').join();
    final runChildren = rPr?.children.map((c) => c.toXmlString()).join() ?? '';
    for (final line in isNew.split('\n')) {
      final p = _element('<a:p/>');
      if (pPr != null) p.children.add(pPr.copy());
      if (line.isNotEmpty) {
        p.children.add(_element('<a:r><a:rPr$runAttributes>$runChildren</a:rPr><a:t>${_esc(line)}</a:t></a:r>'));
      }
      p.children.add(_element('<a:endParaRPr$runAttributes/>'));
      body.children.add(p);
    }
    _slide._touched();
  }

  Iterable<XmlElement> get _rPrs =>
      _body?.descendantElements.where((d) => d.name.local == 'rPr' || d.name.local == 'endParaRPr') ?? const [];

  XmlElement? get _firstRPr => _rPrs.firstOrNull;

  /// Font size in pt (the first run's; without one, a default for title/body).
  double get size {
    final sz = double.tryParse(_firstRPr?.getAttribute('sz') ?? '');
    return sz != null ? sz / 100 : (title ? 40 : 20);
  }

  bool get bold => _firstRPr?.getAttribute('b') == '1';
  bool get italic => _firstRPr?.getAttribute('i') == '1';
  bool get underline => (_firstRPr?.getAttribute('u') ?? 'none') != 'none';

  /// Text color (`RRGGBB`) if it is an explicit RGB.
  String? get color => _a(_a(_firstRPr, 'solidFill'), 'srgbClr')?.getAttribute('val');

  /// Alignment of the first paragraph: `l`, `ctr`, `r`, `just`.
  String get alignmentMode => _a(_paragraphs.firstOrNull, 'pPr')?.getAttribute('algn') ?? (title ? 'ctr' : 'l');

  /// Applies the style to all runs of the box.
  void estilo({double? size, bool? bold, bool? italic, bool? underline, String? color, String? alignmentMode}) {
    for (final r in _rPrs) {
      if (size != null) r.setAttribute('sz', '${(size * 100).round()}');
      if (bold != null) r.setAttribute('b', bold ? '1' : '0');
      if (italic != null) r.setAttribute('i', italic ? '1' : '0');
      if (underline != null) r.setAttribute('u', underline ? 'sng' : 'none');
      if (color != null) {
        r.children.removeWhere((c) => c is XmlElement && const {'solidFill', 'noFill', 'gradFill'}.contains(c.name.local));
        // In the a:rPr schema the fill comes right after a:ln (if any).
        final ln = _a(r, 'ln');
        r.children.insert(ln == null ? 0 : r.children.indexOf(ln) + 1, _element('<a:solidFill><a:srgbClr val="$color"/></a:solidFill>'));
      }
    }
    if (alignmentMode != null) {
      for (final p in _paragraphs) {
        var pPr = _a(p, 'pPr');
        if (pPr == null) {
          pPr = _element('<a:pPr/>');
          p.children.insert(0, pPr);
        }
        pPr.setAttribute('algn', alignmentMode);
      }
    }
    _slide._touched();
  }
}
