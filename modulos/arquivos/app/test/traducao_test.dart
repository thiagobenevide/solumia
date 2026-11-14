import 'package:agent_arquivos/src/api_arquivos.dart';
import 'package:agent_arquivos/src/leitor/camada_pagina.dart';
import 'package:agent_arquivos/src/leitor/traducao.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Texto e retângulos de linhas `(x, y, corpo, texto)`, 5 pontos por caractere, na ordem dada.
(String, List<Rect>) pagina(List<(double, double, double, String)> linhas) {
  final texto = StringBuffer();
  final rects = <Rect>[];
  for (final (x, y, h, t) in linhas) {
    for (var i = 0; i < t.length; i++) {
      texto.write(t[i]);
      rects.add(Rect.fromLTWH(x + i * 5, y, 5, h));
    }
    texto.write('\n');
    rects.add(Rect.zero);
  }
  return (texto.toString(), rects);
}

void main() {
  test('segmentar corta em fim de frase, mas não em abreviações e iniciais', () {
    const texto =
        'Results are shown in Fig. 2 (Smith et al. 2020).\r\nJ. Smith disagrees, e.g. in Table 1. '
        'Is it 3.5 m?\n\nConclusion\n\nWe  agree.';
    final frases = segmentar(texto);
    expect(
      [for (final f in frases) f.original],
      [
        'Results are shown in Fig. 2 (Smith et al. 2020).',
        'J. Smith disagrees, e.g. in Table 1.',
        'Is it 3.5 m?',
        'Conclusion',
        'We agree.',
      ],
    );
    // os índices apontam para o texto original (são os dos retângulos dos caracteres)
    final f = frases[1];
    expect(texto.substring(f.inicio, f.fim + 1), 'J. Smith disagrees, e.g. in Table 1.');
  });

  test('diagramar separa título, autores e parágrafos e põe rodapé no fim', () {
    final corrido = 'x' * 100;
    final (texto, rects) = pagina([
      (475, 700, 10, 'Rodape da pagina'), // os PDFs costumam trazer o rodapé antes do corpo
      (257, 50, 16, 'Um titulo centrado'),
      (50, 100, 10, 'Albert Torno'),
      (50, 114, 10, 'University of Goettingen'),
      (50, 150, 10, '$corrido.'),
      (50, 164, 10, '$corrido.'),
      (50, 178, 10, 'Fim do paragrafo.'),
      (20, 300, 5, 'x'),
      (20, 306, 5, 'y'),
      (20, 312, 5, 'z'),
    ]);
    final blocos = diagramar(texto, rects);
    expect(
      [for (final b in blocos) b.frases.first.original.substring(0, 5)],
      ['Um ti', 'Alber', 'Unive', 'xxxxx', 'Rodap'],
    );
    expect(blocos.first.titulo, isTrue);
    expect(blocos.first.alinhamento, Alinhamento.centro);
    expect(blocos[3].alinhamento, Alinhamento.justificado);
    expect(blocos.last.alinhamento, Alinhamento.direita);
  });

  test('diagramar lê uma coluna inteira antes da outra', () {
    final (texto, rects) = pagina([
      (50, 40, 10, 'Titulo que atravessa as duas colunas da pagina inteira ate o fim dela toda aqui'),
      (50, 100, 10, 'Primeira coluna'),
      (250, 100, 10, 'Segunda coluna'),
      (50, 200, 10, 'Ainda a primeira'),
      (250, 200, 10, 'Ainda a segunda'),
    ]);
    expect(
      [for (final b in diagramar(texto, rects)) b.frases.first.original.split(' ').last],
      [
        'aqui', 'coluna', 'primeira', 'coluna', 'segunda', //
      ],
    );
  });

  testWidgets('painel mostra um parágrafo por bloco e selecionar leva às frases certas', (tester) async {
    final (texto, rects) = pagina([(50, 50, 10, 'First paragraph.'), (50, 100, 10, 'Second one. Third one.')]);
    final blocos = diagramar(texto, rects);
    final tradutor = TradutorDocumento(ApiArquivos('http://x'), 'a', TextosDasPaginas());
    addTearDown(tradutor.dispose);
    tradutor.paginas[0] = PaginaTraduzida(TextoPagina(texto, rects), blocos, ['Primeiro.', 'Segundo.', 'Terceiro.']);
    List<int>? marcadas;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PainelTraducao(
            tradutor: tradutor,
            pagina: 0,
            destaques: const [],
            aoMarcar: (_, frases) => marcadas = frases,
            aoRetomar: () {},
            aoFechar: () {},
          ),
        ),
      ),
    );
    expect(find.text('Primeiro.'), findsOneWidget);
    expect(find.text('Segundo. Terceiro.'), findsOneWidget);

    final inicio = tester.getTopLeft(find.text('Segundo. Terceiro.')) + const Offset(2, 6);
    final gesto = await tester.startGesture(inicio, kind: PointerDeviceKind.mouse);
    await tester.pump();
    await gesto.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesto.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Marcar no original (inglês + português)'));
    await tester.pump();
    expect(marcadas, [1]);
  });
}
