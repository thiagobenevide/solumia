import 'api.dart';
import 'armazem.dart';

/// Pedido que não chegou ao servidor (sem rede, VPS fora): vale guardar e tentar depois.
bool semConexao(Object e) => e is ApiErro && e.status == 0;

/// Operações feitas sem conexão, guardadas no [Armazem] e executadas em ordem quando o servidor
/// volta a responder. Cada uma é um mapa JSON com `op` e o que a operação precisar.
class FilaOffline {
  FilaOffline(this.armazem, {this.caminho = 'fila.json'});

  final Armazem armazem;
  final String caminho;
  Future<List<String>>? _processando;
  int _contador = 0;

  Future<List<Map<String, dynamic>>> itens() async => [
    for (final j in (await armazem.lerJson(caminho) as List? ?? const [])) Map<String, dynamic>.from(j as Map),
  ];

  Future<void> adicionar(Map<String, dynamic> op) async => armazem.gravarJson(caminho, [
    ...await itens(),
    {...op, '_uid': '${DateTime.now().microsecondsSinceEpoch}-${_contador++}'},
  ]);

  /// Executa em ordem. Sem conexão, para e guarda o resto para a próxima vez; erro do servidor
  /// (ex.: 404 de um arquivo já excluído) descarta a operação. Devolve os avisos e erros, para
  /// mostrar ao usuário. [executar] pode devolver um aviso (ex.: "salvo como cópia").
  Future<List<String>> processar(Future<String?> Function(Map<String, dynamic> op) executar) =>
      _processando ??= _processar(executar).whenComplete(() => _processando = null);

  Future<List<String>> _processar(Future<String?> Function(Map<String, dynamic> op) executar) async {
    final avisos = <String>[];
    while (true) {
      final fila = await itens();
      if (fila.isEmpty) break;
      final op = fila.first;
      try {
        final aviso = await executar(op);
        if (aviso != null) avisos.add(aviso);
      } catch (e) {
        if (semConexao(e)) break;
        avisos.add('${op['op']}: $e');
      }
      // Relê: outra operação pode ter entrado na fila enquanto esta rodava.
      await armazem.gravarJson(caminho, [
        for (final o in await itens())
          if (o['_uid'] != op['_uid']) o,
      ]);
    }
    return avisos;
  }
}
