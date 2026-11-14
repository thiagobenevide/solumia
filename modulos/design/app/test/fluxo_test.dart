import 'package:agent_design/src/modelos.dart';
import 'package:agent_design/src/quadro/exportar.dart';
import 'package:agent_design/src/quadro/fluxo.dart';
import 'package:agent_design/src/quadro/pintura.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _fluxo = {
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
    final els = elementosDoFluxo(_fluxo, const Offset(1000, 500), 'f1');
    final nos = els.whereType<NoFluxo>().toList();
    final setas = els.whereType<Ligacao>().toList();
    expect(nos.map((n) => n.id), ['f1.i', 'f1.d', 'f1.c']);
    expect(nos.first.a, const Offset(1000 - 80 + 100, 500)); // canto do fluxo em (1000, 500)
    // a seta sai da base do início e chega no topo (ponta do losango) da decisão
    expect(setas.first.a.dy, closeTo(nos[0].retangulo.bottom, 0.01));
    expect(setas.first.b, nos[1].retangulo.topCenter);
    expect(setas.last.rotulo, 'Sim');
    // ida e volta pelo JSON
    final j = [for (final e in els) Elemento.fromJson(e.toJson())!];
    expect(j.whereType<NoFluxo>().map((n) => n.tipo), [TipoNo.inicio, TipoNo.decisao, TipoNo.circulo]);
    expect(fluxoDoQuadro(j, 'f1')['ligacoes'], [
      {'de': 'i', 'para': 'd', 'rotulo': ''},
      {'de': 'd', 'para': 'c', 'rotulo': 'Sim'},
    ]);
  });

  test('mover um bloco arrasta a seta; apagar o bloco leva a seta junto', () {
    final els = elementosDoFluxo(_fluxo, Offset.zero, 'f');
    final movido = [for (final e in els) e.id == 'f.c' ? e.transformar((q) => q + const Offset(400, 0)) : e];
    final seta = religar(movido).whereType<Ligacao>().last;
    final c = movido.whereType<NoFluxo>().last;
    expect(c.retangulo.inflate(0.01).contains(seta.b), isTrue);
    expect(religar(els.where((e) => e.id != 'f.d').toList()).whereType<Ligacao>(), isEmpty);
  });

  test('texto formatado: negrito, itálico, sublinhado e marcador', () {
    final t = textoFormatado('a **b** *c* __d__ ==e== f*', const TextStyle(), false);
    final partes = {for (final s in t.children!.cast<TextSpan>()) s.text!: s.style!};
    expect(partes['b']!.fontWeight, FontWeight.bold);
    expect(partes['c']!.fontStyle, FontStyle.italic);
    expect(partes['d']!.decoration, TextDecoration.underline);
    expect(partes['e']!.backgroundColor, isNotNull);
    expect(t.children!.cast<TextSpan>().map((s) => s.text).join(), 'a b c d e f*'); // * sem par fica
  });

  test('fluxo exporta em PNG e PDF', () async {
    final els = elementosDoFluxo(_fluxo, Offset.zero, 'f');
    expect((await png(els, Fundo.liso)).sublist(1, 4), 'PNG'.codeUnits);
    expect(String.fromCharCodes((await pdf(els, Fundo.liso)).sublist(0, 4)), '%PDF');
  });
}
