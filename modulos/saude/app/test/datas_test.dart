import 'package:agent_saude/src/datas.dart';
import 'package:agent_saude/src/modelos.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('semana começa na segunda e a grade do mês tem 42 dias', () {
    expect(inicioSemana(DateTime(2026, 10, 28)), DateTime(2026, 10, 26));
    expect(inicioSemana(DateTime(2026, 11, 1)), DateTime(2026, 10, 26));
    final grade = gradeMes(DateTime(2026, 11, 15));
    expect(grade.length, 42);
    expect(grade.first, DateTime(2026, 10, 26));
    expect(iso(grade.last), '2026-12-06');
  });

  test('resumo do item mostra carga sem casas desnecessárias', () {
    final item = ItemAgenda.fromJson({
      'id': 'a',
      'data': '2026-11-02',
      'exercicio_id': 'flexao',
      'ordem': 0,
      'series': 3,
      'repeticoes': '12',
      'carga_kg': 12.5,
    });
    expect(item.resumo, '3 × 12 · 12,5 kg');
    expect(diaLongo(item.data), 'segunda, 2 de novembro');
  });
}
