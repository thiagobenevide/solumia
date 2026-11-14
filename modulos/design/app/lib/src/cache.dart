import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Local copy of a board: what the device has and whether it still needs to be sent to the server.
class LocalCopy {
  LocalCopy(this.summary, this.elements, {required this.pending, required this.erased, this.pageOf = const {}});

  final BoardSummary summary;
  final List<Elemento> elements;
  final bool pending;
  final Set<String> erased;
  final Map<String, String> pageOf;
}

/// Offline cache of the boards on the device (SharedPreferences: file on Android/desktop,
/// localStorage on the web). Without the plugin (tests), it becomes a memory-only cache.
class BoardCache {
  BoardCache._(this._prefs, this._prefix);

  /// [prefix] separates collections on the device (`design.caderno.` for the notebooks).
  static Future<BoardCache> open({String prefix = 'design.quadro.'}) async {
    try {
      return BoardCache._(await SharedPreferences.getInstance(), prefix);
    } catch (_) {
      return BoardCache._(null, prefix);
    }
  }

  final SharedPreferences? _prefs;
  final Map<String, String> _memory = {};
  final String _prefix;

  String? _read(String key) => _prefs != null ? _prefs.getString(key) : _memory[key];

  Iterable<String> get _keys => (_prefs?.getKeys() ?? _memory.keys).where((k) => k.startsWith(_prefix));

  Future<void> store(
    Map<String, dynamic> summary,
    List<Elemento> elements, {
    required bool pending,
    Set<String> erased = const {},
    Map<String, String> pageOf = const {},
  }) async {
    final key = '$_prefix${summary['id']}';
    final text = jsonEncode({
      'resumo': summary,
      'elementos': [for (final e in elements) jsonWithPage(e, pageOf)],
      'pendente': pending,
      'apagados': [...erased],
    });
    if (_prefs == null) {
      _memory[key] = text;
      return;
    }
    try {
      await _prefs.setString(key, text);
    } catch (_) {
      // No space (web localStorage has ~5 MB): the server remains the source.
    }
  }

  LocalCopy? read(String id) {
    final text = _read('$_prefix$id');
    if (text == null) return null;
    final j = jsonDecode(text) as Map<String, dynamic>;
    return LocalCopy(
      BoardSummary.fromJson({...j['resumo'] as Map<String, dynamic>, 'total': (j['elementos'] as List).length}),
      [for (final e in j['elementos'] as List) ?Elemento.fromJson(e as Map<String, dynamic>)],
      pending: j['pendente'] == true,
      erased: {...(j['apagados'] as List? ?? const []).cast<String>()},
      pageOf: elementPages(j['elementos'] as List),
    );
  }

  /// Boards stored on the device, for the gallery without network.
  List<BoardSummary> summaries() => [
    for (final k in _keys)
      if (read(k.substring(_prefix.length)) case final c?) c.summary,
  ]..sort((a, b) => (b.updated ?? DateTime(0)).compareTo(a.updated ?? DateTime(0)));

  Future<void> remover(String id) async {
    _memory.remove('$_prefix$id');
    await _prefs?.remove('$_prefix$id');
  }
}
