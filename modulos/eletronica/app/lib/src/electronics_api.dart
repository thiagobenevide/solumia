import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';

import 'models.dart';

/// Routes of `/api/eletronica`.
class ElectronicsApi {
  ElectronicsApi(String base, {String token = ''})
    : _api = ApiCliente(base, cabecalhos: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'});

  final ApiCliente _api;

  /// For extensions from other screens (e.g. `SimulationApi` in `simulation.dart`).
  ApiCliente get cliente => _api;

  Future<Library> library() async => Library([
    for (final j in await _api.get('api/eletronica/biblioteca') as List) Symbol.fromJson(j as Map<String, dynamic>),
  ]);

  /// Imported symbols matching [q] (all words), from one [library] or all of them.
  Future<List<Symbol>> searchSymbols(String q, {String? library}) async => [
    for (final j in await _api.get(
          'api/eletronica/biblioteca/busca?q=${Uri.encodeQueryComponent(q)}'
          '${library == null ? '' : '&biblioteca=${Uri.encodeQueryComponent(library)}'}',
        ) as List)
      Symbol.fromJson(j as Map<String, dynamic>),
  ];

  /// The symbols of [ids] that exist on the server (base or imported).
  Future<List<Symbol>> symbols(Iterable<String> ids) async => [
    for (final j in await _api.post('api/eletronica/biblioteca/simbolos', {'ids': ids.toList()}) as List)
      Symbol.fromJson(j as Map<String, dynamic>),
  ];

  /// `[{nome, origem, importado, total}]` das bibliotecas importadas.
  Future<List<Map<String, dynamic>>> libraries() async => [
    for (final b in await _api.get('api/eletronica/bibliotecas') as List) b as Map<String, dynamic>,
  ];

  Future<Map<String, dynamic>> importLibrary(String name, List<int> bytes) async =>
      await _api.enviarArquivo('api/eletronica/bibliotecas/importar', 'arquivo', name, bytes) as Map<String, dynamic>;

  /// `{versao, sugeridas: [nomes]}` of the official KiCad libraries.
  Future<Map<String, dynamic>> kicad() async => await _api.get('api/eletronica/bibliotecas/kicad') as Map<String, dynamic>;

  /// Downloads and imports the official [names]; one row per name with `total` or `erro`.
  Future<List<Map<String, dynamic>>> downloadKicad(List<String> names) async => [
    for (final r in await _api.post('api/eletronica/bibliotecas/kicad', {'nomes': names}) as List) r as Map<String, dynamic>,
  ];

  Future<void> removeLibrary(String name) => _api.delete('api/eletronica/bibliotecas/${Uri.encodeComponent(name)}');

  Future<List<ProjectSummary>> list() async => [
    for (final j in await _api.get('api/eletronica/projetos') as List) ProjectSummary.fromJson(j as Map<String, dynamic>),
  ];

  Future<Project> fetch(String id) async => Project.fromJson(await _api.get('api/eletronica/projetos/$id'));

  Future<ProjectSummary> create({String title = ''}) async =>
      ProjectSummary.fromJson(await _api.post('api/eletronica/projetos', {'titulo': title}));

  Future<ProjectSummary> rename(String id, String title) async =>
      ProjectSummary.fromJson(await _api.patch('api/eletronica/projetos/$id', {'titulo': title}));

  /// Saves the schematic over the read [version]. Old version → [ApiErro] with status 409.
  Future<ProjectSummary> save(Project p, int version) async => ProjectSummary.fromJson(
    await _api.put('api/eletronica/projetos/${p.id}/esquematico', {'versao': version, ...p.schematicJson()}),
  );

  /// `{redes: [{nome, pinos: [{ref, pino, nome}]}], soltos: [...]}` of what is saved.
  Future<Map<String, dynamic>> netlist(String id) async =>
      await _api.get('api/eletronica/projetos/$id/netlist') as Map<String, dynamic>;

  /// `[{refs, quantidade, descricao, valor, encapsulamento}]`.
  Future<List<Map<String, dynamic>>> bom(String id) async => [
    for (final l in await _api.get('api/eletronica/projetos/$id/bom') as List) l as Map<String, dynamic>,
  ];

  Future<Uint8List> bomCsv(String id) => _api.getBytes('api/eletronica/projetos/$id/bom.csv');

  Future<ProjectSummary> duplicate(String id) async =>
      ProjectSummary.fromJson(await _api.post('api/eletronica/projetos/$id/duplicar'));

  Future<void> delete(String id) => _api.delete('api/eletronica/projetos/$id');

  /// Electrical check: `[{nivel: erro|aviso, codigo, mensagem, refs, pinos, rede, folha?, x?, y?}]`.
  Future<List<Map<String, dynamic>>> erc(String id) async => [
    for (final p in await _api.get('api/eletronica/projetos/$id/erc') as List) p as Map<String, dynamic>,
  ];
}
