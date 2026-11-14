import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';

import 'modelos.dart';

/// Rotas de `/api/painel` do backend da plataforma (`modulos/painel/backend`).
class ApiPainel {
  ApiPainel(String base, {String token = ''})
    : _api = ApiCliente(base, cabecalhos: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'});

  final ApiCliente _api;

  Future<Disciplina> disciplina() async => Disciplina.fromJson(await _api.get('api/painel/disciplina'));

  Future<Agenda> agenda(String dia) async => Agenda.fromJson(await _api.get('api/painel/agenda/$dia'));

  /// Monta a agenda do dia a partir das tarefas abertas do Kanban (substitui a atual).
  Future<Agenda> sugerir(String dia) async => Agenda.fromJson(await _api.post('api/painel/agenda/$dia/sugerir'));

  /// Grava a agenda editada; a resposta traz as contestações do cobrador.
  Future<Agenda> salvar(String dia, List<Bloco> blocos, String motivo) async => Agenda.fromJson(
    await _api.put('api/painel/agenda/$dia', {
      'blocos': [for (final b in blocos) b.toJson()],
      'motivo': motivo,
    }),
  );

  Future<void> marcar(String dia, String blocoId, bool feito) =>
      _api.post('api/painel/agenda/$dia/blocos/$blocoId/feito?feito=$feito');

  Future<List<Meta>> metas() async => [
    for (final j in await _api.get('api/painel/metas') as List) Meta.fromJson(j),
  ];

  Future<void> criarMeta(String titulo, String frequencia, double alvo, String unidade) => _api.post(
    'api/painel/metas',
    {'titulo': titulo, 'frequencia': frequencia, 'alvo': alvo, 'unidade': unidade},
  );

  Future<void> excluirMeta(String id) => _api.delete('api/painel/metas/$id');

  Future<void> registrar(String metaId, [double quantidade = 1]) =>
      _api.post('api/painel/metas/$metaId/acoes', {'quantidade': quantidade});

  /// `local` (worker no PC) e, se o servidor tiver a chave, `claude`.
  Future<List<String>> provedores() async => [for (final p in await _api.get('api/painel/provedores') as List) '$p'];

  /// Mensagem ao cobrador. “anote …” cria uma nota; “pesquise …” busca na base de notas; no resto
  /// ele responde e pode agir (ver [Resposta.executadas]).
  /// [imagem] (bytes, mime) segue só com esta mensagem; o modelo precisa ter visão.
  Future<Resposta> conversar(
    String mensagem,
    List<(String, String)> historico,
    String provedor, {
    (List<int>, String)? imagem,
  }) async => Resposta.fromJson(
    await _api.post('api/painel/conversar', {
      'mensagem': mensagem,
      'provedor': provedor,
      'historico': _historico(historico),
      if (imagem != null) ...{'imagem': base64Encode(imagem.$1), 'imagem_mime': imagem.$2},
    }),
  );

  /// Mensagem falada (WAV): o worker transcreve e segue como [conversar].
  Future<Resposta> voz(List<int> wav, List<(String, String)> historico, String provedor) async => Resposta.fromJson(
    await _api.enviarArquivo(
      'api/painel/voz',
      'audio',
      'fala.wav',
      wav,
      campos: {'provedor': provedor, 'historico': jsonEncode(_historico(historico))},
    ),
  );

  /// [conversar] em fluxo: [aoAvisar] recebe o andamento ("consultando a internet…") enquanto o
  /// servidor trabalha, para o app mostrar e falar sem deixar o usuário sem resposta.
  Future<Resposta> conversarFluxo(
    String mensagem,
    List<(String, String)> historico,
    String provedor, {
    (List<int>, String)? imagem,
    void Function(String aviso)? aoAvisar,
  }) => _fluxo(
    _api.eventos(
      'api/painel/conversar/fluxo',
      corpo: {
        'mensagem': mensagem,
        'provedor': provedor,
        'historico': _historico(historico),
        if (imagem != null) ...{'imagem': base64Encode(imagem.$1), 'imagem_mime': imagem.$2},
      },
    ),
    aoAvisar,
  );

  /// [voz] em fluxo: [aoTranscrever] chega antes da resposta, e [aoAvisar] como em [conversarFluxo].
  Future<Resposta> vozFluxo(
    List<int> wav,
    List<(String, String)> historico,
    String provedor, {
    void Function(String aviso)? aoAvisar,
    void Function(String texto)? aoTranscrever,
  }) => _fluxo(
    _api.eventos(
      'api/painel/voz/fluxo',
      arquivo: ('audio', 'fala.wav', wav),
      campos: {'provedor': provedor, 'historico': jsonEncode(_historico(historico))},
    ),
    aoAvisar,
    aoTranscrever,
  );

  static Future<Resposta> _fluxo(
    Stream<Map<String, dynamic>> eventos,
    void Function(String)? aoAvisar, [
    void Function(String)? aoTranscrever,
  ]) async {
    await for (final e in eventos) {
      switch (e['evento']) {
        case 'aviso':
          aoAvisar?.call('${e['texto']}');
        case 'transcricao':
          aoTranscrever?.call('${e['texto']}');
        case 'erro':
          throw ApiErro((e['status'] as num?)?.toInt() ?? 500, '${e['detalhe']}');
        case 'fim':
          return Resposta.fromJson(e);
      }
    }
    throw ApiErro(0, 'A conexão caiu antes da resposta.');
  }

  /// A resposta em áudio (WAV), sintetizada no worker. Com [trecho], só aquele pedaço da fala
  /// (vazio depois do último): dá para tocar um enquanto o próximo é gerado.
  Future<Uint8List> falar(String texto, {int? trecho}) =>
      _api.postBytes('api/painel/falar', {'texto': texto, 'trecho': ?trecho});

  Future<Dashboard> dashboard() async => Dashboard.fromJson(await _api.get('api/painel/dashboard'));

  static List<Map<String, String>> _historico(List<(String, String)> h) => [
    for (final (papel, texto) in h) {'papel': papel, 'texto': texto},
  ];
}
