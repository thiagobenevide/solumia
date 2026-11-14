import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';

import 'files_api.dart';
import 'models.dart';

/// Annotations stored on the device: [base] is the last version the server confirmed and [current]
/// the device's; [pending] when it still needs to be uploaded.
typedef LocalAnnotations = ({Annotations base, Annotations current, bool pending});

Map<String, dynamic> _annotationsJson(Annotations a) => {...a.toJson(baseVersion: a.version), 'versao': a.version};

/// Files downloaded for offline use. In the `arquivos` store:
/// `<id>/meta.json`, `<id>/pdf`, `<id>/original` (when it is not the PDF itself), `<id>/anotacoes.json`, `envios/<uid>` (new files waiting)
/// and `fila.json` (rename, move, tags, delete and upload done offline).
class OfflineVault {
  OfflineVault(this.api);

  final FilesApi api;

  /// Files with the reader open: the sync does not touch their annotations (the reader saves them).
  static final openFiles = <String>{};

  Future<Armazem> get _store => Armazem.abrir('arquivos');

  Future<FilaOffline> get _queue async => FilaOffline(await _store);

  Future<List<String>> _ids() async => [
    for (final n in await (await _store).listar(''))
      if (n != 'envios' && n != 'fila.json') n,
  ];

  Future<Set<String>> downloadedItems() async => {...await _ids()};

  Future<List<FileItem>> files() async {
    final a = await _store;
    final items = [
      for (final id in await _ids())
        if (await a.lerJson('$id/meta.json') case final Map<String, dynamic> j) FileItem.fromJson(j),
    ];
    return items..sort((x, y) => y.updated.compareTo(x.updated));
  }

  /// [pdf] when the device already has the bytes (it just uploaded them): does not download again. Also stores
  /// the original (CSV, XML, DOCX…) to open and edit offline; XML has no PDF.
  Future<void> download(FileItem a, {TarefaFundo? task, Uint8List? pdf}) async {
    final (bytes, original, annotations) = await (
      a.type == 'xml' ? Future<Uint8List?>.value() : Future<Uint8List?>.value(pdf ?? api.pdf(a.id, task: task)),
      a.type == 'pdf' ? Future<Uint8List?>.value() : Future<Uint8List?>.value(api.original(a.id)),
      api.annotations(a.id),
    ).wait;
    final store = await _store;
    if (bytes != null) await store.gravar('${a.id}/pdf', bytes);
    if (original != null) await store.gravar('${a.id}/original', original);
    await storeAnnotations(a.id, annotations, annotations, pending: false);
    await store.gravarJson('${a.id}/meta.json', a.toJson());
  }

  Future<void> remover(String id) async => (await _store).apagar(id);

  Future<Uint8List?> pdf(String id) async => (await _store).ler('$id/pdf');

  /// Downloaded original (on a PDF it is the [pdf] itself); `null` if it was downloaded before storing the original.
  Future<Uint8List?> original(String id) async => (await _store).ler('$id/original');

  Future<LocalAnnotations?> annotations(String id) async {
    final j = await (await _store).lerJson('$id/anotacoes.json') as Map<String, dynamic>?;
    if (j == null) return null;
    return (
      base: Annotations.fromJson(j['base'] as Map<String, dynamic>),
      current: Annotations.fromJson(j['atual'] as Map<String, dynamic>),
      pending: j['pendente'] == true,
    );
  }

  Future<void> storeAnnotations(String id, Annotations base, Annotations current, {required bool pending}) async =>
      (await _store).gravarJson('$id/anotacoes.json', {
        'base': _annotationsJson(base),
        'atual': _annotationsJson(current),
        'pendente': pending,
      });

  /// Rename, move or change the tags offline: applies right away to the local copy and uploads later.
  Future<void> edit(FileItem a, {String? title, String? pasta, List<String>? tags}) async {
    await (await _queue).adicionar({
      'op': 'editar',
      'id': a.id,
      'campos': {'titulo': ?title, 'pasta': ?pasta, 'tags': ?tags},
    });
    final store = await _store;
    final j = await store.lerJson('${a.id}/meta.json') as Map<String, dynamic>?;
    if (j != null) {
      await store.gravarJson('${a.id}/meta.json', {...j, 'titulo': ?title, 'pasta': ?pasta, 'tags': ?tags});
    }
  }

  /// Saves the edited original: uploads right away; offline it stays on the device (the file becomes
  /// downloaded) and uploads on sync. Returns the new meta, or `null` when it went to the queue.
  Future<FileItem?> saveOriginal(FileItem a, List<int> bytes) async {
    final store = await _store;
    final downloaded = (await _ids()).contains(a.id);
    try {
      final isNew = await api.replaceOriginal(a.id, a.nomeOriginal, bytes);
      if (downloaded) {
        await store.gravar('${a.id}/original', bytes);
        await store.gravarJson('${a.id}/meta.json', isNew.toJson());
      }
      return isNew;
    } on ApiErro catch (e) {
      if (!semConexao(e)) rethrow;
      await store.gravar('${a.id}/original', bytes);
      if (!downloaded) await store.gravarJson('${a.id}/meta.json', a.toJson());
      await (await _queue).adicionar({'op': 'substituir', 'id': a.id, 'nome': a.nomeOriginal});
      return null;
    }
  }

  Future<void> delete(String id) async {
    await (await _queue).adicionar({'op': 'excluir', 'id': id});
    await remover(id);
  }

  /// New file picked offline: stays on the device and is uploaded when the connection returns.
  Future<void> send(String name, List<int> bytes, {String pasta = ''}) async {
    final uid = '${DateTime.now().microsecondsSinceEpoch}';
    await (await _store).gravar('envios/$uid', bytes);
    await (await _queue).adicionar({'op': 'enviar', 'uid': uid, 'nome': name, 'pasta': pasta});
  }

  /// Operations in the queue plus files with annotations not sent yet.
  Future<int> pendingItems() async {
    var n = (await (await _queue).itens()).length;
    for (final id in await _ids()) {
      if ((await annotations(id))?.pending ?? false) n++;
    }
    return n;
  }

  /// Uploads the queue and the annotations made offline and updates the local copies with the server.
  /// Returns warnings to show (operations refused by the server). Offline, it throws [ApiErro].
  Future<List<String>> sync() async {
    final store = await _store;
    final warnings = await (await _queue).processar((op) async {
      switch (op['op']) {
        case 'editar':
          final c = op['campos'] as Map<String, dynamic>;
          await api.edit(
            op['id'] as String,
            title: c['titulo'] as String?,
            pasta: c['pasta'] as String?,
            tags: (c['tags'] as List?)?.cast<String>(),
          );
        case 'excluir':
          await api.delete(op['id'] as String);
        case 'enviar':
          final bytes = await store.ler('envios/${op['uid']}');
          if (bytes != null) await api.send(op['nome'] as String, bytes, pasta: op['pasta'] as String);
          await store.apagar('envios/${op['uid']}');
        case 'substituir':
          final bytes = await store.ler('${op['id']}/original');
          if (bytes != null) await api.replaceOriginal(op['id'] as String, op['nome'] as String, bytes);
      }
      return null;
    });
    for (final id in await _ids()) {
      if (openFiles.contains(id)) continue;
      final FileItem meta;
      try {
        meta = await api.fetch(id);
      } on ApiErro catch (e) {
        if (e.status != 404) rethrow;
        await remover(id); // deleted on another device
        continue;
      }
      // Original edited elsewhere: downloads the PDF and the original again (when already converted).
      final antes = await store.lerJson('$id/meta.json') as Map<String, dynamic>?;
      // (Old copies, without sha256, get the original this way.) The annotations follow below.
      if (antes?['sha256'] != meta.sha256 && meta.pronto) {
        if (meta.type != 'xml') await store.gravar('$id/pdf', await api.pdf(id));
        if (meta.type != 'pdf') await store.gravar('$id/original', await api.original(id));
      }
      await store.gravarJson('$id/meta.json', meta.toJson());
      final local = await annotations(id);
      Annotations server;
      if (local != null && local.pending) {
        try {
          server = await api.saveAnnotations(id, local.current, local.base.version);
        } on ApiErro catch (e) {
          if (e.status != 409) rethrow;
          final currentItems = await api.annotations(id);
          server = await api.saveAnnotations(id, Annotations.merge(local.base, local.current, currentItems), currentItems.version);
        }
      } else {
        server = await api.annotations(id);
      }
      await storeAnnotations(id, server, server, pending: false);
    }
    return warnings;
  }
}
