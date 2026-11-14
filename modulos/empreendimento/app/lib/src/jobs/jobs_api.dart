import 'package:agent_core/agent_core.dart';

typedef Doc = Map<String, dynamic>;

/// `/api/vagas` routes in the platform backend (`modulos/concursos/backend`, `vagas.py`).
class ApiJobs {
  ApiJobs(String base, {String token = ''})
    : _api = ApiCliente(base, cabecalhos: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'});

  final ApiCliente _api;
  static const _root = 'api/vagas';

  /// `{perfil, vagas, claude, pesquisando}`.
  Future<Doc> listAll() async => await _api.get(_root) as Doc;

  Future<Doc> saveProfile(Doc profile) async => await _api.put('$_root/perfil', profile) as Doc;

  /// Web search by Claude Code, in the background (follow it through `pesquisando`).
  Future<void> runSearch() => _api.post('$_root/pesquisar');

  Future<void> mark(String id, String state) => _api.patch('$_root/$id', {'estado': state});

  Future<void> remove(String id) => _api.delete('$_root/$id');

  /// Adapts the default résumé to the job through Claude Code, in the background (follow it through
  /// `gerando_curriculo` and `erros_curriculo` in the listing).
  Future<void> generateResume(String id) => _api.post('$_root/$id/curriculo');

  /// `{pasta, curriculos: [{id, nome, vaga, em, padrao}]}`, the default one first.
  Future<Doc> resumes() async => await _api.get('$_root/curriculos') as Doc;

  /// `{id, nome, vaga, em, padrao, conteudo}` (Markdown).
  Future<Doc> resume(String id) async => await _api.get('$_root/curriculos/$id') as Doc;

  Future<Doc> createResume(String nome, String content) async =>
      await _api.post('$_root/curriculos', {'nome': nome, 'conteudo': content}) as Doc;

  Future<Doc> saveResume(String id, String nome, String content) async =>
      await _api.put('$_root/curriculos/$id', {'nome': nome, 'conteudo': content}) as Doc;

  Future<void> setDefault(String id) => _api.post('$_root/curriculos/$id/padrao');

  Future<void> removeResume(String id) => _api.delete('$_root/curriculos/$id');
}
