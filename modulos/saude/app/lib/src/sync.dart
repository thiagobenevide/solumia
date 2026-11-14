import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import 'health_api.dart';
import 'dates.dart';
import 'health_connect.dart';

const _task = 'saude.relogio.sincronizar';
const _uniqueName = 'saude-relogio';

/// Reads the last [days] of Health Connect in blocks of 30 and sends them to the backend; returns how many days
/// were sent. Does not request permission: the caller ensures it is there (or the screen asks first).
Future<int> syncWatch(
  HealthApi api,
  HealthConnectReader reader, {
  required int days,
  void Function(DateTime de, DateTime ate)? onRead,
}) async {
  var ate = today();
  final limit = addDays(ate, -(days - 1));
  var sent = 0;
  while (!ate.isBefore(limit)) {
    final start = addDays(ate, -29);
    final de = start.isBefore(limit) ? limit : start;
    onRead?.call(de, ate);
    final batch = await reader.read(de, ate);
    if (batch.isNotEmpty) await api.sendWatchDays(batch);
    sent += batch.length;
    ate = addDays(de, -1);
  }
  return sent;
}

/// Runs in the WorkManager background process (no screen): same address and token as the session that
/// scheduled it. An expired token gives 401 and the task just fails; the next login schedules it again with the new one.
@pragma('vm:entry-point')
void dispatchHealthTasks() {
  Workmanager().executeTask((task, data) async {
    if (task != _task || data == null) return true;
    final reader = HealthConnectReader();
    try {
      if (await reader.problem() != null || !await reader.authorized() || !await reader.backgroundAuthorized()) {
        return true; // nothing to do until the person authorizes on the screen
      }
      await syncWatch(HealthApi(data['url'] as String, token: data['token'] as String), reader, days: 3);
      return true;
    } catch (e) {
      debugPrint('Saúde: sincronização em segundo plano falhou: $e');
      return false; // WorkManager tries again later
    }
  });
}

bool _started = false;

/// Schedules the Health Connect reading every hour, with internet, and does one now (on opening the app).
/// Only on Android; on the PC and the web it does nothing.
Future<void> scheduleSync(String url, String token, HealthApi api) async {
  if (!HealthConnectReader.disponivel || token.isEmpty) return;
  try {
    if (!_started) {
      await Workmanager().initialize(dispatchHealthTasks);
      _started = true;
    }
    await Workmanager().registerPeriodicTask(
      _uniqueName,
      _task,
      frequency: const Duration(hours: 1),
      inputData: {'url': url, 'token': token},
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
    final reader = HealthConnectReader();
    if (await reader.problem() == null && await reader.authorized()) {
      await syncWatch(api, reader, days: 3);
    }
  } catch (e) {
    debugPrint('Saúde: não deu para agendar a sincronização: $e');
  }
}
