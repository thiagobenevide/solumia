import 'dart:math' as math;
import 'dart:ui' show Rect;

/// Sentence of a page's text: [start]..[end] (inclusive) are indices into the PDF text, the same
/// as the character rectangles, to mark the original when the translation is selected.
class Sentence {
  const Sentence(this.start, this.end, this.original);

  final int start;
  final int end;

  /// Sentence text with normalized spaces (it is what goes to the translator and to the highlight).
  final String original;
}

const _abbreviations = {
  'al', 'approx', 'ca', 'cf', 'ch', 'dr', 'e.g', 'eq', 'eqs', 'etc', 'fig', 'figs', 'i.e', 'mr', 'mrs', //
  'ms', 'no', 'nos', 'p', 'pp', 'prof', 'ref', 'refs', 'resp', 'sec', 'st', 'tab', 'vol', 'vs',
};
final _sentenceEnd = RegExp(r'''[.!?]["”’')\]]*\s+(?=["“'(\[]?[A-Z0-9])''');
final _paragraph = RegExp(r'\n[ \t\r]*\n');
final _spaces = RegExp(r'\s+');
final _isLetter = RegExp(r'\p{L}', unicode: true);

String normalize(String s) => s.replaceAll(_spaces, ' ').trim();

/// Splits the page text into sentences (sentence end followed by uppercase/number, or a blank line),
/// without cutting at abbreviations ("et al.", "Fig.", "e.g.") nor at initials ("J. Smith").
List<Sentence> segment(String text) {
  final cortes = <int>{};
  for (final m in _sentenceEnd.allMatches(text)) {
    final antes = text.substring(0, m.start);
    final word = antes.substring(antes.lastIndexOf(_spaces) + 1).replaceFirst(RegExp(r'^[(\["“]+'), '');
    final p = word.toLowerCase();
    if (_abbreviations.contains(p) || RegExp(r'^\p{Lu}$', unicode: true).hasMatch(word)) continue;
    cortes.add(m.end);
  }
  for (final m in _paragraph.allMatches(text)) {
    cortes.add(m.end);
  }
  final bounds = [0, ...(cortes.toList()..sort()), text.length];
  final sentences = <Sentence>[];
  for (var k = 0; k + 1 < bounds.length; k++) {
    var a = bounds[k];
    var b = bounds[k + 1] - 1;
    while (a <= b && text[a].trim().isEmpty) {
      a++;
    }
    while (b >= a && text[b].trim().isEmpty) {
      b--;
    }
    if (a > b) continue;
    final original = normalize(text.substring(a, b + 1));
    if (!_isLetter.hasMatch(original)) continue;
    sentences.add(Sentence(a, b, original));
  }
  return sentences;
}

enum TextAlignment { left, center, right, justified }

/// Text line of the page: [start]..[end] are text indices; [word] is the width of the first
/// word (decides whether the previous line ended early).
class _Row {
  _Row(this.start, Rect r) : end = start, area = r, word = r.width;

  final int start;
  int end;
  Rect area;
  double word;
  bool inWord = true;

  /// Heights of letters without a stem: they measure the font (the character box is tight to its drawing).
  final eyes = <double>[];
  double get eye => eyes.isEmpty ? 0 : (eyes.toList()..sort())[eyes.length ~/ 2];

  /// [r] continues on this line: same height, forward and without a table column gap in between.
  bool continua(Rect r) {
    final h = area.height;
    final overlapping = math.min(area.bottom, r.bottom) - math.max(area.top, r.top);
    return overlapping > 0.2 * math.min(h, r.height) && r.left >= area.right - h * 0.5 && r.left - area.right <= h * 2.5;
  }
}

const _withoutStem = 'acemnorsuvwxz';

/// Paragraph, heading or cell of the page, as it is in the PDF: [area] and [body] in points, [indent] and
/// [rightIndent] as a fraction of the column, [gapBefore] in line heights. Without [sentences] = numbers only.
class ScheduleBlock {
  ScheduleBlock._(this._lines)
    : start = _lines.first.start,
      end = _lines.last.end,
      area = _union(_lines),
      body = _median(_lines);

  final List<_Row> _lines;
  final int start;
  final int end;
  final Rect area;
  final double body;
  List<Sentence> sentences = const [];

  /// Index of the block's first sentence among the page sentences.
  int first = 0;
  TextAlignment alignmentMode = TextAlignment.left;
  bool title = false;
  bool firstLineIndent = false;
  double indent = 0;
  double rightIndent = 0;
  double gapBefore = 0;

  /// Font relative to the page's running text.
  double scale = 1;

  /// Block text when it has no sentences but has numbers (table cell, page number).
  String numbers = '';
  double _left = 0;
  double _right = 0;

  double get _eye => (_lines.map((l) => l.eye).toList()..sort())[_lines.length ~/ 2];

  /// Font size in points (the x-height is about 46% of it).
  double get source => _eye > 0 ? _eye / 0.46 : body * 1.2;

  static Rect _union(List<_Row> lines) => lines.map((l) => l.area).reduce((a, b) => a.expandToInclude(b));

  static double _median(List<_Row> lines) =>
      (lines.map((l) => l.area.height).toList()..sort())[lines.length ~/ 2];
}

List<_Row> _linesOf(String text, List<Rect> chars) {
  final lines = <_Row>[];
  final n = math.min(text.length, chars.length);
  for (var i = 0; i < n; i++) {
    final r = chars[i];
    final current = lines.lastOrNull;
    if (text[i].trim().isEmpty) {
      current?.inWord = false;
      continue;
    }
    if (r.width <= 0 || r.height <= 0) continue;
    if (current != null && current.continua(r)) {
      current
        ..end = i
        ..area = current.area.expandToInclude(r);
      if (current.inWord) current.word = r.right - current.area.left;
    } else {
      lines.add(_Row(i, r));
    }
    if (_withoutStem.contains(text[i])) lines.last.eyes.add(r.height);
  }
  return _withoutRotatedText(lines);
}

/// Rotated text (table header, margin stamp) arrives one letter per line, often
/// backwards: it stays out of the translation, as it is in the PDF.
List<_Row> _withoutRotatedText(List<_Row> lines) {
  bool letter(_Row l) => l.start == l.end;
  final expense = <_Row>[];
  for (var k = 0; k < lines.length; k++) {
    var j = k;
    while (j + 1 < lines.length &&
        letter(lines[j]) &&
        letter(lines[j + 1]) &&
        _overlapsX(lines[j].area, lines[j + 1].area)) {
      j++;
    }
    if (j - k >= 2) {
      k = j;
    } else {
      expense.add(lines[k]);
    }
  }
  return expense;
}

/// Typical line spacing of the page, in line heights.
double _lineSpacing(List<_Row> lines) {
  final reasons = <double>[
    for (var k = 1; k < lines.length; k++)
      if (lines[k].area.top > lines[k - 1].area.top && _overlapsX(lines[k - 1].area, lines[k].area))
        (lines[k].area.top - lines[k - 1].area.top) / math.max(lines[k].area.height, lines[k - 1].area.height),
  ]..sort();
  return reasons.isEmpty ? 1.3 : math.min(reasons[reasons.length ~/ 2], 1.6);
}

bool _overlapsX(Rect a, Rect b) => math.min(a.right, b.right) > math.max(a.left, b.left);

/// [b] continues the paragraph of [lines]: normal line spacing, same font size and the line above not ending
/// early nor changing indent (new paragraph, list, authors and addresses one per line).
bool _sameParagraph(List<_Row> lines, _Row b, double lineSpacing, double typicalWidth) {
  final a = lines.last;
  if (math.max(a.area.width, b.area.width) < typicalWidth * 0.6) return false;
  final h = math.max(a.area.height, b.area.height);
  if (b.area.top <= a.area.top || h / math.min(a.area.height, b.area.height) > 1.35) return false;
  final right = math.max(lines.fold(0.0, (d, l) => math.max(d, l.area.right)), b.area.right);
  if (!_overlapsX(a.area, b.area) || (b.area.top - a.area.top) / h > lineSpacing * 1.3) return false;
  if (a.area.right + b.word + h * 0.3 < right) return false;
  final centered = (a.area.center.dx - b.area.center.dx).abs() < h && a.area.right < b.area.right - h;
  if (centered && a.area.width + b.word + h * 0.3 < b.area.width) return false;
  final indentChanged = (a.area.left - b.area.left).abs() > h * 0.8 && (a.area.right - b.area.right).abs() < h;
  return lines.length < 2 || !indentChanged;
}

Rect _heights(List<ScheduleBlock> blocks) {
  final r = blocks.map((b) => b.area).reduce((a, b) => a.expandToInclude(b));
  return Rect.fromLTRB(0, r.top, 1, r.bottom);
}

/// Column split: separates what is left of a vertical gap that crosses the whole group.
(List<ScheduleBlock>, List<ScheduleBlock>)? _verticalSplit(List<ScheduleBlock> blocks) {
  final byX = [...blocks]..sort((a, b) => a.area.left.compareTo(b.area.left));
  var right = byX.first.area.right;
  for (var k = 1; k < byX.length; k++) {
    if (byX[k].area.left > right + byX[k].body * 0.8) {
      final (a, b) = (byX.sublist(0, k), byX.sublist(k));
      // Real columns share the same height; otherwise they are blocks in different bands.
      if (_heights(a).overlaps(_heights(b))) return (a, b);
    }
    right = math.max(right, byX[k].area.right);
  }
  return null;
}

/// Band split. Among the horizontal gaps, prefers the one that frees the largest part to become columns
/// (header and footer cross the gap between the columns and would prevent the vertical split).
(List<ScheduleBlock>, List<ScheduleBlock>)? _horizontalSplit(List<ScheduleBlock> blocks) {
  final byY = [...blocks]..sort((a, b) => a.area.top.compareTo(b.area.top));
  (List<ScheduleBlock>, List<ScheduleBlock>)? first;
  (List<ScheduleBlock>, List<ScheduleBlock>)? best;
  var larger = 0;
  var low = byY.first.area.bottom;
  for (var k = 1; k < byY.length; k++) {
    if (byY[k].area.top >= low) {
      final cutoff = (byY.sublist(0, k), byY.sublist(k));
      first ??= cutoff;
      for (final part in [cutoff.$1, cutoff.$2]) {
        if (part.length > larger && _verticalSplit(part) != null) {
          larger = part.length;
          best = cutoff;
        }
      }
    }
    low = math.max(low, byY[k].area.bottom);
  }
  return best ?? first;
}

/// Reading order (the PDF often brings header and footer before the body), keeping the column.
void _sort(List<ScheduleBlock> blocks, double left, double right, List<ScheduleBlock> expense) {
  void column(List<ScheduleBlock> part) => _sort(
    part,
    part.fold(double.infinity, (e, b) => math.min(e, b.area.left)),
    part.fold(0, (d, b) => math.max(d, b.area.right)),
    expense,
  );
  if (blocks.length > 1) {
    if (_verticalSplit(blocks) case (final a, final b)) {
      column(a);
      column(b);
      return;
    }
    if (_horizontalSplit(blocks) case (final a, final b)) {
      _sort(a, left, right, expense);
      _sort(b, left, right, expense);
      return;
    }
  }
  for (final b in blocks) {
    b
      .._left = left
      .._right = right;
    expense.add(b);
  }
}

void _finish(ScheduleBlock b) {
  final width = b._right - b._left;
  final left = b.area.left - b._left;
  final right = b._right - b.area.right;
  final h = b.body;
  final middle = (b._left + b._right) / 2;
  final lines = b._lines;
  if (lines.any((l) => l.area.left - b._left > h * 1.5) &&
      lines.every((l) => (l.area.center.dx - middle).abs() < h * 1.2)) {
    b.alignmentMode = TextAlignment.center;
  } else if (left > width * 0.2 && right < h && lines.every((l) => b.area.right - l.area.right < h)) {
    b.alignmentMode = TextAlignment.right;
  } else {
    final filledItems = lines.sublist(0, lines.length - 1);
    if (lines.length >= 3 && filledItems.every((l) => b.area.right - l.area.right < h * 0.6)) {
      b.alignmentMode = TextAlignment.justified;
    }
    if (width > 0 && left > h * 1.2) b.indent = math.min(left / width, 0.35);
    if (width > 0 && right > h * 1.2 && b.alignmentMode == TextAlignment.justified) {
      b.rightIndent = math.min(right / width, 0.35);
    }
    b.firstLineIndent = lines.length >= 2 && lines[0].area.left - lines[1].area.left > h * 0.6;
  }
}

/// x-height of the running text: the one with the most characters on the page (0 = no measure).
double _baseEye(List<_Row> lines) {
  final byEye = <int, int>{};
  for (final l in lines) {
    if (l.eye == 0) continue;
    final key = (l.eye * 4).round();
    byEye[key] = (byEye[key] ?? 0) + l.end - l.start + 1;
  }
  return byEye.isEmpty ? 0 : byEye.entries.reduce((a, b) => b.value > a.value ? b : a).key / 4;
}

/// Without the font weight, a heading with the same size as the text is recognized by being a short loose line.
bool _isHeading(ScheduleBlock b, String text, ScheduleBlock? following) {
  if (b.end - b.start >= 240) return false;
  if (b.scale >= 1.25) return true;
  final dropped = b.gapBefore >= 1 && (following == null || following.gapBefore >= 0.8);
  final short = b._lines.length == 1 && b.end - b.start < 80 && !RegExp(r'[.,;:]$').hasMatch(text);
  return b.scale >= 0.9 && dropped && short && b.alignmentMode != TextAlignment.right;
}

/// Rebuilds the page layout from the character rectangles: blocks in reading
/// order, each with its sentences. Used both in the panel and in the translation over the page.
List<ScheduleBlock> layOut(String text, List<Rect> chars) {
  final lines = _linesOf(text, chars);
  if (lines.isEmpty) return [];
  final lineSpacing = _lineSpacing(lines);
  final typicalWidth = (lines.map((l) => l.area.width).toList()..sort())[lines.length * 3 ~/ 4];
  final groups = <List<_Row>>[];
  for (final l in lines) {
    if (groups.isNotEmpty && _sameParagraph(groups.last, l, lineSpacing, typicalWidth)) {
      groups.last.add(l);
    } else {
      groups.add([l]);
    }
  }
  final blocks = [for (final g in groups) ScheduleBlock._(g)];
  final sortedItems = <ScheduleBlock>[];
  _sort(
    blocks,
    blocks.fold(double.infinity, (e, b) => math.min(e, b.area.left)),
    blocks.fold(0, (d, b) => math.max(d, b.area.right)),
    sortedItems,
  );
  final base = _baseEye(lines);
  var n = 0;
  for (var k = 0; k < sortedItems.length; k++) {
    final b = sortedItems[k];
    final excerpt = text.substring(b.start, b.end + 1);
    _finish(b);
    b
      ..scale = base > 0 && b._eye > 0 ? b._eye / base : 1
      ..first = n
      ..sentences = [for (final f in segment(excerpt)) Sentence(f.start + b.start, f.end + b.start, f.original)];
    if (b.sentences.isEmpty && excerpt.contains(RegExp(r'\d'))) b.numbers = normalize(excerpt);
    n += b.sentences.length;
    if (k > 0) {
      final gap = b.area.top - sortedItems[k - 1].area.bottom;
      b.gapBefore = gap < 0 ? 1 : math.min(gap / sortedItems[k - 1].body, 2.5);
    }
  }
  for (var k = 0; k < sortedItems.length; k++) {
    final b = sortedItems[k];
    b.title = _isHeading(
      b,
      normalize(text.substring(b.start, b.end + 1)),
      k + 1 < sortedItems.length ? sortedItems[k + 1] : null,
    );
  }
  return sortedItems;
}
