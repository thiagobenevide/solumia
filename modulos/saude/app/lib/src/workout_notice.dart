import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'session.dart';

/// Workout with the app in the background (Spotify in front, screen off) on Android: pinned notification
/// with the stage and the rest countdown (the system counts on its own) and an exact alarm at the end of the
/// rest, which rings and vibrates even with the app stopped. With the guide open in front, the alarm goes away
/// (the screen itself does the notifying).
class WorkoutNotice {
  static const _pinned = 9101;
  static const _alarm = 9102;
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _pronto = false;
  static String _last = '';

  /// The tests turn it off (there is no notification plugin).
  @visibleForTesting
  static bool on = true;

  static bool get supported => on && !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> _start() async {
    if (_pronto) return;
    _pronto = true;
    tzdata.initializeTimeZones();
    await _plugin.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
    );
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    if (await android?.canScheduleExactNotifications() == false) await android?.requestExactAlarmsPermission();
  }

  /// [background]: the guide is not in front, so the end of the rest becomes an alarm.
  static Future<void> refresh(WorkoutSession s, {required bool background}) async {
    if (!supported) return;
    if (s.status != 'andamento') return clear();
    final remaining = s.restRemaining();
    final resting = remaining != null && remaining > 0 && !s.paused;
    final end = resting ? DateTime.now().add(Duration(seconds: remaining)) : null;
    final e = s.current;
    final stage = s.paused
        ? 'Treino pausado'
        : resting
        ? 'Descanso · próximo: ${e?.name ?? '—'}'
        : e == null
        ? 'Tudo feito: conclua o treino'
        : '${e.name} · série ${e.series.length + 1} de ${e.planned}';
    final fc = s.currentHr();
    final text = fc == null ? stage : '$stage · ♥ $fc';
    // does not redo the notification on every sync if nothing changed
    final key = '$text|${end == null ? '' : end.millisecondsSinceEpoch ~/ 5000}|$background';
    if (key == _last) return;
    _last = key;
    try {
      await _start();
      await _plugin.show(
        id: _pinned,
        title: 'Treino · ${s.setsDone}/${s.plannedSets} séries',
        body: text,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'treino',
            'Treino em andamento',
            channelDescription: 'Etapa e contagem do descanso',
            importance: Importance.low,
            priority: Priority.low,
            ongoing: true,
            autoCancel: false,
            onlyAlertOnce: true,
            showWhen: end != null,
            usesChronometer: end != null,
            chronometerCountDown: end != null,
            when: end?.millisecondsSinceEpoch,
          ),
        ),
      );
      await _plugin.cancel(id: _alarm);
      if (end != null && background) {
        await _plugin.zonedSchedule(
          id: _alarm,
          title: 'Descanso acabou',
          body: e == null ? 'Bora!' : 'Agora: ${e.name} · série ${e.series.length + 1} de ${e.planned}',
          scheduledDate: tz.TZDateTime.from(end.toUtc(), tz.UTC),
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              'treino_descanso',
              'Fim do descanso',
              channelDescription: 'Toca e vibra quando o descanso acaba',
              importance: Importance.max,
              priority: Priority.max,
              category: AndroidNotificationCategory.alarm,
              enableVibration: true,
              audioAttributesUsage: AudioAttributesUsage.alarm,
            ),
          ),
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        );
      }
    } catch (error) {
      // no permission or plugin unavailable: the guide keeps working with the screen open
      debugPrint('Aviso do treino: $error');
    }
  }

  static Future<void> clear() async {
    if (!supported || !_pronto) return;
    _last = '';
    await _plugin.cancel(id: _pinned);
    await _plugin.cancel(id: _alarm);
  }
}
