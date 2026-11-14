import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/foundation.dart';

import '../files_api.dart';
import '../models.dart';
import '../offline.dart';
import '../screens/reading_projects.dart';

/// `noAparelho`: offline, stored in the downloaded file; uploads when the connection returns.
enum SaveStatus { saved, pending, saving, error, onDevice }

/// Owner of an open file's annotations: edits, undoes/redoes and saves on its own shortly after
/// each change. If another device saved in between, fetches the server's and merges.
class Annotator extends ChangeNotifier {
  Annotator(this.api, this.fileId) {
    activeProjects.addListener(_onProjectsChanged);
  }

  final FilesApi api;
  final String fileId;

  Annotations _current = const Annotations();
  Annotations _synced = const Annotations();
  final List<Annotations> _undo = [];
  final List<Annotations> _redo = [];
  Timer? _wait;
  Future<void>? _isSaving;
  SaveStatus status = SaveStatus.saved;
  String? error;

  Annotations get current => _current;

  /// What shows in the reader: only what is in no project and what belongs to an active project.
  /// Marks of other projects stay stored, but hidden until the project is chosen.
  Annotations get visible {
    final assets = activeProjects.value.toSet();
    bool ve(SlideElement e) => e.projects.isEmpty || e.projects.any(assets.contains);
    if (identical(_current, _cacheBase) && identical(activeProjects.value, _activeCache)) return _cache;
    _cacheBase = _current;
    _activeCache = activeProjects.value;
    return _cache = _current.copy(
      strokes: _current.strokes.where(ve).toList(),
      highlights: _current.highlights.where(ve).toList(),
      texts: _current.texts.where(ve).toList(),
    );
  }

  Annotations _cache = const Annotations();
  Annotations? _cacheBase;
  List<String>? _activeCache;

  void _onProjectsChanged() => notifyListeners();
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  bool get hasPending => !identical(_current, _synced);

  /// File downloaded for offline: each save also stays on the device.
  bool _local = false;

  Future<void> carregar() async {
    OfflineVault.openFiles.add(fileId);
    final local = await api.offline.annotations(fileId);
    _local = local != null;
    try {
      final server = await api.annotations(fileId);
      if (local != null && local.pending) {
        // Annotated offline and not sent yet: merges with the server and uploads.
        _current = Annotations.merge(local.base, local.current, server);
        _synced = server;
        _schedule();
      } else {
        _current = _synced = server;
      }
    } on ApiErro catch (e) {
      if (!semConexao(e) || local == null) rethrow;
      _synced = local.base;
      _current = local.current;
      if (local.pending) status = SaveStatus.onDevice;
    }
    notifyListeners();
  }

  /// Another device annotated ([version] of the change log): brings its annotations, merging with
  /// what was not saved here yet.
  Future<void> refreshFromServer(int version) async {
    if (version <= _synced.version || _isSaving != null) return;
    final server = await api.annotations(fileId);
    _current = hasPending ? Annotations.merge(_synced, _current, server) : server;
    _synced = server;
    notifyListeners();
    if (hasPending) _schedule();
  }

  void _change(Annotations nova) {
    _undo.add(_current);
    if (_undo.length > 200) _undo.removeAt(0);
    _redo.clear();
    _current = nova;
    _schedule();
    notifyListeners();
  }

  /// What is born now goes into the active reading project(s).
  void adicionar(SlideElement e) {
    final assets = activeProjects.value;
    _change(_current.adicionar(e.projects.isEmpty && assets.isNotEmpty ? e.withProjects(assets) : e));
  }

  /// Links to the [projects] everything already annotated on the [page] (strokes, highlights and texts).
  int linkPage(int page, List<String> projects) {
    final v = visible;
    final elements = <SlideElement>[...v.strokes, ...v.highlights, ...v.texts];
    var nova = _current;
    var n = 0;
    for (final e in elements) {
      if (e.page != page || projects.every(e.projects.contains)) continue;
      nova = nova.replace(e.withProjects({...e.projects, ...projects}.toList()));
      n++;
    }
    if (n > 0) _change(nova);
    return n;
  }

  void replace(SlideElement e) => _change(_current.replace(e));

  void remover(Set<String> ids) {
    if (ids.isNotEmpty) _change(_current.remover(ids));
  }

  /// Erasing by dragging the eraser: a single undo step for the whole gesture.
  Annotations? _beforeGesture;

  void startGesture() => _beforeGesture = _current;

  void removeInGesture(Set<String> ids) {
    if (ids.isEmpty) return;
    _current = _current.remover(ids);
    notifyListeners();
  }

  void finishGesture() {
    final antes = _beforeGesture;
    _beforeGesture = null;
    if (antes == null || identical(antes, _current)) return;
    final after = _current;
    _current = antes;
    _change(after);
  }

  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(_current);
    _current = _undo.removeLast();
    _schedule();
    notifyListeners();
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(_current);
    _current = _redo.removeLast();
    _schedule();
    notifyListeners();
  }

  void _schedule() {
    status = SaveStatus.pending;
    _wait?.cancel();
    _wait = Timer(const Duration(milliseconds: 1200), save);
  }

  /// Saves now (also called on leaving the reader).
  Future<void> save() async {
    _wait?.cancel();
    if (_isSaving != null) return _isSaving;
    if (!hasPending) return;
    _isSaving = _send();
    try {
      await _isSaving;
    } finally {
      _isSaving = null;
    }
  }

  Future<void> _send() async {
    status = SaveStatus.saving;
    notifyListeners();
    final sent = _current;
    if (_local) await api.offline.storeAnnotations(fileId, _synced, sent, pending: true);
    try {
      Annotations saved;
      try {
        saved = await api.saveAnnotations(fileId, sent, _synced.version);
      } on ApiErro catch (e) {
        if (e.status != 409) rethrow;
        final server = await api.annotations(fileId);
        final merged = Annotations.merge(_synced, sent, server);
        saved = await api.saveAnnotations(fileId, merged, server.version);
        if (identical(_current, sent)) _current = merged;
      }
      // Keeps the same local objects (the undo compares by identity); only the version changes.
      final synced = identical(_current, sent) ? _current.copy(version: saved.version) : saved;
      if (identical(_current, sent)) _current = synced;
      _synced = synced;
      status = hasPending ? SaveStatus.pending : SaveStatus.saved;
      error = null;
      if (_local) await api.offline.storeAnnotations(fileId, _synced, _current, pending: hasPending);
      if (hasPending) _schedule();
    } catch (e) {
      status = _local && semConexao(e) ? SaveStatus.onDevice : SaveStatus.error;
      error = '$e';
      _wait = Timer(Duration(seconds: semConexao(e) ? 20 : 10), save);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    activeProjects.removeListener(_onProjectsChanged);
    _wait?.cancel();
    OfflineVault.openFiles.remove(fileId);
    super.dispose();
  }
}
