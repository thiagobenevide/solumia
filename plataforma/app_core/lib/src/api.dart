import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:http/http.dart' as http;

/// Falha de uma chamada à API. [status] 0 quando nem chegou ao servidor.
class ApiErro implements Exception {
  ApiErro(this.status, this.mensagem);

  final int status;
  final String mensagem;

  @override
  String toString() => status == 0 ? mensagem : 'HTTP $status: $mensagem';
}

/// Cliente JSON mínimo. Cada módulo cria o seu, apontando para o serviço que o atende.
class ApiCliente {
  ApiCliente(String base, {http.Client? cliente, this.cabecalhos = const {}})
    : base = Uri.parse(base.endsWith('/') ? base : '$base/'),
      _http = cliente ?? http.Client();

  final Uri base;
  final http.Client _http;

  /// Chamado quando um pedido autenticado volta 401 (sessão expirada ou revogada): o app volta
  /// para a tela de login.
  static VoidCallback? aoNaoAutorizado;

  /// Chamado quando o backend pede um código do Authenticator recente (`totp_required`, módulo
  /// Código): o app pergunta o código e confirma; `true` = confirmado, o pedido é repetido.
  static Future<bool> Function()? aoPedirCodigo;

  /// Enviados em todo pedido (ex.: `Authorization` do backend da plataforma).
  final Map<String, String> cabecalhos;

  Map<String, String> get _json => {...cabecalhos, 'Content-Type': 'application/json'};

  /// URL absoluta de um caminho do serviço (aceita query string).
  Uri url(String caminho) => base.resolve(caminho.startsWith('/') ? caminho.substring(1) : caminho);

  Future<dynamic> get(String caminho) => _enviar(() => _http.get(url(caminho), headers: cabecalhos));

  Future<dynamic> put(String caminho, Object corpo) =>
      _enviar(() => _http.put(url(caminho), headers: _json, body: jsonEncode(corpo)));

  Future<dynamic> patch(String caminho, Object corpo) =>
      _enviar(() => _http.patch(url(caminho), headers: _json, body: jsonEncode(corpo)));

  /// GET que devolve bytes (ex.: um PDF ou uma imagem).
  Future<Uint8List> getBytes(String caminho) async =>
      (await _resposta(() => _http.get(url(caminho), headers: cabecalhos))).bodyBytes;

  /// GET em pedaços (cabeçalho `Range`): arquivo grande não depende de uma conexão longa sem
  /// quedas, e cada pedaço tenta de novo sozinho. [gravar] recebe os pedaços em ordem, a partir do
  /// byte [inicio] (para continuar um download interrompido).
  Future<void> getEmPartes(
    String caminho,
    FutureOr<void> Function(Uint8List pedaco) gravar, {
    int inicio = 0,
    void Function(int recebidos, int? total)? progresso,
    bool Function()? cancelado,
    int tamanhoPedaco = 2 << 20,
  }) async {
    final u = url(caminho);
    int? total;
    while (total == null || inicio < total) {
      if (cancelado?.call() ?? false) throw ApiErro(0, 'Cancelado.');
      final faixa = 'bytes=$inicio-${inicio + tamanhoPedaco - 1}';
      final http.Response r;
      try {
        r = await _comTentativas(() => _resposta(() => _http.get(u, headers: {...cabecalhos, 'Range': faixa})));
      } on ApiErro catch (e) {
        if (e.status == 416) return; // pediu além do fim: já estava completo
        rethrow;
      }
      final corpo = r.bodyBytes;
      if (r.statusCode == 200) {
        // Servidor sem suporte a Range: veio o arquivo inteiro (só vale se começou do zero).
        if (inicio > 0) throw ApiErro(0, 'O servidor não aceita continuar downloads');
        await gravar(corpo);
        progresso?.call(corpo.length, corpo.length);
        return;
      }
      total = int.tryParse(r.headers['content-range']?.split('/').last ?? '');
      await gravar(corpo);
      inicio += corpo.length;
      progresso?.call(inicio, total);
      if (corpo.isEmpty || (total == null && corpo.length < tamanhoPedaco)) return;
    }
  }

  /// Bytes de [getEmPartes] juntos na memória (PDF, imagem).
  Future<Uint8List> getBytesEmPartes(
    String caminho, {
    void Function(int recebidos, int? total)? progresso,
    bool Function()? cancelado,
  }) async {
    final b = BytesBuilder(copy: false);
    await getEmPartes(caminho, b.add, progresso: progresso, cancelado: cancelado);
    return b.takeBytes();
  }

  /// Sem conexão ou erro do servidor (5xx): tenta de novo com espera crescente.
  static Future<T> _comTentativas<T>(Future<T> Function() pedido, {int tentativas = 4}) async {
    for (var i = 1; ; i++) {
      try {
        return await pedido();
      } on ApiErro catch (e) {
        if (i >= tentativas || !(e.status == 0 || e.status >= 500)) rethrow;
        await Future<void>.delayed(Duration(seconds: 1 << i));
      }
    }
  }

  Future<dynamic> delete(String caminho) => _enviar(() => _http.delete(url(caminho), headers: cabecalhos));

  Future<dynamic> post(String caminho, [Object? corpo]) => _enviar(
    () => _http.post(
      url(caminho),
      headers: _json,
      body: jsonEncode(corpo ?? const {}),
    ),
  );

  /// POST com corpo JSON que devolve bytes (ex.: uma imagem gerada pelo servidor).
  Future<Uint8List> postBytes(String caminho, Object corpo) async => (await _resposta(
    () => _http.post(url(caminho), headers: _json, body: jsonEncode(corpo)),
  )).bodyBytes;

  /// Envia um arquivo como multipart (campo [campo], mais os [campos] de formulário) e devolve o
  /// JSON da resposta. [metodo] `PUT` para substituir um arquivo existente.
  Future<dynamic> enviarArquivo(
    String caminho,
    String campo,
    String nome,
    List<int> bytes, {
    Map<String, String> campos = const {},
    String metodo = 'POST',
  }) async {
    final r = await _resposta(() async {
      final pedido = http.MultipartRequest(metodo, url(caminho))
        ..headers.addAll(cabecalhos)
        ..fields.addAll(campos)
        ..files.add(http.MultipartFile.fromBytes(campo, bytes, filename: nome));
      return http.Response.fromStream(await _http.send(pedido));
    });
    return r.body.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
  }

  /// Pedido cuja resposta é NDJSON (um objeto por linha, conforme o servidor produz): [corpo] vai
  /// como JSON ou, com [arquivo] (campo, nome, bytes), como multipart junto dos [campos].
  /// Linhas vazias (só para manter a conexão viva) são puladas.
  Stream<Map<String, dynamic>> eventos(
    String caminho, {
    Object? corpo,
    (String, String, List<int>)? arquivo,
    Map<String, String> campos = const {},
  }) async* {
    final http.BaseRequest pedido;
    if (arquivo != null) {
      pedido = http.MultipartRequest('POST', url(caminho))
        ..headers.addAll(cabecalhos)
        ..fields.addAll(campos)
        ..files.add(http.MultipartFile.fromBytes(arquivo.$1, arquivo.$3, filename: arquivo.$2));
    } else {
      pedido = http.Request('POST', url(caminho))
        ..headers.addAll(_json)
        ..body = jsonEncode(corpo ?? const {});
    }
    final http.StreamedResponse r;
    try {
      r = await _http.send(pedido);
    } catch (e) {
      throw ApiErro(0, 'Sem conexão com ${base.origin}');
    }
    if (r.statusCode >= 400) {
      final resposta = await http.Response.fromStream(r);
      if (r.statusCode == 401 && cabecalhos.containsKey('Authorization')) aoNaoAutorizado?.call();
      throw ApiErro(r.statusCode, _detalhe(resposta));
    }
    await for (final linha in r.stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (linha.trim().isEmpty) continue;
      yield (jsonDecode(linha) as Map).cast<String, dynamic>();
    }
  }

  Future<dynamic> _enviar(Future<http.Response> Function() chamada) async {
    final r = await _resposta(chamada);
    return r.body.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
  }

  Future<http.Response> _resposta(Future<http.Response> Function() chamada) async {
    http.Response r;
    try {
      r = await chamada();
      if (r.statusCode == 403 && _tipo(r) == 'totp_required' && (await aoPedirCodigo?.call() ?? false)) {
        r = await chamada();
      }
    } on ApiErro {
      rethrow;
    } catch (e) {
      throw ApiErro(0, 'Sem conexão com ${base.origin}');
    }
    if (r.statusCode == 401 && cabecalhos.containsKey('Authorization')) aoNaoAutorizado?.call();
    if (r.statusCode >= 400) throw ApiErro(r.statusCode, _detalhe(r));
    return r;
  }

  static String? _tipo(http.Response r) {
    try {
      final corpo = jsonDecode(utf8.decode(r.bodyBytes));
      return corpo is Map && corpo['error'] is Map ? '${corpo['error']['type']}' : null;
    } on FormatException {
      return null;
    }
  }

  static String _detalhe(http.Response r) {
    try {
      final corpo = jsonDecode(utf8.decode(r.bodyBytes));
      if (corpo is Map && corpo['detail'] != null) return '${corpo['detail']}';
      // backend da plataforma: {"error": {"message": ...}}
      if (corpo is Map && corpo['error'] is Map) return '${corpo['error']['message']}';
    } on FormatException {
      if (r.body.isNotEmpty) return utf8.decode(r.bodyBytes);
    }
    return r.reasonPhrase ?? 'erro';
  }
}
