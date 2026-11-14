import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../design_api.dart';

/// Board images already decoded, by id. Painting is synchronous: it asks for the image, draws a
/// placeholder while it has not arrived and repaints (this notifier) when it arrives.
class BoardImageCache extends ChangeNotifier {
  BoardImageCache._();

  static final instance = BoardImageCache._();

  ApiDesign? api;
  final Map<String, ui.Image> _ready = {};
  final Map<String, Future<void>> _requested = {};

  ui.Image? fetch(String id) {
    final i = _ready[id];
    if (i == null) unawaited(carregar(id));
    return i;
  }

  Future<void> carregar(String id) {
    final api = this.api;
    if (api == null || id.isEmpty) return Future.value();
    return _requested[id] ??= () async {
      try {
        final codec = await ui.instantiateImageCodec(await api.image(id));
        _ready[id] = (await codec.getNextFrame()).image;
        notifyListeners();
      } catch (_) {
        // Stays on the placeholder; tries again the next time the board opens.
      }
    }();
  }

  /// Export/thumbnail: waits for the [ids] images before drawing.
  Future<void> ensure(Iterable<String> ids) => Future.wait({...ids}.map(carregar));
}

/// Search result being dragged from the panel to the board.
class DraggedImage {
  const DraggedImage(this.result);

  final Map<String, dynamic> result;
}

/// Side panel for Google Images search: type, scroll the results (loads more on reaching
/// the end) and tap the image (goes to the center) or drag it onto the board.
class ImagesPanel extends StatefulWidget {
  const ImagesPanel({super.key, required this.api, required this.insert, required this.close});

  final ApiDesign api;

  /// Gets the chosen result (`url`, `largura`, `altura`, `titulo`); finishes when inserted.
  final Future<void> Function(Map<String, dynamic> result) insert;
  final VoidCallback close;

  @override
  State<ImagesPanel> createState() => _ImagesPanelState();
}

class _ImagesPanelState extends State<ImagesPanel> {
  static const _types = [('foto', 'Fotos'), ('icone', 'Ícones'), ('figura', 'Figuras'), ('todos', 'Todos')];
  // The Google API only returns the first 100 (10 pages of 10).
  static const _maxPages = 10;

  final _search = TextEditingController();
  final _scroll = ScrollController();
  String _type = 'foto';
  final List<Map<String, dynamic>> _results = [];
  int _page = 0;
  bool _loading = false, _end = false;
  String? _error, _inserting;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 300) _moreResults();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _runSearch() {
    setState(() {
      _results.clear();
      _page = 0;
      _end = false;
      _error = null;
    });
    _moreResults();
  }

  Future<void> _moreResults() async {
    final q = _search.text.trim();
    if (_loading || _end || q.isEmpty) return;
    setState(() => _loading = true);
    try {
      final newItems = await widget.api.searchImages(q, type: _type, page: _page);
      if (!mounted || q != _search.text.trim()) return;
      setState(() {
        _results.addAll(newItems);
        _page++;
        _end = newItems.isEmpty || _page >= _maxPages;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pick(Map<String, dynamic> r) async {
    if (_inserting != null) return;
    setState(() => _inserting = r['url'] as String);
    try {
      await widget.insert(r);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Não deu para usar a imagem: $e')));
      }
    } finally {
      if (mounted) setState(() => _inserting = null);
    }
  }

  /// Result thumbnail; if it does not open (some providers block it), tries the original image.
  Widget _thumbnail(Map<String, dynamic> r) {
    final url = r['url'] as String;
    final mini = r['miniatura'] as String? ?? '';
    Widget original() => Image.network(
      url,
      fit: BoxFit.cover,
      cacheWidth: 280,
      errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: mini.isEmpty ? original() : Image.network(mini, fit: BoxFit.cover, errorBuilder: (_, _, _) => original()),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
        child: Row(
          children: [
            Expanded(child: Text('Google Imagens', style: Theme.of(context).textTheme.titleSmall)),
            IconButton(tooltip: 'Fechar', onPressed: widget.close, icon: const Icon(Icons.close)),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: TextField(
          controller: _search,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _runSearch(),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Buscar imagens…',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(tooltip: 'Buscar', onPressed: _runSearch, icon: const Icon(Icons.search)),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Wrap(
          spacing: 6,
          children: [
            for (final (value, label) in _types)
              ChoiceChip(
                label: Text(label),
                selected: _type == value,
                visualDensity: VisualDensity.compact,
                onSelected: (_) {
                  setState(() => _type = value);
                  _runSearch();
                },
              ),
          ],
        ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      Expanded(
        child: GridView.builder(
          controller: _scroll,
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 140,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
          ),
          itemCount: _results.length + (_loading ? 1 : 0),
          itemBuilder: (context, i) {
            if (i >= _results.length) return const Center(child: CircularProgressIndicator());
            final r = _results[i];
            // Horizontal: the vertical drag keeps scrolling the grid.
            return Draggable<DraggedImage>(
              data: DraggedImage(r),
              affinity: Axis.horizontal,
              feedback: Opacity(opacity: 0.8, child: SizedBox.square(dimension: 100, child: _thumbnail(r))),
              child: Tooltip(
                message: '${r['titulo'] ?? ''}',
                child: InkWell(
                  onTap: () => _pick(r),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _thumbnail(r),
                      if (_inserting == r['url']) const Center(child: CircularProgressIndicator()),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ],
  );
}
