import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';

import 'api_arquivos.dart';
import 'modelos.dart';

/// Anotações guardadas no aparelho: [base] é a última versão que o servidor confirmou e [atual]
/// a do aparelho; [pendente] quando ainda falta subir.
typedef AnotacoesLocais = ({Anotacoes base, Anotacoes atual, bool pendente});

Map<String, dynamic> _anotacoesJson(Anotacoes a) => {...a.toJson(versaoBase: a.versao), 'versao': a.versao};

/// Arquivos baixados para usar sem conexão. No armazém `arquivos`:
/// `<id>/meta.json`, `<id>/pdf`, `<id>/original` (quando não é o próprio PDF), `<id>/anotacoes.json`, `envios/<uid>` (arquivos novos à espera)
/// e `fila.json` (renomear, mover, tags, excluir e enviar feitos offline).
class AcervoOffline {
  AcervoOffline(this.api);

  final ApiArquivos api;

  /// Arquivos com o leitor aberto: a sincronização não mexe nas anotações deles (o leitor salva).
  static final abertos = <String>{};

  Future<Armazem> get _armazem => Armazem.abrir('arquivos');

  Future<FilaOffline> get _fila async => FilaOffline(await _armazem);

  Future<List<String>> _ids() async => [
    for (final n in await (await _armazem).listar(''))
      if (n != 'envios' && n != 'fila.json') n,
  ];

  Future<Set<String>> baixados() async => {...await _ids()};

  Future<List<Arquivo>> arquivos() async {
    final a = await _armazem;
    final lista = [
      for (final id in await _ids())
        if (await a.lerJson('$id/meta.json') case final Map<String, dynamic> j) Arquivo.fromJson(j),
    ];
    return lista..sort((x, y) => y.atualizado.compareTo(x.atualizado));
  }

  /// [pdf] quando o aparelho já tem os bytes (acabou de enviar): não baixa de novo. Guarda também
  /// o original (CSV, XML, DOCX…) para abrir e editar sem conexão; XML não tem PDF.
  Future<void> baixar(Arquivo a, {TarefaFundo? tarefa, Uint8List? pdf}) async {
    final (bytes, original, anotacoes) = await (
      a.tipo == 'xml' ? Future<Uint8List?>.value() : Future<Uint8List?>.value(pdf ?? api.pdf(a.id, tarefa: tarefa)),
      a.tipo == 'pdf' ? Future<Uint8List?>.value() : Future<Uint8List?>.value(api.original(a.id)),
      api.anotacoes(a.id),
    ).wait;
    final armazem = await _armazem;
    if (bytes != null) await armazem.gravar('${a.id}/pdf', bytes);
    if (original != null) await armazem.gravar('${a.id}/original', original);
    await guardarAnotacoes(a.id, anotacoes, anotacoes, pendente: false);
    await armazem.gravarJson('${a.id}/meta.json', a.toJson());
  }

  Future<void> remover(String id) async => (await _armazem).apagar(id);

  Future<Uint8List?> pdf(String id) async => (await _armazem).ler('$id/pdf');

  /// Original baixado (num PDF é o próprio [pdf]); `null` se foi baixado antes de guardar o original.
  Future<Uint8List?> original(String id) async => (await _armazem).ler('$id/original');

  Future<AnotacoesLocais?> anotacoes(String id) async {
    final j = await (await _armazem).lerJson('$id/anotacoes.json') as Map<String, dynamic>?;
    if (j == null) return null;
    return (
      base: Anotacoes.fromJson(j['base'] as Map<String, dynamic>),
      atual: Anotacoes.fromJson(j['atual'] as Map<String, dynamic>),
      pendente: j['pendente'] == true,
    );
  }

  Future<void> guardarAnotacoes(String id, Anotacoes base, Anotacoes atual, {required bool pendente}) async =>
      (await _armazem).gravarJson('$id/anotacoes.json', {
        'base': _anotacoesJson(base),
        'atual': _anotacoesJson(atual),
        'pendente': pendente,
      });

  /// Renomear, mover ou trocar as tags sem conexão: vale já na cópia local e sobe depois.
  Future<void> editar(Arquivo a, {String? titulo, String? pasta, List<String>? tags}) async {
    await (await _fila).adicionar({
      'op': 'editar',
      'id': a.id,
      'campos': {'titulo': ?titulo, 'pasta': ?pasta, 'tags': ?tags},
    });
    final armazem = await _armazem;
    final j = await armazem.lerJson('${a.id}/meta.json') as Map<String, dynamic>?;
    if (j != null) {
      await armazem.gravarJson('${a.id}/meta.json', {...j, 'titulo': ?titulo, 'pasta': ?pasta, 'tags': ?tags});
    }
  }

  /// Salva o original editado: sobe já; sem conexão fica no aparelho (o arquivo passa a estar
  /// baixado) e sobe na sincronização. Devolve o meta novo, ou `null` quando ficou na fila.
  Future<Arquivo?> salvarOriginal(Arquivo a, List<int> bytes) async {
    final armazem = await _armazem;
    final baixado = (await _ids()).contains(a.id);
    try {
      final novo = await api.substituirOriginal(a.id, a.nomeOriginal, bytes);
      if (baixado) {
        await armazem.gravar('${a.id}/original', bytes);
        await armazem.gravarJson('${a.id}/meta.json', novo.toJson());
      }
      return novo;
    } on ApiErro catch (e) {
      if (!semConexao(e)) rethrow;
      await armazem.gravar('${a.id}/original', bytes);
      if (!baixado) await armazem.gravarJson('${a.id}/meta.json', a.toJson());
      await (await _fila).adicionar({'op': 'substituir', 'id': a.id, 'nome': a.nomeOriginal});
      return null;
    }
  }

  Future<void> excluir(String id) async {
    await (await _fila).adicionar({'op': 'excluir', 'id': id});
    await remover(id);
  }

  /// Arquivo novo escolhido sem conexão: fica no aparelho e é enviado quando a conexão voltar.
  Future<void> enviar(String nome, List<int> bytes, {String pasta = ''}) async {
    final uid = '${DateTime.now().microsecondsSinceEpoch}';
    await (await _armazem).gravar('envios/$uid', bytes);
    await (await _fila).adicionar({'op': 'enviar', 'uid': uid, 'nome': nome, 'pasta': pasta});
  }

  /// Operações na fila mais arquivos com anotações ainda não enviadas.
  Future<int> pendencias() async {
    var n = (await (await _fila).itens()).length;
    for (final id in await _ids()) {
      if ((await anotacoes(id))?.pendente ?? false) n++;
    }
    return n;
  }

  /// Sobe a fila e as anotações feitas offline e atualiza as cópias locais com o servidor.
  /// Devolve avisos para mostrar (operações recusadas pelo servidor). Sem conexão, lança [ApiErro].
  Future<List<String>> sincronizar() async {
    final armazem = await _armazem;
    final avisos = await (await _fila).processar((op) async {
      switch (op['op']) {
        case 'editar':
          final c = op['campos'] as Map<String, dynamic>;
          await api.editar(
            op['id'] as String,
            titulo: c['titulo'] as String?,
            pasta: c['pasta'] as String?,
            tags: (c['tags'] as List?)?.cast<String>(),
          );
        case 'excluir':
          await api.excluir(op['id'] as String);
        case 'enviar':
          final bytes = await armazem.ler('envios/${op['uid']}');
          if (bytes != null) await api.enviar(op['nome'] as String, bytes, pasta: op['pasta'] as String);
          await armazem.apagar('envios/${op['uid']}');
        case 'substituir':
          final bytes = await armazem.ler('${op['id']}/original');
          if (bytes != null) await api.substituirOriginal(op['id'] as String, op['nome'] as String, bytes);
      }
      return null;
    });
    for (final id in await _ids()) {
      if (abertos.contains(id)) continue;
      final Arquivo meta;
      try {
        meta = await api.obter(id);
      } on ApiErro catch (e) {
        if (e.status != 404) rethrow;
        await remover(id); // excluído em outro aparelho
        continue;
      }
      // Original editado em outro lugar: baixa de novo o PDF e o original (quando já convertido).
      final antes = await armazem.lerJson('$id/meta.json') as Map<String, dynamic>?;
      // (Cópias antigas, sem sha256, ganham assim o original.) As anotações seguem abaixo.
      if (antes?['sha256'] != meta.sha256 && meta.pronto) {
        if (meta.tipo != 'xml') await armazem.gravar('$id/pdf', await api.pdf(id));
        if (meta.tipo != 'pdf') await armazem.gravar('$id/original', await api.original(id));
      }
      await armazem.gravarJson('$id/meta.json', meta.toJson());
      final local = await anotacoes(id);
      Anotacoes servidor;
      if (local != null && local.pendente) {
        try {
          servidor = await api.salvarAnotacoes(id, local.atual, local.base.versao);
        } on ApiErro catch (e) {
          if (e.status != 409) rethrow;
          final atuais = await api.anotacoes(id);
          servidor = await api.salvarAnotacoes(id, Anotacoes.mesclar(local.base, local.atual, atuais), atuais.versao);
        }
      } else {
        servidor = await api.anotacoes(id);
      }
      await guardarAnotacoes(id, servidor, servidor, pendente: false);
    }
    return avisos;
  }
}
