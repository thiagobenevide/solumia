import 'package:agent_core/agent_core.dart';

typedef Doc = Map<String, dynamic>;

/// `/api/youtube` routes in the platform backend: channels and each one's collections (temas,
/// historias, roteiros, planos, metodos), all stored as vault notes.
class ApiYoutube {
  ApiYoutube(String base, {String token = ''})
    : _api = ApiCliente(base, cabecalhos: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'});

  final ApiCliente _api;

  static const _root = 'api/youtube';

  List<Doc> _list(dynamic j) => [for (final d in j as List) d as Doc];

  String _c(String slug) => '$_root/canais/${Uri.encodeComponent(slug)}';

  String _i(String slug, String collection, String id) => '${_c(slug)}/$collection/${Uri.encodeComponent(id)}';

  Future<Doc> schema() async => await _api.get('$_root/esquema') as Doc;

  Future<Doc> runImport({bool replace = false}) async =>
      await _api.post('$_root/importar', {'substituir': replace}) as Doc;

  // --- canais ---

  Future<List<Doc>> channels() async => _list(await _api.get('$_root/canais'));

  Future<Doc> channel(String slug) async => await _api.get(_c(slug)) as Doc;

  Future<Doc> createChannel(Doc dados) async => await _api.post('$_root/canais', dados) as Doc;

  Future<Doc> editChannel(String slug, Doc dados) async => await _api.patch(_c(slug), dados) as Doc;

  Future<void> deleteChannel(String slug) => _api.delete(_c(slug));

  // --- collection items ---

  Future<List<Doc>> items(String slug, String collection, {String q = '', String status = ''}) async {
    final filter = {if (q.isNotEmpty) 'q': q, if (status.isNotEmpty) 'status': status};
    final qs = filter.isEmpty ? '' : '?${Uri(queryParameters: filter).query}';
    return _list(await _api.get('${_c(slug)}/$collection$qs'));
  }

  Future<Doc> item(String slug, String collection, String id) async => await _api.get(_i(slug, collection, id)) as Doc;

  Future<Doc> create(String slug, String collection, Doc dados) async =>
      await _api.post('${_c(slug)}/$collection', dados) as Doc;

  Future<Doc> edit(String slug, String collection, String id, Doc dados) async =>
      await _api.patch(_i(slug, collection, id), dados) as Doc;

  Future<void> delete(String slug, String collection, String id) => _api.delete(_i(slug, collection, id));

  /// Creates the script or the story ([collection]) of a theme, already linked.
  Future<Doc> derive(String slug, String temaId, String collection) async =>
      await _api.post('${_i(slug, 'temas', temaId)}/derivar', {'colecao': collection}) as Doc;
}
