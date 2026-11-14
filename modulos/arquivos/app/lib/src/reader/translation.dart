import 'dart:math' as math;

import 'package:agent_core/agent_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:pdfrx/pdfrx.dart';

import '../files_api.dart';
import '../models.dart';
import 'page_layer.dart';
import 'layout.dart';

export 'layout.dart';

/// How the translation shows in the reader: in the panel, or over the PDF itself.
enum TranslationMode { off, panel, overPage }

/// Translated page: the PDF text, the blocks and the translation of each sentence (empty = it did not come).
class TranslatedPage {
  TranslatedPage(this.text, this.blocks, this.translations);

  final PageText text;
  final List<ScheduleBlock> blocks;
  final List<String> translations;

  /// Sentences in reading order.
  late final sentences = sentencesOf(blocks);

  /// Portuguese of the block; a sentence that did not come stays in the original.
  String textOf(ScheduleBlock b) => [
    for (var k = 0; k < b.sentences.length; k++)
      translations[b.first + k].isEmpty ? b.sentences[k].original : translations[b.first + k],
  ].join(' ');
}

List<Sentence> sentencesOf(List<ScheduleBlock> blocks) => [for (final b in blocks) ...b.sentences];

/// Translates the whole document, page by page, from the one on screen; what was already translated
/// stays on the server (`/traducao`) and comes back right away when the file is opened again.
class DocumentTranslator extends ChangeNotifier {
  DocumentTranslator(this.api, this.fileId, this.texts);

  final FilesApi api;
  final String fileId;
  final PageTexts texts;

  /// 0-based pages.
  final pages = <int, TranslatedPage>{};
  final noText = <int>{};
  final _requesting = <int>{};
  Map<String, dynamic>? _cache;
  String? error;
  bool active = false;
  int total = 0;
  bool _discarded = false;

  bool translating(int page) => _requesting.contains(page);
  int get readyItems => pages.length + noText.length;

  void parar() {
    active = false;
    _notify();
  }

  void _notify() {
    if (!_discarded) notifyListeners();
  }

  @override
  void dispose() {
    _discarded = true;
    active = false;
    super.dispose();
  }

  Future<void> translateDocument(PdfDocument doc, int startingFrom) async {
    if (active) return;
    active = true;
    error = null;
    total = doc.pages.length;
    _notify();
    try {
      _cache ??= await api.translation(fileId);
      final order = [for (var i = startingFrom; i < total; i++) i, for (var i = 0; i < startingFrom; i++) i];
      var batch = <int, (PageText, List<ScheduleBlock>)>{};
      var size = 0;
      for (final i in order) {
        if (!active) return;
        if (pages.containsKey(i) || noText.contains(i)) continue;
        final t = await texts.de(doc.pages[i]);
        final blocks = t == null ? const <ScheduleBlock>[] : layOut(t.text, t.chars);
        final sentences = sentencesOf(blocks);
        if (t == null || sentences.isEmpty) {
          noText.add(i);
          _notify();
          continue;
        }
        final c = _cache?['$i'];
        if (c is Map && listEquals((c['segmentos'] as List?)?.cast<String>(), [for (final f in sentences) f.original])) {
          pages[i] = TranslatedPage(t, blocks, (c['traducoes'] as List).cast<String>());
          _notify();
          continue;
        }
        batch[i] = (t, blocks);
        size += sentences.fold(0, (s, f) => s + f.original.length);
        // The page on screen goes alone, to show up quickly; the others in batches of ~6 thousand characters.
        if (size > 6000 || i == startingFrom) {
          await _send(batch);
          batch = {};
          size = 0;
        }
      }
      if (active && batch.isNotEmpty) await _send(batch);
    } on ApiErro catch (e) {
      error = e.mensagem;
    } catch (e) {
      error = '$e';
    } finally {
      active = false;
      _notify();
    }
  }

  /// Requests the translation of [page] again (when it came out odd or incomplete).
  Future<void> redo(int page) async {
    final p = pages.remove(page);
    if (p == null) return;
    try {
      await _send({page: (p.text, p.blocks)}, redo: true);
    } on ApiErro catch (e) {
      pages[page] = p;
      error = e.mensagem;
      _notify();
    }
  }

  Future<void> _send(Map<int, (PageText, List<ScheduleBlock>)> batch, {bool redo = false}) async {
    _requesting.addAll(batch.keys);
    _notify();
    try {
      final r = await api.translate(fileId, {
        for (final e in batch.entries) e.key: [for (final f in sentencesOf(e.value.$2)) f.original],
      }, redo: redo);
      for (final e in batch.entries) {
        final translations = ((r['${e.key}'] as Map?)?['traducoes'] as List?)?.cast<String>() ?? const [];
        final n = sentencesOf(e.value.$2).length;
        pages[e.key] = TranslatedPage(e.value.$1, e.value.$2, [
          for (var k = 0; k < n; k++) k < translations.length ? translations[k] : '',
        ]);
      }
    } finally {
      _requesting.removeAll(batch.keys);
      _notify();
    }
  }
}

/// Translation of the page on screen, to read in Portuguese. Selecting an excerpt and tapping "Marcar no
/// original" marks the English sentences on the PDF and creates the highlight with original + translation (which goes
/// into the active reading project).
class TranslationPanel extends StatefulWidget {
  const TranslationPanel({
    super.key,
    required this.translator,
    required this.page,
    required this.highlights,
    required this.onMark,
    required this.onResume,
    required this.onClose,
  });

  final DocumentTranslator translator;

  /// Page on screen, 0-based.
  final int page;

  /// Highlights of the page, to show what was already marked.
  final List<Highlight> highlights;
  final void Function(TranslatedPage page, List<int> sentences) onMark;
  final VoidCallback onResume;
  final VoidCallback onClose;

  @override
  State<TranslationPanel> createState() => _TranslationPanelState();
}

class _TranslationPanelState extends State<TranslationPanel> {
  /// Selected sentences, by block (each paragraph reports its part of the selection).
  final _selection = <ScheduleBlock, Set<int>>{};
  int _generation = 0;

  List<int> get _sentences => _selection.values.expand((s) => s).toList()..sort();

  void _clear() {
    _selection.clear();
    _generation++;
  }

  @override
  void didUpdateWidget(TranslationPanel oldValue) {
    super.didUpdateWidget(oldValue);
    if (oldValue.page != widget.page) _clear();
  }

  void _selectedSomething(ScheduleBlock b, Set<int> sentences) {
    if (setEquals(_selection[b] ?? const {}, sentences)) return;
    setState(() => sentences.isEmpty ? _selection.remove(b) : _selection[b] = sentences);
  }

  void _mark(TranslatedPage p) {
    final sentences = _sentences;
    if (sentences.isEmpty) return;
    widget.onMark(p, sentences);
    setState(_clear);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.translator;
    final colors = Theme.of(context).colorScheme;
    final p = t.pages[widget.page];
    final header = Row(
      children: [
        const SizedBox(width: 12),
        const Icon(Icons.translate, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Tradução · p. ${widget.page + 1}'
            '${t.total > 0 && t.readyItems < t.total ? '  (${t.readyItems}/${t.total} páginas)' : ''}',
            style: Theme.of(context).textTheme.titleSmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (t.active)
          IconButton(tooltip: 'Pausar a tradução', icon: const Icon(Icons.pause), onPressed: t.parar)
        else if (t.readyItems < t.total || t.total == 0)
          IconButton(
            tooltip: 'Continuar traduzindo o documento',
            icon: const Icon(Icons.play_arrow),
            onPressed: widget.onResume,
          ),
        if (p != null)
          IconButton(
            tooltip: 'Traduzir esta página de novo',
            icon: const Icon(Icons.refresh),
            onPressed: t.translating(widget.page) ? null : () => t.redo(widget.page),
          ),
        IconButton(tooltip: 'Fechar a tradução', icon: const Icon(Icons.close), onPressed: widget.onClose),
      ],
    );
    Widget body;
    if (p != null) {
      final estilo = Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.5);
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SelectionArea(
              key: ValueKey((p, _generation)),
              contextMenuBuilder: (context, status) => AdaptiveTextSelectionToolbar.buttonItems(
                anchors: status.contextMenuAnchors,
                buttonItems: [
                  ContextMenuButtonItem(
                    label: 'Marcar no original',
                    onPressed: () {
                      status.hideToolbar();
                      _mark(p);
                    },
                  ),
                  ...status.contextMenuButtonItems,
                ],
              ),
              child: LayoutBuilder(
                builder: (context, area) => SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final b in p.blocks)
                        if (b.sentences.isNotEmpty || b.numbers.isNotEmpty)
                          _Paragraph(
                            page: p,
                            block: b,
                            estilo: estilo,
                            width: area.maxWidth - 32,
                            highlights: widget.highlights,
                            onSelect: (sentences) => _selectedSomething(b, sentences),
                          ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_selection.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: FilledButton.icon(
                icon: const Icon(Icons.border_color),
                label: const Text('Marcar no original (inglês + português)'),
                onPressed: () => _mark(p),
              ),
            ),
        ],
      );
    } else if (t.noText.contains(widget.page)) {
      body = const _Notice('Esta página não tem texto selecionável (imagem ou escaneada).');
    } else if (t.translating(widget.page) || t.active) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = _Notice(t.error ?? 'Toque em ▶ para traduzir o documento a partir desta página.');
    }
    return Material(
      color: colors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          if (t.error != null && p != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(t.error!, style: TextStyle(color: colors.error)),
            ),
          const Divider(height: 1),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// One page block in the panel, with the font size, alignment, indent and gap it has in the PDF.
class _Paragraph extends StatefulWidget {
  const _Paragraph({
    required this.page,
    required this.block,
    required this.estilo,
    required this.width,
    required this.highlights,
    required this.onSelect,
  });

  final TranslatedPage page;
  final ScheduleBlock block;
  final TextStyle? estilo;
  final double width;
  final List<Highlight> highlights;

  /// Indices (on the page) of the sentences the selection takes in this block.
  final ValueChanged<Set<int>> onSelect;

  @override
  State<_Paragraph> createState() => _ParagraphState();
}

class _ParagraphState extends State<_Paragraph> {
  final _notifier = SelectionListenerNotifier();
  var _bands = <(int, int)>[];

  @override
  void initState() {
    super.initState();
    _notifier.addListener(_selectionChanged);
  }

  @override
  void dispose() {
    _notifier.dispose();
    super.dispose();
  }

  void _selectionChanged() {
    final s = _notifier.selection;
    final r = s.range;
    final sentences = <int>{};
    if (s.status == SelectionStatus.uncollapsed && r != null) {
      final start = math.min(r.startOffset, r.endOffset);
      final end = math.max(r.startOffset, r.endOffset);
      for (var k = 0; k < _bands.length; k++) {
        if (_bands[k].$1 < end && _bands[k].$2 > start) sentences.add(widget.block.first + k);
      }
    }
    // The selection can change in the middle of a layout (the screen rotated, the panel resized).
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      widget.onSelect(sentences);
    } else {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onSelect(sentences);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.block;
    final p = widget.page;
    final colors = Theme.of(context).colorScheme;
    final spans = <InlineSpan>[];
    _bands = [];
    var pos = 0;
    void write(String text, [TextStyle? estilo]) {
      spans.add(TextSpan(text: text, style: estilo));
      pos += text.length;
    }

    if (b.firstLineIndent) write('\u2003\u2003');
    write(b.numbers);
    for (var k = 0; k < b.sentences.length; k++) {
      if (k > 0) write(' ');
      final f = b.sentences[k];
      final pt = p.translations[b.first + k];
      final start = pos;
      write(
        pt.isEmpty ? f.original : pt,
        TextStyle(
          fontStyle: pt.isEmpty ? FontStyle.italic : null,
          color: pt.isEmpty ? colors.outline : null,
          backgroundColor: widget.highlights
              .where((d) => d.text.contains(f.original))
              .firstOrNull
              ?.color
              .withValues(alpha: 0.35),
        ),
      );
      _bands.add((start, pos));
    }
    final estilo = widget.estilo;
    return Padding(
      padding: EdgeInsets.only(
        top: b.gapBefore * 10,
        left: widget.width * b.indent,
        right: widget.width * b.rightIndent,
      ),
      child: SelectionListener(
        selectionNotifier: _notifier,
        child: Text.rich(
          TextSpan(children: spans),
          textAlign: switch (b.alignmentMode) {
            TextAlignment.left => TextAlign.left,
            TextAlignment.center => TextAlign.center,
            TextAlignment.right => TextAlign.right,
            TextAlignment.justified => TextAlign.justify,
          },
          style: estilo?.copyWith(
            fontSize: (estilo.fontSize ?? 16) * b.scale.clamp(0.8, 1.7),
            fontWeight: b.title ? FontWeight.bold : null,
          ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(text, textAlign: TextAlign.center),
    ),
  );
}
