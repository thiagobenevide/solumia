import 'package:http/http.dart' as http;

// No navegador o `record` grava num blob e devolve a URL dele no stop.
Future<String> caminhoGravacao() async => '';

Future<List<int>> lerEApagar(String caminho) => http.readBytes(Uri.parse(caminho));
