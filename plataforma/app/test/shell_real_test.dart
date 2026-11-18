import 'package:agent/main.dart';
import 'package:agent/shell.dart';
import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Módulo real sem o `iniciar` (notificações não existem no teste).
class _SemIniciar extends Modulo {
  const _SemIniciar(this.m);
  final Modulo m;
  @override
  String get id => m.id;
  @override
  String get nome => m.nome;
  @override
  String get descricao => m.descricao;
  @override
  IconData get icone => m.icone;
  @override
  bool get disponivel => m.disponivel;
  @override
  double? get larguraMaxima => m.larguraMaxima;
  @override
  bool get fundoVidro => m.fundoVidro;
  @override
  TemaCena get cena => m.cena;
  @override
  Widget construir(BuildContext context) => m.construir(context);
}

void main() {
  testWidgets('shell largo com os módulos reais monta sem exceção', (t) async {
    t.view.physicalSize = const Size(2000, 820);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final modulos = [for (final m in modulosDaSessao('x')) _SemIniciar(m)];
    await t.pumpWidget(MaterialApp(home: Shell(modulos: modulos, aoSair: () {}, api: ApiCliente('http://localhost'))));
    await t.pump(const Duration(seconds: 1));
    expect(t.takeException(), isNull);
  });

  for (final nome in ['Tab S9 FE deitado', 'notebook', 'Full HD']) {
    testWidgets('todos os módulos abrem sem estouro na área dividida no $nome', (t) async {
      t.view.physicalSize = _aparelhos[nome]!;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final modulos = [for (final m in modulosDaSessao('x')) _SemIniciar(m)];
      await t.pumpWidget(
        MaterialApp(home: Shell(modulos: modulos, aoSair: () {}, api: ApiCliente('http://localhost'))),
      );
      await t.pump(const Duration(seconds: 1));
      await t.tap(find.byTooltip('Dividir à direita'));
      await t.pump(const Duration(seconds: 1));
      expect(t.takeException(), isNull, reason: modulos.first.nome);
      // O painel da direita está em foco: cada módulo abre nele, ao lado do primeiro.
      for (final m in modulos.skip(1)) {
        final destino = find.descendant(of: find.byType(NavigationRail), matching: find.text(m.nome));
        await t.ensureVisible(destino);
        await t.tap(destino);
        await t.pump(const Duration(seconds: 1));
        expect(t.takeException(), isNull, reason: m.nome);
      }
    });
  }

  _cadaAparelho((nome, tamanho) {
    testWidgets('todos os módulos abrem sem estouro no $nome', (t) async {
      t.view.physicalSize = tamanho;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final modulos = [for (final m in modulosDaSessao('x')) _SemIniciar(m)];
      await t.pumpWidget(
        MaterialApp(home: Shell(modulos: modulos, aoSair: () {}, api: ApiCliente('http://localhost'))),
      );
      await t.pump(const Duration(seconds: 1));
      expect(t.takeException(), isNull, reason: modulos.first.nome);
      for (final m in modulos.skip(1)) {
        if (tamanho.width < 1200) {
          await t.tap(find.text('Mais'));
          await t.pump(const Duration(milliseconds: 500));
        }
        final destino = find.text(m.nome).last;
        await t.ensureVisible(destino);
        await t.tap(destino);
        await t.pump(const Duration(seconds: 1));
        expect(t.takeException(), isNull, reason: m.nome);
      }
    });
  });
}

/// Aparelhos de referência (dp): Galaxy S23 em pé e deitado, Tab S9 FE em pé e deitado, notebook,
/// Full HD e ultrawide.
const _aparelhos = {
  'S23': Size(360, 780),
  'S23 deitado': Size(780, 360),
  'Tab S9 FE': Size(800, 1280),
  'Tab S9 FE deitado': Size(1280, 800),
  'notebook': Size(1366, 768),
  'Full HD': Size(1920, 1080),
  'ultrawide': Size(3440, 1440),
};

void _cadaAparelho(void Function(String nome, Size tamanho) teste) => _aparelhos.forEach(teste);
