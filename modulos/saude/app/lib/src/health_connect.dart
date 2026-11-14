import 'package:flutter/foundation.dart';
import 'package:health/health.dart';

import 'datas.dart';

/// Um registro do Health Connect sem os tipos do plugin (a soma por dia fica testável).
class PontoSaude {
  const PontoSaude(this.tipo, this.inicio, this.fim, this.valor, {this.atividade, this.calorias, this.metros});

  /// Nome do [HealthDataType] (ex.: `HEART_RATE`, `SLEEP_DEEP`).
  final String tipo;
  final DateTime inicio;
  final DateTime fim;
  final double valor;

  /// Só nos treinos (`WORKOUT`).
  final String? atividade;
  final double? calorias;
  final double? metros;

  double get minutos => fim.difference(inicio).inSeconds / 60;
}

const _atividades = {
  'WALKING': 'caminhada', 'RUNNING': 'corrida', 'RUNNING_TREADMILL': 'esteira', 'BIKING': 'bicicleta',
  'BIKING_STATIONARY': 'bicicleta ergométrica', 'SWIMMING_POOL': 'natação', 'SWIMMING_OPEN_WATER': 'natação',
  'STRENGTH_TRAINING': 'musculação', 'WEIGHTLIFTING': 'musculação', 'BOXING': 'boxe', 'YOGA': 'ioga',
  'HIKING': 'trilha', 'ELLIPTICAL': 'elíptico', 'HIGH_INTENSITY_INTERVAL_TRAINING': 'HIIT',
  'CALISTHENICS': 'calistenia', 'MARTIAL_ARTS': 'artes marciais', 'STAIR_CLIMBING': 'escada',
  'OTHER': 'outro',
};

String _hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

double _r(double v, [int casas = 1]) => double.parse(v.toStringAsFixed(casas));

/// Soma os pontos por dia local, no formato de `PUT /api/saude/relogio/dias`. O sono conta no dia em
/// que termina; [passos] vem à parte (o agregado do Health Connect já tira a contagem dupla
/// celular + relógio). Só entram os dias de [de] a [ate].
List<Map<String, dynamic>> agregarDias(List<PontoSaude> pontos, Map<String, int> passos, DateTime de, DateTime ate) {
  final porDia = <String, List<PontoSaude>>{};
  for (final p in pontos) {
    final sono = p.tipo.startsWith('SLEEP_');
    porDia.putIfAbsent(iso(sono ? p.fim : p.inicio), () => []).add(p);
  }
  final dias = <Map<String, dynamic>>[];
  for (var d = dia(de); !d.isAfter(ate); d = somarDias(d, 1)) {
    final chave = iso(d);
    final lista = porDia[chave] ?? const <PontoSaude>[];
    List<PontoSaude> doTipo(String tipo) => [for (final p in lista) if (p.tipo == tipo) p];
    double soma(String tipo) => doTipo(tipo).fold(0, (s, p) => s + p.valor);
    double? media(String tipo) {
      final l = doTipo(tipo);
      return l.isEmpty ? null : _r(l.fold<double>(0, (s, p) => s + p.valor) / l.length);
    }

    double? ultimo(String tipo) {
      final l = doTipo(tipo)..sort((a, b) => a.inicio.compareTo(b.inicio));
      return l.isEmpty ? null : _r(l.last.valor);
    }

    double minutos(List<String> tipos) =>
        lista.where((p) => tipos.contains(p.tipo)).fold(0, (s, p) => s + p.minutos);

    final r = <String, dynamic>{'data': chave};
    void por(String campo, num? v) {
      if (v != null && v > 0) r[campo] = v;
    }

    por('passos', passos[chave]);
    por('distancia_km', _r(soma('DISTANCE_DELTA') / 1000, 2));
    por('calorias_ativas', soma('ACTIVE_ENERGY_BURNED').round());
    por('calorias_total', soma('TOTAL_CALORIES_BURNED').round());
    por('andares', soma('FLIGHTS_CLIMBED').round());
    por('agua_ml', (soma('WATER') * 1000).round());

    final fc = doTipo('HEART_RATE');
    if (fc.isNotEmpty) {
      por('fc_media', media('HEART_RATE'));
      por('fc_min', fc.map((p) => p.valor).reduce((a, b) => a < b ? a : b));
      por('fc_max', fc.map((p) => p.valor).reduce((a, b) => a > b ? a : b));
    }
    por('fc_repouso', media('RESTING_HEART_RATE'));
    por('hrv_ms', media('HEART_RATE_VARIABILITY_RMSSD'));
    // algumas versões dão a fração (0,96) em vez do percentual
    final spo2 = [for (final p in doTipo('BLOOD_OXYGEN')) p.valor <= 1 ? p.valor * 100 : p.valor];
    if (spo2.isNotEmpty) por('spo2', _r(spo2.reduce((a, b) => a + b) / spo2.length));
    por('respiracao', media('RESPIRATORY_RATE'));
    por('pressao_sistolica', media('BLOOD_PRESSURE_SYSTOLIC'));
    por('pressao_diastolica', media('BLOOD_PRESSURE_DIASTOLIC'));
    por('peso_kg', ultimo('WEIGHT'));
    por('gordura_pct', ultimo('BODY_FAT_PERCENTAGE'));
    por('massa_magra_kg', ultimo('LEAN_BODY_MASS'));

    // sono: a sessão dá o horário; os estágios dão a composição. Dormido = sessão − acordado.
    final acordado = minutos(['SLEEP_AWAKE', 'SLEEP_AWAKE_IN_BED', 'SLEEP_OUT_OF_BED']);
    final sessoes = doTipo('SLEEP_SESSION')..sort((a, b) => b.minutos.compareTo(a.minutos));
    final estagios = minutos(['SLEEP_DEEP', 'SLEEP_LIGHT', 'SLEEP_REM', 'SLEEP_ASLEEP']);
    final dormido = sessoes.isNotEmpty
        ? sessoes.fold<double>(0, (s, p) => s + p.minutos) - acordado
        : estagios;
    por('sono_min', dormido.round());
    por('sono_profundo_min', minutos(['SLEEP_DEEP']).round());
    por('sono_leve_min', minutos(['SLEEP_LIGHT']).round());
    por('sono_rem_min', minutos(['SLEEP_REM']).round());
    por('sono_acordado_min', acordado.round());
    if (sessoes.isNotEmpty) {
      r['sono_inicio'] = _hm(sessoes.first.inicio);
      r['sono_fim'] = _hm(sessoes.first.fim);
    }

    final treinos = doTipo('WORKOUT')..sort((a, b) => a.inicio.compareTo(b.inicio));
    if (treinos.isNotEmpty) {
      // o Samsung Health não manda "tempo ativo" ao Health Connect: usa a soma dos treinos
      por('minutos_ativos', treinos.fold<double>(0, (s, p) => s + p.minutos).round());
      r['exercicios'] = [
        for (final t in treinos)
          {
            'tipo': _atividades[t.atividade] ?? (t.atividade ?? 'exercício').toLowerCase().replaceAll('_', ' '),
            'inicio': _hm(t.inicio),
            'minutos': t.minutos.round(),
            if ((t.calorias ?? 0) > 0) 'calorias': t.calorias!.round(),
            if ((t.metros ?? 0) > 0) 'distancia_km': _r(t.metros! / 1000, 2),
          },
      ];
    }
    if (r.length > 1) dias.add(r);
  }
  return dias;
}

/// Lê o Health Connect do Android, onde o Samsung Health publica os dados do Galaxy Watch.
class LeitorHealthConnect {
  final _health = Health();
  bool _configurado = false;

  static const tipos = [
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

  static List<HealthDataAccess> get _leitura => [for (final _ in tipos) HealthDataAccess.READ];

  /// Só existe no Android (celular e tablet); no PC os dados chegam pelo backend.
  static bool get disponivel => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> _configurar() async {
    if (_configurado) return;
    await _health.configure();
    _configurado = true;
  }

  /// Motivo para não dar para ler (Health Connect ausente/desatualizado), ou null.
  Future<String?> problema() async {
    await _configurar();
    final s = await _health.getHealthConnectSdkStatus();
    return switch (s) {
      HealthConnectSdkStatus.sdkAvailable => null,
      HealthConnectSdkStatus.sdkUnavailableProviderUpdateRequired => 'Atualize o Health Connect na Play Store.',
      _ => 'Health Connect não instalado. No Samsung Health, ative a sincronização com o Health Connect.',
    };
  }

  Future<void> instalar() => _health.installHealthConnect();

  Future<bool> autorizado() async {
    await _configurar();
    return await _health.hasPermissions(tipos, permissions: _leitura) ?? false;
  }

  /// Pede leitura de todos os tipos, do histórico anterior aos 30 dias e em segundo plano.
  Future<bool> autorizar() async {
    await _configurar();
    final ok = await _health.requestAuthorization(tipos, permissions: _leitura);
    if (ok && await _health.isHealthDataHistoryAvailable() && !await _health.isHealthDataHistoryAuthorized()) {
      await _health.requestHealthDataHistoryAuthorization();
    }
    if (ok) await autorizarSegundoPlano();
    return ok;
  }

  /// Leitura sem o app aberto (a tarefa do WorkManager); Android 14+ pede à parte.
  Future<bool> segundoPlanoAutorizado() async {
    await _configurar();
    return await _health.isHealthDataInBackgroundAvailable() && await _health.isHealthDataInBackgroundAuthorized();
  }

  Future<bool> autorizarSegundoPlano() async {
    await _configurar();
    if (!await _health.isHealthDataInBackgroundAvailable()) return false;
    if (await _health.isHealthDataInBackgroundAuthorized()) return true;
    return _health.requestHealthDataInBackgroundAuthorization();
  }

  /// Dias de [de] a [ate] somados (o dia anterior também é lido, para o sono que começa na véspera).
  Future<List<Map<String, dynamic>>> ler(DateTime de, DateTime ate) async {
    await _configurar();
    final inicio = somarDias(dia(de), -1);
    final fim = somarDias(dia(ate), 1);
    final pontos = <PontoSaude>[];
    for (final p in await _health.getHealthDataFromTypes(
      types: tipos.where((t) => t != HealthDataType.STEPS).toList(),
      startTime: inicio,
      endTime: fim,
    )) {
      final v = p.value;
      final local = (p.dateFrom.toLocal(), p.dateTo.toLocal());
      if (v is WorkoutHealthValue) {
        pontos.add(PontoSaude(
          p.type.name, local.$1, local.$2, 0,
          atividade: v.workoutActivityType.name,
          calorias: v.totalEnergyBurned?.toDouble(),
          metros: v.totalDistance?.toDouble(),
        ));
      } else if (v is NumericHealthValue) {
        pontos.add(PontoSaude(p.type.name, local.$1, local.$2, v.numericValue.toDouble()));
      }
    }
    final passos = <String, int>{};
    for (var d = dia(de); !d.isAfter(ate); d = somarDias(d, 1)) {
      final n = await _health.getTotalStepsInInterval(d, somarDias(d, 1));
      if (n != null && n > 0) passos[iso(d)] = n;
    }
    return agregarDias(pontos, passos, de, ate);
  }

  /// Frequência cardíaca do relógio entre [de] e [ate] (a sessão de treino), ou null sem amostras.
  /// O Samsung Health leva alguns minutos para passar as amostras ao Health Connect.
  Future<Map<String, dynamic>?> frequencia(DateTime de, DateTime ate) async {
    await _configurar();
    final pontos = await _health.getHealthDataFromTypes(
      types: const [HealthDataType.HEART_RATE],
      startTime: de,
      endTime: ate,
    );
    return resumirFrequencia([
      for (final p in pontos)
        if (p.value is NumericHealthValue) (p.value as NumericHealthValue).numericValue.toDouble(),
    ]);
  }
}

/// Média, máxima e mínima no formato de `frequencia` da sessão de treino.
Map<String, dynamic>? resumirFrequencia(List<double> bpm) {
  final v = [for (final b in bpm) if (b > 20 && b < 250) b];
  if (v.isEmpty) return null;
  return {
    'media': _r(v.reduce((a, b) => a + b) / v.length, 0),
    'maxima': v.reduce((a, b) => a > b ? a : b),
    'minima': v.reduce((a, b) => a < b ? a : b),
    'amostras': v.length,
  };
}
