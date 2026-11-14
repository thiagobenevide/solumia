import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';
import 'package:agent_notas/agent_notas.dart';
import 'package:http/http.dart' as http;

import 'models.dart';
import 'knowledge_models.dart';

String iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Routes of `/api/estudos` and the graph of `/api/notas/grafo`. [notes] opens and creates the synthesis notes.
class StudiesApi {
  /// [client]: swaps the HTTP client (the tests use a fake).
  StudiesApi(String base, {String token = '', http.Client? cliente})
    : _api = ApiCliente(
        base,
        cliente: cliente,
        cabecalhos: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'},
      ),
      notes = NotesApi(base, token: token);

  final ApiCliente _api;
  final NotesApi notes;

  Future<StudyOptions> options() async => StudyOptions.fromJson(await _api.get('api/estudos/opcoes'));

  Future<List<Reading>> readings() async => [
    for (final j in await _api.get('api/estudos/leituras') as List) Reading.fromJson(j),
  ];

  Future<Reading> createReading(Map<String, dynamic> data) async =>
      Reading.fromJson(await _api.post('api/estudos/leituras', data));

  Future<Reading> editReading(String id, Map<String, dynamic> data) async =>
      Reading.fromJson(await _api.patch('api/estudos/leituras/$id', data));

  Future<void> deleteReading(String id) => _api.delete('api/estudos/leituras/$id');

  Future<List<Track>> tracks() async => [
    for (final j in await _api.get('api/estudos/idiomas') as List) Track.fromJson(j),
  ];

  Future<Track> createTrack(Map<String, dynamic> data) async =>
      Track.fromJson(await _api.post('api/estudos/idiomas', data));

  Future<Track> editTrack(String id, Map<String, dynamic> data) async =>
      Track.fromJson(await _api.patch('api/estudos/idiomas/$id', data));

  Future<void> deleteTrack(String id) => _api.delete('api/estudos/idiomas/$id');

  Future<List<StudyDay>> schedule(String id, DateTime de, DateTime ate) async => [
    for (final j in await _api.get('api/estudos/idiomas/$id/cronograma?de=${iso(de)}&ate=${iso(ate)}') as List)
      StudyDay.fromJson(j),
  ];

  /// Minutes studied in the day (0 undoes).
  Future<Track> register(String id, DateTime day, int minutes) async =>
      Track.fromJson(await _api.post('api/estudos/idiomas/$id/sessoes', {'data': iso(day), 'minutos': minutes}));

  Future<List<KnowledgeTrack>> knowledgeTracks() async => [
    for (final j in await _api.get('api/estudos/conhecimento/trilhas') as List) KnowledgeTrack.fromJson(j),
  ];

  /// The track with the steps; [front] (Back-end, Dados…) filters the same sequence.
  Future<KnowledgeTrack> knowledgeTrack(String id, {String? front}) async => KnowledgeTrack.fromJson(
    await _api.get(
      'api/estudos/conhecimento/trilhas/$id${front == null ? '' : '?frente=${Uri.encodeQueryComponent(front)}'}',
    ),
  );

  /// `leitura` (index) + `feita`, `pratica` and/or `nota_id`.
  Future<TrackStep> markStep(String track, String step, Map<String, dynamic> data) async =>
      TrackStep.fromJson(await _api.post('api/estudos/conhecimento/trilhas/$track/etapas/$step', data));

  Future<List<TrackBook>> shelf() async => [
    for (final j in await _api.get('api/estudos/conhecimento/livros') as List) TrackBook.fromJson(j),
  ];

  Future<TrackBook> markBook(String id, bool owned) async =>
      TrackBook.fromJson(await _api.patch('api/estudos/conhecimento/livros/$id', {'tenho': owned}));

  /// Links the book to a reading (creates it if missing), where the PDF is attached and highlighted.
  Future<TrackBook> linkReading(String id) async =>
      TrackBook.fromJson(await _api.post('api/estudos/conhecimento/livros/$id/leitura', {}));

  Future<List<ReadingProject>> projects() async => [
    for (final j in await _api.get('api/estudos/projetos') as List) ReadingProject.fromJson(j),
  ];

  Future<ReadingProject> createProject(Map<String, dynamic> data) async =>
      ReadingProject.fromJson(await _api.post('api/estudos/projetos', data));

  Future<ReadingProject> editProject(String id, Map<String, dynamic> data) async =>
      ReadingProject.fromJson(await _api.patch('api/estudos/projetos/$id', data));

  Future<void> deleteProject(String id) => _api.delete('api/estudos/projetos/$id');

  Future<Matrix> matrix(String id) async => Matrix.fromJson(await _api.get('api/estudos/projetos/$id/matriz'));

  /// Section, citation/content type, keywords, usage status, paraphrase and notes.
  Future<void> classify(String projectId, String itemId, Map<String, String> data) =>
      _api.patch('api/estudos/projetos/$projectId/itens/${Uri.encodeComponent(itemId)}', data);

  /// `.xlsx` spreadsheet of the matrix (Trabalhos, Trechos, Painel and Referências).
  Future<Uint8List> exportProject(String id) => _api.getBytes('api/estudos/projetos/$id/exportar');

  /// State of the reverse citation mapping of the project document (empty if it never ran).
  Future<Map<String, dynamic>> mapping(String id) async =>
      (await _api.get('api/estudos/projetos/$id/mapeamento') as Map).cast<String, dynamic>();

  /// Uploads the finished document (.docx): it stays in Arquivos and Claude maps the citations.
  Future<Map<String, dynamic>> attachDocument(String id, String name, List<int> bytes) async =>
      (await _api.enviarArquivo('api/estudos/projetos/$id/documento', 'arquivo', name, bytes) as Map)
          .cast<String, dynamic>();

  /// Runs the mapping again (after downloading the pending PDFs).
  Future<Map<String, dynamic>> redoMapping(String id) async =>
      (await _api.post('api/estudos/projetos/$id/mapeamento', {}) as Map).cast<String, dynamic>();

  // --- Linguagem (`/api/estudos/linguagem`): local LLM and worker voice, never Claude ---

  Future<dynamic> _lg(String path, [Object? body]) =>
      body == null ? _api.get('api/estudos/linguagem/$path') : _api.post('api/estudos/linguagem/$path', body);

  List<Map<String, dynamic>> _list(Object? j) => [for (final x in j as List) (x as Map).cast<String, dynamic>()];
  Map<String, dynamic> _mapping(Object? j) => (j as Map).cast<String, dynamic>();

  Future<Map<String, dynamic>> speech(String text, String language, {double speed = 1}) async =>
      _mapping(await _lg('fala', {'texto': text, 'idioma': language, 'velocidade': speed}));

  Future<List<Map<String, dynamic>>> vocabulary(String language, {bool due = false}) async =>
      _list(await _lg('vocabulario?idioma=$language&devidas=$due'));

  Future<Map<String, dynamic>> createWord(Map<String, dynamic> data) async => _mapping(await _lg('vocabulario', data));

  Future<Map<String, dynamic>> generatePractice(String id) async => _mapping(await _lg('vocabulario/$id/gerar', {}));

  /// [note] 1 wrong, 2 hard, 3 good, 4 easy (FSRS).
  Future<Map<String, dynamic>> reviewWord(String id, int note) async =>
      _mapping(await _lg('vocabulario/$id/revisar', {'nota': note}));

  /// `{correcao, item}`: the answer correction and the word with its next review.
  Future<Map<String, dynamic>> answerExercise(String id, int score, String answer) async =>
      _mapping(await _lg('vocabulario/$id/responder', {'indice': score, 'resposta': answer}));

  Future<void> deleteWord(String id) => _api.delete('api/estudos/linguagem/vocabulario/$id');

  Future<List<Map<String, dynamic>>> writings(String language) async => _list(await _lg('escritas?idioma=$language'));

  Future<Map<String, dynamic>> createWriting(Map<String, dynamic> data) async => _mapping(await _lg('escritas', data));

  Future<Map<String, dynamic>> answerWriting(String id, int score, String answer) async =>
      _mapping(await _lg('escritas/$id/responder', {'indice': score, 'resposta': answer}));

  Future<void> deleteWriting(String id) => _api.delete('api/estudos/linguagem/escritas/$id');

  Future<List<Map<String, dynamic>>> voiceReadings(String language) async => _list(await _lg('leituras-voz?idioma=$language'));

  Future<Map<String, dynamic>> evaluateReading(List<int> wav, String language, String reference) async => _mapping(
    await _api.enviarArquivo(
      'api/estudos/linguagem/leituras-voz',
      'audio',
      'leitura.wav',
      wav,
      campos: {'idioma': language, 'referencia': reference},
    ),
  );

  Future<void> deleteVoiceReading(String id) => _api.delete('api/estudos/linguagem/leituras-voz/$id');

  Future<void> logActivity(String type, String language, int minutes) =>
      _lg('atividades', {'tipo': type, 'idioma': language, 'minutos': minutes});

  Future<Map<String, dynamic>> progress(String language) async => _mapping(await _lg('progresso?idioma=$language'));

  Future<(List<GraphNode>, List<Edge>)> graph() async {
    final j = await _api.get('api/notas/grafo') as Map<String, dynamic>;
    return (
      [for (final n in j['nos'] as List) GraphNode.fromJson(n)],
      [for (final a in j['arestas'] as List) Edge.fromJson(a)],
    );
  }
}
