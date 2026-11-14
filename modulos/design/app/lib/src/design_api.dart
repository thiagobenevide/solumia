import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import 'models.dart';
import 'board/bing_search.dart';
import 'wireframe/model.dart';

/// Routes of `/api/design`.
class ApiDesign {
  ApiDesign(String base, {String token = ''})
    : _api = ApiCliente(base, cabecalhos: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'}),
      _collection = 'quadros';

  ApiDesign._(this._api, this._collection);

  final ApiCliente _api;

  /// `quadros` (flowcharts) or `cadernos`: the routes of both are the same.
  final String _collection;

  /// The same API talking to `/api/design/cadernos`.
  late final ApiDesign notebooks = _collection == 'cadernos' ? this : ApiDesign._(_api, 'cadernos');

  bool get isNotebook => _collection == 'cadernos';

  Future<List<BoardSummary>> list() async => [
    for (final j in await _api.get('api/design/$_collection') as List) BoardSummary.fromJson(j),
  ];

  Future<Board> fetch(String id) async => Board.fromJson(await _api.get('api/design/$_collection/$id'));

  Future<BoardSummary> create({String title = '', Background background = Background.pontos}) async =>
      BoardSummary.fromJson(await _api.post('api/design/$_collection', {'titulo': title, 'fundo': background.name}));

  Future<BoardSummary> edit(String id, {String? title, Background? background, List<BoardPage>? pages}) async =>
      BoardSummary.fromJson(
        await _api.patch('api/design/$_collection/$id', {
          'titulo': ?title,
          'fundo': ?background?.name,
          if (pages != null) 'paginas': [for (final p in pages) p.toJson()],
        }),
      );

  /// Saves the elements over the read [version]. Old version → [ApiErro] with status 409.
  Future<BoardSummary> save(
    String id,
    int version,
    List<Elemento> elements, {
    Map<String, String> pageOf = const {},
  }) async => BoardSummary.fromJson(
    await _api.put('api/design/$_collection/$id/elementos', {
      'versao': version,
      'elementos': [for (final e in elements) jsonWithPage(e, pageOf)],
    }),
  );

  /// Creates a board from a draw.io file (`.drawio`/`.xml`, all pages).
  Future<BoardSummary> importDrawio(String name, List<int> bytes) async => BoardSummary.fromJson(
    await _api.enviarArquivo('api/design/quadros/importar-drawio', 'arquivo', name, bytes) as Map<String, dynamic>,
  );

  /// The board as `.drawio` (to open in draw.io/diagrams.net).
  Future<Uint8List> downloadDrawio(String id) => _api.getBytes('api/design/$_collection/$id/drawio');

  Future<BoardSummary> duplicate(String id) async =>
      BoardSummary.fromJson(await _api.post('api/design/$_collection/$id/duplicar'));

  Future<Uint8List> thumbnail(String id) => _api.getBytes('api/design/$_collection/$id/miniatura');

  Future<void> uploadThumbnail(String id, List<int> png) =>
      _api.enviarArquivo('api/design/$_collection/$id/miniatura', 'arquivo', 'miniatura.png', png);

  Future<void> delete(String id) => _api.delete('api/design/$_collection/$id');

  // ---------- Wireframes ----------

  Future<List<BoardSummary>> listWireframes() async => [
    for (final j in await _api.get('api/design/wireframes') as List) BoardSummary.fromJson(j),
  ];

  Future<Wireframe> fetchWireframe(String id) async => Wireframe.fromJson(await _api.get('api/design/wireframes/$id'));

  Future<BoardSummary> createWireframe({String title = ''}) async =>
      BoardSummary.fromJson(await _api.post('api/design/wireframes', {'titulo': title}));

  Future<BoardSummary> editWireframe(String id, {String? title, List<WfScreen>? screens}) async => BoardSummary.fromJson(
    await _api.patch('api/design/wireframes/$id', {
      'titulo': ?title,
      if (screens != null) 'paginas': [for (final t in screens) t.toJson()],
    }),
  );

  /// Old version → [ApiErro] with status 409.
  Future<BoardSummary> saveWireframe(String id, int version, List<WfComponent> components) async =>
      BoardSummary.fromJson(
        await _api.put('api/design/wireframes/$id/elementos', {
          'versao': version,
          'elementos': [for (final c in components) c.toJson()],
        }),
      );

  /// Package for another AI: ZIP (`AGENTS.md` + schema + `wireframe.json`) or, with [soJson], only the JSON.
  Future<Uint8List> exportWireframe(String id, {bool soJson = false}) =>
      _api.getBytes('api/design/wireframes/$id/ia?formato=${soJson ? 'json' : 'zip'}');

  /// Render of the [screen] (PNG) that goes in the export ZIP.
  Future<void> uploadScreenPng(String id, String screen, List<int> png) =>
      _api.enviarArquivo('api/design/wireframes/$id/telas/$screen/png', 'arquivo', '$screen.png', png);

  /// Creates a wireframe from what the AI returned (`.json`, `.zip` or text with a ```json block).
  Future<BoardSummary> importWireframe(String name, List<int> bytes) async => BoardSummary.fromJson(
    await _api.enviarArquivo('api/design/wireframes/importar-ia', 'arquivo', name, bytes) as Map<String, dynamic>,
  );

  /// Replaces the content of wireframe [id] with what the AI returned.
  Future<Wireframe> reimportWireframe(String id, String name, List<int> bytes) async => Wireframe.fromJson(
    await _api.enviarArquivo('api/design/wireframes/$id/importar-ia', 'arquivo', name, bytes) as Map<String, dynamic>,
  );

  Future<BoardSummary> duplicateWireframe(String id) async =>
      BoardSummary.fromJson(await _api.post('api/design/wireframes/$id/duplicar'));

  Future<void> deleteWireframe(String id) => _api.delete('api/design/wireframes/$id');

  // ---------- Imagens ----------

  /// Google Images: `[{url, miniatura, titulo, largura, altura}]`, 10 per [page]; [type] is
  /// `foto`, `icone`, `figura` or `todos`.
  /// Searches from the device itself first (the VPS is blocked by search engines); on the web or if it fails,
  /// pelo servidor.
  Future<List<Map<String, dynamic>>> searchImages(String q, {String type = 'foto', int page = 0}) async {
    if (!kIsWeb) {
      try {
        return await searchBing(q, type, page);
      } catch (_) {}
    }
    return [
      for (final r in await _api.get(
        'api/design/imagens/busca?q=${Uri.encodeQueryComponent(q)}&tipo=$type&pagina=$page',
      ) as List)
        r as Map<String, dynamic>,
    ];
  }

  /// Copies the image at [url] to the server and returns the id the [BoardImage] element stores.
  Future<String> storeImage(String url) async =>
      (await _api.post('api/design/imagens', {'url': url}) as Map<String, dynamic>)['id'] as String;

  Future<Uint8List> image(String id) => _api.getBytes('api/design/imagens/$id');

  // ---------- References (Arquivos and Notas) ----------

  /// Trechos marcados nos arquivos lidos: `{texto, comentario, pagina, arquivo_titulo, referencia}`.
  Future<List<Map<String, dynamic>>> highlights(String q) async => [
    for (final r in await _api.get('api/arquivos/destaques?q=${Uri.encodeQueryComponent(q)}') as List)
      r as Map<String, dynamic>,
  ];

  /// Vault notes (summary: `id`, `titulo`, `tipo`, `tags`).
  Future<List<Map<String, dynamic>>> notas(String q) async => [
    for (final r in await _api.get('api/notas?q=${Uri.encodeQueryComponent(q)}') as List) r as Map<String, dynamic>,
  ];

  /// Whole note (`corpo` in Markdown).
  Future<Map<String, dynamic>> nota(String id) async =>
      await _api.get('api/notas/${Uri.encodeComponent(id)}') as Map<String, dynamic>;

  // ---------- Flowcharts with AI ----------

  /// `local` (worker on the PC) and, with a configured key, `claude`.
  Future<List<String>> flowProviders() async => [
    for (final p in await _api.get('api/design/fluxos/provedores') as List) '$p',
  ];

  /// Generates the flow (structure by the AI, positions on the server) and waits for the task to finish, polling
  /// every 2 s. Returns `{titulo, nos: [{id, tipo, texto, x, y, w, h}], ligacoes: [{de, para, rotulo}]}`.
  Future<Map<String, dynamic>> generateFlow({
    String request = '',
    String code = '',
    String file = '',
    Map<String, dynamic>? current,
    String provider = 'local',
    bool Function()? cancelled,
  }) async {
    final t = await _api.post('api/design/fluxos/gerar', {
      'pedido': request,
      'codigo': code,
      'arquivo': file,
      'atual': current,
      'provedor': provider,
    }) as Map<String, dynamic>;
    while (true) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (cancelled?.call() ?? false) throw ApiErro(0, 'Cancelado.');
      final r = await _api.get('api/design/fluxos/tarefas/${t['id']}') as Map<String, dynamic>;
      if (r['estado'] == 'pronto') return r['fluxo'] as Map<String, dynamic>;
      if (r['estado'] == 'erro') throw ApiErro(422, '${r['erro']}');
    }
  }
}
