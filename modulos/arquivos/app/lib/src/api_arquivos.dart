import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';

import 'modelos.dart';
import 'offline.dart';
import 'telas/projetos_leitura.dart';

/// Rotas de `/api/arquivos` (e a criação de nota em `/api/notas`). O mesmo cliente serve o
/// backend local (`http://localhost:48080`) e o da VPS (`https://…` com a chave).
class ApiArquivos {
  ApiArquivos(String base, {String token = ''})
    : _api = ApiCliente(base, cabecalhos: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'});

  final ApiCliente _api;

  /// Arquivos baixados no aparelho e o que foi feito sem conexão.
  late final offline = AcervoOffline(this);

  Map<String, String> get cabecalhos => _api.cabecalhos;

  Future<List<Arquivo>> listar({String q = '', String? pasta}) async {
    final consulta = Uri(queryParameters: {'q': q, 'pasta': ?pasta}).query;
    return [for (final j in await _api.get('api/arquivos?$consulta') as List) Arquivo.fromJson(j)];
  }

  Future<List<String>> pastas() async => [...(await _api.get('api/arquivos/pastas') as List).cast<String>()];

  Future<Arquivo> obter(String id) async => Arquivo.fromJson(await _api.get('api/arquivos/$id'));

  /// Arquivo em branco gerado no servidor: `documento` (.docx), `planilha` (.xlsx) ou `apresentacao` (.pptx).
  Future<Arquivo> novo(String tipo, String titulo, {String pasta = ''}) async =>
      Arquivo.fromJson(await _api.post('api/arquivos/novo', {'tipo': tipo, 'titulo': titulo, 'pasta': pasta}));

  /// Devolve o arquivo guardado; `duplicado` quando um igual já existia.
  Future<(Arquivo, bool)> enviar(String nome, List<int> bytes, {String pasta = ''}) async {
    final j = await _api.enviarArquivo('api/arquivos', 'arquivo', nome, bytes, campos: {'pasta': pasta});
    return (Arquivo.fromJson(j), j['duplicado'] == true);
  }

  Future<Arquivo> editar(String id, {String? titulo, String? pasta, List<String>? tags}) async =>
      Arquivo.fromJson(await _api.patch('api/arquivos/$id', {'titulo': ?titulo, 'pasta': ?pasta, 'tags': ?tags}));

  Future<void> excluir(String id) => _api.delete('api/arquivos/$id');

  Future<Arquivo> duplicar(String id) async => Arquivo.fromJson(await _api.post('api/arquivos/$id/duplicar'));

  Future<void> reconverter(String id) => _api.post('api/arquivos/$id/converter');

  /// Em pedaços: PDF de 20 MB não depende de uma conexão longa sem quedas (celular, túnel).
  Future<Uint8List> pdf(String id, {TarefaFundo? tarefa}) => _api.getBytesEmPartes(
    'api/arquivos/$id/pdf',
    progresso: tarefa?.bytes,
    cancelado: () => tarefa?.cancelada ?? false,
  );

  Future<Uint8List> original(String id) => _api.getBytes('api/arquivos/$id/original');

  /// Troca o original pela versão editada; DOCX/PPTX/planilhas voltam a `convertendo`.
  Future<Arquivo> substituirOriginal(String id, String nome, List<int> bytes) async =>
      Arquivo.fromJson(await _api.enviarArquivo('api/arquivos/$id/original', 'arquivo', nome, bytes, metodo: 'PUT'));

  Uri urlMiniatura(Arquivo a) => _api.url('api/arquivos/${a.id}/miniatura?v=${a.atualizado.millisecondsSinceEpoch}');

  Future<Anotacoes> anotacoes(String id) async => Anotacoes.fromJson(await _api.get('api/arquivos/$id/anotacoes'));

  /// Salva sobre [versaoBase]. Se outro aparelho salvou antes, o servidor responde 409 e quem
  /// chamou busca as atuais e mescla ([Anotacoes.mesclar]).
  Future<Anotacoes> salvarAnotacoes(String id, Anotacoes a, int versaoBase) async =>
      Anotacoes.fromJson(await _api.put('api/arquivos/$id/anotacoes', a.toJson(versaoBase: versaoBase)));

  Future<List<Referencia>> destaques({String q = '', String? arquivoId}) async {
    final consulta = Uri(queryParameters: {'q': q, 'arquivo_id': ?arquivoId}).query;
    return [for (final j in await _api.get('api/arquivos/destaques?$consulta') as List) Referencia.fromJson(j)];
  }

  /// `seq` atual e as mudanças depois de [desde] (criado, editado, excluido, convertido, anotado).
  Future<(int, List<Map<String, dynamic>>)> mudancas(int desde) async {
    final j = await _api.get('api/arquivos/mudancas?desde=$desde') as Map<String, dynamic>;
    return (j['seq'] as int, [...(j['mudancas'] as List).cast<Map<String, dynamic>>()]);
  }

  /// Reescreve [trecho] pelo Claude Code no PC (nunca a API da Anthropic). [arquivoId] dá o documento
  /// inteiro como contexto. Devolve `{texto, mudancas: [{antes, depois, motivo}], observacoes}`.
  Future<Map<String, dynamic>> reescrever({
    required String trecho,
    required String objetivo,
    String instrucao = '',
    String feedback = '',
    String? arquivoId,
  }) async =>
      await _api.post('api/arquivos/reescrever', {
            'trecho': trecho,
            'objetivo': objetivo,
            'instrucao': instrucao,
            'feedback': feedback,
            'arquivo_id': ?arquivoId,
          })
          as Map<String, dynamic>;

  /// Tradução já feita do documento: página (0-based, texto) → `{segmentos, traducoes}`.
  Future<Map<String, dynamic>> traducao(String id) async =>
      await _api.get('api/arquivos/$id/traducao') as Map<String, dynamic>;

  // --- leitura guiada (Estudos › Linguagem, LLM local e voz do worker; nunca o Claude) ---

  /// Fala da [frase] no [idioma] e o tempo de cada palavra (`inicio`/`fim` na frase, `t0`/`t1` em s).
  Future<Map<String, dynamic>> fala(String frase, String idioma, double velocidade) async =>
      (await _api.post('api/estudos/linguagem/fala', {'texto': frase, 'idioma': idioma, 'velocidade': velocidade})
              as Map)
          .cast<String, dynamic>();

  /// Tradução do [termo] no sentido da [frase]: `traducao`, `classe`, `ipa`, `sentido`, `frase_traduzida`.
  Future<Map<String, dynamic>> traduzirTermo(String termo, String frase, String idioma) async =>
      (await _api.post('api/estudos/linguagem/traduzir', {'termo': termo, 'frase': frase, 'idioma': idioma}) as Map)
          .cast<String, dynamic>();

  /// "Criar tarefas": a palavra entra no caderno de vocabulário e a LLM local gera frases e exercícios.
  Future<Map<String, dynamic>> criarPalavra(Map<String, dynamic> dados) async =>
      (await _api.post('api/estudos/linguagem/vocabulario', dados) as Map).cast<String, dynamic>();

  /// Tempo de estudo feito no leitor (entra na trilha do idioma).
  Future<void> registrarAtividade(String tipo, String idioma, int minutos, Map<String, Object> detalhes) =>
      _api.post('api/estudos/linguagem/atividades', {
        'tipo': tipo,
        'idioma': idioma,
        'minutos': minutos,
        'detalhes': detalhes,
      });

  /// Gravação lendo [referencia] em voz alta → palavras certas/trocadas/puladas, ritmo e pronúncia.
  Future<Map<String, dynamic>> avaliarLeitura(
    List<int> wav,
    String idioma,
    String referencia, {
    String? arquivoId,
    String titulo = '',
    int? pagina,
  }) async =>
      (await _api.enviarArquivo(
                'api/estudos/linguagem/leituras-voz',
                'audio',
                'leitura.wav',
                wav,
                campos: {
                  'idioma': idioma,
                  'referencia': referencia,
                  'arquivo_id': ?arquivoId,
                  'titulo': titulo,
                  if (pagina != null) 'pagina': '$pagina',
                },
              )
              as Map)
          .cast<String, dynamic>();

  /// Traduz [paginas] (página → frases originais) pela LLM local do PC; as que já estão
  /// traduzidas com as mesmas frases voltam do cache.
  Future<Map<String, dynamic>> traduzir(String id, Map<int, List<String>> paginas, {bool refazer = false}) async =>
      await _api.post('api/arquivos/$id/traducao', {
            'paginas': [
              for (final e in paginas.entries) {'pagina': e.key, 'segmentos': e.value},
            ],
            'refazer': refazer,
          })
          as Map<String, dynamic>;

  /// Projetos de leitura do módulo Estudos, para ligar trechos e anotações a eles.
  Future<List<ProjetoLeitura>> projetosLeitura() async => [
    for (final j in await _api.get('api/estudos/projetos') as List) ProjetoLeitura.fromJson(j as Map<String, dynamic>),
  ];

  Future<ProjetoLeitura> criarProjetoLeitura(String nome) async =>
      ProjetoLeitura.fromJson(await _api.post('api/estudos/projetos', {'nome': nome}) as Map<String, dynamic>);

  /// Original convertido pelo LibreOffice no servidor (`odt`, `pdf`, `ods`, `csv`, `odp`…).
  Future<Uint8List> exportar(String id, String formato) =>
      _api.getBytes('api/arquivos/$id/exportar?formato=${Uri.encodeQueryComponent(formato)}');

  /// Nota (módulo Notas) com o conteúdo do arquivo em Markdown, para citar depois como referência.
  Future<String> notaDeReferencia(Arquivo a, String markdown) async {
    final nota = await _api.post('api/notas', {
      'titulo': a.titulo,
      'tipo': 'nota',
      'tags': ['referencia'],
      'propriedades': {
        'fonte': ['[[${a.titulo}]]'],
        'arquivo': a.id,
      },
      'corpo': markdown,
    });
    return nota['id'] as String;
  }

  /// Cria uma nota (módulo Notas) citando o destaque, com o arquivo como `fonte`.
  Future<String> criarNota(Referencia r, {required String titulo}) async {
    final nota = await _api.post('api/notas', {
      'titulo': titulo,
      'tipo': 'nota',
      'tags': ['referencia'],
      'propriedades': {
        'fonte': ['[[${r.arquivoTitulo}]]'],
        'pagina': r.destaque.pagina + 1,
      },
      'corpo': '${r.citacao}\n\n${r.destaque.comentario}'.trim(),
    });
    return nota['id'] as String;
  }

  /// Sessão de edição no Collabora (WOPI): action URL + `access_token` e validade (ms desde a época).
  Future<({Uri url, String token, int ttl})> sessaoCollabora(String id) async {
    final j = await _api.post('api/arquivos/$id/collabora') as Map<String, dynamic>;
    return (
      url: Uri.parse(j['url'] as String),
      token: j['access_token'] as String,
      ttl: (j['access_token_ttl'] as num).toInt(),
    );
  }
}
