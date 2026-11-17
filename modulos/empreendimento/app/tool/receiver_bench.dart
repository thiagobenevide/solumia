// Live bench (not part of the test suite): runs the real Receiver on spare ports so a simulated
// phone can be pushed through it. `flutter test tool/receiver_bench.dart` with BENCH_SECONDS set.
import 'dart:io';

import 'package:agent_empreendimento/src/recording/receiver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('receiver bench', () async {
    final seconds = int.parse(Platform.environment['BENCH_SECONDS'] ?? '30');
    final receiver = Receiver(port: 5700, previewPort: 5701, studioPort: null, announce: false);
    await receiver.listen();
    expect(receiver.error, isNull);
    var commanded = false;
    for (var i = 0; i < seconds; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (Platform.environment['REMOTE'] == '1' && receiver.remote && !commanded) {
        commanded = true;
        receiver.setPhone({'manualExposure': true, 'iso': 800});
        receiver.setPhone({'awb': 'manual', 'kelvin': 3200});
        receiver.setPhone({'pointX': 0.25, 'pointY': 0.75});
        receiver.setLens('2');
      }
      if (receiver.phone != null) {
        // ignore: avoid_print
        print('PHONE lens=${receiver.phone!['lens']} settings=${receiver.phone!['settings']}');
      }
      // ignore: avoid_print
      print('t=$i connected=${receiver.connected} ${receiver.header?.description ?? ''} '
          '${receiver.mbps.toStringAsFixed(0)} Mb/s rss=${ProcessInfo.currentRss ~/ (1 << 20)} MB');
    }
    await receiver.stopListening();
    await Future<void>.delayed(const Duration(seconds: 12));
    for (final take in receiver.takes) {
      // ignore: avoid_print
      print('TAKE ${take.file} ${take.description}');
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
