import 'package:flutter/foundation.dart';
import 'package:health/health.dart';

import 'dates.dart';

/// A Health Connect record without the plugin types (the per-day sum stays testable).
class HealthPoint {
  const HealthPoint(this.type, this.start, this.end, this.value, {this.activity, this.calories, this.metros});

  /// Name of the [HealthDataType] (e.g. `HEART_RATE`, `SLEEP_DEEP`).
  final String type;
  final DateTime start;
  final DateTime end;
  final double value;

  /// Only on workouts (`WORKOUT`).
  final String? activity;
  final double? calories;
  final double? metros;

  double get minutes => end.difference(start).inSeconds / 60;
}

const _activities = {
  'WALKING': 'caminhada', 'RUNNING': 'corrida', 'RUNNING_TREADMILL': 'esteira', 'BIKING': 'bicicleta',
  'BIKING_STATIONARY': 'bicicleta ergométrica', 'SWIMMING_POOL': 'natação', 'SWIMMING_OPEN_WATER': 'natação',
  'STRENGTH_TRAINING': 'musculação', 'WEIGHTLIFTING': 'musculação', 'BOXING': 'boxe', 'YOGA': 'ioga',
  'HIKING': 'trilha', 'ELLIPTICAL': 'elíptico', 'HIGH_INTENSITY_INTERVAL_TRAINING': 'HIIT',
  'CALISTHENICS': 'calistenia', 'MARTIAL_ARTS': 'artes marciais', 'STAIR_CLIMBING': 'escada',
  'OTHER': 'outro',
};

String _hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

double _r(double v, [int decimals = 1]) => double.parse(v.toStringAsFixed(decimals));

/// Sums the points per local day, in the format of `PUT /api/saude/relogio/dias`. Sleep counts on the day
/// it ends; [steps] comes separately (the Health Connect aggregate already removes the phone + watch
/// double counting). Only the days from [from] to [to] go in.
List<Map<String, dynamic>> aggregateDays(List<HealthPoint> points, Map<String, int> steps, DateTime de, DateTime ate) {
  final byDay = <String, List<HealthPoint>>{};
  for (final p in points) {
    final sleep = p.type.startsWith('SLEEP_');
    byDay.putIfAbsent(iso(sleep ? p.end : p.start), () => []).add(p);
  }
  final days = <Map<String, dynamic>>[];
  for (var d = day(de); !d.isAfter(ate); d = addDays(d, 1)) {
    final key = iso(d);
    final items = byDay[key] ?? const <HealthPoint>[];
    List<HealthPoint> ofType(String type) => [for (final p in items) if (p.type == type) p];
    double sum(String type) => ofType(type).fold(0, (s, p) => s + p.value);
    double? media(String type) {
      final l = ofType(type);
      return l.isEmpty ? null : _r(l.fold<double>(0, (s, p) => s + p.value) / l.length);
    }

    double? last(String type) {
      final l = ofType(type)..sort((a, b) => a.start.compareTo(b.start));
      return l.isEmpty ? null : _r(l.last.value);
    }

    double minutes(List<String> types) =>
        items.where((p) => types.contains(p.type)).fold(0, (s, p) => s + p.minutes);

    final r = <String, dynamic>{'data': key};
    void by(String field, num? v) {
      if (v != null && v > 0) r[field] = v;
    }

    by('passos', steps[key]);
    by('distancia_km', _r(sum('DISTANCE_DELTA') / 1000, 2));
    by('calorias_ativas', sum('ACTIVE_ENERGY_BURNED').round());
    by('calorias_total', sum('TOTAL_CALORIES_BURNED').round());
    by('andares', sum('FLIGHTS_CLIMBED').round());
    by('agua_ml', (sum('WATER') * 1000).round());

    final fc = ofType('HEART_RATE');
    if (fc.isNotEmpty) {
      by('fc_media', media('HEART_RATE'));
      by('fc_min', fc.map((p) => p.value).reduce((a, b) => a < b ? a : b));
      by('fc_max', fc.map((p) => p.value).reduce((a, b) => a > b ? a : b));
    }
    by('fc_repouso', media('RESTING_HEART_RATE'));
    by('hrv_ms', media('HEART_RATE_VARIABILITY_RMSSD'));
    // some versions give the fraction (0.96) instead of the percentage
    final spo2 = [for (final p in ofType('BLOOD_OXYGEN')) p.value <= 1 ? p.value * 100 : p.value];
    if (spo2.isNotEmpty) by('spo2', _r(spo2.reduce((a, b) => a + b) / spo2.length));
    by('respiracao', media('RESPIRATORY_RATE'));
    by('pressao_sistolica', media('BLOOD_PRESSURE_SYSTOLIC'));
    by('pressao_diastolica', media('BLOOD_PRESSURE_DIASTOLIC'));
    by('peso_kg', last('WEIGHT'));
    by('gordura_pct', last('BODY_FAT_PERCENTAGE'));
    by('massa_magra_kg', last('LEAN_BODY_MASS'));

    // sleep: the session gives the times; the stages give the composition. Slept = session − awake.
    final awake = minutes(['SLEEP_AWAKE', 'SLEEP_AWAKE_IN_BED', 'SLEEP_OUT_OF_BED']);
    final sessions = ofType('SLEEP_SESSION')..sort((a, b) => b.minutes.compareTo(a.minutes));
    final stages = minutes(['SLEEP_DEEP', 'SLEEP_LIGHT', 'SLEEP_REM', 'SLEEP_ASLEEP']);
    final slept = sessions.isNotEmpty
        ? sessions.fold<double>(0, (s, p) => s + p.minutes) - awake
        : stages;
    by('sono_min', slept.round());
    by('sono_profundo_min', minutes(['SLEEP_DEEP']).round());
    by('sono_leve_min', minutes(['SLEEP_LIGHT']).round());
    by('sono_rem_min', minutes(['SLEEP_REM']).round());
    by('sono_acordado_min', awake.round());
    if (sessions.isNotEmpty) {
      r['sono_inicio'] = _hm(sessions.first.start);
      r['sono_fim'] = _hm(sessions.first.end);
    }

    final workouts = ofType('WORKOUT')..sort((a, b) => a.start.compareTo(b.start));
    if (workouts.isNotEmpty) {
      // Samsung Health does not send "active time" to Health Connect: uses the sum of the workouts
      by('minutos_ativos', workouts.fold<double>(0, (s, p) => s + p.minutes).round());
      r['exercicios'] = [
        for (final t in workouts)
          {
            'tipo': _activities[t.activity] ?? (t.activity ?? 'exercício').toLowerCase().replaceAll('_', ' '),
            'inicio': _hm(t.start),
            'minutos': t.minutes.round(),
            if ((t.calories ?? 0) > 0) 'calorias': t.calories!.round(),
            if ((t.metros ?? 0) > 0) 'distancia_km': _r(t.metros! / 1000, 2),
          },
      ];
    }
    if (r.length > 1) days.add(r);
  }
  return days;
}

/// Reads Android's Health Connect, where Samsung Health publishes the Galaxy Watch data.
class HealthConnectReader {
  final _health = Health();
  bool _configured = false;

  static const types = [
    HealthDataType.STEPS,
    HealthDataType.DISTANCE_DELTA,
    HealthDataType.ACTIVE_ENERGY_BURNED,
    HealthDataType.TOTAL_CALORIES_BURNED,
    HealthDataType.FLIGHTS_CLIMBED,
    HealthDataType.WATER,
    HealthDataType.HEART_RATE,
    HealthDataType.RESTING_HEART_RATE,
    HealthDataType.HEART_RATE_VARIABILITY_RMSSD,
    HealthDataType.BLOOD_OXYGEN,
    HealthDataType.RESPIRATORY_RATE,
    HealthDataType.BLOOD_PRESSURE_SYSTOLIC,
    HealthDataType.BLOOD_PRESSURE_DIASTOLIC,
    HealthDataType.WEIGHT,
    HealthDataType.BODY_FAT_PERCENTAGE,
    HealthDataType.LEAN_BODY_MASS,
    HealthDataType.SLEEP_SESSION,
    HealthDataType.SLEEP_DEEP,
    HealthDataType.SLEEP_LIGHT,
    HealthDataType.SLEEP_REM,
    HealthDataType.SLEEP_ASLEEP,
    HealthDataType.SLEEP_AWAKE,
    HealthDataType.SLEEP_AWAKE_IN_BED,
    HealthDataType.SLEEP_OUT_OF_BED,
    HealthDataType.WORKOUT,
  ];

  static List<HealthDataAccess> get _reading => [for (final _ in types) HealthDataAccess.READ];

  /// Only exists on Android (phone and tablet); on the PC the data arrives through the backend.
  static bool get disponivel => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> _configure() async {
    if (_configured) return;
    await _health.configure();
    _configured = true;
  }

  /// Why reading is not possible (Health Connect missing/outdated), or null.
  Future<String?> problem() async {
    await _configure();
    final s = await _health.getHealthConnectSdkStatus();
    return switch (s) {
      HealthConnectSdkStatus.sdkAvailable => null,
      HealthConnectSdkStatus.sdkUnavailableProviderUpdateRequired => 'Atualize o Health Connect na Play Store.',
      _ => 'Health Connect não instalado. No Samsung Health, ative a sincronização com o Health Connect.',
    };
  }

  Future<void> install() => _health.installHealthConnect();

  Future<bool> authorized() async {
    await _configure();
    return await _health.hasPermissions(types, permissions: _reading) ?? false;
  }

  /// Requests reading of every type, of the history older than 30 days and in the background.
  Future<bool> authorize() async {
    await _configure();
    final ok = await _health.requestAuthorization(types, permissions: _reading);
    if (ok && await _health.isHealthDataHistoryAvailable() && !await _health.isHealthDataHistoryAuthorized()) {
      await _health.requestHealthDataHistoryAuthorization();
    }
    if (ok) await authorizeBackground();
    return ok;
  }

  /// Reading without the app open (the WorkManager task); Android 14+ asks separately.
  Future<bool> backgroundAuthorized() async {
    await _configure();
    return await _health.isHealthDataInBackgroundAvailable() && await _health.isHealthDataInBackgroundAuthorized();
  }

  Future<bool> authorizeBackground() async {
    await _configure();
    if (!await _health.isHealthDataInBackgroundAvailable()) return false;
    if (await _health.isHealthDataInBackgroundAuthorized()) return true;
    return _health.requestHealthDataInBackgroundAuthorization();
  }

  /// Days from [from] to [to] summed (the previous day is also read, for sleep starting the night before).
  Future<List<Map<String, dynamic>>> read(DateTime de, DateTime ate) async {
    await _configure();
    final start = addDays(day(de), -1);
    final end = addDays(day(ate), 1);
    final points = <HealthPoint>[];
    for (final p in await _health.getHealthDataFromTypes(
      types: types.where((t) => t != HealthDataType.STEPS).toList(),
      startTime: start,
      endTime: end,
    )) {
      final v = p.value;
      final local = (p.dateFrom.toLocal(), p.dateTo.toLocal());
      if (v is WorkoutHealthValue) {
        points.add(HealthPoint(
          p.type.name, local.$1, local.$2, 0,
          activity: v.workoutActivityType.name,
          calories: v.totalEnergyBurned?.toDouble(),
          metros: v.totalDistance?.toDouble(),
        ));
      } else if (v is NumericHealthValue) {
        points.add(HealthPoint(p.type.name, local.$1, local.$2, v.numericValue.toDouble()));
      }
    }
    final steps = <String, int>{};
    for (var d = day(de); !d.isAfter(ate); d = addDays(d, 1)) {
      final n = await _health.getTotalStepsInInterval(d, addDays(d, 1));
      if (n != null && n > 0) steps[iso(d)] = n;
    }
    return aggregateDays(points, steps, de, ate);
  }

  /// Watch heart rate between [from] and [to] (the workout session), or null without samples.
  /// Samsung Health takes a few minutes to pass the samples to Health Connect.
  Future<Map<String, dynamic>?> frequency(DateTime de, DateTime ate) async {
    await _configure();
    final points = await _health.getHealthDataFromTypes(
      types: const [HealthDataType.HEART_RATE],
      startTime: de,
      endTime: ate,
    );
    return summarizeHeartRate([
      for (final p in points)
        if (p.value is NumericHealthValue) (p.value as NumericHealthValue).numericValue.toDouble(),
    ]);
  }
}

/// Average, max and min in the format of the workout session `frequencia`.
Map<String, dynamic>? summarizeHeartRate(List<double> bpm) {
  final v = [for (final b in bpm) if (b > 20 && b < 250) b];
  if (v.isEmpty) return null;
  return {
    'media': _r(v.reduce((a, b) => a + b) / v.length, 0),
    'maxima': v.reduce((a, b) => a > b ? a : b),
    'minima': v.reduce((a, b) => a < b ? a : b),
    'amostras': v.length,
  };
}
