import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';

import 'modelos.dart';

/// Rotas de `/api/eletronica`.
class ApiEletronica {
  ApiEletronica(String base, {String token = ''})
    : _api = ApiCliente(base, cabecalhos: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'});

  final ApiCliente _api;

  /// Para extensões de outras telas (ex.: `ApiSimulacao` em `simulacao.dart`).
  ApiCliente get cliente => _api;

  Future<Biblioteca> biblioteca() async => Biblioteca([
    for (final j in await _api.get('api/eletronica/biblioteca') as List) Simbolo.fromJson(j as Map<String, dynamic>),
  ]);

  /// Símbolos importados que batem com [q] (todas as palavras), de uma [biblioteca] ou de todas.
  Future<List<Simbolo>> buscarSimbolos(String q, {String? biblioteca}) async => [
    for (final j in await _api.get(
          'api/eletronica/biblioteca/busca?q=${Uri.encodeQueryComponent(q)}'
          '${biblioteca == null ? '' : '&biblioteca=${Uri.encodeQueryComponent(biblioteca)}'}',
        ) as List)
      Simbolo.fromJson(j as Map<String, dynamic>),
  ];

  /// Os símbolos de [ids] que existirem no servidor (base ou importados).
  Future<List<Simbolo>> simbolos(Iterable<String> ids) async => [
    for (final j in await _api.post('api/eletronica/biblioteca/simbolos', {'ids': ids.toList()}) as List)
      Simbolo.fromJson(j as Map<String, dynamic>),
  ];

  /// `[{nome, origem, importado, total}]` das bibliotecas importadas.
  Future<List<Map<String, dynamic>>> bibliotecas() async => [
    for (final b in await _api.get('api/eletronica/bibliotecas') as List) b as Map<String, dynamic>,
  ];

  Future<Map<String, dynamic>> importarBiblioteca(String nome, List<int> bytes) async =>
      await _api.enviarArquivo('api/eletronica/bibliotecas/importar', 'arquivo', nome, bytes) as Map<String, dynamic>;

  /// `{versao, sugeridas: [nomes]}` das bibliotecas oficiais do KiCad.
  Future<Map<String, dynamic>> kicad() async => await _api.get('api/eletronica/bibliotecas/kicad') as Map<String, dynamic>;

  /// Baixa e importa as oficiais [nomes]; uma linha por nome com `total` ou `erro`.
  Future<List<Map<String, dynamic>>> baixarKicad(List<String> nomes) async => [
    for (final r in await _api.post('api/eletronica/bibliotecas/kicad', {'nomes': nomes}) as List) r as Map<String, dynamic>,
  ];

  Future<void> removerBiblioteca(String nome) => _api.delete('api/eletronica/bibliotecas/${Uri.encodeComponent(nome)}');

  Future<List<ResumoProjeto>> listar() async => [
    for (final j in await _api.get('api/eletronica/projetos') as List) ResumoProjeto.fromJson(j as Map<String, dynamic>),
  ];

  Future<Projeto> obter(String id) async => Projeto.fromJson(await _api.get('api/eletronica/projetos/$id'));

  Future<ResumoProjeto> criar({String titulo = ''}) async =>
      ResumoProjeto.fromJson(await _api.post('api/eletronica/projetos', {'titulo': titulo}));

  Future<ResumoProjeto> renomear(String id, String titulo) async =>
      ResumoProjeto.fromJson(await _api.patch('api/eletronica/projetos/$id', {'titulo': titulo}));

  /// Grava o esquemático sobre a [versao] lida. Versão velha → [ApiErro] com status 409.
  Future<ResumoProjeto> salvar(Projeto p, int versao) async => ResumoProjeto.fromJson(
    await _api.put('api/eletronica/projetos/${p.id}/esquematico', {'versao': versao, ...p.esquematicoJson()}),
  );

  /// `{redes: [{nome, pinos: [{ref, pino, nome}]}], soltos: [...]}` do que está gravado.
  Future<Map<String, dynamic>> netlist(String id) async =>
      await _api.get('api/eletronica/projetos/$id/netlist') as Map<String, dynamic>;

  /// `[{refs, quantidade, descricao, valor, encapsulamento}]`.
  Future<List<Map<String, dynamic>>> bom(String id) async => [
    for (final l in await _api.get('api/eletronica/projetos/$id/bom') as List) l as Map<String, dynamic>,
  ];

  Future<Uint8List> bomCsv(String id) => _api.getBytes('api/eletronica/projetos/$id/bom.csv');

  Future<ResumoProjeto> duplicar(String id) async =>
      ResumoProjeto.fromJson(await _api.post('api/eletronica/projetos/$id/duplicar'));

  Future<void> excluir(String id) => _api.delete('api/eletronica/projetos/$id');

  /// Verificação elétrica: `[{nivel: erro|aviso, codigo, mensagem, refs, pinos, rede, folha?, x?, y?}]`.
  Future<List<Map<String, dynamic>>> erc(String id) async => [
    for (final p in await _api.get('api/eletronica/projetos/$id/erc') as List) p as Map<String, dynamic>,
  ];
}
