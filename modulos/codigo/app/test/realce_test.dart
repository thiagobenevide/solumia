import 'package:agent_codigo/src/realce.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Cor de cada trecho da linha `n`, como `texto→cor` (sem cor = null).
Map<String, Color?> _cores(String texto, String caminho, int n) {
  final linhas = realcar(texto, caminho, const TextStyle(), Brightness.dark)!;
  return {for (final t in linhas[n]) t.text!: t.style?.color};
}

void main() {
  final c = coresRealce(Brightness.dark);

  test('python: def, string f, comentário e self', () {
    const src = '@dataclass\ndef f(self, x=1):\n    return f"{self.x} ok"  # fim\n"""a\nb"""\n';
    final l0 = _cores(src, 'a.py', 0);
    expect(l0['@dataclass'], c[Tipo.anotacao]);
    final l1 = _cores(src, 'a.py', 1);
    expect(l1['def'], c[Tipo.palavra]);
    expect(l1['f'], c[Tipo.funcao]);
    expect(l1['self'], c[Tipo.proprio]);
    expect(l1['1'], c[Tipo.numero]);
    final l2 = _cores(src, 'a.py', 2);
    expect(l2['f"'], c[Tipo.texto]);
    expect(l2['{self.x}'], c[Tipo.interpolacao]);
    expect(l2['# fim'], c[Tipo.comentario]);
    expect(_cores(src, 'a.py', 4)['b"""'], c[Tipo.texto]);
  });

  test('dart: classe, chamada e string com interpolação', () {
    const src = "final x = Foo.bar('a \$b');\n/* c\nd */ var y;";
    final l0 = _cores(src, 'a.dart', 0);
    expect(l0['final'], c[Tipo.palavra]);
    expect(l0['Foo'], c[Tipo.classe]);
    expect(l0['bar'], c[Tipo.funcao]);
    expect(l0["'a "], c[Tipo.texto]);
    expect(l0[r'$b'], c[Tipo.interpolacao]);
    expect(_cores(src, 'a.dart', 2)['d */'], c[Tipo.comentario]);
  });

  test('shell: variáveis, comentário e palavras', () {
    const src = 'if [ -n "\$HOME" ]; then echo \${#x} # c\nfi';
    final l0 = _cores(src, 'a.sh', 0);
    expect(l0['if'], c[Tipo.palavra]);
    expect(l0[r'$HOME'], c[Tipo.variavel]);
    expect(l0[r'${#x}'], c[Tipo.variavel]);
    expect(l0['# c'], c[Tipo.comentario]);
  });

  test('extensão desconhecida não realça', () {
    expect(realcar('x', 'a.txt', const TextStyle(), Brightness.dark), isNull);
  });
}
