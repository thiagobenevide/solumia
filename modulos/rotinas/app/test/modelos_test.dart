import 'package:agent_rotinas/src/modelos.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('tempo conta o cronômetro aberto e prazo vencido marca atraso', () {
    final recebida = DateTime(2026, 10, 28, 9);
    final t = Tarefa.fromJson({
      'id': 'a',
      'titulo': 'A',
      'coluna': 'execucao',
      'tempo_total': 90,
      'rodando_desde': '2026-10-28T12:00:00+00:00',
      'prazo': '2026-10-27',
      'tags': ['x'],
    });
    final agora = t.recebidaEm.add(const Duration(seconds: 30));
    expect(t.tempoEm(agora), const Duration(minutes: 2));
    expect(t.atrasadaEm(recebida), isTrue);
    expect(t.coluna, Coluna.execucao);
    expect(formatarDuracao(const Duration(hours: 1, minutes: 5)), '1h05min');
    expect(formatarDuracao(const Duration(minutes: 3, seconds: 7), segundos: true), '03:07');
  });
}
