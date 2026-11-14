import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'panel_api.dart';

/// Checks discipline from time to time and shows each new alert as a system notification
/// (Linux and Android), with the app on any module or minimized. With the app closed, the server push
/// (ntfy) does the nagging. Each alert text notifies once per day.
class CoachWatcher {
  CoachWatcher(this.api, {this.intervalo = const Duration(minutes: 5)});

  final PanelApi api;
  final Duration intervalo;
  final _plugin = FlutterLocalNotificationsPlugin();
  final _seen = <String>{};
  String _day = '';
  int _id = 0;
  Timer? _timer;

  static bool get supported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.linux || defaultTargetPlatform == TargetPlatform.android);

  Future<void> start() async {
    if (!supported || _timer != null) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        linux: LinuxInitializationSettings(defaultActionName: 'Abrir'),
      ),
    );
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    _timer = Timer.periodic(intervalo, (_) => check());
    // first look right after opening, without competing with the screens loading
    Timer(const Duration(seconds: 20), check);
  }

  Future<void> check() async {
    try {
      final d = await api.discipline();
      final today = DateTime.now().toIso8601String().substring(0, 10);
      if (today != _day) {
        _day = today;
        _seen.clear();
      }
      for (final a in d.alerts) {
        if (!_seen.add(a.text)) continue;
        final critical = a.level == 'critico';
        await _plugin.show(
          id: _id++,
          title: critical ? 'Cobrador: entrega em risco' : 'Cobrador',
          body: a.text,
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              'cobrador',
              'Cobrador',
              channelDescription: 'Alertas de disciplina e agenda',
              importance: critical ? Importance.high : Importance.defaultImportance,
              priority: critical ? Priority.high : Priority.defaultPriority,
            ),
            linux: LinuxNotificationDetails(
              urgency: critical ? LinuxNotificationUrgency.critical : LinuxNotificationUrgency.normal,
            ),
          ),
        );
      }
    } on ApiErro {
      // server down: tries again on the next cycle
    } on Exception catch (e) {
      debugPrint('Vigia do cobrador: $e');
    }
  }

  void parar() {
    _timer?.cancel();
    _timer = null;
  }
}
