import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/foundation.dart';

import 'models.dart';
import 'offline.dart';

/// Routes of `/api/notas` in the platform backend (`backend/notes/api.py`). Offline, it reads and
/// writes the on-device mirror ([NotesMirror]); what was done offline is uploaded on the next call
/// that reaches the server.
class NotesApi {
  NotesApi(String base, {String token = ''})
    : _api = ApiCliente(base, cabecalhos: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'});

  final ApiCliente _api;
  final _mirror = NotesMirror();
  List<NoteType>? _types;
  // "Nota" also lists the vault types the app does not know (roteiro, moc...)
  Set<String> get _appTypes => {for (final t in _types ?? const <NoteType>[]) t.id}..remove('nota');
  DateTime? _mirroredAt;

  /// `atualizada` written by this device while syncing: does not count as an edit made elsewhere.
  final _own = <String, String>{};

  /// For the screen: offline right now, how many changes are waiting to upload and warnings from the
  /// last sync (e.g. a conflict that became a copy).
  final offline = ValueNotifier(false);
  final pendingCount = ValueNotifier(0);
  final warnings = ValueNotifier(<String>[]);

  Future<T> _orLocal<T>(Future<T> Function() remote, Future<T> Function() local) async {
    try {
      final r = await remote();
      offline.value = false;
      return r;
    } on ApiErro catch (e) {
      if (!semConexao(e)) rethrow;
      offline.value = true;
      return local();
    }
  }

  Future<bool> _hasPending() async => (await (await _mirror.queue).itens()).isNotEmpty;

  /// Uploads pending changes and refreshes the mirror in the background: reading never waits for
  /// the full sync (it downloads every note).
  Future<void> _beforeRead() async {
    if (await _hasPending()) {
      unawaited(sync().then<void>((_) {}, onError: (_) {}));
    } else if (_mirroredAt == null || DateTime.now().difference(_mirroredAt!) > const Duration(minutes: 10)) {
      _mirroredAt = DateTime.now();
      unawaited(sync().then<void>((_) {}, onError: (_) => _mirroredAt = null));
    }
  }

  Future<List<NoteSummary>> list({String q = '', String? type}) => _orLocal(
    () async {
      await _beforeRead();
      final qs = Uri(queryParameters: {'q': q, 'tipo': ?type}).query;
      return [for (final j in await _api.get('api/notas?$qs') as List) NoteSummary.fromJson(j)];
    },
    () async {
      final term = q.toLowerCase();
      final found = [
        for (final j in await _mirror.allNotes())
          if ((type == null || j['tipo'] == type || type == 'nota' && !_appTypes.contains(j['tipo'])) &&
              [j['titulo'], ...?j['aliases'] as List?, j['corpo']].any((t) => '$t'.toLowerCase().contains(term)))
            j,
      ]..sort((a, b) => '${b['atualizada']}'.compareTo('${a['atualizada']}'));
      return [for (final j in found) NoteSummary.fromJson({...j, 'entradas': (j['entradas'] as List?)?.length ?? 0})];
    },
  );

  /// Types almost never change: fetched once per session.
  Future<List<NoteType>> types() async => _types ??= await _orLocal<List<NoteType>>(
    () async {
      final j = await _api.get('api/notas/tipos') as List;
      await _mirror.storeTypes(j);
      return [for (final t in j) NoteType.fromJson(t)];
    },
    () async => [for (final t in await _mirror.types() ?? const []) NoteType.fromJson(t)],
  );

  Future<List<String>> suggestions(String q) => _orLocal(
    () async => [
      for (final j in await _api.get('api/notas/sugestoes?${Uri(queryParameters: {'q': q}).query}') as List)
        j['titulo'] as String,
    ],
    () async => [
      for (final j in await _mirror.allNotes())
        if ('${j['titulo']}'.toLowerCase().contains(q.toLowerCase())) j['titulo'] as String,
    ].take(10).toList(),
  );

  /// The device copy of the note, to show it at once while [fetch] asks the server; null if absent.
  Future<Note?> cached(String id) async {
    try {
      final j = await _mirror.fetch(await _mirror.realId(id));
      return j == null ? null : Note.fromJson(j);
    } catch (_) {
      return null;
    }
  }

  Future<Note> fetch(String id) async {
    id = await _mirror.realId(id);
    // an edit made offline is still waiting to upload: the device copy is the newest one
    if (await _hasPending()) {
      final local = await _mirror.fetch(id);
      if (local != null) {
        await _beforeRead();
        return Note.fromJson(local);
      }
    }
    return _orLocal(
      () async {
        await _beforeRead();
        final j = await _api.get('api/notas/$id') as Map<String, dynamic>;
        await _mirror.store(j);
        return Note.fromJson(j);
      },
      () async {
        final j = await _mirror.fetch(id);
        if (j == null) throw ApiErro(0, 'Sem conexão e esta nota ainda não estava no aparelho');
        return Note.fromJson(j);
      },
    );
  }

  Future<Note> create(Map<String, dynamic> data) => _orLocal(
    () async {
      final j = await _api.post('api/notas', data) as Map<String, dynamic>;
      await _mirror.store(j);
      return Note.fromJson(j);
    },
    () async {
      final now = DateTime.now().toIso8601String();
      final id = 'offline-${DateTime.now().microsecondsSinceEpoch}';
      final j = _local({'id': id, 'tipo': 'nota', 'criada': now, '_base': null, ...data}, now);
      await (await _mirror.queue).adicionar({'op': 'criar', 'id': id, 'dados': data});
      await _mirror.store(j);
      await _countPending();
      return Note.fromJson(j);
    },
  );

  Future<Note> save(String id, Map<String, dynamic> data) async {
    id = await _mirror.realId(id);
    return _orLocal(
      () async {
        final j = await _api.put('api/notas/$id', data) as Map<String, dynamic>;
        await _mirror.store(j);
        return Note.fromJson(j);
      },
      () async {
        final current = await _mirror.fetch(id);
        if (current == null) throw ApiErro(0, 'Sem conexão e esta nota ainda não estava no aparelho');
        // `_base`: the server's `atualizada` when the offline edit started (detects conflicts).
        final base = current.containsKey('_base') ? current['_base'] : current['atualizada'];
        final j = _local({...current, ...data, '_base': base}, DateTime.now().toIso8601String());
        await (await _mirror.queue).adicionar({'op': 'salvar', 'id': id, 'dados': data, 'base': base});
        await _mirror.store(j);
        await _countPending();
        return Note.fromJson(j);
      },
    );
  }

  Future<void> delete(String id) async {
    id = await _mirror.realId(id);
    await _orLocal(() => _api.delete('api/notas/$id'), () async {
      await (await _mirror.queue).adicionar({'op': 'excluir', 'id': id});
      await _countPending();
    });
    await _mirror.remove(id);
  }

  Future<NoteAnalysis> analysis() async => NoteAnalysis.fromJson(await _api.get('api/notas/analise'));

  /// Note stored only on the device, with the fields the list and the editor use.
  static Map<String, dynamic> _local(Map<String, dynamic> j, String now) {
    final props = Map<String, dynamic>.from(j['propriedades'] as Map? ?? const {});
    return {...j, 'atualizada': now, 'status': props['status'] ?? j['status'], 'prazo': props['prazo'] ?? j['prazo']};
  }

  Future<void> _countPending() async => pendingCount.value = (await (await _mirror.queue).itens()).length;

  /// Uploads the offline queue and refreshes the mirror with every note on the server. Offline, it
  /// throws [ApiErro] with status 0.
  Future<List<String>> sync() async {
    final done = await (await _mirror.queue).processar(_execute);
    await _countPending();
    final allNotes = [for (final j in await _api.get('api/notas/espelho') as List) Map<String, dynamic>.from(j)];
    await _mirror.replace(allNotes);
    _mirroredAt = DateTime.now();
    if (done.isNotEmpty) warnings.value = [...warnings.value, ...done];
    return done;
  }

  Future<String?> _execute(Map<String, dynamic> op) async {
    final data = Map<String, dynamic>.from(op['dados'] as Map? ?? const {});
    switch (op['op']) {
      case 'criar':
        Map<String, dynamic> j;
        try {
          j = await _api.post('api/notas', data) as Map<String, dynamic>;
        } on ApiErro catch (e) {
          if (e.status != 409) rethrow; // a note with this title already exists: it goes in as a copy
          j = await _api.post('api/notas', {...data, 'titulo': '${data['titulo']} (offline)'}) as Map<String, dynamic>;
        }
        await _mirror.mapId(op['id'] as String, j['id'] as String);
        await _mirror.remove(op['id'] as String);
        await _mirror.store(j);
      case 'salvar':
        final id = await _mirror.realId(op['id'] as String);
        final server = await _api.get('api/notas/$id') as Map<String, dynamic>;
        final base = op['base'];
        if (base != null && server['atualizada'] != base && server['atualizada'] != _own[id]) {
          // Edited here offline and elsewhere: nothing is lost, the device version becomes a copy.
          final dt = DateTime.now();
          final title = '${data['titulo'] ?? server['titulo']} (offline ${dt.day}/${dt.month} ${dt.hour}h${dt.minute})';
          await _api.post('api/notas', {
            for (final c in ['tipo', 'tags', 'aliases', 'propriedades', 'corpo']) c: data[c] ?? server[c],
            'titulo': title,
          });
          return '"${server['titulo']}" mudou em outro lugar enquanto você estava offline; sua versão virou "$title".';
        }
        final j = await _api.put('api/notas/$id', data) as Map<String, dynamic>;
        _own[id] = j['atualizada'] as String;
        await _mirror.store(j);
      case 'excluir':
        await _api.delete('api/notas/${await _mirror.realId(op['id'] as String)}');
    }
    return null;
  }
}
