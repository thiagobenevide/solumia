import 'package:agent_design/src/models.dart';
import 'package:agent_design/src/board/export.dart';
import 'package:agent_design/src/board/flow.dart';
import 'package:agent_design/src/board/painting.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _stream = {
  'titulo': 'Crédito',
  'nos': [
    {'id': 'i', 'tipo': 'inicio', 'texto': 'Pedido', 'x': -80, 'y': 0, 'w': 160, 'h': 64},
    {'id': 'd', 'tipo': 'decisao', 'texto': 'Tem **crédito**?', 'x': -100, 'y': 150, 'w': 200, 'h': 120},
    {'id': 'c', 'tipo': 'circulo', 'texto': 'A', 'x': -40, 'y': 360, 'w': 80, 'h': 80},
  ],
  'ligacoes': [
    {'de': 'i', 'para': 'd', 'rotulo': ''},
    {'de': 'd', 'para': 'c', 'rotulo': 'Sim'},
  ],
};

void main() {
  test('fluxo do servidor vira blocos e setas presas às bordas', () {
    final els = flowElements(_stream, const Offset(1000, 500), 'f1');
    final nos = els.whereType<FlowNode>().toList();
    final arrows = els.whereType<Connector>().toList();
    expect(nos.map((n) => n.id), ['f1.i', 'f1.d', 'f1.c']);
    expect(nos.first.a, const Offset(1000 - 80 + 100, 500)); // flow corner at (1000, 500)
    // the arrow leaves the bottom of the start and arrives at the top (diamond tip) of the decision
    expect(arrows.first.a.dy, closeTo(nos[0].retangulo.bottom, 0.01));
    expect(arrows.first.b, nos[1].retangulo.topCenter);
    expect(arrows.last.label, 'Sim');
    // round trip through the JSON
    final j = [for (final e in els) Elemento.fromJson(e.toJson())!];
    expect(j.whereType<FlowNode>().map((n) => n.type), [NodeKind.inicio, NodeKind.decisao, NodeKind.circulo]);
    expect(boardFlow(j, 'f1')['ligacoes'], [
      {'de': 'i', 'para': 'd', 'rotulo': ''},
      {'de': 'd', 'para': 'c', 'rotulo': 'Sim'},
    ]);
  });

  test('mover um bloco arrasta a seta; apagar o bloco leva a seta junto', () {
    final els = flowElements(_stream, Offset.zero, 'f');
    final moved = [for (final e in els) e.id == 'f.c' ? e.transform((q) => q + const Offset(400, 0)) : e];
    final seta = reconnect(moved).whereType<Connector>().last;
    final c = moved.whereType<FlowNode>().last;
    expect(c.retangulo.inflate(0.01).contains(seta.b), isTrue);
    expect(reconnect(els.where((e) => e.id != 'f.d').toList()).whereType<Connector>(), isEmpty);
  });

  test('texto formatado: negrito, itálico, sublinhado e marcador', () {
    final t = formattedText('a **b** *c* __d__ ==e== f*', const TextStyle(), false);
    final parts = {for (final s in t.children!.cast<TextSpan>()) s.text!: s.style!};
    expect(parts['b']!.fontWeight, FontWeight.bold);
    expect(parts['c']!.fontStyle, FontStyle.italic);
    expect(parts['d']!.decoration, TextDecoration.underline);
    expect(parts['e']!.backgroundColor, isNotNull);
    expect(t.children!.cast<TextSpan>().map((s) => s.text).join(), 'a b c d e f*'); // * without a pair stays
  });

  test('fluxo exporta em PNG e PDF', () async {
    final els = flowElements(_stream, Offset.zero, 'f');
    expect((await png(els, Background.liso)).sublist(1, 4), 'PNG'.codeUnits);
    expect(String.fromCharCodes((await pdf(els, Background.liso)).sublist(0, 4)), '%PDF');
  });
}
