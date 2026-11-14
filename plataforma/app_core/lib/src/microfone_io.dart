import 'dart:io';

Future<String> caminhoGravacao() async =>
    '${Directory.systemTemp.path}/fala_${DateTime.now().millisecondsSinceEpoch}.wav';

Future<List<int>> lerEApagar(String caminho) async {
  final arquivo = File(caminho);
  final bytes = await arquivo.readAsBytes();
  await arquivo.delete();
  return bytes;
}
