// Ponte com o núcleo Python: inicia o processo, lê {porta, token} da 1ª linha da saída padrão
// e fala com a API local. O token só existe na memória deste processo.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class ErroNucleo implements Exception {
  ErroNucleo(this.mensagem, [this.status]);
  final String mensagem;
  final int? status;
  @override
  String toString() => mensagem;
}

class Nucleo {
  Nucleo._(this._processo, this._porta, this._token);

  final Process _processo;
  final int _porta;
  final String _token;
  final _cliente = http.Client();
  final List<String> stderr = [];

  static String? localizarExecutavel() {
    final env = Platform.environment['SOLUMIA_CORE'];
    if (env != null && env.isNotEmpty) return env;
    final nome = Platform.isWindows ? 'solumia-configurador.exe' : 'solumia-configurador';
    final bin = Platform.isWindows ? 'Scripts' : 'bin';
    // Instalado: ao lado do executável da interface. Desenvolvimento: configurador/core/.venv.
    final candidatos = <String>[
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}nucleo${Platform.pathSeparator}$nome',
    ];
    var dir = Directory.current;
    for (var i = 0; i < 6; i++) {
      for (final base in ['core', 'configurador${Platform.pathSeparator}core']) {
        candidatos.add([dir.path, base, '.venv', bin, nome].join(Platform.pathSeparator));
      }
      dir = dir.parent;
    }
    for (final c in candidatos) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  static Future<Nucleo> iniciar() async {
    final exe = localizarExecutavel();
    if (exe == null) {
      throw ErroNucleo('Núcleo do configurador não encontrado. Rode "uv sync" em configurador/core '
          'ou defina SOLUMIA_CORE com o caminho do executável.');
    }
    final p = await Process.start(exe, ['servir', '--sair-com-stdin']);
    final erros = <String>[];
    p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      erros.add(l);
      if (erros.length > 200) erros.removeAt(0);
    });
    final String linha;
    try {
      linha = await p.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 30));
    } on Object {
      p.kill();
      throw ErroNucleo('O núcleo não iniciou: ${erros.take(10).join('\n')}');
    }
    final dados = jsonDecode(linha) as Map<String, dynamic>;
    if (dados['erro'] != null) {
      p.kill();
      throw ErroNucleo(dados['erro'] as String);
    }
    final n = Nucleo._(p, dados['porta'] as int, dados['token'] as String);
    n.stderr.addAll(erros);
    return n;
  }

  void encerrar() {
    _cliente.close();
    _processo.kill();
  }

  Uri _uri(String caminho, [Map<String, String>? query]) =>
      Uri(scheme: 'http', host: '127.0.0.1', port: _porta, path: caminho, queryParameters: query);

  Map<String, String> get _cabecalhos =>
      {'Authorization': 'Bearer $_token', 'Content-Type': 'application/json'};

  Future<dynamic> _tratar(http.Response r) async {
    final corpo = r.body.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode >= 400) {
      final detalhe = corpo is Map ? corpo['detail'] : corpo;
      throw ErroNucleo(_texto(detalhe), r.statusCode);
    }
    return corpo;
  }

  static String _texto(dynamic d) {
    if (d is String) return d;
    if (d is List) return d.map((e) => e is Map ? '${e['loc']?.last}: ${e['msg']}' : '$e').join('\n');
    if (d is Map && d['erros'] is Map) {
      return (d['erros'] as Map).entries.map((e) => '${e.key}: ${(e.value as List).join(', ')}').join('\n');
    }
    return '$d';
  }

  Future<dynamic> get(String caminho, [Map<String, String>? query]) async =>
      _tratar(await _cliente.get(_uri(caminho, query), headers: _cabecalhos));

  Future<dynamic> post(String caminho, [Object? corpo]) async =>
      _tratar(await _cliente.post(_uri(caminho), headers: _cabecalhos, body: jsonEncode(corpo ?? {})));

  Future<dynamic> put(String caminho, Object corpo) async =>
      _tratar(await _cliente.put(_uri(caminho), headers: _cabecalhos, body: jsonEncode(corpo)));

  // --- atalhos do manifesto ---
  Future<Map<String, dynamic>> manifesto() async => (await get('/manifesto')) as Map<String, dynamic>;

  Future<Map<String, dynamic>> salvarManifesto(Map<String, dynamic> m) async =>
      (await put('/manifesto', m)) as Map<String, dynamic>;
}
