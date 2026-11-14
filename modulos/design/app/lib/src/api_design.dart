import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import 'modelos.dart';
import 'quadro/busca_bing.dart';
import 'wireframe/modelo.dart';

/// Rotas de `/api/design`.
class ApiDesign {
  ApiDesign(String base, {String token = ''})
    : _api = ApiCliente(base, cabecalhos: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'}),
      _colecao = 'quadros';

  ApiDesign._(this._api, this._colecao);

  final ApiCliente _api;

  /// `quadros` (fluxogramas) ou `cadernos`: as rotas dos dois são iguais.
  final String _colecao;

  /// A mesma API falando com `/api/design/cadernos`.
  late final ApiDesign cadernos = _colecao == 'cadernos' ? this : ApiDesign._(_api, 'cadernos');

  bool get ehCaderno => _colecao == 'cadernos';

  Future<List<ResumoQuadro>> listar() async => [
    for (final j in await _api.get('api/design/$_colecao') as List) ResumoQuadro.fromJson(j),
  ];

  Future<Quadro> obter(String id) async => Quadro.fromJson(await _api.get('api/design/$_colecao/$id'));

  Future<ResumoQuadro> criar({String titulo = '', Fundo fundo = Fundo.pontos}) async =>
      ResumoQuadro.fromJson(await _api.post('api/design/$_colecao', {'titulo': titulo, 'fundo': fundo.name}));

  Future<ResumoQuadro> editar(String id, {String? titulo, Fundo? fundo, List<Pagina>? paginas}) async =>
      ResumoQuadro.fromJson(
        await _api.patch('api/design/$_colecao/$id', {
          'titulo': ?titulo,
          'fundo': ?fundo?.name,
          if (paginas != null) 'paginas': [for (final p in paginas) p.toJson()],
        }),
      );

  /// Grava os elementos sobre a [versao] lida. Versão velha → [ApiErro] com status 409.
  Future<ResumoQuadro> salvar(
    String id,
    int versao,
    List<Elemento> elementos, {
    Map<String, String> paginaDe = const {},
  }) async => ResumoQuadro.fromJson(
    await _api.put('api/design/$_colecao/$id/elementos', {
      'versao': versao,
      'elementos': [for (final e in elementos) jsonComPagina(e, paginaDe)],
    }),
  );

  /// Cria um quadro a partir de um arquivo do draw.io (`.drawio`/`.xml`, todas as páginas).
  Future<ResumoQuadro> importarDrawio(String nome, List<int> bytes) async => ResumoQuadro.fromJson(
    await _api.enviarArquivo('api/design/quadros/importar-drawio', 'arquivo', nome, bytes) as Map<String, dynamic>,
  );

  /// O quadro como `.drawio` (para abrir no draw.io/diagrams.net).
  Future<Uint8List> baixarDrawio(String id) => _api.getBytes('api/design/$_colecao/$id/drawio');

  Future<ResumoQuadro> duplicar(String id) async =>
      ResumoQuadro.fromJson(await _api.post('api/design/$_colecao/$id/duplicar'));

  Future<Uint8List> miniatura(String id) => _api.getBytes('api/design/$_colecao/$id/miniatura');

  Future<void> enviarMiniatura(String id, List<int> png) =>
      _api.enviarArquivo('api/design/$_colecao/$id/miniatura', 'arquivo', 'miniatura.png', png);

  Future<void> excluir(String id) => _api.delete('api/design/$_colecao/$id');

  // ---------- Wireframes ----------

  Future<List<ResumoQuadro>> listarWireframes() async => [
    for (final j in await _api.get('api/design/wireframes') as List) ResumoQuadro.fromJson(j),
  ];

  Future<Wireframe> obterWireframe(String id) async => Wireframe.fromJson(await _api.get('api/design/wireframes/$id'));

  Future<ResumoQuadro> criarWireframe({String titulo = ''}) async =>
      ResumoQuadro.fromJson(await _api.post('api/design/wireframes', {'titulo': titulo}));

  Future<ResumoQuadro> editarWireframe(String id, {String? titulo, List<TelaWf>? telas}) async => ResumoQuadro.fromJson(
    await _api.patch('api/design/wireframes/$id', {
      'titulo': ?titulo,
      if (telas != null) 'paginas': [for (final t in telas) t.toJson()],
    }),
  );

  /// Versão velha → [ApiErro] com status 409.
  Future<ResumoQuadro> salvarWireframe(String id, int versao, List<Componente> componentes) async =>
      ResumoQuadro.fromJson(
        await _api.put('api/design/wireframes/$id/elementos', {
          'versao': versao,
          'elementos': [for (final c in componentes) c.toJson()],
        }),
      );

  /// Pacote para outra IA: ZIP (`AGENTS.md` + schema + `wireframe.json`) ou, com [soJson], só o JSON.
  Future<Uint8List> exportarWireframe(String id, {bool soJson = false}) =>
      _api.getBytes('api/design/wireframes/$id/ia?formato=${soJson ? 'json' : 'zip'}');

  /// Render da [tela] (PNG) que vai no ZIP da exportação.
  Future<void> enviarPngTela(String id, String tela, List<int> png) =>
      _api.enviarArquivo('api/design/wireframes/$id/telas/$tela/png', 'arquivo', '$tela.png', png);

  /// Cria um wireframe do que a IA devolveu (`.json`, `.zip` ou texto com bloco ```json).
  Future<ResumoQuadro> importarWireframe(String nome, List<int> bytes) async => ResumoQuadro.fromJson(
    await _api.enviarArquivo('api/design/wireframes/importar-ia', 'arquivo', nome, bytes) as Map<String, dynamic>,
  );

  /// Troca o conteúdo do wireframe [id] pelo que a IA devolveu.
  Future<Wireframe> reimportarWireframe(String id, String nome, List<int> bytes) async => Wireframe.fromJson(
    await _api.enviarArquivo('api/design/wireframes/$id/importar-ia', 'arquivo', nome, bytes) as Map<String, dynamic>,
  );

  Future<ResumoQuadro> duplicarWireframe(String id) async =>
      ResumoQuadro.fromJson(await _api.post('api/design/wireframes/$id/duplicar'));

  Future<void> excluirWireframe(String id) => _api.delete('api/design/wireframes/$id');

  // ---------- Imagens ----------

  /// Google Imagens: `[{url, miniatura, titulo, largura, altura}]`, 10 por [pagina]; [tipo] é
  /// `foto`, `icone`, `figura` ou `todos`.
  /// Busca primeiro do próprio aparelho (a VPS é bloqueada pelos buscadores); na web ou se falhar,
  /// pelo servidor.
  Future<List<Map<String, dynamic>>> buscarImagens(String q, {String tipo = 'foto', int pagina = 0}) async {
    if (!kIsWeb) {
      try {
        return await buscarNoBing(q, tipo, pagina);
      } catch (_) {}
    }
    return [
      for (final r in await _api.get(
        'api/design/imagens/busca?q=${Uri.encodeQueryComponent(q)}&tipo=$tipo&pagina=$pagina',
      ) as List)
        r as Map<String, dynamic>,
    ];
  }

  /// Copia a imagem de [url] para o servidor e devolve o id que o elemento [Imagem] guarda.
  Future<String> guardarImagem(String url) async =>
      (await _api.post('api/design/imagens', {'url': url}) as Map<String, dynamic>)['id'] as String;

  Future<Uint8List> imagem(String id) => _api.getBytes('api/design/imagens/$id');

  // ---------- Referências (Arquivos e Notas) ----------

  /// Trechos marcados nos arquivos lidos: `{texto, comentario, pagina, arquivo_titulo, referencia}`.
  Future<List<Map<String, dynamic>>> destaques(String q) async => [
    for (final r in await _api.get('api/arquivos/destaques?q=${Uri.encodeQueryComponent(q)}') as List)
      r as Map<String, dynamic>,
  ];

  /// Notas do cofre (resumo: `id`, `titulo`, `tipo`, `tags`).
  Future<List<Map<String, dynamic>>> notas(String q) async => [
    for (final r in await _api.get('api/notas?q=${Uri.encodeQueryComponent(q)}') as List) r as Map<String, dynamic>,
  ];

  /// Nota inteira (`corpo` em Markdown).
  Future<Map<String, dynamic>> nota(String id) async =>
      await _api.get('api/notas/${Uri.encodeComponent(id)}') as Map<String, dynamic>;

  // ---------- Fluxogramas com IA ----------

  /// `local` (worker no PC) e, com chave configurada, `claude`.
  Future<List<String>> provedoresFluxo() async => [
    for (final p in await _api.get('api/design/fluxos/provedores') as List) '$p',
  ];

  /// Gera o fluxo (estrutura pela IA, posições no servidor) e espera a tarefa terminar, consultando a
  /// cada 2 s. Devolve `{titulo, nos: [{id, tipo, texto, x, y, w, h}], ligacoes: [{de, para, rotulo}]}`.
  Future<Map<String, dynamic>> gerarFluxo({
    String pedido = '',
    String codigo = '',
    String arquivo = '',
    Map<String, dynamic>? atual,
    String provedor = 'local',
    bool Function()? cancelado,
  }) async {
    final t = await _api.post('api/design/fluxos/gerar', {
      'pedido': pedido,
      'codigo': codigo,
      'arquivo': arquivo,
      'atual': atual,
      'provedor': provedor,
    }) as Map<String, dynamic>;
    while (true) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (cancelado?.call() ?? false) throw ApiErro(0, 'Cancelado.');
      final r = await _api.get('api/design/fluxos/tarefas/${t['id']}') as Map<String, dynamic>;
      if (r['estado'] == 'pronto') return r['fluxo'] as Map<String, dynamic>;
      if (r['estado'] == 'erro') throw ApiErro(422, '${r['erro']}');
    }
  }
}
