import 'dart:typed_data';

import '../modelos.dart';

/// Programa que abre um arquivo: [comando] recebe o caminho como último argumento.
typedef Editor = ({String nome, List<String> comando});

List<Editor> editoresPara(Arquivo a) => const [];

Future<void> abrirFora(Editor e, Arquivo a, Uint8List bytes, Future<void> Function(Uint8List) aoSalvar) async {}
