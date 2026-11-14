import 'package:flutter/foundation.dart';

import 'notes_api.dart';
import 'models.dart';

/// The open note, shared by the editor and the panels. [version] goes up on every saved change,
/// so the list and the analysis refresh.
class OpenNote extends ChangeNotifier {
  OpenNote(this.api);

  final NotesApi api;
  Note? note;
  bool loading = false;
  String? error;
  int version = 0;

  /// The editor registers here how to save unsaved changes; it runs before switching notes.
  Future<void> Function()? pending;

  Future<void> open(String id) async {
    await pending?.call();
    return _run(() => api.fetch(id));
  }

  Future<void> create(Map<String, dynamic> data) async {
    await pending?.call();
    return _run(() => api.create(data), changed: true);
  }

  /// Opens the note titled [title]; creates it if missing (unresolved link → new note).
  Future<void> openOrCreate(String title, {String type = 'nota'}) async {
    final found = await api.list(q: title);
    final match = found.where((r) => r.title.toLowerCase() == title.toLowerCase()).firstOrNull;
    return match != null ? open(match.id) : create({'titulo': title, 'tipo': type});
  }

  Future<void> save(Map<String, dynamic> data) =>
      _run(() => api.save(note!.id, data), changed: true);

  Future<void> delete() async {
    await api.delete(note!.id);
    note = null;
    version++;
    notifyListeners();
  }

  void close() {
    note = null;
    notifyListeners();
  }

  Future<void> _run(Future<Note> Function() action, {bool changed = false}) async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      note = await action();
      if (changed) version++;
    } catch (e) {
      error = '$e';
    }
    loading = false;
    notifyListeners();
  }
}
