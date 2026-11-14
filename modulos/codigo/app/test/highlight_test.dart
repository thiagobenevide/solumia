import 'package:agent_codigo/src/highlight.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Color of each span of line `n`, as `text→color` (no color = null).
Map<String, Color?> _cores(String text, String path, int n) {
  final lines = highlight(text, path, const TextStyle(), Brightness.dark)!;
  return {for (final t in lines[n]) t.text!: t.style?.color};
}

void main() {
  final c = highlightColors(Brightness.dark);

  test('python: def, string f, comentário e self', () {
    const src = '@dataclass\ndef f(self, x=1):\n    return f"{self.x} ok"  # fim\n"""a\nb"""\n';
    final l0 = _cores(src, 'a.py', 0);
    expect(l0['@dataclass'], c[TokenKind.annotation]);
    final l1 = _cores(src, 'a.py', 1);
    expect(l1['def'], c[TokenKind.keyword]);
    expect(l1['f'], c[TokenKind.function]);
    expect(l1['self'], c[TokenKind.selfRef]);
    expect(l1['1'], c[TokenKind.number]);
    final l2 = _cores(src, 'a.py', 2);
    expect(l2['f"'], c[TokenKind.text]);
    expect(l2['{self.x}'], c[TokenKind.interpolation]);
    expect(l2['# fim'], c[TokenKind.comment]);
    expect(_cores(src, 'a.py', 4)['b"""'], c[TokenKind.text]);
  });

  test('dart: classe, chamada e string com interpolação', () {
    const src = "final x = Foo.bar('a \$b');\n/* c\nd */ var y;";
    final l0 = _cores(src, 'a.dart', 0);
    expect(l0['final'], c[TokenKind.keyword]);
    expect(l0['Foo'], c[TokenKind.typeName]);
    expect(l0['bar'], c[TokenKind.function]);
    expect(l0["'a "], c[TokenKind.text]);
    expect(l0[r'$b'], c[TokenKind.interpolation]);
    expect(_cores(src, 'a.dart', 2)['d */'], c[TokenKind.comment]);
  });

  test('shell: variáveis, comentário e palavras', () {
    const src = 'if [ -n "\$HOME" ]; then echo \${#x} # c\nfi';
    final l0 = _cores(src, 'a.sh', 0);
    expect(l0['if'], c[TokenKind.keyword]);
    expect(l0[r'$HOME'], c[TokenKind.variable]);
    expect(l0[r'${#x}'], c[TokenKind.variable]);
    expect(l0['# c'], c[TokenKind.comment]);
  });

  test('extensão desconhecida não realça', () {
    expect(highlight('x', 'a.txt', const TextStyle(), Brightness.dark), isNull);
  });
}
