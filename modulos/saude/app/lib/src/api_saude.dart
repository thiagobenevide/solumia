import 'package:agent_core/agent_core.dart';
import 'package:agent_notas/agent_notas.dart';
import 'package:http/http.dart' as http;

import 'datas.dart';
import 'modelos.dart';
import 'sessao.dart';

/// Rotas de `/api/saude` no backend da plataforma (local ou VPS, com a chave).
class ApiSaude {
  /// [cliente]: troca o HTTP (os testes usam um falso).
  ApiSaude(String base, {String token = '', http.Client? cliente})
    : _api = ApiCliente(
        base,
        cliente: cliente,
        cabecalhos: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'},
      ),
      notas = ApiNotas(base, token: token);

  final ApiCliente _api;

  /// Reflexões e estudos de teologia são notas do vault.
  final ApiNotas notas;

  Map<String, String> get cabecalhos => _api.cabecalhos;

  /// Áreas do corpo (na ordem da biblioteca) e todos os exercícios.
  Future<(List<String>, List<Exercicio>)> exercicios() async {
    final j = await _api.get('api/saude/exercicios') as Map<String, dynamic>;
    return (
      [...(j['areas'] as List).cast<String>()],
      [for (final e in j['exercicios'] as List) Exercicio.fromJson(e)],
    );
  }

  Future<Exercicio> criarExercicio(Map<String, dynamic> dados) async =>
      Exercicio.fromJson(await _api.post('api/saude/exercicios', dados));

  Future<Exercicio> editarExercicio(String id, Map<String, dynamic> dados) async =>
      Exercicio.fromJson(await _api.patch('api/saude/exercicios/$id', dados));

  Future<void> excluirExercicio(String id) => _api.delete('api/saude/exercicios/$id');

  /// [n] 0 = início do movimento, 1 = fim. [versao] força recarregar depois de trocar a foto.
  Uri urlImagem(String id, {int n = 0, int versao = 0}) => _api.url('api/saude/exercicios/$id/imagem?n=$n&v=$versao');

  Future<Exercicio> enviarImagem(String id, String nome, List<int> bytes) async =>
      Exercicio.fromJson(await _api.enviarArquivo('api/saude/exercicios/$id/imagem', 'arquivo', nome, bytes));

  Future<Exercicio> removerImagem(String id) async =>
      Exercicio.fromJson(await _api.delete('api/saude/exercicios/$id/imagem'));

  Future<List<ItemAgenda>> agenda(DateTime de, DateTime ate) async => [
    for (final j in await _api.get('api/saude/agenda?de=${iso(de)}&ate=${iso(ate)}') as List) ItemAgenda.fromJson(j),
  ];

  Future<ItemAgenda> marcar(DateTime data, String exercicioId) async =>
      ItemAgenda.fromJson(await _api.post('api/saude/agenda', {'data': iso(data), 'exercicio_id': exercicioId}));

  Future<ItemAgenda> editarItem(String id, Map<String, dynamic> dados) async =>
      ItemAgenda.fromJson(await _api.patch('api/saude/agenda/$id', dados));

  Future<void> desmarcar(String id) => _api.delete('api/saude/agenda/$id');

  // --- guia de treino ---

  SessaoTreino _sessao(dynamic j) => SessaoTreino.fromJson(j as Map<String, dynamic>);

  Future<SessaoTreino?> sessaoAtiva() async {
    final j = await _api.get('api/saude/sessoes/ativa');
    return j == null ? null : _sessao(j);
  }

  Future<SessaoTreino> iniciarSessao(DateTime dia, {int descansoS = 60}) async =>
      _sessao(await _api.post('api/saude/sessoes', {'data': iso(dia), 'descanso_s': descansoS}));

  Future<SessaoTreino> sessao(String id) async => _sessao(await _api.get('api/saude/sessoes/$id'));

  /// [acao]: concluir_serie, pausar, continuar, pular_descanso, somar_descanso, ir_para,
  /// pular_exercicio, desfazer_serie, editar_serie, descanso_padrao.
  Future<SessaoTreino> comandoSessao(String id, String acao, [Map<String, dynamic> dados = const {}]) async =>
      _sessao(await _api.post('api/saude/sessoes/$id/comando', {'acao': acao, ...dados}));

  Future<SessaoTreino> concluirSessao(String id, Map<String, dynamic> dados) async =>
      _sessao(await _api.post('api/saude/sessoes/$id/concluir', dados));

  Future<SessaoTreino> editarSessao(String id, Map<String, dynamic> dados) async =>
      _sessao(await _api.patch('api/saude/sessoes/$id', dados));

  Future<void> excluirSessao(String id) => _api.delete('api/saude/sessoes/$id');

  /// Copia [de]..[ate] para o período que começa em [destino].
  Future<void> copiar(DateTime de, DateTime ate, DateTime destino) =>
      _api.post('api/saude/agenda/copiar', {'de': iso(de), 'ate': iso(ate), 'destino': iso(destino)});

  // --- mental ---

  Future<List<Map<String, dynamic>>> habitos(DateTime de, DateTime ate) async =>
      [...(await _api.get('api/saude/mental/habitos?de=${iso(de)}&ate=${iso(ate)}') as List).cast<Map<String, dynamic>>()];

  Future<void> criarHabito(Map<String, dynamic> dados) => _api.post('api/saude/mental/habitos', dados);

  Future<void> editarHabito(String id, Map<String, dynamic> dados) => _api.patch('api/saude/mental/habitos/$id', dados);

  Future<void> excluirHabito(String id) => _api.delete('api/saude/mental/habitos/$id');

  Future<void> marcarHabito(String id, DateTime dia, bool feito) =>
      _api.post('api/saude/mental/habitos/$id/marcar', {'data': iso(dia), 'feito': feito});

  Future<Map<String, dynamic>> foco(DateTime de, DateTime ate) async =>
      await _api.get('api/saude/mental/foco?de=${iso(de)}&ate=${iso(ate)}') as Map<String, dynamic>;

  Future<void> registrarFoco(Map<String, dynamic> sessao) => _api.post('api/saude/mental/foco', sessao);

  Future<List<Map<String, dynamic>>> diario(DateTime de, DateTime ate) async =>
      [...(await _api.get('api/saude/mental/diario?de=${iso(de)}&ate=${iso(ate)}') as List).cast<Map<String, dynamic>>()];

  Future<void> salvarDia(DateTime dia, Map<String, dynamic> dados) => _api.put('api/saude/mental/diario/${iso(dia)}', dados);

  // --- relógio (Galaxy Watch via Samsung Health) ---

  Future<List<Map<String, dynamic>>> diasRelogio(DateTime de, DateTime ate) async =>
      [...(await _api.get('api/saude/relogio/dias?de=${iso(de)}&ate=${iso(ate)}') as List).cast<Map<String, dynamic>>()];

  Future<Map<String, dynamic>> resumoRelogio(DateTime de, DateTime ate) async =>
      await _api.get('api/saude/relogio/resumo?de=${iso(de)}&ate=${iso(ate)}') as Map<String, dynamic>;

  /// Última sincronização de cada origem (`health_connect`, `exportacao`), em ISO UTC.
  Future<Map<String, dynamic>> estadoRelogio() async =>
      await _api.get('api/saude/relogio/estado') as Map<String, dynamic>;

  /// Dias somados do Health Connect; o backend substitui os valores guardados.
  Future<void> enviarDiasRelogio(List<Map<String, dynamic>> dias) => _api.put('api/saude/relogio/dias', {'dias': dias});

  /// Zip de Samsung Health › Configurações › Baixar dados pessoais.
  Future<Map<String, dynamic>> importarSamsung(String nome, List<int> bytes) async =>
      await _api.enviarArquivo('api/saude/relogio/importar', 'arquivo', nome, bytes) as Map<String, dynamic>;

  Future<List<Map<String, dynamic>>> analises() async =>
      [...(await _api.get('api/saude/relogio/analises') as List).cast<Map<String, dynamic>>()];

  /// Pede à LLM local (worker do PC) a análise dos últimos [dias]; demora.
  Future<Map<String, dynamic>> analisar(int dias, String pergunta) async =>
      await _api.post('api/saude/relogio/analises', {'dias': dias, 'pergunta': pergunta}) as Map<String, dynamic>;

  // --- consumo (controle de redes sociais e conteúdo nos aparelhos Android) ---

  Future<Map<String, dynamic>> consumoConfig() async =>
      await _api.get('api/saude/consumo/config') as Map<String, dynamic>;

  Future<Map<String, dynamic>> definirRegra(String categoria, Map<String, dynamic> regra) async =>
      await _api.put('api/saude/consumo/regras/$categoria', regra) as Map<String, dynamic>;

  Future<Map<String, dynamic>> definirApp(String pacote, String nome, String categoria) async => await _api
      .put('api/saude/consumo/apps', {'pacote': pacote, 'nome': nome, 'categoria': categoria}) as Map<String, dynamic>;

  Future<Map<String, dynamic>> removerApp(String pacote) async =>
      await _api.delete('api/saude/consumo/apps/$pacote') as Map<String, dynamic>;

  Future<Map<String, dynamic>> incluirDominio(String categoria, String dominio) async => await _api
      .post('api/saude/consumo/dominios/$categoria', {'dominio': dominio}) as Map<String, dynamic>;

  Future<Map<String, dynamic>> removerDominio(String categoria, String dominio) async => await _api.delete(
    'api/saude/consumo/dominios/$categoria/${Uri.encodeComponent(dominio)}',
  ) as Map<String, dynamic>;

  Future<Map<String, dynamic>> definirProtecao(bool ativa) async =>
      await _api.put('api/saude/consumo/protecao', {'ativa': ativa}) as Map<String, dynamic>;

  Future<void> cancelarPendencia(String id) => _api.delete('api/saude/consumo/pendencias/$id');

  Future<List<Map<String, dynamic>>> dispositivos() async =>
      [...(await _api.get('api/saude/consumo/dispositivos') as List).cast<Map<String, dynamic>>()];

  /// Este aparelho manda o uso/eventos e recebe as regras já montadas para aplicar.
  Future<Map<String, dynamic>> sincronizarConsumo(Map<String, dynamic> dados) async =>
      await _api.post('api/saude/consumo/sincronizar', dados) as Map<String, dynamic>;

  Future<Map<String, dynamic>> resumoConsumo(DateTime de, DateTime ate) async =>
      await _api.get('api/saude/consumo/resumo?de=${iso(de)}&ate=${iso(ate)}') as Map<String, dynamic>;

  Future<List<Map<String, dynamic>>> analisesConsumo() async =>
      [...(await _api.get('api/saude/consumo/analises') as List).cast<Map<String, dynamic>>()];

  /// Pede ao "vigia" (LLM local) a leitura dos últimos [dias]; demora.
  Future<Map<String, dynamic>> analisarConsumo(int dias, String pergunta) async =>
      await _api.post('api/saude/consumo/analises', {'dias': dias, 'pergunta': pergunta}) as Map<String, dynamic>;

  // --- espiritual ---

  Future<List<Map<String, dynamic>>> escopos() async =>
      [...(await _api.get('api/saude/espiritual/escopos') as List).cast<Map<String, dynamic>>()];

  Future<List<Map<String, dynamic>>> planos() async =>
      [...(await _api.get('api/saude/espiritual/planos') as List).cast<Map<String, dynamic>>()];

  Future<Map<String, dynamic>> criarPlano(Map<String, dynamic> dados) async =>
      await _api.post('api/saude/espiritual/planos', dados) as Map<String, dynamic>;

  Future<void> excluirPlano(String id) => _api.delete('api/saude/espiritual/planos/$id');

  Future<List<Map<String, dynamic>>> leiturasDoPlano(String id, DateTime de, DateTime ate) async => [
    ...(await _api.get('api/saude/espiritual/planos/$id/leituras?de=${iso(de)}&ate=${iso(ate)}') as List)
        .cast<Map<String, dynamic>>(),
  ];

  Future<void> marcarLeitura(String id, DateTime dia, bool feito) =>
      _api.post('api/saude/espiritual/planos/$id/marcar', {'data': iso(dia), 'feito': feito});

  /// Notas do vault com a tag (ex.: `reflexao`, `teologia`), mais recentes primeiro.
  Future<List<NotaResumo>> notasComTag(String tag) async => [
    for (final j in await _api.get('api/notas?tag=${Uri.encodeQueryComponent(tag)}') as List) NotaResumo.fromJson(j),
  ]..sort((a, b) => (b.atualizada ?? DateTime(0)).compareTo(a.atualizada ?? DateTime(0)));
}
