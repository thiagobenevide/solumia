import 'package:agent_core/agent_core.dart';
import 'package:agent_notas/agent_notas.dart';
import 'package:http/http.dart' as http;

import 'dates.dart';
import 'models.dart';
import 'session.dart';

/// Routes of `/api/saude` in the platform backend (local or VPS, with the key).
class HealthApi {
  /// [client]: swaps the HTTP client (the tests use a fake).
  HealthApi(String base, {String token = '', http.Client? cliente})
    : _api = ApiCliente(
        base,
        cliente: cliente,
        cabecalhos: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'},
      ),
      notes = NotesApi(base, token: token);

  final ApiCliente _api;

  /// Reflections and theology studies are vault notes.
  final NotesApi notes;

  Map<String, String> get cabecalhos => _api.cabecalhos;

  /// Body areas (in library order) and every exercise.
  Future<(List<String>, List<Exercise>)> exercises() async {
    final j = await _api.get('api/saude/exercicios') as Map<String, dynamic>;
    return (
      [...(j['areas'] as List).cast<String>()],
      [for (final e in j['exercicios'] as List) Exercise.fromJson(e)],
    );
  }

  Future<Exercise> createExercise(Map<String, dynamic> data) async =>
      Exercise.fromJson(await _api.post('api/saude/exercicios', data));

  Future<Exercise> editExercise(String id, Map<String, dynamic> data) async =>
      Exercise.fromJson(await _api.patch('api/saude/exercicios/$id', data));

  Future<void> deleteExercise(String id) => _api.delete('api/saude/exercicios/$id');

  /// [n] 0 = start of the movement, 1 = end. [version] forces a reload after changing the photo.
  Uri imageUrl(String id, {int n = 0, int version = 0}) => _api.url('api/saude/exercicios/$id/imagem?n=$n&v=$version');

  Future<Exercise> uploadImage(String id, String name, List<int> bytes) async =>
      Exercise.fromJson(await _api.enviarArquivo('api/saude/exercicios/$id/imagem', 'arquivo', name, bytes));

  Future<Exercise> removeImage(String id) async =>
      Exercise.fromJson(await _api.delete('api/saude/exercicios/$id/imagem'));

  Future<List<ItemAgenda>> agenda(DateTime de, DateTime ate) async => [
    for (final j in await _api.get('api/saude/agenda?de=${iso(de)}&ate=${iso(ate)}') as List) ItemAgenda.fromJson(j),
  ];

  Future<ItemAgenda> mark(DateTime data, String exerciseId) async =>
      ItemAgenda.fromJson(await _api.post('api/saude/agenda', {'data': iso(data), 'exercicio_id': exerciseId}));

  Future<ItemAgenda> editItem(String id, Map<String, dynamic> data) async =>
      ItemAgenda.fromJson(await _api.patch('api/saude/agenda/$id', data));

  Future<void> unmark(String id) => _api.delete('api/saude/agenda/$id');

  // --- workout guide ---

  WorkoutSession _session(dynamic j) => WorkoutSession.fromJson(j as Map<String, dynamic>);

  Future<WorkoutSession?> activeSession() async {
    final j = await _api.get('api/saude/sessoes/ativa');
    return j == null ? null : _session(j);
  }

  Future<WorkoutSession> startSession(DateTime day, {int restSeconds = 60}) async =>
      _session(await _api.post('api/saude/sessoes', {'data': iso(day), 'descanso_s': restSeconds}));

  Future<WorkoutSession> session(String id) async => _session(await _api.get('api/saude/sessoes/$id'));

  /// [acao]: concluir_serie, pausar, continuar, pular_descanso, somar_descanso, ir_para,
  /// pular_exercicio, desfazer_serie, editar_serie, descanso_padrao.
  Future<WorkoutSession> sessionCommand(String id, String action, [Map<String, dynamic> data = const {}]) async =>
      _session(await _api.post('api/saude/sessoes/$id/comando', {'acao': action, ...data}));

  Future<WorkoutSession> finishSession(String id, Map<String, dynamic> data) async =>
      _session(await _api.post('api/saude/sessoes/$id/concluir', data));

  Future<WorkoutSession> editSession(String id, Map<String, dynamic> data) async =>
      _session(await _api.patch('api/saude/sessoes/$id', data));

  Future<void> deleteSession(String id) => _api.delete('api/saude/sessoes/$id');

  /// Copies [from]..[to] to the period starting at [destination].
  Future<void> copy(DateTime de, DateTime ate, DateTime destination) =>
      _api.post('api/saude/agenda/copiar', {'de': iso(de), 'ate': iso(ate), 'destino': iso(destination)});

  // --- mental ---

  Future<List<Map<String, dynamic>>> habits(DateTime de, DateTime ate) async =>
      [...(await _api.get('api/saude/mental/habitos?de=${iso(de)}&ate=${iso(ate)}') as List).cast<Map<String, dynamic>>()];

  Future<void> createHabit(Map<String, dynamic> data) => _api.post('api/saude/mental/habitos', data);

  Future<void> editHabit(String id, Map<String, dynamic> data) => _api.patch('api/saude/mental/habitos/$id', data);

  Future<void> deleteHabit(String id) => _api.delete('api/saude/mental/habitos/$id');

  Future<void> markHabit(String id, DateTime day, bool done) =>
      _api.post('api/saude/mental/habitos/$id/marcar', {'data': iso(day), 'feito': done});

  Future<Map<String, dynamic>> focus(DateTime de, DateTime ate) async =>
      await _api.get('api/saude/mental/foco?de=${iso(de)}&ate=${iso(ate)}') as Map<String, dynamic>;

  Future<void> logFocus(Map<String, dynamic> session) => _api.post('api/saude/mental/foco', session);

  Future<List<Map<String, dynamic>>> daily(DateTime de, DateTime ate) async =>
      [...(await _api.get('api/saude/mental/diario?de=${iso(de)}&ate=${iso(ate)}') as List).cast<Map<String, dynamic>>()];

  Future<void> saveDay(DateTime day, Map<String, dynamic> data) => _api.put('api/saude/mental/diario/${iso(day)}', data);

  // --- watch (Galaxy Watch via Samsung Health) ---

  Future<List<Map<String, dynamic>>> watchDays(DateTime de, DateTime ate) async =>
      [...(await _api.get('api/saude/relogio/dias?de=${iso(de)}&ate=${iso(ate)}') as List).cast<Map<String, dynamic>>()];

  Future<Map<String, dynamic>> watchSummary(DateTime de, DateTime ate) async =>
      await _api.get('api/saude/relogio/resumo?de=${iso(de)}&ate=${iso(ate)}') as Map<String, dynamic>;

  /// Last sync of each source (`health_connect`, `exportacao`), in ISO UTC.
  Future<Map<String, dynamic>> watchStatus() async =>
      await _api.get('api/saude/relogio/estado') as Map<String, dynamic>;

  /// Summed Health Connect days; the backend replaces the stored values.
  Future<void> sendWatchDays(List<Map<String, dynamic>> days) => _api.put('api/saude/relogio/dias', {'dias': days});

  /// Zip from Samsung Health › Settings › Download personal data.
  Future<Map<String, dynamic>> importSamsung(String name, List<int> bytes) async =>
      await _api.enviarArquivo('api/saude/relogio/importar', 'arquivo', name, bytes) as Map<String, dynamic>;

  Future<List<Map<String, dynamic>>> analyses() async =>
      [...(await _api.get('api/saude/relogio/analises') as List).cast<Map<String, dynamic>>()];

  /// Asks the local LLM (PC worker) for the analysis of the last [days]; it takes a while.
  Future<Map<String, dynamic>> analyze(int days, String question) async =>
      await _api.post('api/saude/relogio/analises', {'dias': days, 'pergunta': question}) as Map<String, dynamic>;

  // --- usage (control of social networks and content on the Android devices) ---

  Future<Map<String, dynamic>> usageConfig() async =>
      await _api.get('api/saude/consumo/config') as Map<String, dynamic>;

  Future<Map<String, dynamic>> setRule(String category, Map<String, dynamic> rule) async =>
      await _api.put('api/saude/consumo/regras/$category', rule) as Map<String, dynamic>;

  Future<Map<String, dynamic>> setApp(String package, String name, String category) async => await _api
      .put('api/saude/consumo/apps', {'pacote': package, 'nome': name, 'categoria': category}) as Map<String, dynamic>;

  Future<Map<String, dynamic>> removerApp(String package) async =>
      await _api.delete('api/saude/consumo/apps/$package') as Map<String, dynamic>;

  Future<Map<String, dynamic>> includeDomain(String category, String domain) async => await _api
      .post('api/saude/consumo/dominios/$category', {'dominio': domain}) as Map<String, dynamic>;

  Future<Map<String, dynamic>> removeDomain(String category, String domain) async => await _api.delete(
    'api/saude/consumo/dominios/$category/${Uri.encodeComponent(domain)}',
  ) as Map<String, dynamic>;

  Future<Map<String, dynamic>> setProtection(bool active) async =>
      await _api.put('api/saude/consumo/protecao', {'ativa': active}) as Map<String, dynamic>;

  Future<void> cancelPending(String id) => _api.delete('api/saude/consumo/pendencias/$id');

  Future<List<Map<String, dynamic>>> devices() async =>
      [...(await _api.get('api/saude/consumo/dispositivos') as List).cast<Map<String, dynamic>>()];

  /// This device sends the usage/events and gets the already built rules to apply.
  Future<Map<String, dynamic>> syncUsage(Map<String, dynamic> data) async =>
      await _api.post('api/saude/consumo/sincronizar', data) as Map<String, dynamic>;

  Future<Map<String, dynamic>> usageSummary(DateTime de, DateTime ate) async =>
      await _api.get('api/saude/consumo/resumo?de=${iso(de)}&ate=${iso(ate)}') as Map<String, dynamic>;

  Future<List<Map<String, dynamic>>> usageAnalyses() async =>
      [...(await _api.get('api/saude/consumo/analises') as List).cast<Map<String, dynamic>>()];

  /// Asks the "watcher" (local LLM) for the reading of the last [days]; it takes a while.
  Future<Map<String, dynamic>> analyzeUsage(int days, String question) async =>
      await _api.post('api/saude/consumo/analises', {'dias': days, 'pergunta': question}) as Map<String, dynamic>;

  // --- espiritual ---

  Future<List<Map<String, dynamic>>> scopes() async =>
      [...(await _api.get('api/saude/espiritual/escopos') as List).cast<Map<String, dynamic>>()];

  Future<List<Map<String, dynamic>>> plans() async =>
      [...(await _api.get('api/saude/espiritual/planos') as List).cast<Map<String, dynamic>>()];

  Future<Map<String, dynamic>> createPlan(Map<String, dynamic> data) async =>
      await _api.post('api/saude/espiritual/planos', data) as Map<String, dynamic>;

  Future<void> deletePlan(String id) => _api.delete('api/saude/espiritual/planos/$id');

  Future<List<Map<String, dynamic>>> planReadings(String id, DateTime de, DateTime ate) async => [
    ...(await _api.get('api/saude/espiritual/planos/$id/leituras?de=${iso(de)}&ate=${iso(ate)}') as List)
        .cast<Map<String, dynamic>>(),
  ];

  Future<void> markReading(String id, DateTime day, bool done) =>
      _api.post('api/saude/espiritual/planos/$id/marcar', {'data': iso(day), 'feito': done});

  /// Vault notes with the tag (e.g. `reflexao`, `teologia`), most recent first.
  Future<List<NoteSummary>> notesWithTag(String tag) async => [
    for (final j in await _api.get('api/notas?tag=${Uri.encodeQueryComponent(tag)}') as List) NoteSummary.fromJson(j),
  ]..sort((a, b) => (b.updated ?? DateTime(0)).compareTo(a.updated ?? DateTime(0)));

  // --- AI coach (`/coach`): profile, equipment, weight, meals and the week's workout ---

  Future<Map<String, dynamic>> coachProfile() async =>
      await _api.get('api/saude/coach/perfil') as Map<String, dynamic>;

  Future<Map<String, dynamic>> saveCoachProfile(Map<String, dynamic> data) async =>
      await _api.patch('api/saude/coach/perfil', data) as Map<String, dynamic>;

  Future<List<Map<String, dynamic>>> weights(DateTime de, DateTime ate) async =>
      (await _api.get('api/saude/coach/peso?de=${iso(de)}&ate=${iso(ate)}') as List).cast<Map<String, dynamic>>();

  Future<void> saveWeight(DateTime day, double kg) => _api.put('api/saude/coach/peso/${iso(day)}', {'peso_kg': kg});

  Future<void> deleteWeight(String day) => _api.delete('api/saude/coach/peso/$day');

  Future<Map<String, dynamic>> foodDay(DateTime day) async =>
      await _api.get('api/saude/coach/dia/${iso(day)}') as Map<String, dynamic>;

  Future<List<Map<String, dynamic>>> meals(DateTime day) async =>
      (await _api.get('api/saude/coach/refeicoes?de=${iso(day)}&ate=${iso(day)}') as List)
          .cast<Map<String, dynamic>>();

  /// Sends the meal (photo and/or description); the server estimates calories with the chosen AI.
  Future<Map<String, dynamic>> sendMeal(
    DateTime day,
    String type,
    String description,
    String ai, {
    ({String name, List<int> bytes})? photo,
  }) async {
    final fields = {'data': iso(day), 'tipo': type, 'descricao': description, 'ia': ai, 'hora': _hourNow()};
    if (photo == null) {
      return await _api.enviarArquivo('api/saude/coach/refeicoes', 'sem_foto', 'x.txt', const [], campos: fields)
          as Map<String, dynamic>;
    }
    return await _api.enviarArquivo('api/saude/coach/refeicoes', 'foto', photo.name, photo.bytes, campos: fields)
        as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> reanalyzeMeal(String id, String correction, String ai) async =>
      await _api.post('api/saude/coach/refeicoes/$id/analisar', {'correcao': correction, 'ia': ai})
          as Map<String, dynamic>;

  Future<void> deleteMeal(String id) => _api.delete('api/saude/coach/refeicoes/$id');

  Uri mealPhotoUrl(String id) => _api.url('api/saude/coach/refeicoes/$id/foto');

  Future<List<Map<String, dynamic>>> workoutPlans() async =>
      (await _api.get('api/saude/coach/planos') as List).cast<Map<String, dynamic>>();

  /// Builds the workout of the chosen [days] with the AI and writes it into the agenda (the other
  /// days stay). `hoje` goes from the phone: the server clock is UTC.
  Future<Map<String, dynamic>> generateWorkoutPlan(String request, String ai, List<DateTime> days) async =>
      await _api.post('api/saude/coach/planos', {
            'pedido': request,
            'ia': ai,
            'substituir': true,
            'datas': [for (final d in days) iso(d)],
            'hoje': iso(today()),
          })
          as Map<String, dynamic>;
}

String _hourNow() {
  final now = DateTime.now();
  return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
}
