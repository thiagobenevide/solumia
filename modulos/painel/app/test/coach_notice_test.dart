import 'package:flutter_test/flutter_test.dart';
import 'package:agent_painel/src/coach_notice.dart';
import 'package:agent_painel/src/models.dart';

void main() {
  test('overdue task gets its own title and a clear action', () {
    final n = CoachNotice.from(const Alert('critico', '“Praticar exercícios físicos” vence atrasada e está fora da agenda.'));
    expect(n.title, 'Prazo vencido: Praticar exercícios físicos');
    expect(n.line, 'Praticar exercícios físicos — prazo vencido');
    expect(n.critical, isTrue);
  });

  test('block, goal and unknown texts', () {
    final block = CoachNotice.from(const Alert('aviso', '“Inglês” (14:00–15:00) passou e não foi marcado como feito.'));
    expect(block.body, contains('das 14:00 às 15:00'));
    final goal = CoachNotice.from(const Alert('aviso', 'Meta “Leitura”: 2 de 5 páginas esperados.'));
    expect(goal.title, 'Meta em atraso: Leitura');
    final other = CoachNotice.from(const Alert('aviso', 'Algo novo.'));
    expect(other.body, 'Algo novo.');
  });

  test('summary of overdue tasks counts them', () {
    final s = CoachSummary([
      CoachNotice.from(const Alert('critico', '“A” vence atrasada e está fora da agenda.')),
      CoachNotice.from(const Alert('critico', '“B” vence atrasada e está fora da agenda.')),
    ]);
    expect(s.title, '2 tarefas com prazo vencido');
    expect(s.lines, ['• A — prazo vencido', '• B — prazo vencido']);
  });
}
