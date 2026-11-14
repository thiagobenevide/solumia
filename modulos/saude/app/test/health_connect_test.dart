import 'package:agent_saude/src/health_connect.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('soma o dia: sono no dia em que acorda, estágios, coração, peso e treinos', () {
    final pontos = [
      PontoSaude('SLEEP_SESSION', DateTime(2026, 11, 9, 23), DateTime(2026, 11, 10, 7), 0),
      PontoSaude('SLEEP_DEEP', DateTime(2026, 11, 10, 1), DateTime(2026, 11, 10, 2, 30), 0),
      PontoSaude('SLEEP_REM', DateTime(2026, 11, 10, 4), DateTime(2026, 11, 10, 5), 0),
      PontoSaude('SLEEP_AWAKE', DateTime(2026, 11, 10, 3), DateTime(2026, 11, 10, 3, 20), 0),
      PontoSaude('HEART_RATE', DateTime(2026, 11, 10, 9), DateTime(2026, 11, 10, 9), 60),
      PontoSaude('HEART_RATE', DateTime(2026, 11, 10, 18), DateTime(2026, 11, 10, 18), 100),
      PontoSaude('RESTING_HEART_RATE', DateTime(2026, 11, 10, 8), DateTime(2026, 11, 10, 8), 55),
      PontoSaude('BLOOD_OXYGEN', DateTime(2026, 11, 10, 3), DateTime(2026, 11, 10, 3), .96),
      PontoSaude('WEIGHT', DateTime(2026, 11, 10, 7), DateTime(2026, 11, 10, 7), 81),
      PontoSaude('WEIGHT', DateTime(2026, 11, 10, 20), DateTime(2026, 11, 10, 20), 80.5),
      PontoSaude('DISTANCE_DELTA', DateTime(2026, 11, 10, 18), DateTime(2026, 11, 10, 19), 3200),
      PontoSaude('WATER', DateTime(2026, 11, 10, 12), DateTime(2026, 11, 10, 12), .5),
      PontoSaude('WORKOUT', DateTime(2026, 11, 10, 18), DateTime(2026, 11, 10, 18, 40), 0,
          atividade: 'WALKING', calorias: 180, metros: 3200),
      PontoSaude('HEART_RATE', DateTime(2026, 11, 8, 9), DateTime(2026, 11, 8, 9), 70), // fora do período
    ];
    final dias = agregarDias(pontos, {'2026-11-10': 9500}, DateTime(2026, 11, 9), DateTime(2026, 11, 10));
    expect(dias, hasLength(1));
    final d = dias.single;
    expect(d['data'], '2026-11-10');
    expect(d['sono_min'], 460); // 8 h na cama − 20 min acordado
    expect((d['sono_profundo_min'], d['sono_rem_min'], d['sono_acordado_min']), (90, 60, 20));
    expect((d['sono_inicio'], d['sono_fim']), ('23:00', '07:00'));
    expect((d['fc_media'], d['fc_min'], d['fc_max'], d['fc_repouso']), (80.0, 60.0, 100.0, 55.0));
    expect(d['spo2'], 96.0);
    expect(d['peso_kg'], 80.5);
    expect((d['passos'], d['distancia_km'], d['agua_ml'], d['minutos_ativos']), (9500, 3.2, 500, 40));
    expect(d['exercicios'], [
      {'tipo': 'caminhada', 'inicio': '18:00', 'minutos': 40, 'calorias': 180, 'distancia_km': 3.2},
    ]);
  });
}
