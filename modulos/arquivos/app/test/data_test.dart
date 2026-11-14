import 'dart:convert';

import 'package:agent_arquivos/src/reader/data_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CSV com ; aspas e quebra de linha vai e volta igual', () {
    const text = 'nome;obs\r\n"Silva; Ana";"disse ""oi""\nde novo"\r\nBia;\r\n';
    final (lines, sep) = readCsv(text);
    expect(sep, ';');
    expect(lines, [
      ['nome', 'obs'],
      ['Silva; Ana', 'disse "oi"\nde novo'],
      ['Bia', ''],
    ]);
    expect(writeCsv(lines, sep, wrap: '\r\n'), text);
  });

  test('original em Latin-1 ou com BOM grava de volta na mesma codificação', () {
    final l1 = OriginalText.decode(latin1.encode('ação'));
    expect((l1.text, l1.emLatin1), ('ação', true));
    expect(l1.encode('ção'), latin1.encode('ção'));
    final good = OriginalText.decode(utf8.encode('\uFEFFa,b'));
    expect(good.text, 'a,b');
    expect(good.encode('c,d'), [0xEF, 0xBB, 0xBF, ...utf8.encode('c,d')]);
  });
}
