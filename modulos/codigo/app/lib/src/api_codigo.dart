import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';

import 'modelos.dart';

/// Rotas de `/api/codigo`.
class ApiCodigo {
  ApiCodigo(String base, {String token = ''})
    : _api = ApiCliente(base, cabecalhos: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'});

  final ApiCliente _api;

  /// Fala → texto (Whisper do PC).
  Future<String> transcrever(List<int> wav) => transcreverFala(_api, wav);

  /// Motivo de não dar para pedir agora (sem worker no PC), ou `null`.
  Future<String?> indisponivel() async => (await _api.get('api/codigo/estado') as Map)['indisponivel'] as String?;

  Future<List<AbaCodigo>> listar() async => [
    for (final j in await _api.get('api/codigo/sessoes') as List) AbaCodigo.fromJson(j),
  ];

  Future<AbaCodigo> criar([String titulo = '']) async =>
      AbaCodigo.fromJson(await _api.post('api/codigo/sessoes', {'titulo': titulo}));

  /// A aba e as etapas a partir da posição [desde] (o app pede só as novas).
  Future<(AbaCodigo, List<Etapa>)> obter(String id, {int desde = 0}) async {
    final j = await _api.get('api/codigo/sessoes/$id?desde=$desde') as Map<String, dynamic>;
    return (
      AbaCodigo.fromJson(j['sessao'] as Map<String, dynamic>),
      [for (final e in j['eventos'] as List) Etapa(e as Map<String, dynamic>)],
    );
  }

  Future<AbaCodigo> renomear(String id, String titulo) async =>
      AbaCodigo.fromJson(await _api.patch('api/codigo/sessoes/$id', {'titulo': titulo}));

  Future<void> excluir(String id) => _api.delete('api/codigo/sessoes/$id');

  /// Manda o pedido ao Claude Code (continua a conversa da aba) com imagens de referência.
  Future<AbaCodigo> enviar(String id, String texto, {List<(String, Uint8List)> imagens = const []}) async =>
      AbaCodigo.fromJson(await _api.post('api/codigo/sessoes/$id/mensagens', {
        'texto': texto,
        'imagens': [for (final (nome, bytes) in imagens) {'nome': nome, 'b64': base64Encode(bytes)}],
      }));

  Future<AbaCodigo> parar(String id) async => AbaCodigo.fromJson(await _api.post('api/codigo/sessoes/$id/parar'));

  /// Pede ao Claude da aba o commit do que ele mudou; [push] e [publicar] (`publicar_app`).
  Future<AbaCodigo> commit(String id, {String mensagem = '', bool push = true, bool publicar = false}) async =>
      AbaCodigo.fromJson(await _api.post('api/codigo/sessoes/$id/commit', {
        'mensagem': mensagem,
        'push': push,
        'publicar': publicar,
      }));

  Future<Uint8List> imagem(String id, String nome) => _api.getBytes('api/codigo/sessoes/$id/imagens/$nome');

  /// `{status, log, rodando}` do repositório no PC.
  Future<Map<String, dynamic>> git() async => await _api.get('api/codigo/git') as Map<String, dynamic>;

  /// Navegador (só leitura): arquivos do repositório no [commit] (vazio = último) e o que ele mudou.
  Future<ArvoreCodigo> arvore([String commit = '']) async =>
      ArvoreCodigo(await _api.get('api/codigo/arvore?commit=$commit') as Map<String, dynamic>);

  Future<ArquivoCodigo> arquivo(String caminho, String commit) async => ArquivoCodigo(
    await _api.get('api/codigo/arquivo?caminho=${Uri.encodeQueryComponent(caminho)}&commit=$commit')
        as Map<String, dynamic>,
  );

  /// Linhas com [termo] no repositório ([observacoes]: só em comentários; sem termo, TODO/FIXME):
  /// `{resultados: [{caminho, linha, texto}], cortado}`.
  Future<Map<String, dynamic>> buscar(String termo, String commit, {bool observacoes = false}) async =>
      await _api.get(
            'api/codigo/busca?termo=${Uri.encodeQueryComponent(termo)}&commit=$commit&observacoes=$observacoes',
          )
          as Map<String, dynamic>;

  /// Contas do Claude Code no PC: `{ativa, contas: [{nome, logado, email, plano}]}`.
  Future<Map<String, dynamic>> contas() async => await _api.get('api/codigo/contas') as Map<String, dynamic>;

  /// Começa o login de [nome] (nova ou expirada) e devolve o link de autorização.
  Future<String> entrarConta(String nome) async =>
      (await _api.post('api/codigo/contas', {'nome': nome}) as Map)['url'] as String;

  /// Cola o [codigo] mostrado depois de autorizar; devolve a lista atualizada.
  Future<Map<String, dynamic>> codigoConta(String nome, String codigo) async =>
      await _api.post('api/codigo/contas/$nome/codigo', {'codigo': codigo}) as Map<String, dynamic>;

  Future<Map<String, dynamic>> ativarConta(String nome) async =>
      await _api.post('api/codigo/contas/$nome/ativar') as Map<String, dynamic>;

  Future<Map<String, dynamic>> removerConta(String nome) async =>
      await _api.delete('api/codigo/contas/$nome') as Map<String, dynamic>;
}
