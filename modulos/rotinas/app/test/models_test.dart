import 'package:agent_rotinas/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('tempo conta o cronômetro aberto e prazo vencido marca atraso', () {
    final received = DateTime(2026, 10, 28, 9);
    final t = Task.fromJson({
      'id': 'a',
      'titulo': 'A',
      'coluna': 'execucao',
      'tempo_total': 90,
      'rodando_desde': '2026-10-28T12:00:00+00:00',
      'prazo': '2026-10-27',
      'tags': ['x'],
    });
    final now = t.receivedAt.add(const Duration(seconds: 30));
    expect(t.timeAt(now), const Duration(minutes: 2));
    expect(t.overdueAt(received), isTrue);
    expect(t.column, BoardColumn.execucao);
    expect(formatDuration(const Duration(hours: 1, minutes: 5)), '1h05min');
    expect(formatDuration(const Duration(minutes: 3, seconds: 7), withSeconds: true), '03:07');
  });
}
