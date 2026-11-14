import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;

import 'armazem.dart';

/// Imagem da rede guardada no aparelho: abrir a tela de novo não baixa outra vez (cada ida à VPS,
/// na Alemanha, custa ~200 ms). Só para URL versionada (ex.: `?v=<atualizado>`): o conteúdo de uma
/// mesma URL nunca muda. No máximo [_simultaneos] downloads por vez, para uma grade de centenas de
/// miniaturas não entupir o servidor nem atrasar as outras chamadas do app.
class ImagemRede extends ImageProvider<ImagemRede> {
  const ImagemRede(this.url, {this.headers = const {}});

  final String url;
  final Map<String, String> headers;

  static const _simultaneos = 6;
  static int _ativos = 0;
  static final _fila = Queue<Completer<void>>();
  static final http.Client _http = http.Client();

  @override
  Future<ImagemRede> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(ImagemRede key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _codec(decode), scale: 1, debugLabel: url);

  Future<ui.Codec> _codec(ImageDecoderCallback decode) async =>
      decode(await ui.ImmutableBuffer.fromUint8List(await _bytes()));

  Future<Uint8List> _bytes() async {
    final armazem = await Armazem.abrir('imagens');
    final nome = _nome(url);
    final guardado = await armazem.ler(nome);
    if (guardado != null && guardado.isNotEmpty) return guardado;
    final bytes = await _baixar();
    unawaited(armazem.gravar(nome, bytes).catchError((_) {}));
    return bytes;
  }

  Future<Uint8List> _baixar() async {
    if (_ativos >= _simultaneos) {
      final vez = Completer<void>();
      _fila.add(vez);
      await vez.future;
    }
    _ativos++;
    try {
      final r = await _http.get(Uri.parse(url), headers: headers);
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) {
        throw NetworkImageLoadException(statusCode: r.statusCode, uri: Uri.parse(url));
      }
      return r.bodyBytes;
    } finally {
      _ativos--;
      if (_fila.isNotEmpty) _fila.removeFirst().complete();
    }
  }

  /// Nome de arquivo estável para a URL (dois FNV-1a de 32 bits, sem pacote de hash).
  static String _nome(String url) {
    var a = 0x811c9dc5, b = 0x050c5d1f;
    for (final c in utf8.encode(url)) {
      a = ((a ^ c) * 0x01000193) & 0xffffffff;
      b = ((b ^ c) * 0x01000193) & 0xffffffff;
      b = ((b << 5) | (b >> 27)) & 0xffffffff;
    }
    return '${a.toRadixString(16).padLeft(8, '0')}${b.toRadixString(16).padLeft(8, '0')}';
  }

  @override
  bool operator ==(Object other) => other is ImagemRede && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
