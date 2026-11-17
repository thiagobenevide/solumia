import 'package:agent_empreendimento/src/recording/phone_pro_panel.dart';
import 'package:agent_empreendimento/src/recording/receiver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _phone() => {
      'camera': {
        'id': '0',
        'manual': true,
        'kelvin': true,
        'point': true,
        'isoMin': 50,
        'isoMax': 3200,
        'exposureMinNs': 100000,
        'exposureMaxNs': 100000000,
        'evMin': -8,
        'evMax': 8,
        'evStep': 0.25,
        'focusMin': 10.0,
        'zoomMin': 0.6,
        'zoomMax': 10.0,
        'eis': true,
      },
      'lens': '0',
      'lenses': [
        {'id': '0', 'label': 'Traseira 0'},
        {'id': '2', 'label': 'Traseira 2'},
      ],
      'fps': 60,
      'settings': {'manualExposure': false, 'iso': 100, 'awb': 'auto', 'kelvin': 5000, 'manualFocus': false},
      'live': {'iso': 400, 'exposureNs': 8333333},
    };

Future<Receiver> _pump(WidgetTester tester) async {
  final receiver = Receiver(port: 5790, previewPort: 5791, studioPort: null, announce: false);
  receiver.phone = _phone();
  await tester.binding.setSurfaceSize(const Size(500, 3000));
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: ListenableBuilder(
        listenable: receiver,
        builder: (context, _) => SingleChildScrollView(child: PhoneProPanel(receiver: receiver)),
      ),
    ),
  ));
  return receiver;
}

void main() {
  testWidgets('shows every Pro section from the phone state', (tester) async {
    await _pump(tester);
    for (final title in ['Lente', 'Exposição', 'Foco', 'Balanço de branco', 'Zoom e imagem']) {
      expect(find.text(title), findsOneWidget);
    }
    expect(find.text('Agora: ISO 400 · 1/120'), findsOneWidget);
    expect(find.text('Traseira 2'), findsOneWidget);
    expect(find.text('Toque no vídeo para escolher onde focar'), findsOneWidget);
  });

  testWidgets('manual exposure shows ISO and shutter; Kelvin shows the temperature', (tester) async {
    final receiver = await _pump(tester);
    await tester.tap(find.text('Manual (ISO e obturador)'));
    await tester.pump();
    expect(receiver.phone!['settings']['manualExposure'], true);
    expect(find.text('ISO'), findsOneWidget);
    expect(find.text('Obturador'), findsOneWidget);
    await tester.tap(find.text('Manual (K)'));
    await tester.pump();
    expect(receiver.phone!['settings']['awb'], 'manual');
    expect(find.text('5000 K'), findsOneWidget);
    await tester.tap(find.text('Manual (distância)'));
    await tester.pump();
    expect(receiver.phone!['settings']['manualFocus'], true);
    expect(find.text('longe'), findsOneWidget);
  });

  testWidgets('hides when the phone does not report a state', (tester) async {
    final receiver = await _pump(tester);
    receiver.phone = null;
    receiver.notifyListeners();
    await tester.pump();
    expect(find.text('Lente'), findsNothing);
  });
}
