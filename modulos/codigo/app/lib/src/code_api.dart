import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';

import 'models.dart';

/// Routes of `/api/codigo`.
class CodeApi {
  CodeApi(String base, {String token = ''})
    : _api = ApiCliente(base, cabecalhos: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'});

  final ApiCliente _api;

  /// Speech → text (Whisper on the PC).
  Future<String> transcrever(List<int> wav) => transcreverFala(_api, wav);

  /// Why requests are not possible right now (no worker on the PC), or `null`.
  Future<String?> unavailable() async => (await _api.get('api/codigo/estado') as Map)['indisponivel'] as String?;

  Future<List<CodeTab>> list() async => [
    for (final j in await _api.get('api/codigo/sessoes') as List) CodeTab.fromJson(j),
  ];

  Future<CodeTab> create([String title = '']) async =>
      CodeTab.fromJson(await _api.post('api/codigo/sessoes', {'titulo': title}));

  /// The tab and the steps from position [since] (the app asks only for the new ones).
  Future<(CodeTab, List<SessionStep>)> fetch(String id, {int since = 0}) async {
    final j = await _api.get('api/codigo/sessoes/$id?desde=$since') as Map<String, dynamic>;
    return (
      CodeTab.fromJson(j['sessao'] as Map<String, dynamic>),
      [for (final e in j['eventos'] as List) SessionStep(e as Map<String, dynamic>)],
    );
  }

  Future<CodeTab> rename(String id, String title) async =>
      CodeTab.fromJson(await _api.patch('api/codigo/sessoes/$id', {'titulo': title}));

  Future<void> delete(String id) => _api.delete('api/codigo/sessoes/$id');

  /// Sends the request to Claude Code (continues the tab conversation) with reference images.
  Future<CodeTab> send(String id, String text, {List<(String, Uint8List)> images = const []}) async =>
      CodeTab.fromJson(await _api.post('api/codigo/sessoes/$id/mensagens', {
        'texto': text,
        'imagens': [for (final (name, bytes) in images) {'nome': name, 'b64': base64Encode(bytes)}],
      }));

  Future<CodeTab> parar(String id) async => CodeTab.fromJson(await _api.post('api/codigo/sessoes/$id/parar'));

  /// Asks the tab's Claude to commit what it changed; [push] and [publish] (`publicar_app`).
  Future<CodeTab> commit(String id, {String mensagem = '', bool push = true, bool publish = false}) async =>
      CodeTab.fromJson(await _api.post('api/codigo/sessoes/$id/commit', {
        'mensagem': mensagem,
        'push': push,
        'publicar': publish,
      }));

  Future<Uint8List> image(String id, String name) => _api.getBytes('api/codigo/sessoes/$id/imagens/$name');

  /// `{status, log, rodando}` of the repository on the PC.
  Future<Map<String, dynamic>> git() async => await _api.get('api/codigo/git') as Map<String, dynamic>;

  /// Browser (read only): repository files at [commit] (empty = latest) and what it changed.
  Future<CodeTree> tree([String commit = '']) async =>
      CodeTree(await _api.get('api/codigo/arvore?commit=$commit') as Map<String, dynamic>);

  Future<CodeFile> file(String path, String commit) async => CodeFile(
    await _api.get('api/codigo/arquivo?caminho=${Uri.encodeQueryComponent(path)}&commit=$commit')
        as Map<String, dynamic>,
  );

  /// Lines with [term] in the repository ([notes]: only in comments; without a term, TODO/FIXME):
  /// `{resultados: [{caminho, linha, texto}], cortado}`.
  Future<Map<String, dynamic>> search(String term, String commit, {bool notes = false}) async =>
      await _api.get(
            'api/codigo/busca?termo=${Uri.encodeQueryComponent(term)}&commit=$commit&observacoes=$notes',
          )
          as Map<String, dynamic>;

  /// Claude Code accounts on the PC: `{ativa, contas: [{nome, logado, email, plano}]}`.
  Future<Map<String, dynamic>> accounts() async => await _api.get('api/codigo/contas') as Map<String, dynamic>;

  /// Starts the login of [name] (new or expired) and returns the authorization link.
  Future<String> signInAccount(String name) async =>
      (await _api.post('api/codigo/contas', {'nome': name}) as Map)['url'] as String;

  /// Pastes the [code] shown after authorizing; returns the updated list.
  Future<Map<String, dynamic>> accountCode(String name, String code) async =>
      await _api.post('api/codigo/contas/$name/codigo', {'codigo': code}) as Map<String, dynamic>;

  Future<Map<String, dynamic>> activateAccount(String name) async =>
      await _api.post('api/codigo/contas/$name/ativar') as Map<String, dynamic>;

  Future<Map<String, dynamic>> removeAccount(String name) async =>
      await _api.delete('api/codigo/contas/$name') as Map<String, dynamic>;
}
