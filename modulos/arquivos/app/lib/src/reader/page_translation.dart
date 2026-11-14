import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'translation.dart';

/// Portuguese text of a block, already fitted to its area, in PDF points.
class _Box {
  _Box(this.area, this.text);

  final Rect area;
  final TextPainter text;
}

/// Largest font size at which [text] fits in the block area (Portuguese is usually longer).
TextPainter _fit(String text, ScheduleBlock b) {
  final minimum = b.source * 0.4;
  var body = b.source;
  while (true) {
    final t = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.black87,
          fontSize: body,
          height: 1.15,
          fontWeight: b.title ? FontWeight.bold : null,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: switch (b.alignmentMode) {
        TextAlignment.left => TextAlign.left,
        TextAlignment.center => TextAlign.center,
        TextAlignment.right => TextAlign.right,
        TextAlignment.justified => TextAlign.justify,
      },
    )..layout(minWidth: b.area.width, maxWidth: b.area.width);
    if (t.height <= b.area.height + b.body * 0.2 || body <= minimum) return t;
    t.dispose();
    body *= 0.94;
  }
}

/// The translation in place of the PDF text, block by block, like Android's screen translation: figures and
/// margins stay the page's. It sits below the ink, so the highlights show on top.
class TranslationLayer extends StatefulWidget {
  const TranslationLayer({super.key, required this.page, required this.translator, required this.mode});

  final PdfPage page;
  final DocumentTranslator translator;
  final ValueNotifier<TranslationMode> mode;

  @override
  State<TranslationLayer> createState() => _TranslationLayerState();
}

class _TranslationLayerState extends State<TranslationLayer> {
  TranslatedPage? _done;
  var _boxes = <_Box>[];

  void _discard() {
    for (final c in _boxes) {
      c.text.dispose();
    }
    _boxes = [];
  }

  @override
  void dispose() {
    _discard();
    super.dispose();
  }

  List<_Box> _boxesOf(TranslatedPage p) {
    if (!identical(p, _done)) {
      _discard();
      _done = p;
      _boxes = [
        for (final b in p.blocks)
          if (b.sentences.isNotEmpty) _Box(b.area, _fit(p.textOf(b), b)),
      ];
    }
    return _boxes;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.translator, widget.mode]),
    builder: (context, _) {
      final p = widget.translator.pages[widget.page.pageNumber - 1];
      if (p == null || widget.mode.value != TranslationMode.overPage) return const SizedBox.shrink();
      return IgnorePointer(
        child: LayoutBuilder(
          builder: (context, c) => RepaintBoundary(
            child: CustomPaint(
              size: c.biggest,
              painter: _TranslationPainter(_boxesOf(p), c.maxWidth / widget.page.width),
            ),
          ),
        ),
      );
    },
  );
}

class _TranslationPainter extends CustomPainter {
  _TranslationPainter(this.boxes, this.scale);

  final List<_Box> boxes;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..scale(scale);
    final background = Paint()..color = Colors.white;
    for (final c in boxes) {
      canvas.drawRect(c.area.inflate(1), background);
    }
    for (final c in boxes) {
      c.text.paint(canvas, c.area.topLeft);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TranslationPainter old) => !identical(old.boxes, boxes) || old.scale != scale;
}

/// Small floating translation bar over the page: progress, pause, redo the page and close.
class TranslationBar extends StatelessWidget {
  const TranslationBar({
    super.key,
    required this.translator,
    required this.page,
    required this.onResume,
    required this.onClose,
  });

  final DocumentTranslator translator;
  final int page;
  final VoidCallback onResume;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = translator;
    final ready = t.pages.containsKey(page);
    final progressInfo = t.total > 0 && t.readyItems < t.total ? ' (${t.readyItems}/${t.total})' : '';
    final warning =
        t.error ??
        (t.noText.contains(page)
            ? 'Esta página não tem texto selecionável'
            : ready
            ? 'Traduzido para o português$progressInfo'
            : t.active
            ? 'Traduzindo para o português$progressInfo'
            : 'Tradução pausada$progressInfo');
    return Material(
      elevation: 4,
      shape: const StadiumBorder(),
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.translate, size: 18),
            const SizedBox(width: 8),
            Flexible(child: Text(warning, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 4),
            if (t.active)
              IconButton(tooltip: 'Pausar a tradução', icon: const Icon(Icons.pause), onPressed: t.parar)
            else if (t.readyItems < t.total || t.total == 0)
              IconButton(
                tooltip: 'Continuar traduzindo o documento',
                icon: const Icon(Icons.play_arrow),
                onPressed: onResume,
              ),
            if (ready)
              IconButton(
                tooltip: 'Traduzir esta página de novo',
                icon: const Icon(Icons.refresh),
                onPressed: t.translating(page) ? null : () => t.redo(page),
              ),
            IconButton(tooltip: 'Fechar a tradução', icon: const Icon(Icons.close), onPressed: onClose),
          ],
        ),
      ),
    );
  }
}
