import 'dart:math';

import 'package:agent_eletronica/src/electronics_api.dart';
import 'package:agent_eletronica/src/models.dart';
import 'package:agent_eletronica/src/simulation.dart';
import 'package:agent_eletronica/src/screens/chart.dart';
import 'package:agent_eletronica/src/screens/simulation_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resultado do ponto de operação e das curvas', () {
    final op = SimulationResult.fromJson({
      'analise': 'op',
      'tensoes': {'VOUT': 2.5, 'VIN': 5},
      'correntes': {'V1': -0.00025},
    });
    expect((op as OperatingPoint).voltages['VIN'], 5.0);

    final ac = SimulationResult.fromJson({
      'analise': 'ac',
      'eixo': {'nome': 'frequência', 'unidade': 'Hz', 'valores': [10, 100, 1000]},
      'series': {'v(VOUT)': [1, 0.7, 0.1], 'i(V1)': [0.001, 0.001, 0.001]},
      'fases': {'v(VOUT)': [0, -45, -84]},
    }) as SimCurves;
    expect([ac.analysis, ac.axis.last, ac.phases['v(VOUT)']![1]], [Analysis.ac, 1000.0, -45.0]);
    expect([SimCurves.unitOf('v(VOUT)'), SimCurves.unitOf('I(V1)')], ['V', 'A']);
  });

  test('passo redondo de 1, 2 ou 5', () {
    expect(roundStep(10), 2);
    expect(roundStep(0.003), closeTo(0.0005, 1e-12));
    expect(roundStep(37), 5);
    expect(roundStep(40), 10);
  });

  testWidgets('osciloscópio desenha e mostra valores ao passar o mouse (linear e log)', (t) async {
    for (final logX in [false, true]) {
      final x = [for (var i = 1; i <= 200; i++) logX ? pow(10, i / 40).toDouble() : i * 1e-5];
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 300,
            child: CurvesChart(
              x: x,
              series: {'v(OUT)': [for (final v in x) sin(v * 1000)], 'v(IN)': [for (final _ in x) 1.0]},
              colors: {'v(OUT)': signalColors[0], 'v(IN)': signalColors[1]},
              unitX: logX ? 'Hz' : 's',
              unitY: 'V',
              logX: logX,
            ),
          ),
        ),
      ));
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(300, 150));
      await mouse.moveTo(const Offset(320, 150));
      await t.pump();
      expect(t.takeException(), isNull);
      await mouse.removePointer();
    }
  });

  testWidgets('tela de simulação abre sem servidor e mostra o erro', (t) async {
    final project = Project.fromJson({
      'id': 'p',
      'titulo': 'Divisor',
      'versao': 1,
      'folhas': [{'id': 'f1', 'nome': 'Folha 1'}],
    });
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: SimulationScreen(api: ElectronicsApi('http://localhost:1'), project: project, save: () async {}),
    ));
    await t.pump();
    expect(find.text('Simular'), findsOneWidget);
    await t.tap(find.text('Transiente'));
    await t.pump();
    expect(find.text('Duração'), findsOneWidget);
    await t.tap(find.text('Netlist SPICE'));
    await t.pumpAndSettle();
    expect(find.textContaining('Não gerou a netlist'), findsOneWidget);
  });
}
