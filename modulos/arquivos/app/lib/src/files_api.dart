import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';

import 'models.dart';
import 'offline.dart';
import 'screens/reading_projects.dart';

/// Routes of `/api/arquivos` (and note creation in `/api/notas`). The same client serves the
/// backend local (`http://localhost:48080`) e o da VPS (`https://…` com a chave).
class FilesApi {
  FilesApi(String base, {String token = ''})
    : _api = ApiCliente(base, cabecalhos: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'});

  final ApiCliente _api;

  /// Files downloaded on the device and what was done offline.
  late final offline = OfflineVault(this);

  Map<String, String> get cabecalhos => _api.cabecalhos;

  Future<List<FileItem>> list({String q = '', String? pasta}) async {
    final query = Uri(queryParameters: {'q': q, 'pasta': ?pasta}).query;
    return [for (final j in await _api.get('api/arquivos?$query') as List) FileItem.fromJson(j)];
  }

  Future<List<String>> pastas() async => [...(await _api.get('api/arquivos/pastas') as List).cast<String>()];

  Future<FileItem> fetch(String id) async => FileItem.fromJson(await _api.get('api/arquivos/$id'));

  /// Blank file generated on the server: `documento` (.docx), `planilha` (.xlsx) or `apresentacao` (.pptx).
  Future<FileItem> isNew(String type, String title, {String pasta = ''}) async =>
      FileItem.fromJson(await _api.post('api/arquivos/novo', {'tipo': type, 'titulo': title, 'pasta': pasta}));

  /// Returns the stored file; `duplicado` when an identical one already existed.
  Future<(FileItem, bool)> send(String name, List<int> bytes, {String pasta = ''}) async {
    final j = await _api.enviarArquivo('api/arquivos', 'arquivo', name, bytes, campos: {'pasta': pasta});
    return (FileItem.fromJson(j), j['duplicado'] == true);
  }

  Future<FileItem> edit(String id, {String? title, String? pasta, List<String>? tags}) async =>
      FileItem.fromJson(await _api.patch('api/arquivos/$id', {'titulo': ?title, 'pasta': ?pasta, 'tags': ?tags}));

  Future<void> delete(String id) => _api.delete('api/arquivos/$id');

  Future<FileItem> duplicate(String id) async => FileItem.fromJson(await _api.post('api/arquivos/$id/duplicar'));

  Future<void> reconvert(String id) => _api.post('api/arquivos/$id/converter');

  /// In chunks: a 20 MB PDF does not depend on a long connection without drops (phone, tunnel).
  Future<Uint8List> pdf(String id, {TarefaFundo? task}) => _api.getBytesEmPartes(
    'api/arquivos/$id/pdf',
    progresso: task?.bytes,
    cancelado: () => task?.cancelada ?? false,
  );

  Future<Uint8List> original(String id) => _api.getBytes('api/arquivos/$id/original');

  /// Replaces the original with the edited version; DOCX/PPTX/spreadsheets go back to `convertendo`.
  Future<FileItem> replaceOriginal(String id, String name, List<int> bytes) async =>
      FileItem.fromJson(await _api.enviarArquivo('api/arquivos/$id/original', 'arquivo', name, bytes, metodo: 'PUT'));

  Uri thumbnailUrl(FileItem a) => _api.url('api/arquivos/${a.id}/miniatura?v=${a.updated.millisecondsSinceEpoch}');

  Future<Annotations> annotations(String id) async => Annotations.fromJson(await _api.get('api/arquivos/$id/anotacoes'));

  /// Saves over [baseVersion]. If another device saved first, the server answers 409 and the
  /// caller fetches the current ones and merges ([Annotations.merge]).
  Future<Annotations> saveAnnotations(String id, Annotations a, int baseVersion) async =>
      Annotations.fromJson(await _api.put('api/arquivos/$id/anotacoes', a.toJson(baseVersion: baseVersion)));

  Future<List<Reference>> highlights({String q = '', String? fileId}) async {
    final query = Uri(queryParameters: {'q': q, 'arquivo_id': ?fileId}).query;
    return [for (final j in await _api.get('api/arquivos/destaques?$query') as List) Reference.fromJson(j)];
  }

  /// Current `seq` and the changes after [since] (criado, editado, excluido, convertido, anotado).
  Future<(int, List<Map<String, dynamic>>)> changes(int since) async {
    final j = await _api.get('api/arquivos/mudancas?desde=$since') as Map<String, dynamic>;
    return (j['seq'] as int, [...(j['mudancas'] as List).cast<Map<String, dynamic>>()]);
  }

  /// Rewrites [excerpt] with the Claude Code on the PC (never the Anthropic API). [fileId] gives the document
  /// inteiro como contexto. Devolve `{texto, mudancas: [{antes, depois, motivo}], observacoes}`.
  Future<Map<String, dynamic>> rewrite({
    required String excerpt,
    required String goal,
    String instruction = '',
    String feedback = '',
    String? fileId,
  }) async =>
      await _api.post('api/arquivos/reescrever', {
            'trecho': excerpt,
            'objetivo': goal,
            'instrucao': instruction,
            'feedback': feedback,
            'arquivo_id': ?fileId,
          })
          as Map<String, dynamic>;

  /// Translation already done of the document: page (0-based, text) → `{segmentos, traducoes}`.
  Future<Map<String, dynamic>> translation(String id) async =>
      await _api.get('api/arquivos/$id/traducao') as Map<String, dynamic>;

  // --- guided reading (Estudos › Linguagem, local LLM and worker voice; never Claude) ---

  /// Speech of the [sentence] in [language] and the timing of each word (`inicio`/`fim` in the sentence, `t0`/`t1` in s).
  Future<Map<String, dynamic>> speech(String sentence, String language, double speed) async =>
      (await _api.post('api/estudos/linguagem/fala', {'texto': sentence, 'idioma': language, 'velocidade': speed})
              as Map)
          .cast<String, dynamic>();

  /// Translation of [term] in the sense of the [sentence]: `traducao`, `classe`, `ipa`, `sentido`, `frase_traduzida`.
  Future<Map<String, dynamic>> translateTerm(String term, String sentence, String language) async =>
      (await _api.post('api/estudos/linguagem/traduzir', {'termo': term, 'frase': sentence, 'idioma': language}) as Map)
          .cast<String, dynamic>();

  /// "Criar tarefas": the word goes into the vocabulary notebook and the local LLM generates sentences and exercises.
  Future<Map<String, dynamic>> createWord(Map<String, dynamic> data) async =>
      (await _api.post('api/estudos/linguagem/vocabulario', data) as Map).cast<String, dynamic>();

  /// Study time spent in the reader (goes into the language track).
  Future<void> logActivity(String type, String language, int minutes, Map<String, Object> details) =>
      _api.post('api/estudos/linguagem/atividades', {
        'tipo': type,
        'idioma': language,
        'minutos': minutes,
        'detalhes': details,
      });

  /// Recording reading [reference] aloud → correct/swapped/skipped words, pace and pronunciation.
  Future<Map<String, dynamic>> evaluateReading(
    List<int> wav,
    String language,
    String reference, {
    String? fileId,
    String title = '',
    int? page,
  }) async =>
      (await _api.enviarArquivo(
                'api/estudos/linguagem/leituras-voz',
                'audio',
                'leitura.wav',
                wav,
                campos: {
                  'idioma': language,
                  'referencia': reference,
                  'arquivo_id': ?fileId,
                  'titulo': title,
                  if (page != null) 'pagina': '$page',
                },
              )
              as Map)
          .cast<String, dynamic>();

  /// Translates [pages] (page → original sentences) with the local LLM on the PC; those already
  /// translated with the same sentences come back from the cache.
  Future<Map<String, dynamic>> translate(String id, Map<int, List<String>> pages, {bool redo = false}) async =>
      await _api.post('api/arquivos/$id/traducao', {
            'paginas': [
              for (final e in pages.entries) {'pagina': e.key, 'segmentos': e.value},
            ],
            'refazer': redo,
          })
          as Map<String, dynamic>;

  /// Reading projects of the Estudos module, to link excerpts and annotations to them.
  Future<List<ReadingProject>> readingProjects() async => [
    for (final j in await _api.get('api/estudos/projetos') as List) ReadingProject.fromJson(j as Map<String, dynamic>),
  ];

  Future<ReadingProject> createReadingProject(String name) async =>
      ReadingProject.fromJson(await _api.post('api/estudos/projetos', {'nome': name}) as Map<String, dynamic>);

  /// Original converted by LibreOffice on the server (`odt`, `pdf`, `ods`, `csv`, `odp`…).
  Future<Uint8List> export(String id, String formatStr) =>
      _api.getBytes('api/arquivos/$id/exportar?formato=${Uri.encodeQueryComponent(formatStr)}');

  /// Note (Notas module) with the file content in Markdown, to cite later as a reference.
  Future<String> referenceNote(FileItem a, String markdown) async {
    final note = await _api.post('api/notas', {
      'titulo': a.title,
      'tipo': 'nota',
      'tags': ['referencia'],
      'propriedades': {
        'fonte': ['[[${a.title}]]'],
        'arquivo': a.id,
      },
      'corpo': markdown,
    });
    return note['id'] as String;
  }

  /// Creates a note (Notas module) citing the highlight, with the file as `fonte`.
  Future<String> createNote(Reference r, {required String title}) async {
    final note = await _api.post('api/notas', {
      'titulo': title,
      'tipo': 'nota',
      'tags': ['referencia'],
      'propriedades': {
        'fonte': ['[[${r.fileTitle}]]'],
        'pagina': r.highlight.page + 1,
      },
      'corpo': '${r.citation}\n\n${r.highlight.comment}'.trim(),
    });
    return note['id'] as String;
  }

  /// Collabora editing session (WOPI): action URL + `access_token` and expiry (ms since the epoch).
  Future<({Uri url, String token, int ttl})> collaboraSession(String id) async {
    final j = await _api.post('api/arquivos/$id/collabora') as Map<String, dynamic>;
    return (
      url: Uri.parse(j['url'] as String),
      token: j['access_token'] as String,
      ttl: (j['access_token_ttl'] as num).toInt(),
    );
  }
}
