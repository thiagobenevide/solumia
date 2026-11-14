import 'package:agent_core/agent_core.dart';

typedef Doc = Map<String, dynamic>;

/// Rotas de `/api/vagas` no backend da plataforma (`modulos/concursos/backend`, `vagas.py`).
class ApiVagas {
  ApiVagas(String base, {String token = ''})
    : _api = ApiCliente(base, cabecalhos: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'});

  final ApiCliente _api;
  static const _raiz = 'api/vagas';

  /// `{perfil, vagas, claude, pesquisando}`.
  Future<Doc> listar() async => await _api.get(_raiz) as Doc;

  Future<Doc> salvarPerfil(Doc perfil) async => await _api.put('$_raiz/perfil', perfil) as Doc;

  /// Pesquisa na web pelo Claude Code, em segundo plano (acompanhar por `pesquisando`).
  Future<void> pesquisar() => _api.post('$_raiz/pesquisar');

  Future<void> marcar(String id, String estado) => _api.patch('$_raiz/$id', {'estado': estado});

  Future<void> remover(String id) => _api.delete('$_raiz/$id');

  /// Adapta o currículo padrão à vaga pelo Claude Code, em segundo plano (acompanhar por
  /// `gerando_curriculo` e `erros_curriculo` da listagem).
  Future<void> gerarCurriculo(String id) => _api.post('$_raiz/$id/curriculo');

  /// `{pasta, curriculos: [{id, nome, vaga, em, padrao}]}`, o padrão primeiro.
  Future<Doc> curriculos() async => await _api.get('$_raiz/curriculos') as Doc;

  /// `{id, nome, vaga, em, padrao, conteudo}` (Markdown).
  Future<Doc> curriculo(String id) async => await _api.get('$_raiz/curriculos/$id') as Doc;

  Future<Doc> criarCurriculo(String nome, String conteudo) async =>
      await _api.post('$_raiz/curriculos', {'nome': nome, 'conteudo': conteudo}) as Doc;

  Future<Doc> salvarCurriculo(String id, String nome, String conteudo) async =>
      await _api.put('$_raiz/curriculos/$id', {'nome': nome, 'conteudo': conteudo}) as Doc;

  Future<void> definirPadrao(String id) => _api.post('$_raiz/curriculos/$id/padrao');

  Future<void> removerCurriculo(String id) => _api.delete('$_raiz/curriculos/$id');
}
