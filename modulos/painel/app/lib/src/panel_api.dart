import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';

import 'models.dart';

/// Routes of `/api/painel` in the platform backend (`modulos/painel/backend`).
class PanelApi {
  PanelApi(String base, {String token = ''})
    : _api = ApiCliente(base, cabecalhos: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'});

  final ApiCliente _api;

  Future<Discipline> discipline() async => Discipline.fromJson(await _api.get('api/painel/disciplina'));

  Future<Agenda> agenda(String day) async => Agenda.fromJson(await _api.get('api/painel/agenda/$day'));

  /// Builds the day schedule from the open Kanban tasks (replaces the current one).
  Future<Agenda> suggest(String day) async => Agenda.fromJson(await _api.post('api/painel/agenda/$day/sugerir'));

  /// Saves the edited schedule; the reply brings the coach's objections.
  Future<Agenda> save(String day, List<ScheduleBlock> blocks, String reason) async => Agenda.fromJson(
    await _api.put('api/painel/agenda/$day', {
      'blocos': [for (final b in blocks) b.toJson()],
      'motivo': reason,
    }),
  );

  Future<void> mark(String day, String blockId, bool done) =>
      _api.post('api/painel/agenda/$day/blocos/$blockId/feito?feito=$done');

  Future<List<Goal>> goals() async => [
    for (final j in await _api.get('api/painel/metas') as List) Goal.fromJson(j),
  ];

  Future<void> createGoal(String title, String frequency, double target, String unit) => _api.post(
    'api/painel/metas',
    {'titulo': title, 'frequencia': frequency, 'alvo': target, 'unidade': unit},
  );

  Future<void> deleteGoal(String id) => _api.delete('api/painel/metas/$id');

  Future<void> register(String goalId, [double amount = 1]) =>
      _api.post('api/painel/metas/$goalId/acoes', {'quantidade': amount});

  /// `local` (worker on the PC) and, if the server has the key, `claude`.
  Future<List<String>> providers() async => [for (final p in await _api.get('api/painel/provedores') as List) '$p'];

  /// Message to the coach. “anote …” creates a note; “pesquise …” searches the notes; otherwise
  /// it answers and may act (see [CoachReply.actions]).
  /// [image] (bytes, mime) goes only with this message; the model must support vision.
  Future<CoachReply> chat(
    String mensagem,
    List<(String, String)> history,
    String provider, {
    (List<int>, String)? image,
  }) async => CoachReply.fromJson(
    await _api.post('api/painel/conversar', {
      'mensagem': mensagem,
      'provedor': provider,
      'historico': _history(history),
      if (image != null) ...{'imagem': base64Encode(image.$1), 'imagem_mime': image.$2},
    }),
  );

  /// Spoken message (WAV): the worker transcribes it and it continues as [chat].
  Future<CoachReply> voice(List<int> wav, List<(String, String)> history, String provider) async => CoachReply.fromJson(
    await _api.enviarArquivo(
      'api/painel/voz',
      'audio',
      'fala.wav',
      wav,
      campos: {'provedor': provider, 'historico': jsonEncode(_history(history))},
    ),
  );

  /// [chat] as a stream: [onWarn] gets the progress ("consultando a internet…") while the
  /// server works, so the app can show and speak it without leaving the user without an answer.
  Future<CoachReply> chatStream(
    String mensagem,
    List<(String, String)> history,
    String provider, {
    (List<int>, String)? image,
    void Function(String warning)? onWarn,
  }) => _stream(
    _api.eventos(
      'api/painel/conversar/fluxo',
      corpo: {
        'mensagem': mensagem,
        'provedor': provider,
        'historico': _history(history),
        if (image != null) ...{'imagem': base64Encode(image.$1), 'imagem_mime': image.$2},
      },
    ),
    onWarn,
  );

  /// [voice] as a stream: [aoTranscrever] arrives before the reply, and [onWarn] as in [chatStream].
  Future<CoachReply> voiceStream(
    List<int> wav,
    List<(String, String)> history,
    String provider, {
    void Function(String warning)? onWarn,
    void Function(String text)? aoTranscrever,
  }) => _stream(
    _api.eventos(
      'api/painel/voz/fluxo',
      arquivo: ('audio', 'fala.wav', wav),
      campos: {'provedor': provider, 'historico': jsonEncode(_history(history))},
    ),
    onWarn,
    aoTranscrever,
  );

  static Future<CoachReply> _stream(
    Stream<Map<String, dynamic>> eventos,
    void Function(String)? onWarn, [
    void Function(String)? aoTranscrever,
  ]) async {
    await for (final e in eventos) {
      switch (e['evento']) {
        case 'aviso':
          onWarn?.call('${e['texto']}');
        case 'transcricao':
          aoTranscrever?.call('${e['texto']}');
        case 'erro':
          throw ApiErro((e['status'] as num?)?.toInt() ?? 500, '${e['detalhe']}');
        case 'fim':
          return CoachReply.fromJson(e);
      }
    }
    throw ApiErro(0, 'A conexão caiu antes da resposta.');
  }

  /// The reply as audio (WAV), synthesized on the worker. With [excerpt], only that piece of the speech
  /// (empty after the last one): one can play while the next is generated.
  Future<Uint8List> speak(String text, {int? excerpt}) =>
      _api.postBytes('api/painel/falar', {'texto': text, 'trecho': ?excerpt});

  Future<Dashboard> dashboard() async => Dashboard.fromJson(await _api.get('api/painel/dashboard'));

  static List<Map<String, String>> _history(List<(String, String)> h) => [
    for (final (role, text) in h) {'papel': role, 'texto': text},
  ];
}
