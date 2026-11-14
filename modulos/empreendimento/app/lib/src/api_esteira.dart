import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';

import 'models.dart';

/// Calls to the esteira panel (`./dark panel`, default `http://localhost:8765`), `/api/v1` API.
///
/// Reads with a variable structure (script, editor, graph, process, options) come back as [Json]: the app
/// only displays and returns that data; the esteira is the one that interprets it.
class ApiEsteira {
  /// [token]: login session. Through the VPS (`https://<domain>/esteira/`) nginx requires the token; on the PC
  /// (`localhost:8765`) it is ignored.
  ApiEsteira(String base, {String token = ''})
    : _token = token,
      _api = ApiCliente(base, cabecalhos: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'}) {
    _renewMedia();
  }

  final ApiCliente _api;
  final String _token;

  /// Media token (`POST /api/auth/token-midia`, 12 h, only opens `/esteira/`): it is the one that goes in the
  /// URLs, so a leaked URL (history, log) does not open the API. Until it arrives, the session one is used.
  String? _media;
  DateTime _mediaIn = DateTime(2000);
  bool _searchingMedia = false;

  String get base => _api.base.toString();

  void _renewMedia() {
    if (_token.isEmpty || _searchingMedia || DateTime.now().difference(_mediaIn) < const Duration(hours: 6)) return;
    _searchingMedia = true;
    ApiCliente(_api.base.resolve('/').toString(), cabecalhos: {'Authorization': 'Bearer $_token'})
        .post('/api/auth/token-midia')
        .then((r) {
          _media = (r as Map)['token'] as String?;
          _mediaIn = DateTime.now();
        })
        .catchError((_) {})
        .whenComplete(() => _searchingMedia = false);
  }

  /// Absolute URL of a file served by the esteira (thumbnails, video, audio, PDF, frames). It carries the
  /// token in `?token=`: image, player and external browser open the URL without sending a header.
  String arquivo(String caminho) {
    final u = _api.url(caminho);
    if (_token.isEmpty) return u.toString();
    _renewMedia();
    return u.replace(queryParameters: {...u.queryParameters, 'token': _media ?? _token}).toString();
  }

  static const _v1 = 'api/v1';

  Future<Json> _json(String caminho) async => await _api.get('$_v1/$caminho') as Json;

  Future<List<dynamic>> _list(String caminho) async => await _api.get('$_v1/$caminho') as List;

  Future<dynamic> _post(String caminho, [Object? corpo]) => _api.post('$_v1/$caminho', corpo);

  // ---------- Biblioteca ----------

  /// Stage names and who runs each operation; does not change while the panel runs, so it stays in memory.
  late final Future<Json> meta = _json('meta');

  Future<List<Channel>> channels() async => [for (final c in await _list('canais')) Channel.fromJson(c as Json)];

  Future<List<Script>> scripts(String channel) async => [
    for (final r in await _list('canais/$channel/roteiros')) Script.fromJson(r as Json),
  ];

  /// Imports the scripts (if needed) and queues `tudo` for each one; returns how many went in.
  /// `templates`: script path → `id@N` template that the Studio production will use.
  Future<int> produce(List<String> paths, {Map<String, String> templates = const {}}) async =>
      (await _post('produzir', {'roteiros': paths, 'templates': templates}) as List).where((t) => t != null).length;

  /// `./dark script canal:N [--to M]` in the queue. `false`: it was already in the queue.
  Future<bool> generateScript(String target, {String until = '', String engine = 'local'}) async =>
      await _post('roteiros/gerar', {'alvo': target, 'ate': until, 'motor': engine}) != null;

  // ---------- Episode ----------

  Future<List<EpisodeSummary>> episodes({String channel = ''}) async => [
    for (final e in await _list('episodios?canal=${Uri.encodeQueryComponent(channel)}'))
      EpisodeSummary.fromJson(e as Json),
  ];

  Future<Episode> episode(String ep) async => Episode.fromJson(await _json('episodios/$ep'));

  /// Queues the stage. `false`: the same stage was already queued or running.
  Future<bool> run(
    String ep,
    String stage, {
    bool redo = false,
    String engine = '',
    bool renderOnly = false,
  }) async =>
      await _post('episodios/$ep/rodar/$stage', {
        'refazer': redo,
        'motor': engine,
        'so_render': renderOnly,
      }) !=
      null;

  Future<void> openFilmCraft(String ep) => _post('episodios/$ep/abrir');

  Future<Json> script(String ep) => _json('episodios/$ep/roteiro');

  Future<Json> cuts(String ep, String filter) => _json('episodios/$ep/cortes?filtro=$filter');

  Future<Json> toggleCut(String ep, int k) async =>
      await _post('episodios/$ep/cortes/$k/alternar') as Json;

  Future<Json> scenes(String ep) => _json('episodios/$ep/cenas');

  Future<bool> swapMedia(String ep, int scene, String searchEn) async =>
      await _post('episodios/$ep/cenas/$scene/trocar', {'busca_en': searchEn}) != null;

  Future<Json> graphics(String ep) => _json('episodios/$ep/graficos');

  Future<void> openEffectCraft(String ep, int i) => _post('episodios/$ep/graficos/$i/effectcraft');

  Future<Json> thumbs(String ep) => _json('episodios/$ep/thumbs');

  Future<void> useThumb(String ep, String arquivo, int slot) =>
      _post('episodios/$ep/thumbs/usar', {'arquivo': arquivo, 'vaga': slot});

  Future<void> openPhotoCraft(String ep, String arquivo) =>
      _post('episodios/$ep/thumbs/photocraft', {'arquivo': arquivo});

  /// Uploads an image as a thumbnail background; returns the name it got in `thumbs/`.
  Future<String> sendBackground(String ep, String nome, List<int> bytes) async =>
      (await _api.enviarArquivo('$_v1/episodios/$ep/thumbs/fundo', 'arquivo', nome, bytes) as Json)['nome']
          as String;

  // ---------- Edit packages (edit on any machine) ----------

  /// URL to download the editor file: zip with the media (FilmCraft/EffectCraft) or the `.pcraft`.
  String packageFilmCraft(String ep) => arquivo('$_v1/episodios/$ep/pacote/filmcraft');

  String graphicPackage(String ep, int i) => arquivo('$_v1/episodios/$ep/graficos/$i/pacote');

  String packageThumb(String ep, String thumb) =>
      arquivo('$_v1/episodios/$ep/thumbs/pacote?arquivo=${Uri.encodeQueryComponent(thumb)}');

  /// Overwrites the editor file with the edit (the previous one stays in `log/envios/`); returns how many
  /// referenced media were not found in the episode.
  Future<int> sendFilmCraft(String ep, String nome, List<int> bytes) =>
      _sendEdit('episodios/$ep/pacote/filmcraft', nome, bytes);

  Future<int> sendGraphic(String ep, int i, String nome, List<int> bytes) =>
      _sendEdit('episodios/$ep/graficos/$i/pacote', nome, bytes);

  Future<int> sendThumb(String ep, String thumb, String nome, List<int> bytes) =>
      _sendEdit('episodios/$ep/thumbs/pacote?thumb=${Uri.encodeQueryComponent(thumb)}', nome, bytes);

  Future<int> _sendEdit(String caminho, String nome, List<int> bytes) async =>
      (await _api.enviarArquivo('$_v1/$caminho', 'arquivo', nome, bytes) as Json)['midia_faltando'] as int;

  // ---------- Editor ----------

  Future<Json> graphicEditor(String ep, int i, {double t = 0}) =>
      _json('episodios/$ep/editor/grafico/$i?t=$t');

  Future<Json> editorThumb(String ep, {String arquivo = '', String background = ''}) => _json(
    'episodios/$ep/editor/thumb?arquivo=${Uri.encodeQueryComponent(arquivo)}&fundo=${Uri.encodeQueryComponent(background)}',
  );

  /// Preview PNG (graphic at instant [t], with a transparent background; whole thumbnail).
  Future<Uint8List> frame(String ep, String kind, Json state, {double t = 0}) =>
      _api.postBytes('$_v1/episodios/$ep/editor/quadro', {'tipo': kind, 'estado': state, 't': t});

  /// Saves the piece and queues its render; returns its new index in the list.
  Future<int> saveGraphic(String ep, int i, Json state) async =>
      (await _post('episodios/$ep/editor/grafico/$i', state) as Json)['i'] as int;

  Future<void> deleteGraphic(String ep, int i) => _post('episodios/$ep/editor/grafico/$i/excluir');

  Future<String> saveThumb(String ep, Json state) async =>
      (await _post('episodios/$ep/editor/thumb', state) as Json)['arquivo'] as String;

  Future<Json> suggest(String ep, String kind, Json state, String request, String engine) async => await _post(
    'episodios/$ep/editor/ia',
    {'tipo': kind, 'estado': state, 'pedido': request, 'motor': engine},
  ) as Json;

  // ---------- Fila e processos ----------

  Future<ProductionQueue> queue() async => ProductionQueue.fromJson(await _json('fila'));

  Future<void> cancelar(int task) => _post('fila/$task/cancelar');

  Future<void> cleanQueue() => _post('fila/limpar');

  Future<Json> processes({int limit = 300}) => _json('processos?limite=$limit');

  Future<Json> process(String id) => _json('processos/$id');

  Future<void> stopProcess(String id) => _post('processos/$id/parar');

  // ---------- Monitor, options, costs, library ----------

  Future<Machine> machine() async => Machine.fromJson(await _json('monitor'));

  Future<Json> graph() => _json('grafo');

  Future<Json> graphNode(String id) => _json('grafo/no/$id');

  Future<Json> options() => _json('opcoes');

  Future<Json> saveOptions(Json options) async => await _post('opcoes', options) as Json;

  Future<void> downloadModel(String nome) => _post('opcoes/baixar', {'nome': nome});

  Future<Json> downloading() => _json('opcoes/baixando');

  Future<Json> costs() => _json('custos');

  // ---------- Backup and Craft Apps dataset ----------
  Future<Json> backup() => _json('backup');
  Future<Json> dataset() => _json('dataset');
  Future<void> verdictAssembly(String ep, String verdict, {String comment = ''}) =>
      _post('dataset/montagem/$ep', {'veredito': verdict, 'comentario': comment});

  Future<Json> mediaLibrary({String q = '', String kind = ''}) =>
      _json('acervo?q=${Uri.encodeQueryComponent(q)}&tipo=$kind');

  // ---------- Studio (network channels, styles, productions per style) ----------

  Future<List<dynamic>> studioChannels() => _list('estudio/canais');

  Future<Json> newChannel(Json dados) async => await _post('estudio/canais', dados) as Json;

  /// Channel templates, each one with its stored versions (`ref` = `id@N`) and the state of the samples.
  Future<List<dynamic>> templates(String channel) => _list('estudio/templates?canal=$channel');

  Future<Json> newTemplate(String channel, String modo, List<String> formats, {String nome = ''}) async =>
      await _post('estudio/templates', {'canal': channel, 'modo': modo, 'formatos': formats, 'nome': nome}) as Json;

  /// 30 s sample of the version (vertical and horizontal) in the queue.
  Future<void> generateSample(String ref) => _post('estudio/templates/$ref/amostra');

  /// URL of a version's sample (`formato` = 16x9 or 9x16).
  String sample(String id, int version, String format) => arquivo('$_v1/estudio/amostras/$id-v$version/$format.mp4');

  Future<void> chooseTemplate(String ep, String ref) => _api.put('$_v1/estudio/producoes/$ep/template', {'estilo': ref});

  Future<Json> estilo(String id) => _json('estudio/estilos/$id');

  Future<Json> saveStyle(String id, Json estilo) async =>
      await _api.put('$_v1/estudio/estilos/$id', estilo) as Json;

  Future<Json> lockStyle(String id, bool locked) async =>
      await _post('estudio/estilos/$id/travar', {'travado': locked}) as Json;

  Future<void> sendReference(String id, String nome, List<int> bytes) =>
      _api.enviarArquivo('$_v1/estudio/estilos/$id/referencias', 'arquivo', nome, bytes);

  Future<void> eraseReference(String id, String nome) =>
      _api.delete('$_v1/estudio/estilos/$id/referencias/${Uri.encodeComponent(nome)}');

  Future<Json> duplicateStyle(String id, String newId, String nome) async =>
      await _post('estudio/estilos/$id/duplicar', {'id': newId, 'nome': nome}) as Json;

  Future<Json> studioLevels() => _json('estudio/niveis');

  Future<List<dynamic>> studioSources() => _list('estudio/fontes');

  /// Bytes of the .ttf/.otf for the preview (FontLoader).
  Future<Uint8List> sourceFile(String arquivo) => _api.getBytes('$_v1/estudio/fontes/arquivo/${Uri.encodeComponent(arquivo)}');

  Future<void> sendSource(String nome, List<int> bytes) =>
      _api.enviarArquivo('$_v1/estudio/fontes', 'arquivo', nome, bytes);

  Future<void> proposeStyle(String id, String niche) => _post('estudio/estilos/$id/propor', {'nicho': niche});

  Future<List<dynamic>> studioProductions(String channel) => _list('estudio/producoes?canal=$channel');

  /// Script breakdown (pasted passage or episode) by the style triggers; `estilo` = the screen's draft.
  Future<Json> testStyle(String id, {String texto = '', String ep = '', Json? estilo}) async =>
      await _post('estudio/estilos/$id/testar', {'texto': texto, 'ep': ep, 'estilo': estilo}) as Json;

  Future<Json> studioProduction(String ep) => _json('estudio/producoes/$ep');

  Future<void> produceStudio(
    String ep, {
    String estilo = '',
    List<String> formats = const [],
    List<String> stages = const [],
    Map<String, String> intensidade = const {},
  }) => _post('estudio/producoes/$ep/produzir', {
    'estilo': estilo,
    'formatos': formats,
    'etapas': stages,
    'intensidade': intensidade,
  });

  Future<void> approveGate(String ep, String gate, bool approved, {String note = ''}) =>
      _post('estudio/producoes/$ep/aprovar/$gate', {'aprovado': approved, 'nota': note});

  Future<Json> studioCut(String ep) => _json('estudio/producoes/$ep/corte');

  Future<void> cutBySound(String ep) => _post('estudio/producoes/$ep/corte');

  Future<Json> marking(String ep, {String estilo = ''}) => _json(
    'estudio/producoes/$ep/apontamento${estilo.isEmpty ? '' : '?estilo=${Uri.encodeQueryComponent(estilo)}'}',
  );

  /// `produzir` (style, formats, intensity) together with `confirmar` already queues the production.
  Future<Json> saveMarking(String ep, List<Json> marks, {bool confirm = false, Json? produce}) async =>
      await _api.put('$_v1/estudio/producoes/$ep/apontamento', {
            'marcas': marks,
            'confirmar': confirm,
            'produzir': ?produce,
          })
          as Json;

  Future<void> revertSplice(String ep, num de, num until, bool revert) =>
      _api.put('$_v1/estudio/producoes/$ep/corte/emenda', {'de': de, 'ate': until, 'reverter': revert});

  Future<Json> editScene(String ep, int id, Json scene) async =>
      await _api.put('$_v1/estudio/producoes/$ep/cenas/$id', scene) as Json;

  Future<Json> dependencies() => _json('estudio/dependencias');

  Future<void> installDependencies() => _post('estudio/dependencias/instalar');

  Future<Json> bench() => _json('bancada');

  Future<void> runBench({List<String> models = const []}) => _post('bancada/rodar', {'modelos': models});

  /// Approvals base → fine-tune: cases per task, minimum, last export and whether `.venv-treino` exists.
  Future<Json> training() => _json('estudio/treino');

  Future<Json> exportTraining() async => await _api.post('$_v1/estudio/treino/exportar', {}) as Json;

  Future<void> trainLora() => _post('estudio/treino/treinar');

  // ---------- Piece factory (Studio) ----------

  /// Requests, review queue, library gaps, today's spend and the factory log.
  Future<Json> pieceFactory() => _json('estudio/fabrica');

  /// New request (`tipo`: livre | referencia | lacunas); goes straight into the Claude queue.
  Future<Json> newFactoryRequest(Json dados) async => await _post('estudio/fabrica/pedidos', dados) as Json;

  /// Ready-made request for the first piece: the PDF citation.
  Future<Json> requestQuote({double cap = 3, String engine = 'html'}) async =>
      await _post('estudio/fabrica/citacao?teto_dia_usd=$cap&motor=$engine') as Json;

  /// Reference image of the request; returns the stored name.
  Future<String> sendFactoryReference(String nome, List<int> bytes) async =>
      ((await _api.enviarArquivo('$_v1/estudio/fabrica/referencias', 'arquivo', nome, bytes)) as Json)['nome'] as String;

  Future<void> pauseRequest(String id, bool pausado) => _post('estudio/fabrica/pedidos/$id/pausar?pausado=$pausado');

  Future<void> runRequest(String id) => _post('estudio/fabrica/pedidos/$id/rodar');

  /// Live factory panel: stage in progress, Claude/local LLM calls, quota, today's numbers,
  /// idea queue, library, dataset and timeline.
  Future<Json> factoryPanel() => _json('estudio/fabrica/painel');

  /// Claude creates `quantidade` ideas in a batch and the local LLM runs each one in N1.
  Future<Json> generateIdeas(int quantidade, String texto) async =>
      await _post('estudio/fabrica/ideias', {'quantidade': quantidade, 'texto': texto}) as Json;

  /// Port of the HTML pieces to EffectCraft by the local LLM (resumes the open request).
  Future<Json> portarHtml() async => await _post('estudio/fabrica/porte') as Json;

  /// Library pieces with their sheet, the last gate and the proof frames.
  Future<List<dynamic>> libraryPieces() => _list('estudio/pecas');

  /// `acao`: aprovar | ajuste (text = what to change) | variacao | reprovar (text = reason).
  Future<Json> reviewPiece(String id, String acao, [String texto = '', int? note]) async =>
      await _post('estudio/pecas/$id/revisar', {'acao': acao, 'texto': texto, 'nota': note}) as Json;

  /// Timeline per block: swaps the scene's piece for another (the local AI fills the new one; it teaches the bench).
  Future<Json> swapPiece(String ep, int scene, String piece) async =>
      await _post('estudio/producoes/$ep/cenas/$scene/trocar', {'peca': piece}) as Json;

  /// Render of the block only: span → splice into the rendered video → loudness and preview (queue).
  Future<void> renderBlock(String ep, int bloco) => _post('estudio/producoes/$ep/blocos/$bloco/render', {'formatos': []});

  /// Continuous library growth from the gaps (on, pieces per day, cap, engine, review queue limit).
  Future<Json> saveExpansion(Json dados) async => await _api.put('$_v1/estudio/fabrica/ampliacao', dados) as Json;

  /// HTML × EffectCraft: overall, per intent and the engine suggestion per intent.
  Future<Json> enginesComparison() => _json('estudio/fabrica/comparacao');

  /// Engine decision per intent (requests with the "auto" engine).
  Future<Json> applyEngines(Map<String, String> byIntent) async =>
      await _api.put('$_v1/estudio/fabrica/motores', {'por_intencao': byIntent}) as Json;

  Future<void> pieceGate(String id) => _post('estudio/pecas/$id/portao');

  /// Short MP4 of the piece in the style's skin (render engine queue).
  Future<void> piecePreview(String id, String estilo) => _post('estudio/pecas/$id/previa', {'estilo': estilo});

  Future<List<dynamic>> piecePreviews(String id) => _list('estudio/pecas/$id/previas');

  /// Every approved piece in the skin of each style (queue); the result brings the sheets and the problems.
  Future<void> channelsProof(List<String> styles) => _post('estudio/pecas/prova-canais', {'estilos': styles});

  Future<Json> resultChannelsProof() => _json('estudio/pecas/prova-canais');
}
