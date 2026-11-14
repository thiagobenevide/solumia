// Bridge to the Python core: starts the process, reads {porta, token} from the first line of standard
// output and talks to the local API. The token only exists in this process's memory.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class CoreError implements Exception {
  CoreError(this.message, [this.status]);
  final String message;
  final int? status;
  @override
  String toString() => message;
}

class Core {
  Core._(this._process, this._port, this._token);

  final Process _process;
  final int _port;
  final String _token;
  final _client = http.Client();
  final List<String> stderr = [];

  static String? findExecutable() {
    final env = Platform.environment['SOLUMIA_CORE'];
    if (env != null && env.isNotEmpty) return env;
    final name = Platform.isWindows ? 'solumia-configurador.exe' : 'solumia-configurador';
    final bin = Platform.isWindows ? 'Scripts' : 'bin';
    // Installed: next to the interface executable. Development: configurador/core/.venv.
    final candidates = <String>[
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}nucleo${Platform.pathSeparator}$name',
    ];
    var dir = Directory.current;
    for (var i = 0; i < 6; i++) {
      for (final base in ['core', 'configurador${Platform.pathSeparator}core']) {
        candidates.add([dir.path, base, '.venv', bin, name].join(Platform.pathSeparator));
      }
      dir = dir.parent;
    }
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  static Future<Core> start() async {
    final exe = findExecutable();
    if (exe == null) {
      throw CoreError('Núcleo do configurador não encontrado. Rode "uv sync" em configurador/core '
          'ou defina SOLUMIA_CORE com o caminho do executável.');
    }
    final p = await Process.start(exe, ['servir', '--sair-com-stdin']);
    final errors = <String>[];
    p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      errors.add(l);
      if (errors.length > 200) errors.removeAt(0);
    });
    final String line;
    try {
      line = await p.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 30));
    } on Object {
      p.kill();
      throw CoreError('O núcleo não iniciou: ${errors.take(10).join('\n')}');
    }
    final payload = jsonDecode(line) as Map<String, dynamic>;
    if (payload['erro'] != null) {
      p.kill();
      throw CoreError(payload['erro'] as String);
    }
    final n = Core._(p, payload['porta'] as int, payload['token'] as String);
    n.stderr.addAll(errors);
    return n;
  }

  void shutdown() {
    _client.close();
    _process.kill();
  }

  Uri _uri(String route, [Map<String, String>? query]) =>
      Uri(scheme: 'http', host: '127.0.0.1', port: _port, path: route, queryParameters: query);

  Map<String, String> get _headers =>
      {'Authorization': 'Bearer $_token', 'Content-Type': 'application/json'};

  Future<dynamic> _handle(http.Response r) async {
    final body = r.body.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode >= 400) {
      final detail = body is Map ? body['detail'] : body;
      throw CoreError(_text(detail), r.statusCode);
    }
    return body;
  }

  static String _text(dynamic d) {
    if (d is String) return d;
    if (d is List) return d.map((e) => e is Map ? '${e['loc']?.last}: ${e['msg']}' : '$e').join('\n');
    if (d is Map && d['erros'] is Map) {
      return (d['erros'] as Map).entries.map((e) => '${e.key}: ${(e.value as List).join(', ')}').join('\n');
    }
    return '$d';
  }

  Future<dynamic> get(String route, [Map<String, String>? query]) async =>
      _handle(await _client.get(_uri(route, query), headers: _headers));

  Future<dynamic> post(String route, [Object? body]) async =>
      _handle(await _client.post(_uri(route), headers: _headers, body: jsonEncode(body ?? {})));

  Future<dynamic> put(String route, Object body) async =>
      _handle(await _client.put(_uri(route), headers: _headers, body: jsonEncode(body)));

  // --- manifest shortcuts ---
  Future<Map<String, dynamic>> manifest() async => (await get('/manifesto')) as Map<String, dynamic>;

  Future<Map<String, dynamic>> saveManifest(Map<String, dynamic> m) async =>
      (await put('/manifesto', m)) as Map<String, dynamic>;
}
