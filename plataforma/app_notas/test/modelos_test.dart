import 'package:agent_notas/agent_notas.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Nota lê relações e link sem nota', () {
    final n = Nota.fromJson({
      'id': 'a1',
      'titulo': 'Meta',
      'tipo': 'meta',
      'propriedades': {'status': 'aberta', 'prazo': '2026-01-10'},
      'saidas': [
        {'tipo': 'parte_de', 'titulo': 'Projeto X', 'id': null},
      ],
      'entradas': [
        {'tipo': 'cobra', 'id': 'b2', 'titulo': 'Cobrança 1', 'trecho': 'cobra: [[Meta]]'},
      ],
    });
    expect(n.saidas.single.id, isNull);
    expect(n.entradas.single.tipo, 'cobra');
    expect(linkRe.firstMatch('ver [[Meta|apelido]]')!.group(1), 'Meta');
  });
}
