import 'dart:async';
import 'dart:ui' show Color, Rect;

import 'package:agent_core/agent_core.dart';
import 'package:flutter/foundation.dart';

import '../design_api.dart';
import '../cache.dart';
import '../models.dart';
import 'export.dart';
import 'images.dart';

enum SaveState { saved, pending, saving, error }

/// State of an open board: elements, undo/redo, autosave, offline cache and thumbnail.
/// Each change swaps the whole list (immutable), so the undo stores only references.
class BoardEditor extends ChangeNotifier {
  BoardEditor(
    this.api,
    this.cache,
    BoardSummary summary,
    List<Elemento> elements, {
    bool pending = false,
    Set<String> erased = const {},
    Map<String, String> pageOf = const {},
    this.offline = false,
  }) : id = summary.id,
       title = summary.title,
       background = summary.background,
       _summary = summary.toJson(),
       _version = summary.version,
       // On opening, the arrows stay as they were saved (recomputing with the blocks of all pages
       // changed the routes); only those imported from draw.io, without tips, are computed.
       _all = List.unmodifiable(reconnect(elements, keepReady: true)),
       _pageOf = {...pageOf},
       pages = summary.pages.isEmpty ? const [BoardPage('', 'Página 1')] : summary.pages,
       _erased = {...erased} {
    currentPage = pages.first.id;
    _applyFilter();
    if (pending) _schedule();
  }

  /// Opens from the server; without network, from the device copy. If the copy had unsent changes,
  /// merges with what is on the server and saves.
  static Future<BoardEditor> open(ApiDesign api, BoardCache cache, String id) async {
    BoardImageCache.instance.api = api;
    final local = cache.read(id);
    Board? remote;
    try {
      remote = await api.fetch(id);
    } catch (_) {
      if (local == null) rethrow;
    }
    if (remote == null) {
      return BoardEditor(
        api,
        cache,
        local!.summary,
        local.elements,
        pending: local.pending,
        erased: local.erased,
        pageOf: local.pageOf,
        offline: true,
      );
    }
    if (local != null && local.pending) {
      return BoardEditor(
        api,
        cache,
        remote.summary,
        merge(local.elements, remote.elements, local.erased),
        pending: true,
        erased: local.erased,
        pageOf: {...remote.pageOf, ...local.pageOf},
      );
    }
    unawaited(cache.store(remote.summary.toJson(), remote.elements, pending: false, pageOf: remote.pageOf));
    return BoardEditor(api, cache, remote.summary, remote.elements, pageOf: remote.pageOf);
  }

  final ApiDesign api;
  final BoardCache cache;
  final String id;
  String title;
  Background background;
  bool offline;
  final Map<String, dynamic> _summary;
  int _version;

  /// All elements, of all pages; [elements] is only the open page.
  List<Elemento> _all;
  List<Elemento> _elements = const [];
  final Map<String, String> _pageOf;

  /// Board tabs (draw.io: several pages in the same file).
  List<BoardPage> pages;
  late String currentPage;
  final List<List<Elemento>> _undo = [];
  final List<List<Elemento>> _redo = [];
  final Set<String> _erased;
  SaveState state = SaveState.saved;
  Timer? _timer;
  Future<void>? _saving;

  static const _undoLimit = 200;
  static const _wait = Duration(milliseconds: 1200);
  static const _retry = Duration(seconds: 15);

  List<Elemento> get elements => _elements;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  Rect? get bounds {
    final l = boundsOf(_elements), sheet = role?.retangulo;
    return sheet == null || l == null ? l ?? sheet : l.expandToInclude(sheet);
  }

  Map<String, dynamic> get _currentSummary => {
    ..._summary,
    'titulo': title,
    'fundo': background.name,
    'versao': _version,
    'paginas': [for (final p in pages) p.toJson()],
  };

  String _elementPage(Elemento e) {
    final p = _pageOf[e.id] ?? pages.first.id;
    return pages.any((x) => x.id == p) ? p : pages.first.id;
  }

  void _applyFilter() => _elements = List.unmodifiable(_all.where((e) => _elementPage(e) == currentPage));

  // ---------- pages ----------

  void goTo(String page) {
    if (page == currentPage || !pages.any((p) => p.id == page)) return;
    currentPage = page;
    _applyFilter();
    notifyListeners();
  }

  Future<void> _savePages() async {
    try {
      await api.edit(id, pages: pages);
    } catch (_) {
      // no network: the pages go into the cache (summary) and into the next save of the elements
    }
    await cache.store(_currentSummary, _all, pending: state != SaveState.saved, erased: _erased, pageOf: _pageOf);
  }

  /// The first page without an id gets one now (the server requires an id), and its elements stay on it.
  void _idForFirst() {
    if (pages.length != 1 || pages.first.id.isNotEmpty) return;
    pages = [BoardPage('p0', pages.first.name, color: pages.first.color, role: pages.first.role)];
    for (final e in _all) {
      _pageOf.putIfAbsent(e.id, () => 'p0');
    }
    currentPage = 'p0';
  }

  Future<void> newPage(String name) async {
    final pid = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    _idForFirst();
    // In the notebook the new sheet comes out with the same paper as the open sheet.
    pages = [...pages, BoardPage(pid, name, role: _page.role)];
    goTo(pid);
    _schedule();
    await _savePages();
  }

  Future<void> renamePage(String page, String name) async {
    pages = [for (final p in pages) p.id == page ? p.copy(name: name) : p];
    notifyListeners();
    await _savePages();
  }

  /// Colors the tab to mark the page (null removes the color).
  Future<void> colorPage(String page, Color? color) async {
    final wasCurrent = page == currentPage;
    if (page.isEmpty) {
      _idForFirst();
      page = pages.first.id;
      _schedule();
    }
    pages = [for (final p in pages) p.id == page ? p.copy(color: color, noColor: color == null) : p];
    if (wasCurrent) currentPage = page;
    notifyListeners();
    await _savePages();
  }

  BoardPage get _page => pages.firstWhere((p) => p.id == currentPage, orElse: () => pages.first);

  /// Notebook: paper of each sheet, with [defaultPaper] on the one without; board: null (infinite).
  Paper? defaultPaper;

  Paper? get role => defaultPaper == null ? null : _page.role ?? defaultPaper;

  /// Changes the paper of the open sheet or, with [all], of every sheet of the notebook.
  Future<void> changePaper(Paper isNew, {bool allItems = false}) async {
    if (currentPage.isEmpty) _idForFirst();
    pages = [for (final p in pages) allItems || p.id == currentPage ? p.copy(role: isNew) : p];
    _schedule();
    notifyListeners();
    await _savePages();
  }

  /// Notebook: the smart pen swaps the fresh stroke for an aligned line/figure (null = it stays).
  Elemento? Function(Traco stroke)? fitStroke;

  /// Deletes the page and what is on it (only the element list stays in the undo).
  Future<void> deletePage(String page) async {
    if (pages.length <= 1) return;
    final leaves = {for (final e in _all) if (_elementPage(e) == page) e.id};
    pages = [for (final p in pages) if (p.id != page) p];
    _erased.addAll(leaves);
    _all = List.unmodifiable(_all.where((e) => !leaves.contains(e.id)));
    currentPage = pages.first.id;
    _applyFilter();
    _schedule();
    notifyListeners();
    await _savePages();
  }

  void _swap(List<Elemento> newItems, {bool store = true}) {
    if (store) {
      _undo.add(_all);
      if (_undo.length > _undoLimit) _undo.removeAt(0);
      _redo.clear();
    }
    // Flowchart arrows follow the blocks; those that lost a block leave too (and count as erased).
    final reconnected = reconnect(newItems);
    if (reconnected.length != newItems.length) {
      final remainItems = {for (final e in reconnected) e.id};
      _erased.addAll(newItems.where((e) => !remainItems.contains(e.id)).map((e) => e.id));
    }
    // [newItems] is the open page: the other pages stay as they are.
    for (final e in reconnected) {
      _pageOf.putIfAbsent(e.id, () => currentPage);
    }
    _all = List.unmodifiable([..._all.where((e) => _elementPage(e) != currentPage), ...reconnected]);
    _applyFilter();
    _schedule();
    notifyListeners();
  }

  void adicionar(Elemento e) => _swap([..._elements, if (e is Traco) fitStroke?.call(e) ?? e else e]);

  void addMany(List<Elemento> newItems) => _swap([..._elements, ...newItems]);

  /// Swaps one group of elements for another in a single step (the undo brings everything back): the AI adjusting a
  /// flow. Ids that come back stop counting as erased.
  void swapGroup(Set<String> leave, List<Elemento> enterItem) {
    final enter = {for (final e in enterItem) e.id};
    _erased
      ..addAll(leave.difference(enter))
      ..removeAll(enter);
    _swap([
      for (final e in _elements)
        if (!leave.contains(e.id)) e,
      ...enterItem,
    ]);
  }

  /// Swaps elements by id (move, resize, recolor the selection), keeping the order.
  /// Layers: puts the elements in [ids] order (the last one in front); those not in [ids] stay behind.
  void reorder(List<String> ids) {
    final byId = {for (final e in _elements) e.id: e};
    final na = ids.toSet();
    _swap([..._elements.where((e) => !na.contains(e.id)), for (final id in ids) ?byId[id]]);
  }

  void replace(Map<String, Elemento> newItems) => _swap([for (final e in _elements) newItems[e.id] ?? e]);

  /// The eraser erases several elements in a single gesture: [startGesture] stores one undo step and
  /// the following [remove] calls (with `store: false`) go into it.
  void startGesture() {
    _undo.add(_all);
    _redo.clear();
  }

  void remover(Set<String> ids, {bool store = true}) {
    if (ids.isEmpty) return;
    _erased.addAll(ids);
    _swap([
      for (final e in _elements)
        if (!ids.contains(e.id)) e,
    ], store: store);
  }

  /// Undoes the eraser gesture that erased nothing (the stored step stayed equal to the current one).
  void endGesture() {
    if (_undo.isNotEmpty && identical(_undo.last, _all)) _undo.removeLast();
  }

  void clear() => remover({for (final e in _elements) e.id});

  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(_all);
    _all = _undo.removeLast();
    _applyFilter();
    _schedule();
    notifyListeners();
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(_all);
    _all = _redo.removeLast();
    _applyFilter();
    _schedule();
    notifyListeners();
  }

  void _schedule([Duration wait = _wait]) {
    state = SaveState.pending;
    _timer?.cancel();
    if (_discarded) return; // off screen: the device copy stays pending and goes on the next opening
    _timer = Timer(wait, save);
  }

  /// Saves now (the autosave calls it on its own; the screen calls it on leaving).
  Future<void> save() async {
    _timer?.cancel();
    await _saving;
    if (state == SaveState.saved) return;
    _saving = _save();
    await _saving;
    _saving = null;
  }

  Future<void> _save() async {
    state = SaveState.saving;
    notifyListeners();
    final erased = {..._erased};
    // First on the device: if the network drops, nothing is lost.
    await cache.store(_currentSummary, _all, pending: true, erased: _erased, pageOf: _pageOf);
    try {
      try {
        _version = (await api.save(id, _version, _all, pageOf: _pageOf)).version;
      } on ApiErro catch (e) {
        if (e.status != 409) rethrow;
        // Another device saved first: merges the two versions and saves over its one.
        final remote = await api.fetch(id);
        remote.pageOf.forEach((k, v) => _pageOf.putIfAbsent(k, () => v));
        _all = List.unmodifiable(merge(_all, remote.elements, _erased));
        _applyFilter();
        _version = (await api.save(id, remote.summary.version, _all, pageOf: _pageOf)).version;
      }
      offline = false;
      _erased.removeAll(erased);
      // Changed during the save? `_schedule` already marked it pending and the timer saves again.
      if (state == SaveState.saving) state = SaveState.saved;
      await cache.store(_currentSummary, _all, pending: state != SaveState.saved, erased: _erased, pageOf: _pageOf);
      unawaited(_uploadThumbnail());
    } catch (_) {
      // No network: stays in the cache and retries on its own.
      offline = true;
      state = SaveState.error;
      if (!_discarded) _timer = Timer(_retry, save);
    }
    notifyListeners();
  }

  Future<void> _uploadThumbnail() async {
    try {
      // thumbnail of the first page (it is the one that opens first)
      final first = [for (final e in _all) if (_elementPage(e) == pages.first.id) e];
      await api.uploadThumbnail(id, await png(first, background, density: 1, maxSide: 480));
    } catch (_) {
      // The thumbnail is a gallery ornament; failing does not hurt the board.
    }
  }

  @override
  void dispose() {
    _discarded = true;
    _timer?.cancel();
    super.dispose();
  }

  // The screen calls `save()` and disposes the editor right after: the save finishes later and can no
  // longer notify anyone.
  bool _discarded = false;

  @override
  void notifyListeners() {
    if (!_discarded) super.notifyListeners();
  }
}
