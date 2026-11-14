import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

import 'models.dart';

/// Routes of `/api/concursos` in the platform backend (`modulos/concursos/backend`).
class ExamsApi {
  /// [client]: swaps the HTTP client (the tests use a fake).
  ExamsApi(String base, {String token = '', http.Client? client})
    : _api = ApiCliente(
        base,
        cliente: client,
        cabecalhos: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'},
      );

  final ApiCliente _api;
  static const _root = 'api/concursos';

  Future<List<ExamSummary>> list() async => [
    for (final j in await _api.get(_root) as List) ExamSummary.fromJson(j as Doc),
  ];

  Future<List<Alert>> alerts() async => [
    for (final j in await _api.get('$_root/alertas') as List) Alert.fromJson(j as Doc),
  ];

  Future<Exam> fetch(String id) async => Exam.fromJson(await _api.get('$_root/$id') as Doc);

  Future<Exam> create(Doc data) async => Exam.fromJson(await _api.post(_root, data) as Doc);

  Future<Exam> save(String id, Doc data) async =>
      Exam.fromJson(await _api.patch('$_root/$id', data) as Doc);

  Future<void> delete(String id) => _api.delete('$_root/$id');

  Future<Exam> uploadNotice(String id, String name, List<int> bytes) async =>
      Exam.fromJson(await _api.enviarArquivo('$_root/$id/edital', 'arquivo', name, bytes) as Doc);

  Future<Exam> noticeByLink(String id, String url) async =>
      Exam.fromJson(await _api.post('$_root/$id/edital/link', {'url': url}) as Doc);

  /// Starts the generation by Claude (minutes); follow it with [fetch] until it leaves `gerando`.
  Future<Exam> generatePlan(String id) async => Exam.fromJson(await _api.post('$_root/$id/plano') as Doc);

  Future<Exam> replan(String id) async => Exam.fromJson(await _api.post('$_root/$id/replanejar') as Doc);

  Future<void> mark(String id, String task, bool done) =>
      _api.patch('$_root/$id/tarefas/$task', {'feito': done});

  Future<void> addDeadline(String id, Doc due) => _api.post('$_root/$id/prazos', due);

  Future<void> removeDeadline(String id, String due) => _api.delete('$_root/$id/prazos/$due');

  // ---------- rumores ----------
  Future<Rumors> rumors() async => Rumors.fromJson(await _api.get('$_root/rumores') as Doc);

  /// Search by Claude Code in the background; empty [query] = every IT exam.
  Future<void> researchRumors(String query) => _api.post('$_root/rumores/pesquisar', {'consulta': query});

  Future<void> followRumor(String id, bool sim) => _api.put('$_root/rumores/$id/acompanhar', {'acompanhar': sim});

  // ---------- radar ----------
  Future<Radar> radar() async => Radar.fromJson(await _api.get('$_root/radar') as Doc);

  Future<void> refreshRadar() => _api.post('$_root/radar/atualizar');

  /// Web research by Claude Code (open and forecast), in the background.
  Future<void> researchRadarClaude() => _api.post('$_root/radar/claude');

  Future<TravelRoute> route(String item) async => TravelRoute.fromJson(await _api.get('$_root/radar/$item/rota') as Doc);

  /// Becomes a followed exam (downloads the notice and already asks Claude for the flow); returns the id.
  Future<String> follow(String item, String cargo) async =>
      ((await _api.post('$_root/radar/$item/acompanhar', {'cargo': cargo})) as Doc)['id'] as String;

  // ---------- simulados ----------
  Future<(List<MockExam>, Doc)> mockExams(String id) async {
    final r = await _api.get('$_root/$id/simulados') as Doc;
    return ([for (final s in r['simulados'] as List) MockExam.fromJson(s as Doc)], r['desempenho'] as Doc);
  }

  Future<void> newMockExam(String id, int questions, {String discipline = ''}) =>
      _api.post('$_root/$id/simulados', {'questoes': questions, 'disciplina': discipline});

  Future<MockExam> answer(String id, String sid, List<int?> answers, int withSeconds) async => MockExam.fromJson(
    await _api.post('$_root/$id/simulados/$sid/respostas', {'respostas': answers, 'segundos': withSeconds}) as Doc,
  );

  Future<void> deleteMockExam(String id, String sid) => _api.delete('$_root/$id/simulados/$sid');

  // ---------- materiais ----------
  Future<(String, List<StudyMaterial>)> materials(String id) async {
    final r = await _api.get('$_root/$id/materiais') as Doc;
    return (r['estado'] as String, [for (final m in r['itens'] as List) StudyMaterial.fromJson(m as Doc)]);
  }

  Future<void> searchMaterials(String id) => _api.post('$_root/$id/materiais/buscar');
}
