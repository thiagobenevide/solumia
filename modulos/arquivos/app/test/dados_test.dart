import 'dart:convert';

import 'package:agent_arquivos/src/leitor/dados_tela.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CSV com ; aspas e quebra de linha vai e volta igual', () {
    const texto = 'nome;obs\r\n"Silva; Ana";"disse ""oi""\nde novo"\r\nBia;\r\n';
    final (linhas, sep) = lerCsv(texto);
    expect(sep, ';');
    expect(linhas, [
      ['nome', 'obs'],
      ['Silva; Ana', 'disse "oi"\nde novo'],
      ['Bia', ''],
    ]);
    expect(escreverCsv(linhas, sep, quebra: '\r\n'), texto);
  });

  test('original em Latin-1 ou com BOM grava de volta na mesma codificação', () {
    final l1 = TextoOriginal.decodificar(latin1.encode('ação'));
    expect((l1.texto, l1.emLatin1), ('ação', true));
    expect(l1.codificar('ção'), latin1.encode('ção'));
    final bom = TextoOriginal.decodificar(utf8.encode('\uFEFFa,b'));
    expect(bom.texto, 'a,b');
    expect(bom.codificar('c,d'), [0xEF, 0xBB, 0xBF, ...utf8.encode('c,d')]);
  });
}
