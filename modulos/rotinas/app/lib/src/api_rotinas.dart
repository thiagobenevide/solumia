import 'package:agent_core/agent_core.dart';

import 'modelos.dart';

/// Rotas de `/api/rotinas` do backend da plataforma (`modulos/rotinas/backend`).
class ApiRotinas {
  ApiRotinas(String base, {String token = ''})
    : _api = ApiCliente(base, cabecalhos: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'});

  final ApiCliente _api;

  /// Fala → texto (Whisper do PC).
  Future<String> transcrever(List<int> wav) => transcreverFala(_api, wav);

  Future<List<Tarefa>> listar() async => [
    for (final j in await _api.get('api/rotinas/tarefas') as List) Tarefa.fromJson(j),
  ];

  Future<Resumo> resumo() async => Resumo.fromJson(await _api.get('api/rotinas/resumo'));

  Future<Tarefa> criar(Map<String, dynamic> dados) async =>
      Tarefa.fromJson(await _api.post('api/rotinas/tarefas', dados));

  Future<Tarefa> salvar(String id, Map<String, dynamic> dados) async =>
      Tarefa.fromJson(await _api.patch('api/rotinas/tarefas/$id', dados));

  Future<Tarefa> mover(String id, Coluna coluna, [int? ordem]) async => Tarefa.fromJson(
    await _api.post('api/rotinas/tarefas/$id/mover', {'coluna': coluna.name, 'ordem': ?ordem}),
  );

  /// [acao]: `iniciar`, `pausar` ou `zerar`.
  Future<Tarefa> cronometro(String id, String acao) async =>
      Tarefa.fromJson(await _api.post('api/rotinas/tarefas/$id/$acao'));

  Future<void> excluir(String id) => _api.delete('api/rotinas/tarefas/$id');

  /// Pergunta ao LLM com o quadro como contexto. [historico]: pares (`usuario`|`assistente`, texto).
  Future<String> perguntar(String pergunta, List<(String, String)> historico) async {
    final r = await _api.post('api/rotinas/perguntar', {
      'pergunta': pergunta,
      'historico': [for (final (papel, texto) in historico) {'papel': papel, 'texto': texto}],
    });
    return (r as Map)['resposta'] as String;
  }
}
