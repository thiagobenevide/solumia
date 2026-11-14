import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_arquivos/src/editores/docx.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

const _ns =
    'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"';

const _secao = '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1417" w:right="1701" w:bottom="1417" w:left="1701"/></w:sectPr>';

const _estilos =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:styles $_ns>'
    '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>'
    '<w:style w:type="paragraph" w:styleId="Ttulo1"><w:name w:val="heading 1"/></w:style>'
    '</w:styles>';

const _numeracao =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:numbering $_ns>'
    '<w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/><w:lvlText w:val="•"/></w:lvl></w:abstractNum>'
    '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>'
    '</w:numbering>';

String _corpo(String paragrafos) =>
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document $_ns><w:body>$paragrafos$_secao</w:body></w:document>';

Uint8List _docx(String corpo) {
  final zip = Archive();
  void add(String nome, String texto) => zip.add(ArchiveFile.bytes(nome, utf8.encode(texto)));
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
  add('word/styles.xml', _estilos);
  add('word/numbering.xml', _numeracao);
  add('word/document.xml', corpo);
  return ZipEncoder().encodeBytes(zip);
}

const _paragrafos =
    '<w:p><w:pPr><w:pStyle w:val="Ttulo1"/></w:pPr><w:r><w:t>Relatório</w:t></w:r></w:p>'
    '<w:p><w:r><w:t xml:space="preserve">Texto com </w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>negrito</w:t></w:r>'
    '<w:r><w:t xml:space="preserve"> e </w:t></w:r><w:r><w:rPr><w:i/></w:rPr><w:t>itálico</w:t></w:r><w:r><w:t>.</w:t></w:r></w:p>'
    '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>item um</w:t></w:r></w:p>'
    '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>item dois</w:t></w:r></w:p>'
    '<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:t>fim</w:t><w:tab/><w:t>!</w:t></w:r></w:p>';

String _arquivo(Uint8List docx, String nome) =>
    utf8.decode(ZipDecoder().decodeBytes(docx).findFile(nome)!.content);

void main() {
  test('lê título, negrito/itálico, lista com marcador e alinhamento', () {
    final doc = DocumentoDocx.ler(_docx(_corpo(_paragrafos)));
    expect(doc.avisos, isEmpty);
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

  final editado = <Map<String, dynamic>>[
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
    final original = _docx(_corpo(_paragrafos));
    final gravado = DocumentoDocx.ler(original).gravar(editado);
    final relido = DocumentoDocx.ler(gravado);
    expect(relido.avisos, isEmpty);
    // Texto e atributos de bloco por linha.
    final linhas = _linhasDe(relido.delta);
    expect(linhas, [
      ('Novo título', {'header': 2}),
      ('sublinhado veja o site', <String, dynamic>{}),
      ('primeiro', {'list': 'ordered'}),
      ('segundo', {'list': 'ordered'}),
      ('meio', <String, dynamic>{}),
      ('de novo', {'list': 'ordered'}),
      ('marcador', {'list': 'bullet'}),
    ]);
    expect(relido.delta.firstWhere((o) => o['insert'] == 'o site')['attributes'], {
      'link': 'https://exemplo.com/?a=1&b=2',
    });

    expect(_arquivo(gravado, 'word/styles.xml').contains('w:styleId="Ttulo1"'), isTrue);
    expect(_arquivo(gravado, 'word/styles.xml').contains('heading 2'), isTrue); // estilo mínimo acrescentado
    final documento = _arquivo(gravado, 'word/document.xml');
    expect(documento, contains(_secao));
    expect(documento.trim().endsWith('$_secao</w:body></w:document>'), isTrue);
    expect(_arquivo(gravado, 'word/_rels/document.xml.rels'), contains('TargetMode="External"'));

    // Segunda lista numerada recomeça em 1 (num com startOverride), e regravar não acumula nums.
    final numeracao = _arquivo(gravado, 'word/numbering.xml');
    expect('<w:num '.allMatches(numeracao).length, 3);
    expect(numeracao, contains('w:startOverride'));
    final regravado = DocumentoDocx.ler(gravado).gravar(editado);
    expect('<w:num '.allMatches(_arquivo(regravado, 'word/numbering.xml')).length, 3);
  });

  test('tabela, imagem e nota de rodapé geram aviso; o texto da tabela continua', () {
    const tabela =
        '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>célula</w:t></w:r></w:p></w:tc></w:tr></w:tbl>'
        '<w:p><w:r><w:drawing/></w:r><w:r><w:footnoteReference w:id="1"/></w:r></w:p>';
    final doc = DocumentoDocx.ler(_docx(_corpo(tabela)));
    expect(doc.avisos, containsAll(['tabelas', 'imagens e objetos', 'notas de rodapé']));
    expect(doc.delta.first['insert'], startsWith('célula\n'));
  });

  test('revisões e comentários do orientador entram no delta e voltam ao gravar', () {
    const revisado =
        '<w:p><w:commentRangeStart w:id="0"/><w:r><w:t xml:space="preserve">Texto </w:t></w:r>'
        '<w:ins w:id="5" w:author="Orientador" w:date="2026-10-01T12:00:00Z"><w:r><w:t>novo</w:t></w:r></w:ins>'
        '<w:del w:id="6" w:author="Orientador" w:date="2026-10-01T12:00:00Z"><w:r><w:delText>velho</w:delText></w:r></w:del>'
        '<w:commentRangeEnd w:id="0"/><w:r><w:commentReference w:id="0"/></w:r>'
        '<w:r><w:rPr><w:rFonts w:ascii="Arial"/><w:color w:val="FF0000"/><w:sz w:val="28"/><w:highlight w:val="yellow"/>'
        '<w:vertAlign w:val="superscript"/></w:rPr><w:t>fim</w:t></w:r></w:p>';
    final zip = ZipDecoder().decodeBytes(_docx(_corpo(revisado)));
    zip.add(
      ArchiveFile.bytes(
        'word/comments.xml',
        utf8.encode(
          '<w:comments $_ns><w:comment w:id="0" w:author="Orientador" w:date="2026-10-01T12:00:00Z" w:initials="OR">'
          '<w:p><w:r><w:t>Reveja esta frase.</w:t></w:r></w:p></w:comment></w:comments>',
        ),
      ),
    );
    final doc = DocumentoDocx.ler(ZipEncoder().encodeBytes(zip));
    expect(doc.avisos, isEmpty);
    expect(doc.comentarios.single.autor, 'Orientador');
    expect(doc.comentarios.single.texto, 'Reveja esta frase.');
    Map<String, dynamic>? attr(String t) => doc.delta.firstWhere((o) => o['insert'] == t)['attributes'] as Map<String, dynamic>?;
    expect(lerMarca(attr('novo')![atributoInsercao] as String).autor, 'Orientador');
    expect(attr('novo')![atributoComentario], '0');
    expect(lerMarca(attr('velho')![atributoExclusao] as String).data, DateTime.utc(2026, 10, 1, 12));
    expect(attr('fim'), {'font': 'Arial', 'color': '#FF0000', 'size': '14', 'background': '#FFFF00', 'script': 'super'});

    // Eu acrescento uma inserção minha e um comentário novo; liga o rastreio.
    final delta = [
      ...doc.delta.take(doc.delta.length - 1),
      {
        'insert': ' meu',
        'attributes': {atributoInsercao: marcaRevisao('Eu', DateTime.utc(2026, 11, 1)), atributoComentario: '1'},
      },
      doc.delta.last,
    ];
    final comentarios = [...doc.comentarios, Comentario(id: '1', autor: 'Eu', texto: 'Ajustei.')];
    final gravado = doc.gravar(delta, comentarios: comentarios, rastrear: true);
    final xml = _arquivo(gravado, 'word/document.xml');
    expect(xml, contains('w:author="Orientador"'));
    expect(xml, contains('<w:delText xml:space="preserve">velho</w:delText>'));
    expect(xml, contains('w:author="Eu" w:date="2026-11-01T00:00:00Z"'));
    expect(_arquivo(gravado, 'word/comments.xml'), contains('Ajustei.'));
    expect(_arquivo(gravado, 'word/_rels/document.xml.rels'), contains('relationships/comments'));
    final relido = DocumentoDocx.ler(gravado);
    expect(relido.comentarios.map((c) => c.id), ['0', '1']);
    expect(relido.delta.firstWhere((o) => o['insert'] == ' meu')['attributes'][atributoComentario], '1');
    expect(relido.delta.firstWhere((o) => o['insert'] == 'velho')['attributes'][atributoExclusao], isNotNull);
  });

  test('arquivo que não é docx dá erro em português', () {
    expect(
      () => DocumentoDocx.ler(Uint8List.fromList(utf8.encode('não sou zip'))),
      throwsA(isA<DocxInvalido>().having((e) => e.mensagem, 'mensagem', contains('.docx'))),
    );
  });

  final soffice = Process.runSync('sh', ['-c', 'command -v soffice']).exitCode == 0;
  test('LibreOffice abre o docx gravado', () {
    final dir = Directory.systemTemp.createTempSync('docx_test');
    try {
      final gravado = DocumentoDocx.ler(_docx(_corpo(_paragrafos))).gravar(editado);
      File('${dir.path}/doc.docx').writeAsBytesSync(gravado);
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
      final texto = File('${dir.path}/doc.txt').readAsStringSync();
      for (final t in ['Novo título', 'sublinhado veja o site', 'primeiro', 'de novo', 'marcador']) {
        expect(texto, contains(t));
      }
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: soffice ? false : 'soffice ausente', timeout: const Timeout(Duration(minutes: 2)));
}

/// (texto da linha, atributos de bloco) de cada linha do delta.
List<(String, Map<String, dynamic>)> _linhasDe(List<Map<String, dynamic>> delta) {
  final linhas = <(String, Map<String, dynamic>)>[];
  var atual = StringBuffer();
  for (final op in delta) {
    final ins = op['insert'] as String;
    final attr = (op['attributes'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    final partes = ins.split('\n');
    for (var i = 0; i < partes.length; i++) {
      atual.write(partes[i]);
      if (i < partes.length - 1) {
        linhas.add((atual.toString(), {
          for (final e in attr.entries)
            if (const {'header', 'list', 'align', 'indent'}.contains(e.key)) e.key: e.value,
        }));
        atual = StringBuffer();
      }
    }
  }
  return linhas;
}
