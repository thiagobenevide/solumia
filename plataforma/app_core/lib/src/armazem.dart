import 'dart:convert';
import 'dart:typed_data';

import 'armazem_memoria.dart' if (dart.library.io) 'armazem_io.dart';

/// Pasta do aparelho para o modo offline: arquivos em disco no Android/desktop; na web e nos
/// testes (sem o plugin), só em memória. Caminhos relativos com `/`.
abstract class Armazem {
  static final _abertos = <String, Future<Armazem>>{};

  /// Um por [nome] no app inteiro (vários clientes da mesma API dividem a mesma pasta).
  static Future<Armazem> abrir(String nome) => _abertos[nome] ??= abrirArmazem(nome);

  Future<Uint8List?> ler(String caminho);

  Future<void> gravar(String caminho, List<int> bytes);

  /// Apaga um arquivo ou uma pasta inteira.
  Future<void> apagar(String caminho);

  /// Nomes dentro de [pasta] (arquivos e subpastas), sem o caminho.
  Future<List<String>> listar(String pasta);

  Future<dynamic> lerJson(String caminho) async {
    final b = await ler(caminho);
    return b == null ? null : jsonDecode(utf8.decode(b));
  }

  Future<void> gravarJson(String caminho, Object? valor) => gravar(caminho, utf8.encode(jsonEncode(valor)));
}

class ArmazemMemoria extends Armazem {
  final _dados = <String, Uint8List>{};

  @override
  Future<Uint8List?> ler(String caminho) async => _dados[caminho];

  @override
  Future<void> gravar(String caminho, List<int> bytes) async => _dados[caminho] = Uint8List.fromList(bytes);

  @override
  Future<void> apagar(String caminho) async => _dados.removeWhere((k, _) => k == caminho || k.startsWith('$caminho/'));

  @override
  Future<List<String>> listar(String pasta) async {
    final prefixo = pasta.isEmpty ? '' : '$pasta/';
    return {
      for (final k in _dados.keys)
        if (k.startsWith(prefixo)) k.substring(prefixo.length).split('/').first,
    }.toList();
  }
}
