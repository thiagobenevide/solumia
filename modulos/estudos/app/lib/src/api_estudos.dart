import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';
import 'package:agent_notas/agent_notas.dart';
import 'package:http/http.dart' as http;

import 'modelos.dart';
import 'modelos_conhecimento.dart';

String iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Rotas de `/api/estudos` e o grafo de `/api/notas/grafo`. [notas] abre e cria as notas de síntese.
class ApiEstudos {
  /// [cliente]: troca o HTTP (os testes usam um falso).
  ApiEstudos(String base, {String token = '', http.Client? cliente})
    : _api = ApiCliente(
        base,
        cliente: cliente,
        cabecalhos: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'},
      ),
      notas = ApiNotas(base, token: token);

  final ApiCliente _api;
  final ApiNotas notas;

  Future<Opcoes> opcoes() async => Opcoes.fromJson(await _api.get('api/estudos/opcoes'));

  Future<List<Leitura>> leituras() async => [
    for (final j in await _api.get('api/estudos/leituras') as List) Leitura.fromJson(j),
  ];

  Future<Leitura> criarLeitura(Map<String, dynamic> dados) async =>
      Leitura.fromJson(await _api.post('api/estudos/leituras', dados));

  Future<Leitura> editarLeitura(String id, Map<String, dynamic> dados) async =>
      Leitura.fromJson(await _api.patch('api/estudos/leituras/$id', dados));

  Future<void> excluirLeitura(String id) => _api.delete('api/estudos/leituras/$id');

  Future<List<Trilha>> trilhas() async => [
    for (final j in await _api.get('api/estudos/idiomas') as List) Trilha.fromJson(j),
  ];

  Future<Trilha> criarTrilha(Map<String, dynamic> dados) async =>
      Trilha.fromJson(await _api.post('api/estudos/idiomas', dados));

  Future<Trilha> editarTrilha(String id, Map<String, dynamic> dados) async =>
      Trilha.fromJson(await _api.patch('api/estudos/idiomas/$id', dados));

  Future<void> excluirTrilha(String id) => _api.delete('api/estudos/idiomas/$id');

  Future<List<DiaEstudo>> cronograma(String id, DateTime de, DateTime ate) async => [
    for (final j in await _api.get('api/estudos/idiomas/$id/cronograma?de=${iso(de)}&ate=${iso(ate)}') as List)
      DiaEstudo.fromJson(j),
  ];

  /// Minutos estudados no dia (0 desfaz).
  Future<Trilha> registrar(String id, DateTime dia, int minutos) async =>
      Trilha.fromJson(await _api.post('api/estudos/idiomas/$id/sessoes', {'data': iso(dia), 'minutos': minutos}));

  Future<List<TrilhaConhecimento>> trilhasConhecimento() async => [
    for (final j in await _api.get('api/estudos/conhecimento/trilhas') as List) TrilhaConhecimento.fromJson(j),
  ];

  /// A trilha com as etapas; [frente] (Back-end, Dados…) filtra a mesma sequência.
  Future<TrilhaConhecimento> trilhaConhecimento(String id, {String? frente}) async => TrilhaConhecimento.fromJson(
    await _api.get(
      'api/estudos/conhecimento/trilhas/$id${frente == null ? '' : '?frente=${Uri.encodeQueryComponent(frente)}'}',
    ),
  );

  /// `leitura` (índice) + `feita`, `pratica` e/ou `nota_id`.
  Future<EtapaTrilha> marcarEtapa(String trilha, String etapa, Map<String, dynamic> dados) async =>
      EtapaTrilha.fromJson(await _api.post('api/estudos/conhecimento/trilhas/$trilha/etapas/$etapa', dados));

  Future<List<LivroTrilha>> estante() async => [
    for (final j in await _api.get('api/estudos/conhecimento/livros') as List) LivroTrilha.fromJson(j),
  ];

  Future<LivroTrilha> marcarLivro(String id, bool tenho) async =>
      LivroTrilha.fromJson(await _api.patch('api/estudos/conhecimento/livros/$id', {'tenho': tenho}));

  /// Liga o livro a uma leitura (cria se não houver), onde se anexa o PDF e se grifa.
  Future<LivroTrilha> ligarLeitura(String id) async =>
      LivroTrilha.fromJson(await _api.post('api/estudos/conhecimento/livros/$id/leitura', {}));

  Future<List<ProjetoLeitura>> projetos() async => [
    for (final j in await _api.get('api/estudos/projetos') as List) ProjetoLeitura.fromJson(j),
  ];

  Future<ProjetoLeitura> criarProjeto(Map<String, dynamic> dados) async =>
      ProjetoLeitura.fromJson(await _api.post('api/estudos/projetos', dados));

  Future<ProjetoLeitura> editarProjeto(String id, Map<String, dynamic> dados) async =>
      ProjetoLeitura.fromJson(await _api.patch('api/estudos/projetos/$id', dados));

  Future<void> excluirProjeto(String id) => _api.delete('api/estudos/projetos/$id');

  Future<Matriz> matriz(String id) async => Matriz.fromJson(await _api.get('api/estudos/projetos/$id/matriz'));

  /// Seção, tipo de citação/conteúdo, palavras-chave, status de uso, paráfrase e observações.
  Future<void> classificar(String projetoId, String itemId, Map<String, String> dados) =>
      _api.patch('api/estudos/projetos/$projetoId/itens/${Uri.encodeComponent(itemId)}', dados);

  /// Planilha `.xlsx` da matriz (Trabalhos, Trechos, Painel e Referências).
  Future<Uint8List> exportarProjeto(String id) => _api.getBytes('api/estudos/projetos/$id/exportar');

  /// Estado do mapeamento reverso de citações do documento do projeto (vazio se nunca rodou).
  Future<Map<String, dynamic>> mapeamento(String id) async =>
      (await _api.get('api/estudos/projetos/$id/mapeamento') as Map).cast<String, dynamic>();

  /// Envia o documento pronto (.docx): fica nos Arquivos e o Claude mapeia as citações.
  Future<Map<String, dynamic>> anexarDocumento(String id, String nome, List<int> bytes) async =>
      (await _api.enviarArquivo('api/estudos/projetos/$id/documento', 'arquivo', nome, bytes) as Map)
          .cast<String, dynamic>();

  /// Roda de novo o mapeamento (depois de baixar os PDFs pendentes).
  Future<Map<String, dynamic>> refazerMapeamento(String id) async =>
      (await _api.post('api/estudos/projetos/$id/mapeamento', {}) as Map).cast<String, dynamic>();

  // --- Linguagem (`/api/estudos/linguagem`): LLM local e voz do worker, nunca o Claude ---

  Future<dynamic> _lg(String caminho, [Object? corpo]) =>
      corpo == null ? _api.get('api/estudos/linguagem/$caminho') : _api.post('api/estudos/linguagem/$caminho', corpo);

  List<Map<String, dynamic>> _lista(Object? j) => [for (final x in j as List) (x as Map).cast<String, dynamic>()];
  Map<String, dynamic> _mapa(Object? j) => (j as Map).cast<String, dynamic>();

  Future<Map<String, dynamic>> fala(String texto, String idioma, {double velocidade = 1}) async =>
      _mapa(await _lg('fala', {'texto': texto, 'idioma': idioma, 'velocidade': velocidade}));

  Future<List<Map<String, dynamic>>> vocabulario(String idioma, {bool devidas = false}) async =>
      _lista(await _lg('vocabulario?idioma=$idioma&devidas=$devidas'));

  Future<Map<String, dynamic>> criarPalavra(Map<String, dynamic> dados) async => _mapa(await _lg('vocabulario', dados));

  Future<Map<String, dynamic>> gerarPratica(String id) async => _mapa(await _lg('vocabulario/$id/gerar', {}));

  /// [nota] 1 errei, 2 difícil, 3 bom, 4 fácil (FSRS).
  Future<Map<String, dynamic>> revisarPalavra(String id, int nota) async =>
      _mapa(await _lg('vocabulario/$id/revisar', {'nota': nota}));

  /// `{correcao, item}`: a correção da resposta e a palavra com a próxima revisão.
  Future<Map<String, dynamic>> responderExercicio(String id, int indice, String resposta) async =>
      _mapa(await _lg('vocabulario/$id/responder', {'indice': indice, 'resposta': resposta}));

  Future<void> excluirPalavra(String id) => _api.delete('api/estudos/linguagem/vocabulario/$id');

  Future<List<Map<String, dynamic>>> escritas(String idioma) async => _lista(await _lg('escritas?idioma=$idioma'));

  Future<Map<String, dynamic>> criarEscrita(Map<String, dynamic> dados) async => _mapa(await _lg('escritas', dados));

  Future<Map<String, dynamic>> responderEscrita(String id, int indice, String resposta) async =>
      _mapa(await _lg('escritas/$id/responder', {'indice': indice, 'resposta': resposta}));

  Future<void> excluirEscrita(String id) => _api.delete('api/estudos/linguagem/escritas/$id');

  Future<List<Map<String, dynamic>>> leiturasVoz(String idioma) async => _lista(await _lg('leituras-voz?idioma=$idioma'));

  Future<Map<String, dynamic>> avaliarLeitura(List<int> wav, String idioma, String referencia) async => _mapa(
    await _api.enviarArquivo(
      'api/estudos/linguagem/leituras-voz',
      'audio',
      'leitura.wav',
      wav,
      campos: {'idioma': idioma, 'referencia': referencia},
    ),
  );

  Future<void> excluirLeituraVoz(String id) => _api.delete('api/estudos/linguagem/leituras-voz/$id');

  Future<void> registrarAtividade(String tipo, String idioma, int minutos) =>
      _lg('atividades', {'tipo': tipo, 'idioma': idioma, 'minutos': minutos});

  Future<Map<String, dynamic>> progresso(String idioma) async => _mapa(await _lg('progresso?idioma=$idioma'));

  Future<(List<NoGrafo>, List<Aresta>)> grafo() async {
    final j = await _api.get('api/notas/grafo') as Map<String, dynamic>;
    return (
      [for (final n in j['nos'] as List) NoGrafo.fromJson(n)],
      [for (final a in j['arestas'] as List) Aresta.fromJson(a)],
    );
  }
}
