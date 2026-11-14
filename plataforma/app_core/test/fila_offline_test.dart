import 'package:agent_core/agent_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sem conexão para e guarda; erro do servidor descarta', () async {
    final fila = FilaOffline(ArmazemMemoria());
    for (final n in [1, 2, 3]) {
      await fila.adicionar({'op': 'x', 'n': n});
    }
    final feitas = <int>[];
    var online = false;
    Future<String?> executar(Map<String, dynamic> op) async {
      if (op['n'] == 2) throw ApiErro(404, 'sumiu');
      if (op['n'] == 3 && !online) throw ApiErro(0, 'sem rede');
      feitas.add(op['n'] as int);
      return null;
    }

    expect(await fila.processar(executar), hasLength(1)); // o 404
    expect([for (final o in await fila.itens()) o['n']], [3]);
    online = true;
    await fila.processar(executar);
    expect(feitas, [1, 3]);
    expect(await fila.itens(), isEmpty);
  });
}
