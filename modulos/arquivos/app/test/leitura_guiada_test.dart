import 'package:agent_arquivos/src/leitor/leitura_guiada.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('palavras cortadas como em shared/linguagem.py', () {
    // mesmo caso de plataforma/backend/tests/test_linguagem.py
    expect(palavrasDe("Deep-learning isn't new."), [(0, 13), (14, 19), (20, 23)]);
    expect(palavrasDe('meth-\nod, ação'), [(0, 4), (6, 8), (10, 14)]);
  });

  test('palavraEm acha a palavra do caractere tocado', () {
    const t = 'The method works.';
    expect(palavraEm(t, 6), const Trecho(4, 9));
    expect(palavraEm(t, 16), const Trecho(16, 16)); // o ponto final, fora de palavra
  });
}
