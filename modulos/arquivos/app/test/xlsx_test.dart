import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_arquivos/src/editores/xlsx.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

const _ns = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"';
const _rel = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

/// XLSX mínimo: duas abas, sharedStrings com texto rico, célula com estilo, fórmula e calcChain.
Uint8List _xlsx() {
  final arquivos = {
    '[Content_Types].xml': '<?xml version="1.0" encoding="UTF-8"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '<Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        '<Override PartName="/xl/calcChain.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.calcChain+xml"/>'
        '</Types>',
    '_rels/.rels': '<?xml version="1.0" encoding="UTF-8"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="$_rel/officeDocument" Target="xl/workbook.xml"/></Relationships>',
    'xl/workbook.xml': '<?xml version="1.0" encoding="UTF-8"?><workbook $_ns><sheets>'
        '<sheet name="Vendas" sheetId="1" r:id="rId1"/><sheet name="Resumo" sheetId="2" r:id="rId2"/>'
        '</sheets></workbook>',
    'xl/_rels/workbook.xml.rels': '<?xml version="1.0" encoding="UTF-8"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="$_rel/worksheet" Target="worksheets/sheet1.xml"/>'
        '<Relationship Id="rId2" Type="$_rel/worksheet" Target="/xl/worksheets/sheet2.xml"/>'
        '<Relationship Id="rId3" Type="$_rel/sharedStrings" Target="sharedStrings.xml"/>'
        '<Relationship Id="rId4" Type="$_rel/styles" Target="styles.xml"/>'
        '<Relationship Id="rId5" Type="$_rel/calcChain" Target="calcChain.xml"/>'
        '</Relationships>',
    'xl/sharedStrings.xml': '<?xml version="1.0" encoding="UTF-8"?><sst $_ns count="3" uniqueCount="3">'
        '<si><t>Produto</t></si><si><t>Qtd</t></si>'
        '<si><r><rPr><b/></rPr><t>Café </t></r><r><t>forte</t></r><rPh><t>x</t></rPh></si></sst>',
    'xl/styles.xml': '<?xml version="1.0" encoding="UTF-8"?><styleSheet $_ns>'
        '<fonts count="2"><font/><font><b/></font></fonts><fills count="1"><fill/></fills>'
        '<borders count="1"><border/></borders><cellStyleXfs count="1"><xf/></cellStyleXfs>'
        '<cellXfs count="2"><xf/><xf fontId="1" applyFont="1"/></cellXfs></styleSheet>',
    'xl/calcChain.xml': '<?xml version="1.0" encoding="UTF-8"?><calcChain $_ns><c r="B4" i="1"/></calcChain>',
    'xl/worksheets/sheet1.xml': '<?xml version="1.0" encoding="UTF-8"?><worksheet $_ns>'
        '<dimension ref="A1:B4"/><cols><col min="2" max="2" width="20" customWidth="1"/></cols><sheetData>'
        '<row r="1"><c r="A1" s="1" t="s"><v>0</v></c><c r="B1" s="1" t="s"><v>1</v></c></row>'
        '<row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>3</v></c></row>'
        '<row r="3" ht="30" customHeight="1"><c r="A3" t="inlineStr"><is><t>Chá</t></is></c><c r="B3"><v>4</v></c></row>'
        '<row r="4"><c r="A4" t="b"><v>1</v></c><c r="B4"><f>SUM(B2:B3)</f><v>7</v></c></row>'
        '</sheetData><mergeCells count="1"><mergeCell ref="C3:D4"/></mergeCells></worksheet>',
    'xl/worksheets/sheet2.xml': '<?xml version="1.0" encoding="UTF-8"?><worksheet $_ns><sheetData>'
        '<row r="1"><c r="A1"><f>Vendas!B4*2</f><v>14</v></c>'
        '<c r="B1"><f t="shared" ref="B1:B2" si="0">A1+1</f><v>15</v></c></row>'
        '<row r="2"><c r="B2"><f t="shared" si="0"/><v>1</v></c></row>'
        '</sheetData></worksheet>',
  };
  final zip = Archive();
  arquivos.forEach((nome, texto) => zip.add(ArchiveFile.bytes(nome, utf8.encode(texto))));
  return ZipEncoder().encodeBytes(zip);
}

String _texto(Uint8List xlsx, String caminho) =>
    utf8.decode(ZipDecoder().decodeBytes(xlsx).find(caminho)!.content);

void main() {
  test('referências A1', () {
    expect(refCelula(2, 1), 'B3');
    expect(refCelula(0, 27), 'AB1');
    expect(colunaDeLetras('AB'), 27);
    expect(letrasDaColuna(16383), 'XFD');
    expect(lerRef(r'$C$10'), (9, 2));
  });

  test('lê abas, textos compartilhados, texto rico, booleano e fórmula', () {
    final p = Pasta.ler(_xlsx());
    expect(p.abas.map((a) => a.nome), ['Vendas', 'Resumo']);
    final v = p.abas.first;
    expect((v.linhas, v.colunas), (4, 2));
    expect(v.celula(0, 0), 'Produto');
    expect(v.celula(1, 0), 'Café forte');
    expect(v.celula(2, 0), 'Chá');
    expect(v.celula(3, 0), 'VERDADEIRO');
    expect(v.celula(3, 1), '7');
    expect(v.conteudo(3, 1), '=SUM(B2:B3)');
    // Fórmula compartilhada expandida a partir da mestre.
    expect(p.abas[1].conteudo(1, 1), '=A2+1');
  });

  test('edita, grava e relê preservando estilo, abas e removendo o calcChain', () {
    final p = Pasta.ler(_xlsx());
    final v = p.abas.first;
    v.definir(0, 0, 'Item & cia');
    v.definir(1, 1, '2,5');
    v.definir(4, 0, 'Total novo');
    v.definir(4, 1, '=B4*10');
    expect(p.alterada, isTrue);
    final bytes = p.gravar();

    final zip = ZipDecoder().decodeBytes(bytes);
    expect(zip.find('xl/calcChain.xml'), isNull);
    expect(_texto(bytes, '[Content_Types].xml'), isNot(contains('calcChain')));
    expect(_texto(bytes, 'xl/_rels/workbook.xml.rels'), isNot(contains('calcChain')));
    expect(_texto(bytes, 'xl/workbook.xml'), contains('<calcPr fullCalcOnLoad="1"/>'));
    // Aba sem alteração e estilos ficam byte a byte.
    expect(_texto(bytes, 'xl/worksheets/sheet2.xml'), contains('<f t="shared" si="0"/>'));
    expect(_texto(bytes, 'xl/styles.xml'), contains('applyFont="1"'));
    final folha = _texto(bytes, 'xl/worksheets/sheet1.xml');
    expect(folha, contains('<c r="A1" s="1" t="inlineStr">'));
    expect(folha, contains('<c r="B1" s="1" t="s"><v>1</v></c>'));
    expect(folha, contains('<row r="3" ht="30" customHeight="1">'));
    expect(folha, contains('<dimension ref="A1:B5"/>'));

    final de = Pasta.ler(bytes);
    expect(de.abas.map((a) => a.nome), ['Vendas', 'Resumo']);
    final a = de.abas.first;
    expect(a.celula(0, 0), 'Item & cia');
    expect(a.celula(1, 1), '2.5');
    expect(a.celula(4, 0), 'Total novo');
    expect(a.conteudo(4, 1), '=B4*10');
    expect(a.celula(1, 0), 'Café forte');
    expect(de.abas[1].conteudo(1, 1), '=A2+1');
  });

  test('inserir e excluir linha e coluna no meio renumera células, fórmulas e mesclas', () {
    final p = Pasta.ler(_xlsx());
    final v = p.abas.first;
    v.inserirLinha(1); // nova linha 2: Café vai para A3, a soma para B5
    expect(v.celula(2, 0), 'Café forte');
    expect(v.conteudo(4, 1), '=SUM(B3:B4)');
    expect(p.abas[1].conteudo(0, 0), '=Vendas!B5*2');
    v.inserirColuna(0);
    expect(v.celula(2, 1), 'Café forte');
    expect(v.conteudo(4, 2), '=SUM(C3:C4)');
    v.excluirLinha(2);
    expect(v.conteudo(3, 2), '=SUM(C3:C3)');
    final bytes = p.gravar();
    final folha = _texto(bytes, 'xl/worksheets/sheet1.xml');
    expect(folha, contains('<mergeCell ref="D3:E4"/>'));
    expect(folha, contains('<col min="3" max="3"'));
    expect(folha, contains('<row r="3" ht="30" customHeight="1">'));
    // A aba Resumo apontava para Vendas e foi reescrita; a compartilhada virou explícita.
    final resumo = _texto(bytes, 'xl/worksheets/sheet2.xml');
    expect(resumo, contains('<f>Vendas!C4*2</f>'));
    expect(resumo, contains('<f>A2+1</f>'));
    final de = Pasta.ler(bytes).abas.first;
    expect(de.celula(0, 1), 'Produto');
    expect(de.conteudo(3, 2), '=SUM(C3:C3)');
  });

  test('arquivo que não é XLSX dá erro em português', () {
    expect(() => Pasta.ler(Uint8List.fromList([1, 2, 3])), throwsA(isA<XlsxInvalido>()));
    final soZip = ZipEncoder().encodeBytes(Archive()..add(ArchiveFile.bytes('a.txt', [65])));
    expect(
      () => Pasta.ler(soZip),
      throwsA(isA<XlsxInvalido>().having((e) => e.mensagem, 'mensagem', contains('workbook'))),
    );
  });

  final soffice = Process.runSync('which', ['soffice']).exitCode == 0;
  test('LibreOffice abre o resultado e recalcula a fórmula nova', () async {
    final dir = await Directory.systemTemp.createTemp('xlsx_teste');
    try {
      final p = Pasta.ler(_xlsx());
      p.abas.first.definir(4, 1, '=B4*10');
      await File('${dir.path}/p.xlsx').writeAsBytes(p.gravar());
      final r = await Process.run('soffice', [
        '--headless',
        '-env:UserInstallation=file://${dir.path}/perfil',
        '--convert-to',
        'csv',
        '--outdir',
        dir.path,
        '${dir.path}/p.xlsx',
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final csv = await File('${dir.path}/p.csv').readAsString();
      expect(csv, contains('Café forte'));
      expect(csv, contains('70'));
    } finally {
      await dir.delete(recursive: true);
    }
  }, skip: soffice ? false : 'soffice ausente', timeout: const Timeout(Duration(minutes: 2)));
}
