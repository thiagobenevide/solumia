import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';
import 'package:http/http.dart' as http;

import 'format.dart';

/// Routes of `/api/financas` in the platform backend (local or VPS, with the key).
class FinanceApi {
  /// [client]: test HTTP client (`MockClient`).
  FinanceApi(String base, {String token = '', http.Client? cliente})
    : _api = ApiCliente(base, cliente: cliente, cabecalhos: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'});

  final ApiCliente _api;

  static const _root = 'api/financas';

  String _q(Map<String, String> filter) => filter.isEmpty ? '' : '?${Uri(queryParameters: filter).query}';

  List<Doc> _list(dynamic j) => [for (final d in j as List) d as Doc];

  // --- CRUD of the collections (contas, categorias, transacoes, regras, metas, programacoes, empresas,
  // setores, operacoes, proventos) ---

  Future<List<Doc>> list(String collection, [Map<String, String> filter = const {}]) async =>
      _list(await _api.get('$_root/$collection${_q(filter)}'));

  Future<Doc> fetch(String collection, String id) async => await _api.get('$_root/$collection/$id') as Doc;

  Future<Doc> create(String collection, Doc data) async => await _api.post('$_root/$collection', data) as Doc;

  Future<Doc> edit(String collection, String id, Doc data) async =>
      await _api.patch('$_root/$collection/$id', data) as Doc;

  Future<void> delete(String collection, String id) => _api.delete('$_root/$collection/$id');

  // --- painel ---

  Future<Doc> summary(String mes) async => await _api.get('$_root/resumo?mes=$mes') as Doc;

  Future<List<Doc>> flow({int months = 12, String? ate}) async =>
      _list(await _api.get('$_root/fluxo${_q({'meses': '$months', 'ate': ?ate})}'));

  Future<Doc> counterparties({String? de, String? ate}) async =>
      await _api.get('$_root/contrapartes${_q({'de': ?de, 'ate': ?ate})}') as Doc;

  Future<Doc> invoices(String accountId) async => await _api.get('$_root/faturas/$accountId') as Doc;

  Future<Doc> projection({int days = 60}) async => await _api.get('$_root/projecao?dias=$days') as Doc;

  Future<Doc> post(String scheduleId, String data) async =>
      await _api.post('$_root/programacoes/$scheduleId/lancar', {'data': data}) as Doc;

  Future<List<Doc>> goals() async => _list(await _api.get('$_root/metas/progresso'));

  // --- extrato ---

  /// Imports a statement (OFX, CSV, XLS/XLSX or PDF). A PDF or unknown layout is read by the AI:
  /// the reply comes with `tarefa` and here we wait for it to finish.
  Future<Doc> importFile(String accountId, String name, List<int> bytes, {String provider = 'local'}) async {
    final r = await _api.enviarArquivo('$_root/importar', 'arquivo', name, bytes,
        campos: {'conta_id': accountId, 'provedor': provider}) as Doc;
    return r.containsKey('tarefa') ? waitForTask(r['tarefa'] as String) : r;
  }

  /// Polls the task every [intervalo] until it finishes; returns the `resultado`. [onPartial] gets
  /// what the server already has while it runs (tasks that fill `parcial`).
  Future<Doc> waitForTask(String id,
      {bool Function()? isCancelled, void Function(Doc)? onPartial, Duration intervalo = const Duration(seconds: 2)}) async {
    while (true) {
      await Future<void>.delayed(intervalo);
      if (isCancelled?.call() ?? false) throw ApiErro(0, 'Cancelado.');
      final t = await _api.get('$_root/tarefas/$id') as Doc;
      if (t['estado'] == 'pronto') return t['resultado'] as Doc;
      if (t['parcial'] case final Doc p when p.isNotEmpty) onPartial?.call(p);
      if (t['estado'] == 'erro') throw ApiErro(422, '${t['erro']}');
    }
  }

  Future<List<String>> aiProviders() async => [for (final p in await _api.get('$_root/ia/provedores') as List) '$p'];

  /// Fixes what is already saved (sign and payment method of the card, rules and AI); returns
  /// `{sinais, formas, categorizadas, categorizadas_ia, sem_categoria}`.
  Future<Doc> correct({String provider = 'local'}) async =>
      waitForTask((await _api.post('$_root/corrigir?provedor=$provider') as Doc)['tarefa'] as String);

  /// Categorizes with the AI what the rules did not catch; returns `{analisadas, categorizadas, formas}`.
  Future<Doc> categorizeAi({String provider = 'local'}) async =>
      waitForTask((await _api.post('$_root/categorizar-ia?provedor=$provider') as Doc)['tarefa'] as String);

  Future<List<Doc>> installments() async => _list(await _api.get('$_root/parcelamentos'));

  /// Save up × finance an item (math only, no AI): `valor`, `tipo`, `entrada`, `prazo_meses`, …
  Future<Doc> simulate(Doc parameters) async => await _api.post('$_root/cenarios/simular', parameters) as Doc;

  /// Free question: the AI extracts the parameters, the server simulates and the AI explains. Returns
  /// `{parametros, resultado, analise}`.
  Future<Doc> ask(String question, {Doc adjustments = const {}, String provider = 'local', bool Function()? isCancelled}) async {
    final t = await _api.post('$_root/cenarios/perguntar', {'pergunta': question, 'ajustes': adjustments, 'provedor': provider}) as Doc;
    return waitForTask(t['tarefa'] as String, isCancelled: isCancelled);
  }

  /// Short chat about your data (fast mode of the local LLM). [messages]: `{role, content}`, the
  /// last one is the question; [scenario]: `{pergunta, analise}` of the open simulation.
  Future<String> chat(List<Doc> messages, {Doc? scenario}) async =>
      (await _api.post('$_root/cenarios/conversar', {'mensagens': messages, 'cenario': ?scenario}) as Doc)['resposta']
          as String;

  /// Speech → text with the worker's Whisper.
  Future<String> transcrever(List<int> wav) => transcreverFala(_api, wav, idioma: 'pt');

  /// Text → WAV with the worker's voice (Piper).
  Future<Uint8List> speak(String text) => _api.postBytes('api/painel/falar', {'texto': text});

  /// Applies [data] to all the [ids]; with [rule], creates the rule for the next imports.
  Future<int> batch(List<String> ids, Doc data, {String? rule}) async =>
      (await _api.post('$_root/transacoes/lote', {'ids': ids, 'dados': data, 'regra': ?rule}) as Doc)['alteradas']
          as int;

  /// Deletes several [ids] of [collection] in one call (up to 500; for more, use `executarEmLotes`).
  Future<int> deleteBatch(String collection, List<String> ids) async =>
      (await _api.post('$_root/$collection/excluir-lote', {'ids': ids}) as Doc)['excluidas'] as int;

  Future<int> applyRules() async => (await _api.post('$_root/regras/aplicar') as Doc)['categorizadas'] as int;

  // --- real-time market and CVM ---

  /// Top 10 gainers and losers of the day (`fund` = FIIs/funds).
  Future<Doc> highlights({String type = 'stock'}) async => await _api.get('$_root/mercado/destaques?tipo=$type') as Doc;

  /// Headlines of the day: `economia`, `acoes`, `fiis`, `impostos` or `juros`.
  Future<Doc> news({String topic = 'economia'}) async => await _api.get('$_root/mercado/noticias?tema=$topic') as Doc;

  /// Ticker or name: stock (quote, CVM income statement/balance sheet, links) or FII (monthly report, DY, P/VP).
  /// [onPartial] gets the incomplete sheet (registration first; `carregando` lists what is missing).
  Future<Doc> asset(String q, {bool Function()? isCancelled, void Function(Doc)? onPartial}) async {
    final t = await _api.post('$_root/mercado/ativo', {'q': q}) as Doc;
    return waitForTask(t['tarefa'] as String,
        isCancelled: isCancelled, onPartial: onPartial, intervalo: const Duration(milliseconds: 700));
  }

  /// Search while typing (stocks and FIIs): ticker by prefix, name, nickname and similar name.
  Future<List<Doc>> suggest(String q) async =>
      _list(await _api.get('$_root/mercado/sugerir${_q({'q': q})}'));

  // --- finance studies ---

  Future<Doc> study({String? objective}) async => await _api.get('$_root/estudo${_q({'objetivo': ?objective})}') as Doc;

  Future<Doc> studyObjective(String objective) async =>
      await _api.put('$_root/estudo/objetivo', {'objetivo': objective}) as Doc;

  /// [item]: `etapa:<id>`, `livro:<id>`, `cap:<livro>:<n>`, `artigo:<id>` or `relatorio:<id>`.
  Future<void> studyMark(String item, {String? status, String? note}) =>
      _api.patch('$_root/estudo/itens', {'item': item, 'status': ?status, 'nota': ?note});

  Future<void> studyOwned(String bookId, bool owned) => _api.put('$_root/estudo/livros/$bookId/tenho', {'tenho': owned});

  Future<Doc> studyNewBook(String title, String author) async =>
      await _api.post('$_root/estudo/livros', {'titulo': title, 'autor': author}) as Doc;

  /// Claude builds the reading guide (chapters, order, why); returns the book with the guide.
  Future<Doc> studyGuide(String bookId, {bool Function()? isCancelled}) async {
    final t = await _api.post('$_root/estudo/livros/$bookId/guia') as Doc;
    return waitForTask(t['tarefa'] as String, isCancelled: isCancelled, intervalo: const Duration(seconds: 4));
  }

  /// Puts the book/article in Estudos › Leituras and ensures the "Trilha de Finanças" project.
  Future<Doc> studyRead(String item) async => await _api.post('$_root/estudo/ler', {'item': item}) as Doc;

  /// Highlights and comments of the "Trilha de Finanças" project, by work.
  Future<Doc> studyQuotes() async => await _api.get('$_root/estudo/citacoes') as Doc;

  /// Fills the company's income statement, balance sheet and cash flow (6 years) from CVM; returns the updated company.
  Future<Doc> importCvm(String companyId) async {
    final t = await _api.post('$_root/empresas/$companyId/importar-cvm') as Doc;
    return (await waitForTask(t['tarefa'] as String))['empresa'] as Doc;
  }

  /// Downloads the CVM document through the VPS (release, presentation or the PDF inside the DFP/ITR package)
  /// to the Arquivos module (`Finanças/<ticker>`); returns the stored file (`id` to open).
  Future<Doc> storeDocument(String url, String title, String ticker, {bool Function()? isCancelled}) async {
    final t = await _api.post('$_root/mercado/guardar', {'url': url, 'titulo': title, 'ticker': ticker}) as Doc;
    return (await waitForTask(t['tarefa'] as String, isCancelled: isCancelled))['arquivo'] as Doc;
  }

  // --- investimentos ---

  Future<List<Doc>> questionnaire() async => _list(await _api.get('$_root/questionario'));

  Future<List<Doc>> saveQuestionnaire(List<Doc> questions) async =>
      _list(await _api.put('$_root/questionario', questions));

  Future<List<Doc>> ranking() async => _list(await _api.get('$_root/empresas/ranking'));

  Future<Doc> analysis(String companyId) async => await _api.get('$_root/empresas/$companyId/analise') as Doc;

  Future<Doc> sectorAnalysis(String sectorId) async => await _api.get('$_root/setores/$sectorId/analise') as Doc;

  Future<Doc> portfolio() async => await _api.get('$_root/carteira') as Doc;
}
