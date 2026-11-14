import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

import 'formato.dart';

/// Rotas de `/api/financas` no backend da plataforma (local ou VPS, com a chave).
class ApiFinancas {
  /// [cliente]: HTTP de teste (`MockClient`).
  ApiFinancas(String base, {String token = '', http.Client? cliente})
    : _api = ApiCliente(base, cliente: cliente, cabecalhos: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'});

  final ApiCliente _api;

  static const _raiz = 'api/financas';

  String _q(Map<String, String> filtro) => filtro.isEmpty ? '' : '?${Uri(queryParameters: filtro).query}';

  List<Doc> _lista(dynamic j) => [for (final d in j as List) d as Doc];

  // --- CRUD das coleções (contas, categorias, transacoes, regras, metas, programacoes, empresas,
  // setores, operacoes, proventos) ---

  Future<List<Doc>> listar(String colecao, [Map<String, String> filtro = const {}]) async =>
      _lista(await _api.get('$_raiz/$colecao${_q(filtro)}'));

  Future<Doc> obter(String colecao, String id) async => await _api.get('$_raiz/$colecao/$id') as Doc;

  Future<Doc> criar(String colecao, Doc dados) async => await _api.post('$_raiz/$colecao', dados) as Doc;

  Future<Doc> editar(String colecao, String id, Doc dados) async =>
      await _api.patch('$_raiz/$colecao/$id', dados) as Doc;

  Future<void> excluir(String colecao, String id) => _api.delete('$_raiz/$colecao/$id');

  // --- painel ---

  Future<Doc> resumo(String mes) async => await _api.get('$_raiz/resumo?mes=$mes') as Doc;

  Future<List<Doc>> fluxo({int meses = 12, String? ate}) async =>
      _lista(await _api.get('$_raiz/fluxo${_q({'meses': '$meses', 'ate': ?ate})}'));

  Future<Doc> contrapartes({String? de, String? ate}) async =>
      await _api.get('$_raiz/contrapartes${_q({'de': ?de, 'ate': ?ate})}') as Doc;

  Future<Doc> faturas(String contaId) async => await _api.get('$_raiz/faturas/$contaId') as Doc;

  Future<Doc> projecao({int dias = 60}) async => await _api.get('$_raiz/projecao?dias=$dias') as Doc;

  Future<Doc> lancar(String programacaoId, String data) async =>
      await _api.post('$_raiz/programacoes/$programacaoId/lancar', {'data': data}) as Doc;

  Future<List<Doc>> metas() async => _lista(await _api.get('$_raiz/metas/progresso'));

  // --- extrato ---

  /// Importa um extrato (OFX, CSV, XLS/XLSX ou PDF). PDF ou layout desconhecido é lido pela IA:
  /// a resposta vem com `tarefa` e aqui esperamos ela terminar.
  Future<Doc> importar(String contaId, String nome, List<int> bytes, {String provedor = 'local'}) async {
    final r = await _api.enviarArquivo('$_raiz/importar', 'arquivo', nome, bytes,
        campos: {'conta_id': contaId, 'provedor': provedor}) as Doc;
    return r.containsKey('tarefa') ? esperarTarefa(r['tarefa'] as String) : r;
  }

  /// Consulta a tarefa a cada [intervalo] até terminar; devolve o `resultado`. [aoParcial] recebe o
  /// que o servidor já tem enquanto roda (tarefas que preenchem `parcial`).
  Future<Doc> esperarTarefa(String id,
      {bool Function()? cancelado, void Function(Doc)? aoParcial, Duration intervalo = const Duration(seconds: 2)}) async {
    while (true) {
      await Future<void>.delayed(intervalo);
      if (cancelado?.call() ?? false) throw ApiErro(0, 'Cancelado.');
      final t = await _api.get('$_raiz/tarefas/$id') as Doc;
      if (t['estado'] == 'pronto') return t['resultado'] as Doc;
      if (t['parcial'] case final Doc p when p.isNotEmpty) aoParcial?.call(p);
      if (t['estado'] == 'erro') throw ApiErro(422, '${t['erro']}');
    }
  }

  Future<List<String>> provedoresIa() async => [for (final p in await _api.get('$_raiz/ia/provedores') as List) '$p'];

  /// Conserta o que já está gravado (sinal e forma de pagamento do cartão, regras e IA); devolve
  /// `{sinais, formas, categorizadas, categorizadas_ia, sem_categoria}`.
  Future<Doc> corrigir({String provedor = 'local'}) async =>
      esperarTarefa((await _api.post('$_raiz/corrigir?provedor=$provedor') as Doc)['tarefa'] as String);

  /// Categoriza com a IA o que as regras não pegaram; devolve `{analisadas, categorizadas, formas}`.
  Future<Doc> categorizarIa({String provedor = 'local'}) async =>
      esperarTarefa((await _api.post('$_raiz/categorizar-ia?provedor=$provedor') as Doc)['tarefa'] as String);

  Future<List<Doc>> parcelamentos() async => _lista(await _api.get('$_raiz/parcelamentos'));

  /// Juntar × financiar um bem (só contas, sem IA): `valor`, `tipo`, `entrada`, `prazo_meses`, …
  Future<Doc> simular(Doc parametros) async => await _api.post('$_raiz/cenarios/simular', parametros) as Doc;

  /// Pergunta livre: a IA tira os parâmetros, o servidor simula e a IA explica. Devolve
  /// `{parametros, resultado, analise}`.
  Future<Doc> perguntar(String pergunta, {Doc ajustes = const {}, String provedor = 'local', bool Function()? cancelado}) async {
    final t = await _api.post('$_raiz/cenarios/perguntar', {'pergunta': pergunta, 'ajustes': ajustes, 'provedor': provedor}) as Doc;
    return esperarTarefa(t['tarefa'] as String, cancelado: cancelado);
  }

  /// Conversa curta sobre os seus dados (modo rápido do LLM local). [mensagens]: `{role, content}`, a
  /// última é a pergunta; [cenario]: `{pergunta, analise}` da simulação aberta.
  Future<String> conversar(List<Doc> mensagens, {Doc? cenario}) async =>
      (await _api.post('$_raiz/cenarios/conversar', {'mensagens': mensagens, 'cenario': ?cenario}) as Doc)['resposta']
          as String;

  /// Fala → texto pelo Whisper do worker.
  Future<String> transcrever(List<int> wav) => transcreverFala(_api, wav, idioma: 'pt');

  /// Texto → WAV pela voz do worker (Piper).
  Future<Uint8List> falar(String texto) => _api.postBytes('api/painel/falar', {'texto': texto});

  /// Aplica [dados] em todas as [ids]; com [regra], cria a regra para as próximas importações.
  Future<int> lote(List<String> ids, Doc dados, {String? regra}) async =>
      (await _api.post('$_raiz/transacoes/lote', {'ids': ids, 'dados': dados, 'regra': ?regra}) as Doc)['alteradas']
          as int;

  /// Exclui várias [ids] de [colecao] numa chamada (até 500; para mais, usar `executarEmLotes`).
  Future<int> excluirLote(String colecao, List<String> ids) async =>
      (await _api.post('$_raiz/$colecao/excluir-lote', {'ids': ids}) as Doc)['excluidas'] as int;

  Future<int> aplicarRegras() async => (await _api.post('$_raiz/regras/aplicar') as Doc)['categorizadas'] as int;

  // --- mercado em tempo real e CVM ---

  /// 10 maiores altas e baixas do dia (`fund` = FIIs/fundos).
  Future<Doc> destaques({String tipo = 'stock'}) async => await _api.get('$_raiz/mercado/destaques?tipo=$tipo') as Doc;

  /// Manchetes do dia: `economia`, `acoes`, `fiis`, `impostos` ou `juros`.
  Future<Doc> noticias({String tema = 'economia'}) async => await _api.get('$_raiz/mercado/noticias?tema=$tema') as Doc;

  /// Ticker ou nome: ação (cotação, DRE/balanço da CVM, links) ou FII (informe mensal, DY, P/VP).
  /// [aoParcial] recebe a ficha incompleta (cadastro primeiro; `carregando` lista o que falta).
  Future<Doc> ativo(String q, {bool Function()? cancelado, void Function(Doc)? aoParcial}) async {
    final t = await _api.post('$_raiz/mercado/ativo', {'q': q}) as Doc;
    return esperarTarefa(t['tarefa'] as String,
        cancelado: cancelado, aoParcial: aoParcial, intervalo: const Duration(milliseconds: 700));
  }

  /// Busca enquanto digita (ações e FIIs): ticker pelo começo, nome, apelido e nome parecido.
  Future<List<Doc>> sugerir(String q) async =>
      _lista(await _api.get('$_raiz/mercado/sugerir${_q({'q': q})}'));

  // --- estudos de finanças ---

  Future<Doc> estudo({String? objetivo}) async => await _api.get('$_raiz/estudo${_q({'objetivo': ?objetivo})}') as Doc;

  Future<Doc> estudoObjetivo(String objetivo) async =>
      await _api.put('$_raiz/estudo/objetivo', {'objetivo': objetivo}) as Doc;

  /// [item]: `etapa:<id>`, `livro:<id>`, `cap:<livro>:<n>`, `artigo:<id>` ou `relatorio:<id>`.
  Future<void> estudoMarcar(String item, {String? status, String? nota}) =>
      _api.patch('$_raiz/estudo/itens', {'item': item, 'status': ?status, 'nota': ?nota});

  Future<void> estudoTenho(String livroId, bool tenho) => _api.put('$_raiz/estudo/livros/$livroId/tenho', {'tenho': tenho});

  Future<Doc> estudoNovoLivro(String titulo, String autor) async =>
      await _api.post('$_raiz/estudo/livros', {'titulo': titulo, 'autor': autor}) as Doc;

  /// O Claude monta o guia de leitura (capítulos, ordem, por quê); devolve o livro com o guia.
  Future<Doc> estudoGuia(String livroId, {bool Function()? cancelado}) async {
    final t = await _api.post('$_raiz/estudo/livros/$livroId/guia') as Doc;
    return esperarTarefa(t['tarefa'] as String, cancelado: cancelado, intervalo: const Duration(seconds: 4));
  }

  /// Põe o livro/artigo em Estudos › Leituras e garante o projeto "Trilha de Finanças".
  Future<Doc> estudoLer(String item) async => await _api.post('$_raiz/estudo/ler', {'item': item}) as Doc;

  /// Grifos e comentários do projeto "Trilha de Finanças", por obra.
  Future<Doc> estudoCitacoes() async => await _api.get('$_raiz/estudo/citacoes') as Doc;

  /// Preenche DRE, balanço e fluxo (6 anos) da empresa pela CVM; devolve a empresa atualizada.
  Future<Doc> importarCvm(String empresaId) async {
    final t = await _api.post('$_raiz/empresas/$empresaId/importar-cvm') as Doc;
    return (await esperarTarefa(t['tarefa'] as String))['empresa'] as Doc;
  }

  /// Baixa o documento da CVM pela VPS (release, apresentação ou o PDF de dentro do pacote DFP/ITR)
  /// para o módulo Arquivos (`Finanças/<ticker>`); devolve o arquivo guardado (`id` para abrir).
  Future<Doc> guardarDocumento(String url, String titulo, String ticker, {bool Function()? cancelado}) async {
    final t = await _api.post('$_raiz/mercado/guardar', {'url': url, 'titulo': titulo, 'ticker': ticker}) as Doc;
    return (await esperarTarefa(t['tarefa'] as String, cancelado: cancelado))['arquivo'] as Doc;
  }

  // --- investimentos ---

  Future<List<Doc>> questionario() async => _lista(await _api.get('$_raiz/questionario'));

  Future<List<Doc>> salvarQuestionario(List<Doc> perguntas) async =>
      _lista(await _api.put('$_raiz/questionario', perguntas));

  Future<List<Doc>> ranking() async => _lista(await _api.get('$_raiz/empresas/ranking'));

  Future<Doc> analise(String empresaId) async => await _api.get('$_raiz/empresas/$empresaId/analise') as Doc;

  Future<Doc> analiseSetor(String setorId) async => await _api.get('$_raiz/setores/$setorId/analise') as Doc;

  Future<Doc> carteira() async => await _api.get('$_raiz/carteira') as Doc;
}
