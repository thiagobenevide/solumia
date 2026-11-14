import 'package:agent_design/src/cache.dart';
import 'package:agent_design/src/models.dart';
import 'package:agent_design/src/board/export.dart';
import 'package:agent_design/src/board/input.dart';
import 'package:agent_design/src/board/toolbox.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const stroke = Traco(
    't1',
    brush: Pincel.caneta,
    color: Color(0xFF1E5EFF),
    thickness: 4,
    pontos: [StrokePoint(0, 0, 0.5), StrokePoint(100, 0, 1)],
  );

  test('elementos vão e voltam do JSON', () {
    final elements = [
      stroke,
      const Forma('f1', shape: ShapeKind.seta, a: Offset(1, 2), b: Offset(30, 40), color: Colors.red, thickness: 3),
      const BoardText('x1', position: Offset(5, 5), text: 'Olá', color: Colors.black, size: 24),
    ];
    final volta = [for (final e in elements) Elemento.fromJson(e.toJson())!.toJson()];
    expect(volta, [for (final e in elements) e.toJson()]);
    expect(Elemento.fromJson({'id': 'v', 'tipo': 'video'}), isNull);
  });

  test('borracha encosta no traço e na borda da forma, não no vazio', () {
    expect(stroke.touches(const Offset(50, 3), 2), isTrue);
    expect(stroke.touches(const Offset(50, 30), 2), isFalse);
    const ret = Forma(
      'r',
      shape: ShapeKind.retangulo,
      a: Offset.zero,
      b: Offset(100, 100),
      color: Colors.black,
      thickness: 2,
    );
    expect(ret.touches(const Offset(100, 50), 2), isTrue);
    expect(ret.touches(const Offset(50, 50), 2), isFalse);
  });

  test('mesclar mantém o local, traz o remoto novo e respeita o que foi apagado aqui', () {
    Traco t(String id) => Traco(id, brush: Pincel.caneta, color: Colors.black, thickness: 1, pontos: const []);
    final r = merge([t('a'), t('c')], [t('a'), t('b'), t('d')], {'d'});
    expect(r.map((e) => e.id), ['b', 'a', 'c']);
  });

  test('caneta desenha, ponta de borracha e botão lateral apagam, dedo só move com caneta vista', () {
    Gesture g(
      PointerDeviceKind type, {
      int buttons = kPrimaryButton,
      bool finger = true,
      Tool f = Tool.caneta,
    }) => classify(type: type, buttons: buttons, tool: f, fingerDraws: finger);
    expect(g(PointerDeviceKind.stylus), Gesture.draw);
    expect(g(PointerDeviceKind.invertedStylus), Gesture.erase);
    expect(g(PointerDeviceKind.stylus, buttons: kPrimaryButton | kPrimaryStylusButton), Gesture.erase);
    expect(g(PointerDeviceKind.touch, finger: false), Gesture.pan);
    expect(g(PointerDeviceKind.mouse, buttons: kMiddleMouseButton), Gesture.pan);
    expect(g(PointerDeviceKind.mouse, f: Tool.hand), Gesture.pan);

    final toolbox = Estojo();
    expect(toolbox.fingerDraws, isTrue);
    toolbox.penSeen();
    expect(toolbox.fingerDraws, isFalse);
  });

  test('zoom mantém parado o ponto sob o cursor', () {
    final c = Camera()..offset = const Offset(10, 20);
    final antes = c.toWorld(const Offset(200, 150));
    c.zoom(2, const Offset(200, 150));
    expect(c.toWorld(const Offset(200, 150)), antes);
  });

  test('laço pega o que abraça e transformar move, escala e recolore', () {
    const lasso = [Offset(-10, -10), Offset(120, -10), Offset(120, 10), Offset(-10, 10)];
    expect(stroke.insideLasso(lasso), isTrue);
    expect(stroke.insideLasso(const [Offset(200, 200), Offset(300, 200), Offset(300, 300)]), isFalse);

    final dobro = stroke.transform((q) => q * 2, factor: 2, id: 'copia', color: Colors.red);
    expect(dobro.id, 'copia');
    expect(dobro.color, Colors.red);
    expect(dobro.thickness, 8);
    expect(dobro.pontos.last.offset, const Offset(200, 0));
    expect(dobro.pontos.last.p, 1);
  });

  test('cache guarda o quadro com as mudanças pendentes', () async {
    final cache = await BoardCache.open();
    final summary = {
      'id': 'q1',
      'titulo': 'Aula',
      'fundo': 'grade',
      'versao': 3,
      'atualizado': '2026-10-28T10:00:00+00:00',
    };
    await cache.store(summary, [stroke], pending: true, erased: {'x'});
    final c = cache.read('q1')!;
    expect((c.summary.title, c.summary.background, c.summary.version, c.pending), ('Aula', Background.grade, 3, true));
    expect(c.erased, {'x'});
    expect(c.elements.single.toJson(), stroke.toJson());
    expect(cache.summaries().single.id, 'q1');
    await cache.remover('q1');
    expect(cache.read('q1'), isNull);
  });

  test('exporta PNG e PDF', () async {
    final image = await png([stroke], Background.pontos, density: 1);
    expect(image.sublist(1, 4), 'PNG'.codeUnits);
    final documento = await pdf([stroke], Background.liso);
    expect(String.fromCharCodes(documento.sublist(0, 4)), '%PDF');
  });

  test('grupo e tabela vão e voltam pelo JSON', () {
    final grouped = stroke.withGroup('g1');
    expect((Elemento.fromJson(grouped.toJson())!).group, 'g1');
    expect(stroke.toJson().containsKey('grupo'), isFalse);

    final t = BoardTable.nova('tb', const Offset(10, 20), 2, 3);
    final full = t.copy(
      cells: [
        [const Cell(text: 'Mês'), const Cell(text: 'Entrada', background: Color(0xFFC8E6C9)), const Cell()],
        [const Cell(text: 'Jan'), const Cell(text: '1.000', alignmentMode: 2, bold: true), const Cell()],
      ],
    ).fitted();
    final volta = Elemento.fromJson(full.transform((q) => q, group: 'g2').toJson())! as BoardTable;
    expect((volta.linhas, volta.columns, volta.group), (2, 3, 'g2'));
    expect(volta.cells[0][1].background, const Color(0xFFC8E6C9));
    expect(volta.cells[1][1].alignmentMode, 2);
    expect(volta.retangulo.topLeft, const Offset(10, 20));
    final dobro = volta.transform((q) => q * 2, factor: 2);
    expect(dobro.widths.first, closeTo(volta.widths.first * 2, 0.01));
  });
}
