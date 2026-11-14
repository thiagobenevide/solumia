import 'package:agent_core/agent_core.dart';

import 'models.dart';

/// Routes of `/api/rotinas` in the platform backend (`modulos/rotinas/backend`).
class RoutinesApi {
  RoutinesApi(String base, {String token = ''})
    : _api = ApiCliente(base, cabecalhos: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'});

  final ApiCliente _api;

  /// Speech → text (Whisper on the PC).
  Future<String> transcrever(List<int> wav) => transcreverFala(_api, wav);

  Future<List<Task>> list() async => [
    for (final j in await _api.get('api/rotinas/tarefas') as List) Task.fromJson(j),
  ];

  Future<BoardSummary> summary() async => BoardSummary.fromJson(await _api.get('api/rotinas/resumo'));

  Future<Task> create(Map<String, dynamic> data) async =>
      Task.fromJson(await _api.post('api/rotinas/tarefas', data));

  Future<Task> save(String id, Map<String, dynamic> data) async =>
      Task.fromJson(await _api.patch('api/rotinas/tarefas/$id', data));

  Future<Task> move(String id, BoardColumn column, [int? order]) async => Task.fromJson(
    await _api.post('api/rotinas/tarefas/$id/mover', {'coluna': column.name, 'ordem': ?order}),
  );

  /// [action]: `iniciar`, `pausar` or `zerar`.
  Future<Task> timer(String id, String action) async =>
      Task.fromJson(await _api.post('api/rotinas/tarefas/$id/$action'));

  Future<void> delete(String id) => _api.delete('api/rotinas/tarefas/$id');

  /// Asks the LLM with the board as context. [history]: pairs (`usuario`|`assistente`, text).
  Future<String> ask(String question, List<(String, String)> history) async {
    final r = await _api.post('api/rotinas/perguntar', {
      'pergunta': question,
      'historico': [for (final (role, text) in history) {'papel': role, 'texto': text}],
    });
    return (r as Map)['resposta'] as String;
  }
}
