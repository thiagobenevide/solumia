import 'package:agent_arquivos/src/reader/guided_reading.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('palavras cortadas como em shared/linguagem.py', () {
    // same case as plataforma/backend/tests/test_linguagem.py
    expect(wordsOf("Deep-learning isn't new."), [(0, 13), (14, 19), (20, 23)]);
    expect(wordsOf('meth-\nod, ação'), [(0, 4), (6, 8), (10, 14)]);
  });

  test('palavraEm acha a palavra do caractere tocado', () {
    const t = 'The method works.';
    expect(wordAt(t, 6), const Span(4, 9));
    expect(wordAt(t, 16), const Span(16, 16)); // the period, outside a word
  });
}
