import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

import 'modelos.dart';

/// Rotas de `/api/concursos` do backend da plataforma (`modulos/concursos/backend`).
class ApiConcursos {
  /// [cliente]: troca o HTTP (os testes usam um falso).
  ApiConcursos(String base, {String token = '', http.Client? cliente})
    : _api = ApiCliente(
        base,
        cliente: cliente,
        cabecalhos: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'},
      );

  final ApiCliente _api;
  static const _raiz = 'api/concursos';

  Future<List<ResumoConcurso>> listar() async => [
    for (final j in await _api.get(_raiz) as List) ResumoConcurso.fromJson(j as Doc),
  ];

  Future<List<Alerta>> alertas() async => [
    for (final j in await _api.get('$_raiz/alertas') as List) Alerta.fromJson(j as Doc),
  ];

  Future<Concurso> obter(String id) async => Concurso.fromJson(await _api.get('$_raiz/$id') as Doc);

  Future<Concurso> criar(Doc dados) async => Concurso.fromJson(await _api.post(_raiz, dados) as Doc);

  Future<Concurso> salvar(String id, Doc dados) async =>
      Concurso.fromJson(await _api.patch('$_raiz/$id', dados) as Doc);

  Future<void> excluir(String id) => _api.delete('$_raiz/$id');

  Future<Concurso> enviarEdital(String id, String nome, List<int> bytes) async =>
      Concurso.fromJson(await _api.enviarArquivo('$_raiz/$id/edital', 'arquivo', nome, bytes) as Doc);

  Future<Concurso> editalPorLink(String id, String url) async =>
      Concurso.fromJson(await _api.post('$_raiz/$id/edital/link', {'url': url}) as Doc);

  /// Começa a geração pelo Claude (minutos); acompanhar por [obter] até sair de `gerando`.
  Future<Concurso> gerarPlano(String id) async => Concurso.fromJson(await _api.post('$_raiz/$id/plano') as Doc);

  Future<Concurso> replanejar(String id) async => Concurso.fromJson(await _api.post('$_raiz/$id/replanejar') as Doc);

  Future<void> marcar(String id, String tarefa, bool feito) =>
      _api.patch('$_raiz/$id/tarefas/$tarefa', {'feito': feito});

  Future<void> adicionarPrazo(String id, Doc prazo) => _api.post('$_raiz/$id/prazos', prazo);

  Future<void> removerPrazo(String id, String prazo) => _api.delete('$_raiz/$id/prazos/$prazo');

  // ---------- rumores ----------
  Future<Rumores> rumores() async => Rumores.fromJson(await _api.get('$_raiz/rumores') as Doc);

  /// Busca pelo Claude Code em segundo plano; [consulta] vazia = todos de TI.
  Future<void> pesquisarRumores(String consulta) => _api.post('$_raiz/rumores/pesquisar', {'consulta': consulta});

  Future<void> acompanharRumor(String id, bool sim) => _api.put('$_raiz/rumores/$id/acompanhar', {'acompanhar': sim});

  // ---------- radar ----------
  Future<Radar> radar() async => Radar.fromJson(await _api.get('$_raiz/radar') as Doc);

  Future<void> atualizarRadar() => _api.post('$_raiz/radar/atualizar');

  /// Pesquisa na web pelo Claude Code (abertos e previstos), em segundo plano.
  Future<void> pesquisarRadarClaude() => _api.post('$_raiz/radar/claude');

  Future<Rota> rota(String item) async => Rota.fromJson(await _api.get('$_raiz/radar/$item/rota') as Doc);

  /// Vira um concurso acompanhado (baixa o edital e já pede o fluxo ao Claude); devolve o id.
  Future<String> acompanhar(String item, String cargo) async =>
      ((await _api.post('$_raiz/radar/$item/acompanhar', {'cargo': cargo})) as Doc)['id'] as String;

  // ---------- simulados ----------
  Future<(List<Simulado>, Doc)> simulados(String id) async {
    final r = await _api.get('$_raiz/$id/simulados') as Doc;
    return ([for (final s in r['simulados'] as List) Simulado.fromJson(s as Doc)], r['desempenho'] as Doc);
  }

  Future<void> novoSimulado(String id, int questoes, {String disciplina = ''}) =>
      _api.post('$_raiz/$id/simulados', {'questoes': questoes, 'disciplina': disciplina});

  Future<Simulado> responder(String id, String sid, List<int?> respostas, int segundos) async => Simulado.fromJson(
    await _api.post('$_raiz/$id/simulados/$sid/respostas', {'respostas': respostas, 'segundos': segundos}) as Doc,
  );

  Future<void> excluirSimulado(String id, String sid) => _api.delete('$_raiz/$id/simulados/$sid');

  // ---------- materiais ----------
  Future<(String, List<MaterialEstudo>)> materiais(String id) async {
    final r = await _api.get('$_raiz/$id/materiais') as Doc;
    return (r['estado'] as String, [for (final m in r['itens'] as List) MaterialEstudo.fromJson(m as Doc)]);
  }

  Future<void> buscarMateriais(String id) => _api.post('$_raiz/$id/materiais/buscar');
}
