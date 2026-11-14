import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../files_api.dart';
import 'page_layer.dart';
import 'layout.dart';
import 'geometry.dart';
import 'translation.dart' show sentencesOf;

const readingLanguages = {'en': 'Inglês', 'es': 'Espanhol', 'fr': 'Francês', 'pt': 'Português'};
const readingSpeeds = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

final _word = RegExp(r"[\p{L}\p{N}\p{M}_’']+(?:[-‐][\p{L}\p{N}\p{M}_’']+)*", unicode: true);

/// Words of [text] as (start, exclusive end): the same split as `shared/linguagem.py`, to match
/// the timing of each word the server returns.
List<(int, int)> wordsOf(String text) => [for (final m in _word.allMatches(text)) (m.start, m.end)];

/// Excerpt of a page's text: character indices, [end] inclusive (like `Sentence`).
class Span {
  const Span(this.start, this.end);

  final int start;
  final int end;

  @override
  bool operator ==(Object other) => other is Span && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// The word containing character [i] (or just it, outside a word).
Span wordAt(String text, int i) {
  for (final (a, b) in wordsOf(text)) {
    if (a <= i && i < b) return Span(a, b - 1);
  }
  return Span(i, i);
}

/// Word of the speech matched to the page text: [excerpt] on the page, time in seconds.
typedef SpeechMark = ({Span excerpt, double t0, double t1});

class _Speech {
  _Speech(this.bytes, this.mime, this.marks);

  final Uint8List bytes;
  final String mime;
  final List<SpeechMark> marks;
}

/// Guided reading in the reader: the worker voice reads the page sentence by sentence in the text's language and marks the
/// word being said; tapping a word (or holding and dragging over an excerpt) pauses and
/// brings the in-context translation by the local LLM. From there you can listen, mark and "Criar tarefas" (vocabulary
/// notebook of Estudos › Linguagem). It also records the person reading the page aloud.
class GuidedReading extends ChangeNotifier {
  GuidedReading(this.api, this.fileId, this.title, this.texts);

  final FilesApi api;
  final String fileId;
  final String title;
  final PageTexts texts;

  bool active = false;
  bool playing = false;
  bool loading = false;
  String language = 'en';
  double speed = 1.0;
  String? error;

  /// Page being read now (0-based), its sentences and the current sentence.
  int page = 0;
  List<Sentence> sentences = const [];
  int score = 0;
  PageText? text;

  /// Word being said (on [page]).
  Span? word;

  /// Looked-up excerpt (tapped or selected) and its translation.
  Span? selection;
  int? selectionPage;
  String term = '';
  String lookupSentence = '';
  Map<String, dynamic>? query;
  bool lookingUp = false;

  /// Reading the page aloud: recording and the last result.
  final _recorder = GravadorLeitura();
  bool get recording => _recorder.gravando;
  bool evaluating = false;

  final _player = Tocador();
  final _speeches = <String, Future<_Speech>>{};
  StreamSubscription<Duration>? _position;
  StreamSubscription<void>? _end;
  PdfDocument? _doc;
  void Function(int page)? _goTo;
  _Speech? _current;
  int _generation = 0;
  bool _discarded = false;

  final _clock = Stopwatch();
  int _lookups = 0, _readSentences = 0, _created = 0;

  Sentence? get currentSentence => score < sentences.length ? sentences[score] : null;

  void _notify() {
    if (!_discarded) notifyListeners();
  }

  /// Turns on guided reading from [page] (0-based); [goTo] turns the page in the viewer.
  Future<void> open(PdfDocument doc, int page, {required void Function(int page) goTo}) async {
    _doc = doc;
    _goTo = goTo;
    active = true;
    error = null;
    _position ??= _player.posicao.listen(_onProgress);
    _end ??= _player.terminou.listen((_) => _onFinish());
    await _load(page);
    _notify();
  }

  Future<void> _load(int p) async {
    final doc = _doc;
    if (doc == null) return;
    page = p;
    score = 0;
    word = null;
    _current = null;
    final t = await texts.de(doc.pages[p]);
    text = t;
    sentences = t == null ? const [] : sentencesOf(layOut(t.text, t.chars));
  }

  /// Turns it off, logging the study time in the language track.
  Future<void> close() async {
    _generation++;
    playing = false;
    active = false;
    selection = null;
    query = null;
    word = null;
    await _player.parar();
    if (_recorder.gravando) await _recorder.cancelar();
    _registrar();
    _notify();
  }

  void _registrar() {
    _clock.stop();
    final withSeconds = _clock.elapsed.inSeconds;
    if (withSeconds < 30 && _lookups == 0) return;
    final minutes = (withSeconds / 60).ceil();
    api
        .logActivity('leitura_guiada', language, minutes, {
          'frases': _readSentences,
          'consultas': _lookups,
          'palavras_criadas': _created,
          'arquivo_id': fileId,
        })
        .catchError((_) {}); // offline: this session's time is lost, the reading is not
    _clock.reset();
    _lookups = _readSentences = _created = 0;
  }

  void changeLanguage(String i) {
    language = i;
    _restartSentence();
  }

  void changeSpeed(double v) {
    speed = v;
    _restartSentence();
  }

  void _restartSentence() {
    _current = null;
    if (playing) {
      _playCurrent();
    } else {
      _notify();
    }
  }

  Future<void> play() async {
    if (!active) return;
    selection = null;
    query = null;
    playing = true;
    _clock.start();
    if (_current != null) {
      await _player.retomar();
      _notify();
    } else {
      await _playCurrent();
    }
  }

  Future<void> pause() async {
    _generation++;
    playing = false;
    loading = false;
    _clock.stop();
    await _player.pausar();
    _notify();
  }

  /// Frase anterior/seguinte ([delta] −1/+1).
  Future<void> skip(int delta) async {
    final isNew = score + delta;
    if (isNew < 0 && page > 0) {
      await _load(page - 1);
      _goTo?.call(page);
      score = sentences.isEmpty ? 0 : sentences.length - 1;
    } else if (isNew >= sentences.length) {
      if (!await _nextPage()) return;
    } else {
      score = isNew.clamp(0, sentences.isEmpty ? 0 : sentences.length - 1);
    }
    _current = null;
    word = null;
    playing ? await _playCurrent() : _notify();
  }

  /// Starts reading from the sentence containing the looked-up excerpt.
  Future<void> readFromHere() async {
    final s = selection, p = selectionPage;
    if (s == null || p == null) return;
    if (p != page) {
      await _load(p);
    }
    final k = sentences.indexWhere((f) => f.start <= s.start && s.start <= f.end);
    score = k < 0 ? 0 : k;
    _current = null;
    await play();
  }

  Future<bool> _nextPage() async {
    final doc = _doc;
    if (doc == null || page + 1 >= doc.pages.length) {
      playing = false;
      _notify();
      return false;
    }
    await _load(page + 1);
    _goTo?.call(page);
    return true;
  }

  Future<void> _playCurrent() async {
    final g = ++_generation;
    var f = currentSentence;
    // Page without text (figure, blank page): moves to the next one.
    while (f == null) {
      if (!await _nextPage()) return;
      f = currentSentence;
    }
    loading = true;
    error = null;
    _notify();
    try {
      final speech = await _speechOf(page, f);
      if (g != _generation || !playing) return;
      if (score + 1 < sentences.length) _speechOf(page, sentences[score + 1]).ignore(); // already requests the next one
      _current = speech;
      loading = false;
      _notify();
      await _player.tocar(speech.bytes, speech.mime);
    } on ApiErro catch (e) {
      if (g != _generation) return;
      error = e.mensagem;
      playing = false;
      loading = false;
      _notify();
    }
  }

  Future<_Speech> _speechOf(int p, Sentence f) {
    final key = '$language|$speed|$p|${f.start}';
    return _speeches.putIfAbsent(key, () async {
      try {
        final r = await api.speech(f.original, language, speed);
        return _Speech(base64Decode(r['audio_b64'] as String), r['mime'] as String, _marks(f, r['palavras'] as List));
      } catch (_) {
        _speeches.remove(key); // an error is not cached: tapping again tries again
        rethrow;
      }
    });
  }

  /// The k-th word of the normalized sentence is the k-th of the page text (only the spaces change).
  List<SpeechMark> _marks(Sentence f, List keywords) {
    final t = text?.text ?? '';
    final ofPage = [
      for (final (a, b) in wordsOf(t.substring(f.start, (f.end + 1).clamp(f.start, t.length))))
        Span(f.start + a, f.start + b - 1),
    ];
    final order = {for (final (k, (a, _)) in wordsOf(f.original).indexed) a: k};
    return [
      for (final p in keywords.cast<Map>())
        if (order[p['inicio']] case final k? when k < ofPage.length)
          (excerpt: ofPage[k], t0: (p['t0'] as num).toDouble(), t1: (p['t1'] as num).toDouble()),
    ];
  }

  void _onProgress(Duration d) {
    final speech = _current;
    if (speech == null || !playing) return;
    final s = d.inMilliseconds / 1000;
    Span? found;
    for (final m in speech.marks) {
      if (m.t0 <= s) found = m.excerpt;
      if (m.t1 > s) break;
    }
    if (found != word) {
      word = found;
      _notify();
    }
  }

  Future<void> _onFinish() async {
    if (!playing) return;
    _readSentences++;
    _current = null;
    word = null;
    score++;
    if (score >= sentences.length && !await _nextPage()) return;
    await _playCurrent();
  }

  /// Tap/selection over the text of page [p]: pauses and translates the excerpt in the sentence context.
  Future<void> lookUp(int p, PageText t, Span excerpt) async {
    if (playing) await pause();
    selection = excerpt;
    selectionPage = p;
    term = normalize(t.text.substring(excerpt.start, excerpt.end + 1)).replaceAll(RegExp(r'^\W+|\W+$', unicode: true), '');
    final ofPage = p == page ? sentences : sentencesOf(layOut(t.text, t.chars));
    lookupSentence =
        ofPage.where((f) => f.start <= excerpt.start && excerpt.start <= f.end).firstOrNull?.original ?? term;
    query = null;
    error = null;
    if (term.isEmpty) return _notify();
    lookingUp = true;
    _lookups++;
    _notify();
    final request = term;
    try {
      final r = await api.translateTerm(term, lookupSentence, language);
      if (request == term) query = r;
    } on ApiErro catch (e) {
      error = e.mensagem;
    } finally {
      lookingUp = false;
      _notify();
    }
  }

  void closeLookup() {
    selection = null;
    query = null;
    _notify();
  }

  /// The pronunciation of [text] with the same voice as the reading.
  Future<void> listen(String text) async {
    if (playing) await pause();
    try {
      final r = await api.speech(text, language, 0.85);
      _current = null;
      await _player.tocar(base64Decode(r['audio_b64'] as String), r['mime'] as String);
    } on ApiErro catch (e) {
      error = e.mensagem;
      _notify();
    }
  }

  /// "Criar tarefas": the looked-up term goes into the vocabulary notebook (sentences and exercises by the local LLM).
  Future<String> createTasks() async {
    final c = query;
    await api.createWord({
      'termo': term,
      'idioma': language,
      'contexto': lookupSentence,
      'traducao': c?['traducao'] ?? '',
      'classe': c?['classe'] ?? '',
      'ipa': c?['ipa'] ?? '',
      'arquivo_id': fileId,
      'titulo': title,
      'pagina': selectionPage ?? page,
    });
    _created++;
    return term;
  }

  /// Text the person is going to read aloud: from the current sentence to the end of the page.
  String get textToRead => [for (final f in sentences.skip(score)) f.original].join(' ');

  Future<bool> save() async {
    if (playing) await pause();
    final ok = await _recorder.iniciar();
    _notify();
    return ok;
  }

  /// Stops recording and evaluates against [textToRead]; the result stays in Estudos › Linguagem.
  Future<Map<String, dynamic>?> stopAndEvaluate() async {
    final reference = textToRead;
    final start = DateTime.now();
    final wav = await _recorder.parar();
    _notify();
    if (wav == null || wav.length < 44 + 16000 * 2) return null; // less than 1 s
    evaluating = true;
    _notify();
    try {
      final r = await api.evaluateReading(wav, language, reference, fileId: fileId, title: title, page: page);
      final minutes = (DateTime.now().difference(start).inSeconds / 60).ceil();
      api.logActivity('leitura_voz', language, minutes, {'arquivo_id': fileId}).catchError((_) {});
      return r;
    } finally {
      evaluating = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _discarded = true;
    _generation++;
    _position?.cancel();
    _end?.cancel();
    if (active) _registrar();
    _player.dispose();
    _recorder.dispose();
    super.dispose();
  }
}

/// Guided reading layer over a page: paints the read sentence and word and the looked-up excerpt, and
/// takes the tap (word) or the hold-and-drag (excerpt). Only exists with guided reading on.
class ReadingLayer extends StatefulWidget {
  const ReadingLayer({super.key, required this.page, required this.guide, required this.texts});

  final PdfPage page;
  final GuidedReading guide;
  final PageTexts texts;

  @override
  State<ReadingLayer> createState() => _ReadingLayerState();
}

class _ReadingLayerState extends State<ReadingLayer> {
  PageText? _text;
  int? _anchor;
  Span? _drag;

  int get _n => widget.page.pageNumber - 1;

  @override
  void initState() {
    super.initState();
    widget.texts.de(widget.page).then((t) {
      if (mounted) setState(() => _text = t);
    });
  }

  int? _char(Offset local, double scale) {
    final t = _text;
    if (t == null) return null;
    final p = local / scale;
    final i = nearestChar(t.chars, p);
    return i != null && t.chars[i].inflate(6).contains(p) ? i : null;
  }

  Span _union(String text, int a, int b) {
    final x = wordAt(text, a < b ? a : b), y = wordAt(text, a < b ? b : a);
    return Span(x.start, y.end);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.guide,
    builder: (context, _) {
      final g = widget.guide, t = _text;
      if (!g.active || t == null) return const SizedBox.shrink();
      final colors = Theme.of(context).colorScheme;
      final layers = <(List<Rect>, Color)>[
        if (g.page == _n && g.currentSentence != null)
          (excerptRects(t.chars, g.currentSentence!.start, g.currentSentence!.end), colors.primary.withAlpha(28)),
        if (g.page == _n && g.word != null)
          (excerptRects(t.chars, g.word!.start, g.word!.end), Colors.amber.withAlpha(140)),
        if (_drag != null)
          (excerptRects(t.chars, _drag!.start, _drag!.end), Colors.lightBlue.withAlpha(90))
        else if (g.selectionPage == _n && g.selection != null)
          (excerptRects(t.chars, g.selection!.start, g.selection!.end), Colors.lightBlue.withAlpha(90)),
      ];
      return LayoutBuilder(
        builder: (context, c) {
          final scale = c.maxWidth / widget.page.width;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) {
              final i = _char(d.localPosition, scale);
              if (i != null) g.lookUp(_n, t, wordAt(t.text, i));
            },
            onLongPressStart: (d) {
              _anchor = _char(d.localPosition, scale);
              if (_anchor != null) setState(() => _drag = wordAt(t.text, _anchor!));
            },
            onLongPressMoveUpdate: (d) {
              final i = _char(d.localPosition, scale);
              if (_anchor != null && i != null) setState(() => _drag = _union(t.text, _anchor!, i));
            },
            onLongPressEnd: (_) {
              final s = _drag;
              setState(() => _drag = _anchor = null);
              if (s != null) g.lookUp(_n, t, s);
            },
            child: CustomPaint(size: c.biggest, painter: _ReadingPainter(layers, scale)),
          );
        },
      );
    },
  );
}

class _ReadingPainter extends CustomPainter {
  _ReadingPainter(this.layers, this.scale);

  final List<(List<Rect>, Color)> layers;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    for (final (rects, color) in layers) {
      final ink = Paint()..color = color;
      for (final r in rects) {
        final e = Rect.fromLTRB(r.left * scale, r.top * scale, r.right * scale, r.bottom * scale).inflate(1);
        canvas.drawRRect(RRect.fromRectAndRadius(e, const Radius.circular(2)), ink);
      }
    }
  }

  @override
  bool shouldRepaint(_ReadingPainter old) => true;
}
