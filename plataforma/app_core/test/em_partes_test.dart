import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final dados = Uint8List.fromList(List.generate(10, (i) => i));

  /// Servidor com Range que falha (503) no primeiro pedido do segundo pedaço.
  ApiCliente servidor() {
    var falhou = false;
    return ApiCliente(
      'http://x',
      cliente: MockClient((r) async {
        final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(r.headers['Range']!)!;
        final ini = int.parse(m[1]!);
        if (ini >= dados.length) return http.Response('', 416);
        if (ini == 4 && !falhou) {
          falhou = true;
          return http.Response('', 503);
        }
        final fim = (int.parse(m[2]!) + 1).clamp(0, dados.length);
        return http.Response.bytes(dados.sublist(ini, fim), 206,
            headers: {'content-range': 'bytes $ini-${fim - 1}/${dados.length}'});
      }),
    );
  }

  test('junta os pedaços e tenta de novo o que falhou', () async {
    final partes = <int>[];
    await servidor().getEmPartes('f', partes.addAll, tamanhoPedaco: 4);
    expect(partes, dados);
  });

  test('continua de onde parou', () async {
    final partes = <int>[];
    await servidor().getEmPartes('f', partes.addAll, inicio: 6, tamanhoPedaco: 4);
    expect(partes, dados.sublist(6));
  });
}
