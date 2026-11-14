import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models.dart';
import 'annotator.dart';
import 'toolbox.dart';
import 'geometry.dart';
import 'painting.dart';

/// Text of a page with the rectangle of each character, in PDF points as the page is displayed.
class PageText {
  PageText(this.text, this.chars);

  final String text;
  final List<Rect> chars;
}

/// Loads the text of each page only once (the smart highlighter uses it to find the lines).
class PageTexts {
  final Map<int, Future<PageText?>> _cache = {};
  final Map<int, PageText?> readyOnes = {};

  Future<PageText?> de(PdfPage page) => _cache.putIfAbsent(page.pageNumber, () async {
    try {
      final t = await page.loadStructuredText();
      final r = PageText(t.fullText, [for (final c in t.charRects) c.toRect(page: page)]);
      return readyOnes[page.pageNumber] = r.text.trim().isEmpty ? null : r;
    } catch (_) {
      return readyOnes[page.pageNumber] = null;
    }
  });
}

/// Ink layer over a PDF page: takes the pen (or the finger/mouse, if allowed),
/// draws the stroke live and saves it to the [Annotator] on release.
class PageLayer extends StatefulWidget {
  const PageLayer({
    super.key,
    required this.page,
    required this.annotator,
    required this.toolbox,
    required this.texts,
    required this.onCreateText,
    required this.onTextTap,
    required this.onHighlightTap,
  });

  final PdfPage page;
  final Annotator annotator;
  final ReaderToolbox toolbox;
  final PageTexts texts;
  final void Function(int page, Offset position) onCreateText;
  final void Function(AnnotatedText text) onTextTap;
  final void Function(Highlight highlight) onHighlightTap;

  @override
  State<PageLayer> createState() => _PageLayerState();
}

class _PageLayerState extends State<PageLayer> {
  final _live = _Live();
  double _scale = 1;
  Tool? _emUso;
  List<InkPoint> _points = [];
  Offset _start = Offset.zero;
  bool _straightened = false;
  Timer? _hold;
  (int, int)? _excerpt;

  int get _index => widget.page.pageNumber - 1;

  @override
  void dispose() {
    _hold?.cancel();
    _live.dispose();
    super.dispose();
  }

  Set<PointerDeviceKind> get _devices => {
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    if (!widget.toolbox.penOnly) ...{PointerDeviceKind.touch, PointerDeviceKind.mouse, PointerDeviceKind.unknown},
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.annotator, widget.toolbox]),
    builder: (context, _) => LayoutBuilder(
      builder: (context, c) {
        _scale = c.maxWidth / widget.page.width;
        final browsing = widget.toolbox.tool == Tool.pan;
        final painting = Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(child: CustomPaint(painter: _PagePainter(widget.annotator.visible, _index, _scale))),
            CustomPaint(painter: _LivePainter(_live, _scale)),
          ],
        );
        if (browsing) return IgnorePointer(child: painting);
        return RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: {
            _InkRecognizer: GestureRecognizerFactoryWithHandlers<_InkRecognizer>(
              () => _InkRecognizer(_devices),
              (r) => r
                ..devices = _devices
                ..onItemTap = _tap
                ..onMove = _mover
                ..onDrop = _drop
                ..onCancel = _cancel,
            ),
          },
          child: painting,
        );
      },
    ),
  );

  Offset _pt(PointerEvent e) => e.localPosition / _scale;

  double _pressure(PointerEvent e) {
    if (e.kind != PointerDeviceKind.stylus && e.kind != PointerDeviceKind.invertedStylus) return 0.5;
    final band = e.pressureMax - e.pressureMin;
    if (band <= 0) return 0.5;
    return ((e.pressure - e.pressureMin) / band).clamp(0.05, 1.0);
  }

  void _tap(PointerDownEvent e) {
    // Pen eraser tip or S Pen side button pressed: erases, whatever the tool.
    final button = e.kind == PointerDeviceKind.stylus && e.buttons & kPrimaryStylusButton != 0;
    _emUso = e.kind == PointerDeviceKind.invertedStylus || button ? Tool.eraser : widget.toolbox.tool;
    _start = _pt(e);
    _straightened = false;
    _excerpt = null;
    switch (_emUso!) {
      case Tool.eraser:
        widget.annotator.startGesture();
        _erase(_start);
      case Tool.textMark:
        widget.texts.de(widget.page);
        _points = [InkPoint(_start.dx, _start.dy, 0.5)];
      case Tool.text || Tool.pan:
        break;
      default:
        _points = [InkPoint(_start.dx, _start.dy, _pressure(e))];
        _live.stroke = _liveStroke();
        _armHold();
    }
  }

  void _mover(PointerMoveEvent e) {
    final p = _pt(e);
    switch (_emUso) {
      case Tool.eraser:
        _erase(p);
      case Tool.textMark:
        _points.add(InkPoint(p.dx, p.dy, 0.5));
        _updateExcerpt(p);
      case Tool.text || Tool.pan || null:
        break;
      default:
        final last = _points.last.offset;
        if ((p - last).distance * _scale < 0.8) return;
        if (_straightened || widget.toolbox.straightLines) {
          _points = straighten([_points.first, InkPoint(p.dx, p.dy, _pressure(e))]);
        } else {
          // Stabilizer: follows the tip with a slight delay, absorbing the hand and pressure tremor.
          final a = _points.last;
          final s = a.offset + (p - a.offset) * 0.55;
          _points.add(InkPoint(s.dx, s.dy, a.p + (_pressure(e) - a.p) * 0.35));
          if ((p - last).distance * _scale > 3) _armHold();
        }
        _live.stroke = _liveStroke();
    }
  }

  void _drop(PointerUpEvent e) {
    _hold?.cancel();
    final p = _pt(e);
    final wasTap = (p - _start).distance * _scale < 6;
    switch (_emUso) {
      case Tool.eraser:
        widget.annotator.finishGesture();
        _live.eraser = null;
      case Tool.text:
        if (wasTap) _tapText(p);
      case Tool.textMark:
        if (wasTap) {
          _tapHighlight(p);
        } else {
          _saveHighlight();
        }
      case Tool.pan || null:
        break;
      default:
        // The stabilizer lags a bit behind: the stroke ends where the tip left.
        if (_points.length > 1 && !_straightened && !widget.toolbox.straightLines) {
          _points.add(InkPoint(p.dx, p.dy, _points.last.p));
        }
        if (_points.isNotEmpty) widget.annotator.adicionar(_liveStroke()!);
    }
    _clear();
  }

  void _cancel() {
    _hold?.cancel();
    if (_emUso == Tool.eraser) widget.annotator.finishGesture();
    _clear();
  }

  void _clear() {
    _emUso = null;
    _points = [];
    _excerpt = null;
    _live
      ..stroke = null
      ..excerpt = const []
      ..eraser = null;
  }

  /// Holding the pen still at the end of the stroke for half a second straightens it (Samsung Notes).
  void _armHold() {
    _hold?.cancel();
    _hold = Timer(const Duration(milliseconds: 550), () {
      if (_points.length < 3 || _straightened) return;
      _straightened = true;
      _points = straighten(_points);
      _live.stroke = _liveStroke();
    });
  }

  InkStroke? _liveStroke() {
    final f = _emUso;
    final brush = f == Tool.textMark ? Brush.marcador : f?.brush;
    if (brush == null) return null;
    final points = widget.toolbox.straightLines && _points.length > 1 ? straighten(_points) : _points;
    return InkStroke(
      id: newId(),
      page: _index,
      brush: brush,
      color: widget.toolbox.colorOf(f!),
      thickness: widget.toolbox.thicknessOf(f),
      points: List.of(points),
    );
  }

  void _erase(Offset p) {
    final radius = widget.toolbox.thicknessOf(Tool.eraser) / 2;
    _live.eraser = (p, radius);
    final a = widget.annotator.visible;
    widget.annotator.removeInGesture({
      for (final t in a.strokes)
        if (t.page == _index && touchesStroke(t, p, radius)) t.id,
      for (final d in a.highlights)
        if (d.page == _index && d.rectangles.any((r) => r.inflate(radius).contains(p))) d.id,
      for (final t in a.texts)
        if (t.page == _index && textBounds(t).inflate(radius).contains(p)) t.id,
    });
  }

  void _updateExcerpt(Offset p) {
    final text = widget.texts.readyOnes[widget.page.pageNumber];
    if (text == null) {
      // Page without text (scanned): becomes a straight free highlighter.
      _live.stroke = InkStroke(
        id: '',
        page: _index,
        brush: Brush.marcador,
        color: widget.toolbox.colorOf(Tool.textMark),
        thickness: widget.toolbox.thicknessOf(Tool.textMark),
        points: straighten(_points),
      );
      return;
    }
    final i = nearestChar(text.chars, _start);
    final j = nearestChar(text.chars, p);
    if (i == null || j == null) return;
    _excerpt = i <= j ? (i, j) : (j, i);
    _live.stroke = null;
    _live.excerpt = excerptRects(text.chars, _excerpt!.$1, _excerpt!.$2);
    _live.excerptColor = widget.toolbox.colorOf(Tool.textMark);
  }

  void _saveHighlight() {
    final text = widget.texts.readyOnes[widget.page.pageNumber];
    final excerpt = _excerpt;
    if (text == null || excerpt == null) {
      if (_live.stroke != null) widget.annotator.adicionar(_live.stroke!.copyWithId(newId()));
      return;
    }
    final content = text.text.substring(excerpt.$1, excerpt.$2 + 1).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (content.isEmpty) return;
    widget.annotator.adicionar(
      Highlight(
        id: newId(),
        page: _index,
        text: content,
        color: widget.toolbox.colorOf(Tool.textMark),
        rectangles: excerptRects(text.chars, excerpt.$1, excerpt.$2),
        created: DateTime.now(),
      ),
    );
  }

  void _tapText(Offset p) {
    for (final t in widget.annotator.visible.texts.reversed) {
      if (t.page == _index && textBounds(t).inflate(4).contains(p)) return widget.onTextTap(t);
    }
    widget.onCreateText(_index, p);
  }

  void _tapHighlight(Offset p) {
    for (final d in widget.annotator.visible.highlights.reversed) {
      if (d.page == _index && d.rectangles.any((r) => r.inflate(3).contains(p))) return widget.onHighlightTap(d);
    }
  }
}

extension on InkStroke {
  InkStroke copyWithId(String id) =>
      InkStroke(id: id, page: page, brush: brush, color: color, thickness: thickness, points: points, projects: projects);
}

/// What is being drawn right now (repaints only the top layer).
class _Live extends ChangeNotifier {
  InkStroke? _trace;
  List<Rect> _excerpt = const [];
  Color excerptColor = const Color(0xFFFFEB3B);
  (Offset, double)? _eraser;

  InkStroke? get stroke => _trace;
  set stroke(InkStroke? t) {
    _trace = t;
    notifyListeners();
  }

  List<Rect> get excerpt => _excerpt;
  set excerpt(List<Rect> r) {
    _excerpt = r;
    notifyListeners();
  }

  (Offset, double)? get eraser => _eraser;
  set eraser((Offset, double)? b) {
    _eraser = b;
    notifyListeners();
  }
}

class _PagePainter extends CustomPainter {
  _PagePainter(this.annotations, this.page, this.scale);

  final Annotations annotations;
  final int page;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    for (final d in annotations.highlights) {
      if (d.page == page) paintHighlight(canvas, d, scale);
    }
    for (final t in annotations.strokes) {
      if (t.page == page) paintStroke(canvas, t, scale);
    }
    for (final t in annotations.texts) {
      if (t.page == page) paintText(canvas, t, scale);
    }
  }

  @override
  bool shouldRepaint(_PagePainter old) =>
      !identical(old.annotations, annotations) || old.scale != scale || old.page != page;
}

class _LivePainter extends CustomPainter {
  _LivePainter(this.live, this.scale) : super(repaint: live);

  final _Live live;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final ink = Paint()
      ..color = live.excerptColor.withValues(alpha: 0.4)
      ..blendMode = BlendMode.multiply;
    for (final r in live.excerpt) {
      canvas.drawRect(Rect.fromLTRB(r.left * scale, r.top * scale, r.right * scale, r.bottom * scale), ink);
    }
    if (live.stroke case final t?) paintStroke(canvas, t, scale);
    if (live.eraser case (final p, final radius)) {
      canvas.drawCircle(
        p * scale,
        radius * scale,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = Colors.grey.shade600,
      );
    }
  }

  @override
  bool shouldRepaint(_LivePainter old) => old.scale != scale || old.live != live;
}

/// Wins the gesture arena as soon as an allowed device touches: the stroke comes out right away and the
/// viewer does not scroll along. Devices outside [devices] (the finger, in "só caneta" mode)
/// do not even enter, and the viewer keeps scrolling and zooming with them.
class _InkRecognizer extends OneSequenceGestureRecognizer {
  _InkRecognizer(this.devices);

  Set<PointerDeviceKind> devices;
  void Function(PointerDownEvent)? onItemTap;
  void Function(PointerMoveEvent)? onMove;
  void Function(PointerUpEvent)? onDrop;
  VoidCallback? onCancel;
  int? _pointer;

  @override
  bool isPointerAllowed(PointerDownEvent event) => _pointer == null && devices.contains(event.kind);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer, event.transform);
    _pointer = event.pointer;
    resolve(GestureDisposition.accepted);
    onItemTap?.call(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerMoveEvent) {
      onMove?.call(event);
    } else if (event is PointerUpEvent) {
      onDrop?.call(event);
      _end(event.pointer);
    } else if (event is PointerCancelEvent) {
      onCancel?.call();
      _end(event.pointer);
    }
  }

  void _end(int pointer) {
    _pointer = null;
    stopTrackingPointer(pointer);
  }

  @override
  void rejectGesture(int pointer) {
    super.rejectGesture(pointer);
    if (pointer == _pointer) {
      _pointer = null;
      onCancel?.call();
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'tinta';
}
