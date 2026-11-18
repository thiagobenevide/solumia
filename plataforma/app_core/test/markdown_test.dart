import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _md = '''# Título
Texto **negrito *it*** e *itálico*, ~~tachado~~, ==marcado==, `código`, [[Outra nota]], [site](https://x.y)
<span style="color:#e03131">vermelho **forte**</span> <u>sub</u> %%oculto%% ![](https://x.y/a.png) e <mark style="background:#8ce99a">verde</mark>
- item
1. um
- [x] feito
> citação
| a | b |
| --- | --- |
```mermaid
flowchart TD
```
---''';

void main() {
  testWidgets('o texto formatado mantém exatamente o Markdown', (tester) async {
    final c = ControladorMarkdown()..text = _md;
    late TextSpan span;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (ctx) {
      span = c.buildTextSpan(context: ctx, withComposing: false);
      return const SizedBox();
    })));
    expect(span.toPlainText(), _md);
  });

  testWidgets('o visualizador renderiza sem quebrar', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: VisualizadorMarkdown(texto: '$_md\n> [!tip] Dica\n> corpo')))));
    expect(find.text('Dica'), findsOneWidget);
  });

  testWidgets('a barra completa monta', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: CampoMarkdown(controle: ControladorMarkdown(text: _md))))));
    expect(find.byTooltip('Pincel: copiar a formatação da seleção'), findsOneWidget);
  });

  test('pincel copia e borracha limpa', () {
    final c = ControladorMarkdown(text: '<u>**ab**</u> cd')..selection = const TextSelection(baseOffset: 5, extentOffset: 7);
    expect(c.formatosDaSelecao(), [('<u>', '</u>'), ('**', '**')]);
    c.limparFormatacao();
    expect(c.text, 'ab cd');
  });

  test('envolver alterna e prefixar numera as linhas', () {
    final c = ControladorMarkdown()
      ..text = 'a\nb'
      ..selection = const TextSelection(baseOffset: 0, extentOffset: 3);
    c.prefixarLinhas((i) => '${i + 1}. ', RegExp(r'^\s*\d+[.)]\s'));
    expect(c.text, '1. a\n2. b');
    c
      ..text = 'x'
      ..selection = const TextSelection(baseOffset: 0, extentOffset: 1);
    c.envolver('**');
    expect(c.text, '**x**');
    c.envolver('**');
    expect(c.text, 'x');
  });

  testWidgets('leitura de nota do Obsidian não mostra as marcas', (tester) async {
    const nota = """## Seção **forte**
Parágrafo com [[Outra nota|apelido]], [[Nota#Parte]], _ênfase_ e snake_case_nome.
Segunda linha do mesmo parágrafo.

- nível 1
  - nível 2 com `código`
    - nível 3
1) primeiro
2) segundo
> [!tip] Dica
> texto da dica
| Coluna | Valor |
|:--|--:|
| **a** | 1 |
```python
print("oi")
```""";
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: VisualizadorMarkdown(texto: nota)))));
    final all = tester.widgetList<RichText>(find.byType(RichText)).map((t) => t.text.toPlainText()).join('\n');
    for (final mark in ['## ', '**', '[[', ']]', '> ']) {
      expect(all.contains(mark), isFalse, reason: 'vazou "$mark" em: $all');
    }
    expect(all, contains('apelido'));
    expect(all, contains('snake_case_nome'));
    expect(all, contains('print("oi")'));
  });
}
