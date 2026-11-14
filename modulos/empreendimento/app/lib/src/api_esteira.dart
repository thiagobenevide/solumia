import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';

import 'modelos.dart';

/// Chamadas ao painel da esteira (`./dark panel`, padrão `http://localhost:8765`), API `/api/v1`.
///
/// Leituras de estrutura variável (roteiro, editor, grafo, processo, opções) voltam como [Json]: o app
/// só exibe e devolve esses dados, quem os interpreta é a esteira.
class ApiEsteira {
  /// [token]: sessão do login. Pela VPS (`https://<domínio>/esteira/`) o nginx exige o token; no PC
  /// (`localhost:8765`) ele é ignorado.
  ApiEsteira(String base, {String token = ''})
    : _token = token,
      _api = ApiCliente(base, cabecalhos: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'}) {
    _renovarMidia();
  }

  final ApiCliente _api;
  final String _token;

  /// Token de mídia (`POST /api/auth/token-midia`, 12 h, só abre `/esteira/`): é ele que vai nas
  /// URLs, para uma URL vazada (histórico, log) não abrir a API. Enquanto não chega, vai o da sessão.
  String? _midia;
  DateTime _midiaEm = DateTime(2000);
  bool _buscandoMidia = false;

  String get base => _api.base.toString();

  void _renovarMidia() {
    if (_token.isEmpty || _buscandoMidia || DateTime.now().difference(_midiaEm) < const Duration(hours: 6)) return;
    _buscandoMidia = true;
    ApiCliente(_api.base.resolve('/').toString(), cabecalhos: {'Authorization': 'Bearer $_token'})
        .post('/api/auth/token-midia')
        .then((r) {
          _midia = (r as Map)['token'] as String?;
          _midiaEm = DateTime.now();
        })
        .catchError((_) {})
        .whenComplete(() => _buscandoMidia = false);
  }

  /// URL absoluta de um arquivo servido pela esteira (thumbs, vídeo, áudio, PDF, quadros). Leva o
  /// token em `?token=`: imagem, player e navegador externo abrem a URL sem mandar cabeçalho.
  String arquivo(String caminho) {
    final u = _api.url(caminho);
    if (_token.isEmpty) return u.toString();
    _renovarMidia();
    return u.replace(queryParameters: {...u.queryParameters, 'token': _midia ?? _token}).toString();
  }

  static const _v1 = 'api/v1';

  Future<Json> _json(String caminho) async => await _api.get('$_v1/$caminho') as Json;

  Future<List<dynamic>> _lista(String caminho) async => await _api.get('$_v1/$caminho') as List;

  Future<dynamic> _post(String caminho, [Object? corpo]) => _api.post('$_v1/$caminho', corpo);

  // ---------- Biblioteca ----------

  /// Nomes das etapas e quem faz cada operação; não muda enquanto o painel roda, então fica em memória.
  late final Future<Json> meta = _json('meta');

  Future<List<Canal>> canais() async => [for (final c in await _lista('canais')) Canal.fromJson(c as Json)];

  Future<List<Roteiro>> roteiros(String canal) async => [
    for (final r in await _lista('canais/$canal/roteiros')) Roteiro.fromJson(r as Json),
  ];

  /// Importa os roteiros (se preciso) e põe `tudo` de cada um na fila; devolve quantos entraram.
  /// `templates`: caminho do roteiro → template `id@N` que a produção no Estúdio vai usar.
  Future<int> produzir(List<String> caminhos, {Map<String, String> templates = const {}}) async =>
      (await _post('produzir', {'roteiros': caminhos, 'templates': templates}) as List).where((t) => t != null).length;

  /// `./dark script canal:N [--to M]` na fila. `false`: já estava na fila.
  Future<bool> gerarRoteiro(String alvo, {String ate = '', String motor = 'local'}) async =>
      await _post('roteiros/gerar', {'alvo': alvo, 'ate': ate, 'motor': motor}) != null;

  // ---------- Episódio ----------

  Future<List<EpisodioResumo>> episodios({String canal = ''}) async => [
    for (final e in await _lista('episodios?canal=${Uri.encodeQueryComponent(canal)}'))
      EpisodioResumo.fromJson(e as Json),
  ];

  Future<Episodio> episodio(String ep) async => Episodio.fromJson(await _json('episodios/$ep'));

  /// Põe a etapa na fila. `false`: a mesma etapa já estava na fila ou rodando.
  Future<bool> rodar(
    String ep,
    String etapa, {
    bool refazer = false,
    String motor = '',
    bool soRender = false,
  }) async =>
      await _post('episodios/$ep/rodar/$etapa', {
        'refazer': refazer,
        'motor': motor,
        'so_render': soRender,
      }) !=
      null;

  Future<void> abrirFilmCraft(String ep) => _post('episodios/$ep/abrir');

  Future<Json> roteiro(String ep) => _json('episodios/$ep/roteiro');

  Future<Json> cortes(String ep, String filtro) => _json('episodios/$ep/cortes?filtro=$filtro');

  Future<Json> alternarCorte(String ep, int k) async =>
      await _post('episodios/$ep/cortes/$k/alternar') as Json;

  Future<Json> cenas(String ep) => _json('episodios/$ep/cenas');

  Future<bool> trocarMidia(String ep, int cena, String buscaEn) async =>
      await _post('episodios/$ep/cenas/$cena/trocar', {'busca_en': buscaEn}) != null;

  Future<Json> graficos(String ep) => _json('episodios/$ep/graficos');

  Future<void> abrirEffectCraft(String ep, int i) => _post('episodios/$ep/graficos/$i/effectcraft');

  Future<Json> thumbs(String ep) => _json('episodios/$ep/thumbs');

  Future<void> usarThumb(String ep, String arquivo, int vaga) =>
      _post('episodios/$ep/thumbs/usar', {'arquivo': arquivo, 'vaga': vaga});

  Future<void> abrirPhotoCraft(String ep, String arquivo) =>
      _post('episodios/$ep/thumbs/photocraft', {'arquivo': arquivo});

  /// Envia uma imagem para fundo de thumb; devolve o nome com que ficou em `thumbs/`.
  Future<String> enviarFundo(String ep, String nome, List<int> bytes) async =>
      (await _api.enviarArquivo('$_v1/episodios/$ep/thumbs/fundo', 'arquivo', nome, bytes) as Json)['nome']
          as String;

  // ---------- Pacotes de edição (editar em qualquer máquina) ----------

  /// URL para baixar o arquivo do editor: zip com a mídia (FilmCraft/EffectCraft) ou o `.pcraft`.
  String pacoteFilmCraft(String ep) => arquivo('$_v1/episodios/$ep/pacote/filmcraft');

  String pacoteGrafico(String ep, int i) => arquivo('$_v1/episodios/$ep/graficos/$i/pacote');

  String pacoteThumb(String ep, String thumb) =>
      arquivo('$_v1/episodios/$ep/thumbs/pacote?arquivo=${Uri.encodeQueryComponent(thumb)}');

  /// Sobrescreve o arquivo do editor com a edição (o anterior fica em `log/envios/`); devolve quantas
  /// mídias referenciadas não foram achadas no episódio.
  Future<int> enviarFilmCraft(String ep, String nome, List<int> bytes) =>
      _enviarEdicao('episodios/$ep/pacote/filmcraft', nome, bytes);

  Future<int> enviarGrafico(String ep, int i, String nome, List<int> bytes) =>
      _enviarEdicao('episodios/$ep/graficos/$i/pacote', nome, bytes);

  Future<int> enviarThumb(String ep, String thumb, String nome, List<int> bytes) =>
      _enviarEdicao('episodios/$ep/thumbs/pacote?thumb=${Uri.encodeQueryComponent(thumb)}', nome, bytes);

  Future<int> _enviarEdicao(String caminho, String nome, List<int> bytes) async =>
      (await _api.enviarArquivo('$_v1/$caminho', 'arquivo', nome, bytes) as Json)['midia_faltando'] as int;

  // ---------- Editor ----------

  Future<Json> editorGrafico(String ep, int i, {double t = 0}) =>
      _json('episodios/$ep/editor/grafico/$i?t=$t');

  Future<Json> editorThumb(String ep, {String arquivo = '', String fundo = ''}) => _json(
    'episodios/$ep/editor/thumb?arquivo=${Uri.encodeQueryComponent(arquivo)}&fundo=${Uri.encodeQueryComponent(fundo)}',
  );

  /// PNG da prévia (gráfico no instante [t], com fundo transparente; thumb inteira).
  Future<Uint8List> quadro(String ep, String tipo, Json estado, {double t = 0}) =>
      _api.postBytes('$_v1/episodios/$ep/editor/quadro', {'tipo': tipo, 'estado': estado, 't': t});

  /// Grava a peça e põe a renderização na fila; devolve o novo índice dela na lista.
  Future<int> salvarGrafico(String ep, int i, Json estado) async =>
      (await _post('episodios/$ep/editor/grafico/$i', estado) as Json)['i'] as int;

  Future<void> excluirGrafico(String ep, int i) => _post('episodios/$ep/editor/grafico/$i/excluir');

  Future<String> salvarThumb(String ep, Json estado) async =>
      (await _post('episodios/$ep/editor/thumb', estado) as Json)['arquivo'] as String;

  Future<Json> sugerir(String ep, String tipo, Json estado, String pedido, String motor) async => await _post(
    'episodios/$ep/editor/ia',
    {'tipo': tipo, 'estado': estado, 'pedido': pedido, 'motor': motor},
  ) as Json;

  // ---------- Fila e processos ----------

  Future<Fila> fila() async => Fila.fromJson(await _json('fila'));

  Future<void> cancelar(int tarefa) => _post('fila/$tarefa/cancelar');

  Future<void> limparFila() => _post('fila/limpar');

  Future<Json> processos({int limite = 300}) => _json('processos?limite=$limite');

  Future<Json> processo(String id) => _json('processos/$id');

  Future<void> pararProcesso(String id) => _post('processos/$id/parar');

  // ---------- Monitor, opções, custos, acervo ----------

  Future<Maquina> maquina() async => Maquina.fromJson(await _json('monitor'));

  Future<Json> grafo() => _json('grafo');

  Future<Json> noDoGrafo(String id) => _json('grafo/no/$id');

  Future<Json> opcoes() => _json('opcoes');

  Future<Json> salvarOpcoes(Json opcoes) async => await _post('opcoes', opcoes) as Json;

  Future<void> baixarModelo(String nome) => _post('opcoes/baixar', {'nome': nome});

  Future<Json> baixando() => _json('opcoes/baixando');

  Future<Json> custos() => _json('custos');

  // ---------- Backup e dataset das Craft Apps ----------
  Future<Json> backup() => _json('backup');
  Future<Json> dataset() => _json('dataset');
  Future<void> vereditoMontagem(String ep, String veredito, {String comentario = ''}) =>
      _post('dataset/montagem/$ep', {'veredito': veredito, 'comentario': comentario});

  Future<Json> acervo({String q = '', String tipo = ''}) =>
      _json('acervo?q=${Uri.encodeQueryComponent(q)}&tipo=$tipo');

  // ---------- Estúdio (canais da rede, estilos, produções por estilo) ----------

  Future<List<dynamic>> estudioCanais() => _lista('estudio/canais');

  Future<Json> novoCanal(Json dados) async => await _post('estudio/canais', dados) as Json;

  /// Templates do canal, cada um com as versões guardadas (`ref` = `id@N`) e o estado dos exemplos.
  Future<List<dynamic>> templates(String canal) => _lista('estudio/templates?canal=$canal');

  Future<Json> novoTemplate(String canal, String modo, List<String> formatos, {String nome = ''}) async =>
      await _post('estudio/templates', {'canal': canal, 'modo': modo, 'formatos': formatos, 'nome': nome}) as Json;

  /// Exemplo de 30 s da versão (vertical e horizontal) na fila.
  Future<void> gerarAmostra(String ref) => _post('estudio/templates/$ref/amostra');

  /// URL do exemplo de uma versão (`formato` = 16x9 ou 9x16).
  String amostra(String id, int versao, String formato) => arquivo('$_v1/estudio/amostras/$id-v$versao/$formato.mp4');

  Future<void> escolherTemplate(String ep, String ref) => _api.put('$_v1/estudio/producoes/$ep/template', {'estilo': ref});

  Future<Json> estilo(String id) => _json('estudio/estilos/$id');

  Future<Json> salvarEstilo(String id, Json estilo) async =>
      await _api.put('$_v1/estudio/estilos/$id', estilo) as Json;

  Future<Json> travarEstilo(String id, bool travado) async =>
      await _post('estudio/estilos/$id/travar', {'travado': travado}) as Json;

  Future<void> enviarReferencia(String id, String nome, List<int> bytes) =>
      _api.enviarArquivo('$_v1/estudio/estilos/$id/referencias', 'arquivo', nome, bytes);

  Future<void> apagarReferencia(String id, String nome) =>
      _api.delete('$_v1/estudio/estilos/$id/referencias/${Uri.encodeComponent(nome)}');

  Future<Json> duplicarEstilo(String id, String novoId, String nome) async =>
      await _post('estudio/estilos/$id/duplicar', {'id': novoId, 'nome': nome}) as Json;

  Future<Json> niveisEstudio() => _json('estudio/niveis');

  Future<List<dynamic>> fontesEstudio() => _lista('estudio/fontes');

  /// Bytes do .ttf/.otf para a prévia (FontLoader).
  Future<Uint8List> arquivoFonte(String arquivo) => _api.getBytes('$_v1/estudio/fontes/arquivo/${Uri.encodeComponent(arquivo)}');

  Future<void> enviarFonte(String nome, List<int> bytes) =>
      _api.enviarArquivo('$_v1/estudio/fontes', 'arquivo', nome, bytes);

  Future<void> proporEstilo(String id, String nicho) => _post('estudio/estilos/$id/propor', {'nicho': nicho});

  Future<List<dynamic>> producoesEstudio(String canal) => _lista('estudio/producoes?canal=$canal');

  /// Decupagem do roteiro (trecho colado ou episódio) pelos gatilhos do estilo; `estilo` = rascunho da tela.
  Future<Json> testarEstilo(String id, {String texto = '', String ep = '', Json? estilo}) async =>
      await _post('estudio/estilos/$id/testar', {'texto': texto, 'ep': ep, 'estilo': estilo}) as Json;

  Future<Json> producaoEstudio(String ep) => _json('estudio/producoes/$ep');

  Future<void> produzirEstudio(
    String ep, {
    String estilo = '',
    List<String> formatos = const [],
    List<String> etapas = const [],
    Map<String, String> intensidade = const {},
  }) => _post('estudio/producoes/$ep/produzir', {
    'estilo': estilo,
    'formatos': formatos,
    'etapas': etapas,
    'intensidade': intensidade,
  });

  Future<void> aprovarPortao(String ep, String portao, bool aprovado, {String nota = ''}) =>
      _post('estudio/producoes/$ep/aprovar/$portao', {'aprovado': aprovado, 'nota': nota});

  Future<Json> corteEstudio(String ep) => _json('estudio/producoes/$ep/corte');

  Future<void> cortarPeloSom(String ep) => _post('estudio/producoes/$ep/corte');

  Future<Json> apontamento(String ep, {String estilo = ''}) => _json(
    'estudio/producoes/$ep/apontamento${estilo.isEmpty ? '' : '?estilo=${Uri.encodeQueryComponent(estilo)}'}',
  );

  /// `produzir` (estilo, formatos, intensidade) junto com `confirmar` já põe a produção na fila.
  Future<Json> salvarApontamento(String ep, List<Json> marcas, {bool confirmar = false, Json? produzir}) async =>
      await _api.put('$_v1/estudio/producoes/$ep/apontamento', {
            'marcas': marcas,
            'confirmar': confirmar,
            'produzir': ?produzir,
          })
          as Json;

  Future<void> reverterEmenda(String ep, num de, num ate, bool reverter) =>
      _api.put('$_v1/estudio/producoes/$ep/corte/emenda', {'de': de, 'ate': ate, 'reverter': reverter});

  Future<Json> editarCena(String ep, int id, Json cena) async =>
      await _api.put('$_v1/estudio/producoes/$ep/cenas/$id', cena) as Json;

  Future<Json> dependencias() => _json('estudio/dependencias');

  Future<void> instalarDependencias() => _post('estudio/dependencias/instalar');

  Future<Json> bancada() => _json('bancada');

  Future<void> rodarBancada({List<String> modelos = const []}) => _post('bancada/rodar', {'modelos': modelos});

  /// Base de aprovações → fine-tune: casos por tarefa, mínimo, última exportação e se o `.venv-treino` existe.
  Future<Json> treino() => _json('estudio/treino');

  Future<Json> exportarTreino() async => await _api.post('$_v1/estudio/treino/exportar', {}) as Json;

  Future<void> treinarLora() => _post('estudio/treino/treinar');

  // ---------- Fábrica de peças (Estúdio) ----------

  /// Pedidos, fila de revisão, lacunas do acervo, gasto do dia e registro da fábrica.
  Future<Json> fabrica() => _json('estudio/fabrica');

  /// Pedido novo (`tipo`: livre | referencia | lacunas); entra direto na fila do Claude.
  Future<Json> novoPedidoFabrica(Json dados) async => await _post('estudio/fabrica/pedidos', dados) as Json;

  /// Pedido pronto da primeira peça: a citação de PDF.
  Future<Json> pedidoCitacao({double teto = 3, String motor = 'html'}) async =>
      await _post('estudio/fabrica/citacao?teto_dia_usd=$teto&motor=$motor') as Json;

  /// Imagem de referência do pedido; devolve o nome guardado.
  Future<String> enviarReferenciaFabrica(String nome, List<int> bytes) async =>
      ((await _api.enviarArquivo('$_v1/estudio/fabrica/referencias', 'arquivo', nome, bytes)) as Json)['nome'] as String;

  Future<void> pausarPedido(String id, bool pausado) => _post('estudio/fabrica/pedidos/$id/pausar?pausado=$pausado');

  Future<void> rodarPedido(String id) => _post('estudio/fabrica/pedidos/$id/rodar');

  /// Painel ao vivo da fábrica: etapa em andamento, chamadas do Claude/LLM local, cota, números de hoje,
  /// fila de ideias, acervo, dataset e linha do tempo.
  Future<Json> painelFabrica() => _json('estudio/fabrica/painel');

  /// O Claude cria `quantidade` ideias em lote e a LLM local executa cada uma em N1.
  Future<Json> gerarIdeias(int quantidade, String texto) async =>
      await _post('estudio/fabrica/ideias', {'quantidade': quantidade, 'texto': texto}) as Json;

  /// Porte das peças HTML para EffectCraft pela LLM local (retoma o pedido aberto).
  Future<Json> portarHtml() async => await _post('estudio/fabrica/porte') as Json;

  /// Peças do acervo com a ficha, o último portão e os quadros da prova.
  Future<List<dynamic>> pecasAcervo() => _lista('estudio/pecas');

  /// `acao`: aprovar | ajuste (texto = o que mudar) | variacao | reprovar (texto = motivo).
  Future<Json> revisarPeca(String id, String acao, [String texto = '', int? nota]) async =>
      await _post('estudio/pecas/$id/revisar', {'acao': acao, 'texto': texto, 'nota': nota}) as Json;

  /// Linha do tempo por bloco: troca a peça da cena por outra (a IA local preenche a nova; ensina a bancada).
  Future<Json> trocarPeca(String ep, int cena, String peca) async =>
      await _post('estudio/producoes/$ep/cenas/$cena/trocar', {'peca': peca}) as Json;

  /// Render só do bloco: trecho → emenda no vídeo renderizado → loudness e prévia (fila).
  Future<void> renderBloco(String ep, int bloco) => _post('estudio/producoes/$ep/blocos/$bloco/render', {'formatos': []});

  /// Ampliação contínua do acervo pelas lacunas (liga, peças por dia, teto, motor, limite da fila de revisão).
  Future<Json> salvarAmpliacao(Json dados) async => await _api.put('$_v1/estudio/fabrica/ampliacao', dados) as Json;

  /// HTML × EffectCraft: geral, por intenção e a sugestão de motor por intenção.
  Future<Json> comparacaoMotores() => _json('estudio/fabrica/comparacao');

  /// Decisão de motor por intenção (pedidos com motor "auto").
  Future<Json> aplicarMotores(Map<String, String> porIntencao) async =>
      await _api.put('$_v1/estudio/fabrica/motores', {'por_intencao': porIntencao}) as Json;

  Future<void> portaoPeca(String id) => _post('estudio/pecas/$id/portao');

  /// MP4 curto da peça na pele do estilo (fila do motor de render).
  Future<void> previaPeca(String id, String estilo) => _post('estudio/pecas/$id/previa', {'estilo': estilo});

  Future<List<dynamic>> previasPeca(String id) => _lista('estudio/pecas/$id/previas');

  /// Todas as peças aprovadas na pele de cada estilo (fila); o resultado traz as folhas e os problemas.
  Future<void> provaCanais(List<String> estilos) => _post('estudio/pecas/prova-canais', {'estilos': estilos});

  Future<Json> resultadoProvaCanais() => _json('estudio/pecas/prova-canais');
}
