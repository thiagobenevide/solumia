import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_arquivos/src/editors/pptx.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

const _ns =
    'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
    'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"';
const _rel = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _rels = 'xmlns="http://schemas.openxmlformats.org/package/2006/relationships"';

Uint8List _pptx() {
  final zip = Archive();
  void add(String name, String text) => zip.add(ArchiveFile.bytes(name, utf8.encode(text)));
  add(
    '[Content_Types].xml',
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>'
        '</Types>',
  );
  add(
    'ppt/presentation.xml',
    '<p:presentation $_ns><p:sldIdLst><p:sldId id="256" r:id="rId2"/></p:sldIdLst>'
        '<p:sldSz cx="9144000" cy="5143500"/></p:presentation>',
  );
  add('ppt/_rels/presentation.xml.rels', '<Relationships $_rels><Relationship Id="rId2" Type="$_rel/slide" Target="slides/slide1.xml"/></Relationships>');
  add(
    'ppt/slides/_rels/slide1.xml.rels',
    '<Relationships $_rels><Relationship Id="rId1" Type="$_rel/slideLayout" Target="../slideLayouts/slideLayout1.xml"/></Relationships>',
  );
  add(
    'ppt/slideLayouts/slideLayout1.xml',
    '<p:sldLayout $_ns><p:cSld><p:spTree><p:sp><p:nvSpPr><p:cNvPr id="2" name="T"/><p:cNvSpPr/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>'
        '<p:spPr><a:xfrm><a:off x="100" y="200"/><a:ext cx="3000" cy="400"/></a:xfrm></p:spPr></p:sp></p:spTree></p:cSld></p:sldLayout>',
  );
  add(
    'ppt/slides/slide1.xml',
    '<p:sld $_ns><p:cSld><p:spTree>'
        '<p:sp><p:nvSpPr><p:cNvPr id="2" name="Título"/><p:cNvSpPr/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:spPr/>'
        '<p:txBody><a:bodyPr/><a:p><a:r><a:rPr lang="pt-BR" sz="3600" b="1"/><a:t>Olá</a:t></a:r></a:p></p:txBody></p:sp>'
        '</p:spTree></p:cSld></p:sld>',
  );
  return ZipEncoder().encodeBytes(zip);
}

void main() {
  test('lê slide com posição herdada do layout, edita, duplica e regrava', () {
    final ap = Presentation.read(_pptx());
    expect(ap.slides, hasLength(1));
    final title = ap.slides.single.shapes.single;
    expect((title.x, title.y, title.w), (100, 200, 3000));
    expect(title.text, 'Olá');
    expect(title.size, 36);
    expect(title.bold, isTrue);

    title.text = 'Resultados\nSegunda linha';
    title.estilo(size: 40, color: 'C00000', alignmentMode: 'ctr');
    title.placeAt(500, 600, 4000, 800);
    ap.slides.first.newBox().text = 'Nota';
    ap.duplicate(0);
    ap.move(1, 0);

    final reread = Presentation.read(ap.save());
    expect(reread.slides, hasLength(2));
    final f = reread.slides[1].shapes.first;
    expect(f.text, 'Resultados\nSegunda linha');
    expect((f.size, f.color, f.alignmentMode, f.x, f.w), (40, 'C00000', 'ctr', 500, 4000));
    expect(reread.slides[1].shapes.last.text, 'Nota');
    expect(reread.slides[0].shapes.first.text, 'Resultados\nSegunda linha');

    reread.delete(0);
    final final_ = Presentation.read(reread.save());
    expect(final_.slides, hasLength(1));
  });
}
