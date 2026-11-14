import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_arquivos/src/editors/docx.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

const _ns =
    'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"';

const _section = '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1417" w:right="1701" w:bottom="1417" w:left="1701"/></w:sectPr>';

const _styles =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:styles $_ns>'
    '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>'
    '<w:style w:type="paragraph" w:styleId="Ttulo1"><w:name w:val="heading 1"/></w:style>'
    '</w:styles>';

const _numbering =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:numbering $_ns>'
    '<w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/><w:lvlText w:val="•"/></w:lvl></w:abstractNum>'
    '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>'
    '</w:numbering>';

String _body(String paragraphs) =>
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document $_ns><w:body>$paragraphs$_section</w:body></w:document>';

Uint8List _docx(String body) {
  final zip = Archive();
  void add(String name, String text) => zip.add(ArchiveFile.bytes(name, utf8.encode(text)));
  add(
    '[Content_Types].xml',
    '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
        '<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>'
        '</Types>',
  );
  add(
    '_rels/.rels',
    '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '</Relationships>',
  );
  add(
    'word/_rels/document.xml.rels',
    '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>'
        '</Relationships>',
  );
  add('word/styles.xml', _styles);
  add('word/numbering.xml', _numbering);
  add('word/document.xml', body);
  return ZipEncoder().encodeBytes(zip);
}

const _paragraphs =
    '<w:p><w:pPr><w:pStyle w:val="Ttulo1"/></w:pPr><w:r><w:t>Relatório</w:t></w:r></w:p>'
    '<w:p><w:r><w:t xml:space="preserve">Texto com </w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>negrito</w:t></w:r>'
    '<w:r><w:t xml:space="preserve"> e </w:t></w:r><w:r><w:rPr><w:i/></w:rPr><w:t>itálico</w:t></w:r><w:r><w:t>.</w:t></w:r></w:p>'
    '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>item um</w:t></w:r></w:p>'
    '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>item dois</w:t></w:r></w:p>'
    '<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:t>fim</w:t><w:tab/><w:t>!</w:t></w:r></w:p>';

String _file(Uint8List docx, String name) =>
    utf8.decode(ZipDecoder().decodeBytes(docx).findFile(name)!.content);

void main() {
  test('lê título, negrito/itálico, lista com marcador e alinhamento', () {
    final doc = DocxDocument.read(_docx(_body(_paragraphs)));
    expect(doc.warnings, isEmpty);
    expect(doc.delta, [
      {'insert': 'Relatório'},
      {
        'insert': '\n',
        'attributes': {'header': 1},
      },
      {'insert': 'Texto com '},
      {
        'insert': 'negrito',
        'attributes': {'bold': true},
      },
      {'insert': ' e '},
      {
        'insert': 'itálico',
        'attributes': {'italic': true},
      },
      {'insert': '.\nitem um'},
      {
        'insert': '\n',
        'attributes': {'list': 'bullet'},
      },
      {'insert': 'item dois'},
      {
        'insert': '\n',
        'attributes': {'list': 'bullet'},
      },
      {'insert': 'fim\t!'},
      {
        'insert': '\n',
        'attributes': {'align': 'center'},
      },
    ]);
  });

  final edited = <Map<String, dynamic>>[
    {'insert': 'Novo título'},
    {
      'insert': '\n',
      'attributes': {'header': 2},
    },
    {
      'insert': 'sublinhado',
      'attributes': {'underline': true, 'strike': true},
    },
    {'insert': ' veja '},
    {
      'insert': 'o site',
      'attributes': {'link': 'https://exemplo.com/?a=1&b=2'},
    },
    {'insert': '\nprimeiro'},
    {
      'insert': '\n',
      'attributes': {'list': 'ordered'},
    },
    {'insert': 'segundo'},
    {
      'insert': '\n',
      'attributes': {'list': 'ordered'},
    },
    {'insert': 'meio\nde novo'},
    {
      'insert': '\n',
      'attributes': {'list': 'ordered'},
    },
    {'insert': 'marcador'},
    {
      'insert': '\n',
      'attributes': {'list': 'bullet'},
    },
  ];

  test('grava o delta editado, relê igual e preserva styles.xml e sectPr', () {
    final original = _docx(_body(_paragraphs));
    final saved = DocxDocument.read(original).save(edited);
    final rereadItem = DocxDocument.read(saved);
    expect(rereadItem.warnings, isEmpty);
    // Text and block attributes per line.
    final lines = _linesOf(rereadItem.delta);
    expect(lines, [
      ('Novo título', {'header': 2}),
      ('sublinhado veja o site', <String, dynamic>{}),
      ('primeiro', {'list': 'ordered'}),
      ('segundo', {'list': 'ordered'}),
      ('meio', <String, dynamic>{}),
      ('de novo', {'list': 'ordered'}),
      ('marcador', {'list': 'bullet'}),
    ]);
    expect(rereadItem.delta.firstWhere((o) => o['insert'] == 'o site')['attributes'], {
      'link': 'https://exemplo.com/?a=1&b=2',
    });

    expect(_file(saved, 'word/styles.xml').contains('w:styleId="Ttulo1"'), isTrue);
    expect(_file(saved, 'word/styles.xml').contains('heading 2'), isTrue); // minimal style added
    final documentItem = _file(saved, 'word/document.xml');
    expect(documentItem, contains(_section));
    expect(documentItem.trim().endsWith('$_section</w:body></w:document>'), isTrue);
    expect(_file(saved, 'word/_rels/document.xml.rels'), contains('TargetMode="External"'));

    // A second numbered list restarts at 1 (num with startOverride), and rewriting does not pile up nums.
    final numbering = _file(saved, 'word/numbering.xml');
    expect('<w:num '.allMatches(numbering).length, 3);
    expect(numbering, contains('w:startOverride'));
    final resaved = DocxDocument.read(saved).save(edited);
    expect('<w:num '.allMatches(_file(resaved, 'word/numbering.xml')).length, 3);
  });

  test('tabela, imagem e nota de rodapé geram aviso; o texto da tabela continua', () {
    const table =
        '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>célula</w:t></w:r></w:p></w:tc></w:tr></w:tbl>'
        '<w:p><w:r><w:drawing/></w:r><w:r><w:footnoteReference w:id="1"/></w:r></w:p>';
    final doc = DocxDocument.read(_docx(_body(table)));
    expect(doc.warnings, containsAll(['tabelas', 'imagens e objetos', 'notas de rodapé']));
    expect(doc.delta.first['insert'], startsWith('célula\n'));
  });

  test('revisões e comentários do orientador entram no delta e voltam ao gravar', () {
    const reviewed =
        '<w:p><w:commentRangeStart w:id="0"/><w:r><w:t xml:space="preserve">Texto </w:t></w:r>'
        '<w:ins w:id="5" w:author="Orientador" w:date="2026-10-01T12:00:00Z"><w:r><w:t>novo</w:t></w:r></w:ins>'
        '<w:del w:id="6" w:author="Orientador" w:date="2026-10-01T12:00:00Z"><w:r><w:delText>velho</w:delText></w:r></w:del>'
        '<w:commentRangeEnd w:id="0"/><w:r><w:commentReference w:id="0"/></w:r>'
        '<w:r><w:rPr><w:rFonts w:ascii="Arial"/><w:color w:val="FF0000"/><w:sz w:val="28"/><w:highlight w:val="yellow"/>'
        '<w:vertAlign w:val="superscript"/></w:rPr><w:t>fim</w:t></w:r></w:p>';
    final zip = ZipDecoder().decodeBytes(_docx(_body(reviewed)));
    zip.add(
      ArchiveFile.bytes(
        'word/comments.xml',
        utf8.encode(
          '<w:comments $_ns><w:comment w:id="0" w:author="Orientador" w:date="2026-10-01T12:00:00Z" w:initials="OR">'
          '<w:p><w:r><w:t>Reveja esta frase.</w:t></w:r></w:p></w:comment></w:comments>',
        ),
      ),
    );
    final doc = DocxDocument.read(ZipEncoder().encodeBytes(zip));
    expect(doc.warnings, isEmpty);
    expect(doc.comments.single.author, 'Orientador');
    expect(doc.comments.single.text, 'Reveja esta frase.');
    Map<String, dynamic>? attr(String t) => doc.delta.firstWhere((o) => o['insert'] == t)['attributes'] as Map<String, dynamic>?;
    expect(readMark(attr('novo')![insertionAttribute] as String).author, 'Orientador');
    expect(attr('novo')![commentAttribute], '0');
    expect(readMark(attr('velho')![deletionAttribute] as String).data, DateTime.utc(2026, 10, 1, 12));
    expect(attr('fim'), {'font': 'Arial', 'color': '#FF0000', 'size': '14', 'background': '#FFFF00', 'script': 'super'});

    // I add an insertion of mine and a new comment; turns tracking on.
    final delta = [
      ...doc.delta.take(doc.delta.length - 1),
      {
        'insert': ' meu',
        'attributes': {insertionAttribute: revisionMark('Eu', DateTime.utc(2026, 11, 1)), commentAttribute: '1'},
      },
      doc.delta.last,
    ];
    final comments = [...doc.comments, Comment(id: '1', author: 'Eu', text: 'Ajustei.')];
    final saved = doc.save(delta, comments: comments, track: true);
    final xml = _file(saved, 'word/document.xml');
    expect(xml, contains('w:author="Orientador"'));
    expect(xml, contains('<w:delText xml:space="preserve">velho</w:delText>'));
    expect(xml, contains('w:author="Eu" w:date="2026-11-01T00:00:00Z"'));
    expect(_file(saved, 'word/comments.xml'), contains('Ajustei.'));
    expect(_file(saved, 'word/_rels/document.xml.rels'), contains('relationships/comments'));
    final rereadItem = DocxDocument.read(saved);
    expect(rereadItem.comments.map((c) => c.id), ['0', '1']);
    expect(rereadItem.delta.firstWhere((o) => o['insert'] == ' meu')['attributes'][commentAttribute], '1');
    expect(rereadItem.delta.firstWhere((o) => o['insert'] == 'velho')['attributes'][deletionAttribute], isNotNull);
  });

  test('arquivo que não é docx dá erro em português', () {
    expect(
      () => DocxDocument.read(Uint8List.fromList(utf8.encode('não sou zip'))),
      throwsA(isA<InvalidDocx>().having((e) => e.mensagem, 'mensagem', contains('.docx'))),
    );
  });

  final soffice = Process.runSync('sh', ['-c', 'command -v soffice']).exitCode == 0;
  test('LibreOffice abre o docx gravado', () {
    final dir = Directory.systemTemp.createTempSync('docx_test');
    try {
      final saved = DocxDocument.read(_docx(_body(_paragraphs))).save(edited);
      File('${dir.path}/doc.docx').writeAsBytesSync(saved);
      final r = Process.runSync('soffice', [
        '-env:UserInstallation=file://${dir.path}/perfil',
        '--headless',
        '--convert-to',
        'txt:Text',
        '--outdir',
        dir.path,
        '${dir.path}/doc.docx',
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final text = File('${dir.path}/doc.txt').readAsStringSync();
      for (final t in ['Novo título', 'sublinhado veja o site', 'primeiro', 'de novo', 'marcador']) {
        expect(text, contains(t));
      }
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: soffice ? false : 'soffice ausente', timeout: const Timeout(Duration(minutes: 2)));
}

/// (line text, block attributes) of each delta line.
List<(String, Map<String, dynamic>)> _linesOf(List<Map<String, dynamic>> delta) {
  final lines = <(String, Map<String, dynamic>)>[];
  var current = StringBuffer();
  for (final op in delta) {
    final ins = op['insert'] as String;
    final attr = (op['attributes'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    final parts = ins.split('\n');
    for (var i = 0; i < parts.length; i++) {
      current.write(parts[i]);
      if (i < parts.length - 1) {
        lines.add((current.toString(), {
          for (final e in attr.entries)
            if (const {'header', 'list', 'align', 'indent'}.contains(e.key)) e.key: e.value,
        }));
        current = StringBuffer();
      }
    }
  }
  return lines;
}
