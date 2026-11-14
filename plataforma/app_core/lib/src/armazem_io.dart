import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'armazem.dart';

Future<Armazem> abrirArmazem(String nome) async {
  try {
    final base = await getApplicationSupportDirectory();
    return ArmazemPasta(Directory('${base.path}/offline/$nome'));
  } catch (_) {
    return ArmazemMemoria();
  }
}

class ArmazemPasta extends Armazem {
  ArmazemPasta(this.raiz);

  final Directory raiz;

  File _arquivo(String caminho) => File('${raiz.path}/$caminho');

  @override
  Future<Uint8List?> ler(String caminho) async {
    final f = _arquivo(caminho);
    return await f.exists() ? f.readAsBytes() : null;
  }

  /// Grava num temporário e renomeia: o app fechar no meio não deixa arquivo pela metade.
  @override
  Future<void> gravar(String caminho, List<int> bytes) async {
    final f = _arquivo(caminho);
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
  }

  @override
  Future<void> apagar(String caminho) async {
    final f = _arquivo(caminho);
    if (await FileSystemEntity.isDirectory(f.path)) {
      await Directory(f.path).delete(recursive: true);
    } else if (await f.exists()) {
      await f.delete();
    }
  }

  @override
  Future<List<String>> listar(String pasta) async {
    final d = Directory(pasta.isEmpty ? raiz.path : '${raiz.path}/$pasta');
    if (!await d.exists()) return [];
    return [
      await for (final e in d.list())
        if (!e.path.endsWith('.tmp')) e.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
    ];
  }
}
