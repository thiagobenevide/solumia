import 'package:agent_core/agent_core.dart';

typedef Doc = Map<String, dynamic>;

/// Rotas de `/api/youtube` no backend da plataforma: canais e as coleções de cada um (temas,
/// historias, roteiros, planos, metodos), todos guardados como notas do cofre.
class ApiYoutube {
  ApiYoutube(String base, {String token = ''})
    : _api = ApiCliente(base, cabecalhos: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'});

  final ApiCliente _api;

  static const _raiz = 'api/youtube';

  List<Doc> _lista(dynamic j) => [for (final d in j as List) d as Doc];

  String _c(String slug) => '$_raiz/canais/${Uri.encodeComponent(slug)}';

  String _i(String slug, String colecao, String id) => '${_c(slug)}/$colecao/${Uri.encodeComponent(id)}';

  Future<Doc> esquema() async => await _api.get('$_raiz/esquema') as Doc;

  Future<Doc> importar({bool substituir = false}) async =>
      await _api.post('$_raiz/importar', {'substituir': substituir}) as Doc;

  // --- canais ---

  Future<List<Doc>> canais() async => _lista(await _api.get('$_raiz/canais'));

  Future<Doc> canal(String slug) async => await _api.get(_c(slug)) as Doc;

  Future<Doc> criarCanal(Doc dados) async => await _api.post('$_raiz/canais', dados) as Doc;

  Future<Doc> editarCanal(String slug, Doc dados) async => await _api.patch(_c(slug), dados) as Doc;

  Future<void> excluirCanal(String slug) => _api.delete(_c(slug));

  // --- itens das coleções ---

  Future<List<Doc>> itens(String slug, String colecao, {String q = '', String status = ''}) async {
    final filtro = {if (q.isNotEmpty) 'q': q, if (status.isNotEmpty) 'status': status};
    final qs = filtro.isEmpty ? '' : '?${Uri(queryParameters: filtro).query}';
    return _lista(await _api.get('${_c(slug)}/$colecao$qs'));
  }

  Future<Doc> item(String slug, String colecao, String id) async => await _api.get(_i(slug, colecao, id)) as Doc;

  Future<Doc> criar(String slug, String colecao, Doc dados) async =>
      await _api.post('${_c(slug)}/$colecao', dados) as Doc;

  Future<Doc> editar(String slug, String colecao, String id, Doc dados) async =>
      await _api.patch(_i(slug, colecao, id), dados) as Doc;

  Future<void> excluir(String slug, String colecao, String id) => _api.delete(_i(slug, colecao, id));

  /// Cria o roteiro ou a história ([colecao]) de um tema, já ligados.
  Future<Doc> derivar(String slug, String temaId, String colecao) async =>
      await _api.post('${_i(slug, 'temas', temaId)}/derivar', {'colecao': colecao}) as Doc;
}
