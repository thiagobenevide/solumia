import 'package:agent_core/agent_core.dart';

/// On-device copy of the notes, to read, search, create and edit offline. In the `notas` store:
/// `notas/<id>.json` (JSON as the server sends it), `tipos.json`, `fila.json` and `ids.json`
/// (provisional `offline-…` id of a note created offline → id given by the server).
class NotesMirror {
  Future<Armazem> get _store => Armazem.abrir('notas');

  Future<FilaOffline> get queue async => FilaOffline(await _store);

  Future<List<Map<String, dynamic>>> allNotes() async {
    final a = await _store;
    return [
      for (final n in await a.listar('notas'))
        if (await a.lerJson('notas/$n') case final Map<String, dynamic> j) j,
    ];
  }

  Future<Map<String, dynamic>?> fetch(String id) async =>
      await (await _store).lerJson('notas/$id.json') as Map<String, dynamic>?;

  Future<void> store(Map<String, dynamic> note) async => (await _store).gravarJson('notas/${note['id']}.json', note);

  Future<void> remove(String id) async => (await _store).apagar('notas/$id.json');

  /// Replaces the whole mirror with the server's, keeping notes created offline that were not sent yet.
  Future<void> replace(List<Map<String, dynamic>> notes) async {
    final ids = {for (final n in notes) n['id']};
    for (final n in await allNotes()) {
      final id = n['id'] as String;
      if (!ids.contains(id) && !id.startsWith('offline-')) await remove(id);
    }
    for (final n in notes) {
      await store(n);
    }
  }

  Future<List<dynamic>?> types() async => await (await _store).lerJson('tipos.json') as List?;

  Future<void> storeTypes(List<dynamic> types) async => (await _store).gravarJson('tipos.json', types);

  Future<String> realId(String id) async {
    if (!id.startsWith('offline-')) return id;
    final ids = await (await _store).lerJson('ids.json') as Map?;
    return ids?[id] as String? ?? id;
  }

  Future<void> mapId(String provisional, String real) async {
    final a = await _store;
    await a.gravarJson('ids.json', {...(await a.lerJson('ids.json') as Map? ?? const {}), provisional: real});
  }
}
