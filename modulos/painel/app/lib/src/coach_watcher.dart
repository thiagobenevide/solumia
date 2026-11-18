import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'coach_notice.dart';
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
  static const _summaryId = 900000;
  Timer? _timer;

  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.windows);

  Future<void> start() async {
    if (!supported || _timer != null) return;
    await _plugin.initialize(
      settings: InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        linux: LinuxInitializationSettings(
          defaultActionName: 'Abrir',
          defaultIcon: AssetsLinuxIcon('assets/logo.png'),
        ),
        windows: WindowsInitializationSettings(
          appName: 'Solumia',
          appUserModelId: 'com.thiagobenevide.solumia',
          guid: '6f1c2b7e-3d4a-4e8b-9a51-2c7d0e9f4b63',
        ),
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
      final fresh = <CoachNotice>[];
      for (final a in d.alerts) {
        if (_seen.add(a.text)) fresh.add(CoachNotice.from(a));
      }
      if (fresh.length == 1) await _showOne(fresh.first);
      if (fresh.length > 1) await _showSummary(CoachSummary(fresh));
    } on ApiErro {
      // server down: tries again on the next cycle
    } on Exception catch (e) {
      debugPrint('Vigia do cobrador: $e');
    }
  }

  Future<void> _showOne(CoachNotice n) {
    return _plugin.show(
      id: _id++,
      title: n.title,
      body: n.body,
      notificationDetails: _details(n.critical, null),
    );
  }

  /// One notification for the whole batch, always on the same id: a newer batch replaces it
  /// instead of piling up on the screen.
  Future<void> _showSummary(CoachSummary s) {
    final lines = s.lines;
    return _plugin.show(
      id: _summaryId,
      title: s.title,
      body: lines.join('\n'),
      notificationDetails: _details(
        s.critical,
        InboxStyleInformation(lines, contentTitle: s.title, summaryText: 'Cobrador'),
      ),
    );
  }

  NotificationDetails _details(bool critical, StyleInformation? style) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        'cobrador',
        'Cobrador',
        channelDescription: 'Alertas de disciplina e agenda',
        importance: critical ? Importance.high : Importance.defaultImportance,
        priority: critical ? Priority.high : Priority.defaultPriority,
        styleInformation: style,
        subText: 'Cobrador',
      ),
      linux: LinuxNotificationDetails(
        urgency: critical ? LinuxNotificationUrgency.critical : LinuxNotificationUrgency.normal,
      ),
      windows: const WindowsNotificationDetails(),
    );
  }

  void parar() {
    _timer?.cancel();
    _timer = null;
  }
}
