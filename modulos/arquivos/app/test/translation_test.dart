import 'package:agent_arquivos/src/files_api.dart';
import 'package:agent_arquivos/src/reader/page_layer.dart';
import 'package:agent_arquivos/src/reader/translation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Text and line rectangles `(x, y, corpo, texto)`, 5 points per character, in the given order.
(String, List<Rect>) page(List<(double, double, double, String)> lines) {
  final text = StringBuffer();
  final rects = <Rect>[];
  for (final (x, y, h, t) in lines) {
    for (var i = 0; i < t.length; i++) {
      text.write(t[i]);
      rects.add(Rect.fromLTWH(x + i * 5, y, 5, h));
    }
    text.write('\n');
    rects.add(Rect.zero);
  }
  return (text.toString(), rects);
}

void main() {
  test('segmentar corta em fim de frase, mas não em abreviações e iniciais', () {
    const text =
        'Results are shown in Fig. 2 (Smith et al. 2020).\r\nJ. Smith disagrees, e.g. in Table 1. '
        'Is it 3.5 m?\n\nConclusion\n\nWe  agree.';
    final sentences = segment(text);
    expect(
      [for (final f in sentences) f.original],
      [
        'Results are shown in Fig. 2 (Smith et al. 2020).',
        'J. Smith disagrees, e.g. in Table 1.',
        'Is it 3.5 m?',
        'Conclusion',
        'We agree.',
      ],
    );
    // the indices point to the original text (they are the ones of the character rectangles)
    final f = sentences[1];
    expect(text.substring(f.start, f.end + 1), 'J. Smith disagrees, e.g. in Table 1.');
  });

  test('diagramar separa título, autores e parágrafos e põe rodapé no fim', () {
    final running = 'x' * 100;
    final (text, rects) = page([
      (475, 700, 10, 'Rodape da pagina'), // PDFs often bring the footer before the body
      (257, 50, 16, 'Um titulo centrado'),
      (50, 100, 10, 'Albert Torno'),
      (50, 114, 10, 'University of Goettingen'),
      (50, 150, 10, '$running.'),
      (50, 164, 10, '$running.'),
      (50, 178, 10, 'Fim do paragrafo.'),
      (20, 300, 5, 'x'),
      (20, 306, 5, 'y'),
      (20, 312, 5, 'z'),
    ]);
    final blocks = layOut(text, rects);
    expect(
      [for (final b in blocks) b.sentences.first.original.substring(0, 5)],
      ['Um ti', 'Alber', 'Unive', 'xxxxx', 'Rodap'],
    );
    expect(blocks.first.title, isTrue);
    expect(blocks.first.alignmentMode, TextAlignment.center);
    expect(blocks[3].alignmentMode, TextAlignment.justified);
    expect(blocks.last.alignmentMode, TextAlignment.right);
  });

  test('diagramar lê uma coluna inteira antes da outra', () {
    final (text, rects) = page([
      (50, 40, 10, 'Titulo que atravessa as duas colunas da pagina inteira ate o fim dela toda aqui'),
      (50, 100, 10, 'Primeira coluna'),
      (250, 100, 10, 'Segunda coluna'),
      (50, 200, 10, 'Ainda a primeira'),
      (250, 200, 10, 'Ainda a segunda'),
    ]);
    expect(
      [for (final b in layOut(text, rects)) b.sentences.first.original.split(' ').last],
      [
        'aqui', 'coluna', 'primeira', 'coluna', 'segunda', //
      ],
    );
  });

  testWidgets('painel mostra um parágrafo por bloco e selecionar leva às frases certas', (tester) async {
    final (text, rects) = page([(50, 50, 10, 'First paragraph.'), (50, 100, 10, 'Second one. Third one.')]);
    final blocks = layOut(text, rects);
    final translator = DocumentTranslator(FilesApi('http://x'), 'a', PageTexts());
    addTearDown(translator.dispose);
    translator.pages[0] = TranslatedPage(PageText(text, rects), blocks, ['Primeiro.', 'Segundo.', 'Terceiro.']);
    List<int>? marked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TranslationPanel(
            translator: translator,
            page: 0,
            highlights: const [],
            onMark: (_, sentences) => marked = sentences,
            onResume: () {},
            onClose: () {},
          ),
        ),
      ),
    );
    expect(find.text('Primeiro.'), findsOneWidget);
    expect(find.text('Segundo. Terceiro.'), findsOneWidget);

    final start = tester.getTopLeft(find.text('Segundo. Terceiro.')) + const Offset(2, 6);
    final gesture = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    await tester.pump();
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Marcar no original (inglês + português)'));
    await tester.pump();
    expect(marked, [1]);
  });
}
