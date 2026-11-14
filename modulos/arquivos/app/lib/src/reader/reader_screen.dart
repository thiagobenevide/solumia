import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../files_api.dart';
import '../models.dart';
import '../screens/highlight_actions.dart';
import '../screens/reading_projects.dart';
import 'annotator.dart';
import 'page_layer.dart';
import 'toolbox.dart';
import 'geometry.dart';
import 'guided_reading.dart';
import 'guided_reading_bar.dart';
import 'translation.dart';
import 'page_translation.dart';

/// Reader of a file (PDF, or already converted DOCX/PPTX) with ink annotation on top.
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key, required this.api, required this.file, this.initialPage = 1});

  final FilesApi api;
  final FileItem file;
  final int initialPage;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  late final _annotator = Annotator(widget.api, widget.file.id);
  final _toolbox = ReaderToolbox();
  final _strings = PageTexts();
  final _controller = PdfViewerController();
  late final _translator = DocumentTranslator(widget.api, widget.file.id, _strings);
  late final _guide = GuidedReading(widget.api, widget.file.id, widget.file.title, _strings);
  late final _currentPage = ValueNotifier(widget.initialPage - 1);
  final _viewerKey = GlobalKey();
  final _mode = ValueNotifier(TranslationMode.off);
  late final Future<Uint8List> _pdf = _open();
  Timer? _polling;
  int _seq = 0;

  Future<Uint8List> _open() async {
    final local = await widget.api.offline.pdf(widget.file.id);
    final (bytes, _) = await (
      local != null ? Future.value(local) : widget.api.pdf(widget.file.id),
      _annotator.carregar(),
    ).wait;
    try {
      final (seq, _) = await widget.api.changes(1 << 50);
      _seq = seq;
    } on ApiErro catch (e) {
      if (!semConexao(e)) rethrow; // offline with the file downloaded: the polling picks it up when it returns
    }
    _polling = Timer.periodic(const Duration(seconds: 4), (_) => _checkChanges());
    return bytes;
  }

  /// Annotations made on another device show up here without reopening the file.
  Future<void> _checkChanges() async {
    try {
      final (seq, changes) = await widget.api.changes(_seq);
      _seq = seq;
      final mine = changes.where((m) => m['arquivo_id'] == widget.file.id && m['acao'] == 'anotado');
      if (mine.isNotEmpty) await _annotator.refreshFromServer(mine.last['versao'] as int);
    } catch (_) {
      // Offline right now: tries again on the next cycle.
    }
  }

  @override
  void dispose() {
    _polling?.cancel();
    _annotator.save().whenComplete(_annotator.dispose);
    _toolbox.dispose();
    _translator.dispose();
    _guide.dispose();
    _currentPage.dispose();
    _mode.dispose();
    super.dispose();
  }

  Future<void> _text(int page, Offset position, [AnnotatedText? existing]) async {
    final text = await askText(
      context,
      title: existing == null ? 'Texto na página ${page + 1}' : 'Editar texto (vazio apaga)',
      initial: existing?.text ?? '',
      lines: 3,
    );
    if (text == null) return;
    if (existing != null) {
      text.trim().isEmpty ? _annotator.remover({existing.id}) : _annotator.replace(existing.withText(text));
    } else if (text.trim().isNotEmpty) {
      _annotator.adicionar(
        AnnotatedText(
          id: newId(),
          page: page,
          position: position,
          text: text,
          color: _toolbox.colorOf(Tool.text),
          size: _toolbox.thicknessOf(Tool.text),
        ),
      );
    }
  }

  /// Newest version of the highlight (the sheet can change projects and then the comment).
  Highlight _currentOf(Highlight d) => _annotator.current.highlights.firstWhere((x) => x.id == d.id, orElse: () => d);

  void _linkPage() {
    final page = (_controller.pageNumber ?? 1) - 1;
    final n = _annotator.linkPage(page, activeProjects.value);
    notify(
      context,
      n == 0 ? 'Nada novo para ligar na página ${page + 1}' : '$n anotações da página ${page + 1} ligadas',
    );
  }

  /// Excerpt already marked without the active project: links it instead of ignoring the "Marcar".
  bool _linkToProject(Highlight d) {
    final assets = activeProjects.value;
    if (assets.isEmpty || assets.every(d.projects.contains)) return false;
    _annotator.replace(d.withProjects({...d.projects, ...assets}.toList()));
    notify(context, 'Trecho já marcado: ligado ao projeto ativo');
    return true;
  }

  void _translate(TranslationMode mode) {
    setState(() => _mode.value = mode);
    if (mode != TranslationMode.off) _resumeTranslation();
  }

  void _resumeTranslation() {
    if (_controller.isReady) _translator.translateDocument(_controller.document, _currentPage.value);
  }

  /// Sentences selected in the translation → highlight on the English original, with the translation; the
  /// `Annotator` links it to the active reading project. If it was already marked the same, opens the highlight.
  void _markTranslation(int page, TranslatedPage p, List<int> sentences) {
    final original = [for (final k in sentences) p.sentences[k].original].join(' ');
    final translation = [for (final k in sentences) p.translations[k]].where((t) => t.isNotEmpty).join(' ');
    final existing = _annotator.visible.highlights.where((d) => d.page == page && d.text == original).firstOrNull;
    if (existing != null) {
      if (_linkToProject(existing)) return;
      return _highlight(existing);
    }
    _annotator.adicionar(
      Highlight(
        id: newId(),
        page: page,
        text: original,
        translation: translation,
        color: _toolbox.colorOf(Tool.textMark),
        rectangles: [
          for (final k in sentences) ...excerptRects(p.text.chars, p.sentences[k].start, p.sentences[k].end),
        ],
        created: DateTime.now(),
      ),
    );
    notify(
      context,
      activeProjects.value.isEmpty
          ? 'Marcado no original. Escolha um projeto ativo para o trecho entrar no projeto de leitura.'
          : 'Marcado no original e no projeto de leitura (inglês + português)',
    );
  }

  /// Guided reading: the voice reads from the page on screen; tapping a word translates it.
  void _toggleGuide() {
    if (_guide.active) {
      _guide.close();
    } else if (_controller.isReady) {
      _guide.open(_controller.document, _currentPage.value, goTo: (p) => _controller.goToPage(pageNumber: p + 1));
    }
  }

  /// The excerpt looked up in the guided reading becomes a highlight on the PDF, with the translation (goes into the active project).
  void _markLookup() {
    final s = _guide.selection, p = _guide.selectionPage;
    final t = p == null ? null : _strings.readyOnes[p + 1];
    if (s == null || p == null || t == null) return;
    final text = normalize(t.text.substring(s.start, s.end + 1));
    final existing = _annotator.visible.highlights.where((d) => d.page == p && d.text == text).firstOrNull;
    if (existing != null) {
      if (_linkToProject(existing)) return;
      return notify(context, 'Esse trecho já está marcado.');
    }
    _annotator.adicionar(
      Highlight(
        id: newId(),
        page: p,
        text: text,
        translation: (_guide.query?['traducao'] as String?) ?? '',
        color: _toolbox.colorOf(Tool.textMark),
        rectangles: excerptRects(t.chars, s.start, s.end),
        created: DateTime.now(),
      ),
    );
    notify(context, 'Marcado no PDF com a tradução');
  }

  void _highlight(Highlight d) => showHighlight(
    context,
    api: widget.api,
    reference: Reference.de(d, widget.file),
    onComment: (c) => _annotator.replace(_currentOf(d).withComment(c)),
    onTranslate: (t) => _annotator.replace(_currentOf(d).copy(translation: t)),
    onProjectsChanged: (p) => _annotator.replace(_currentOf(d).withProjects(p)),
    onDelete: () => _annotator.remover({d.id}),
    onOpen: () => _controller.goToPage(pageNumber: d.page + 1),
  );

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _annotator.undo,
      const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true): _annotator.redo,
      const SingleActivator(LogicalKeyboardKey.keyY, control: true): _annotator.redo,
      const SingleActivator(LogicalKeyboardKey.keyS, control: true): _annotator.save,
    },
    child: Focus(
      autofocus: true,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.file.title, overflow: TextOverflow.ellipsis),
          actions: [
            ListenableBuilder(
              listenable: _guide,
              builder: (context, _) => IconButton(
                tooltip: _guide.active ? 'Fechar a leitura guiada' : 'Leitura guiada (ouvir e traduzir tocando)',
                icon: Icon(
                  Icons.record_voice_over_outlined,
                  color: _guide.active ? Theme.of(context).colorScheme.primary : null,
                ),
                onPressed: _toggleGuide,
              ),
            ),
            PopupMenuButton<TranslationMode>(
              tooltip: 'Traduzir o documento para o português',
              icon: Icon(
                Icons.translate,
                color: _mode.value == TranslationMode.off ? null : Theme.of(context).colorScheme.primary,
              ),
              onSelected: _translate,
              itemBuilder: (context) => [
                CheckedPopupMenuItem(
                  value: TranslationMode.panel,
                  checked: _mode.value == TranslationMode.panel,
                  child: const Text('No painel, junto do PDF'),
                ),
                CheckedPopupMenuItem(
                  value: TranslationMode.overPage,
                  checked: _mode.value == TranslationMode.overPage,
                  child: const Text('Sobre a página'),
                ),
                if (_mode.value != TranslationMode.off)
                  const PopupMenuItem(value: TranslationMode.off, child: Text('Desligar a tradução')),
              ],
            ),
            ActiveProjectButton(api: widget.api, onLinkPage: _linkPage),
            ListenableBuilder(
              listenable: _annotator,
              builder: (context, _) => Row(
                children: [
                  _SaveIcon(_annotator),
                  IconButton(
                    tooltip: 'Desfazer (Ctrl+Z)',
                    icon: const Icon(Icons.undo),
                    onPressed: _annotator.canUndo ? _annotator.undo : null,
                  ),
                  IconButton(
                    tooltip: 'Refazer (Ctrl+Y)',
                    icon: const Icon(Icons.redo),
                    onPressed: _annotator.canRedo ? _annotator.redo : null,
                  ),
                ],
              ),
            ),
            Builder(
              builder: (context) => IconButton(
                tooltip: 'Destaques deste arquivo',
                icon: const Icon(Icons.format_list_bulleted),
                onPressed: () => Scaffold.of(context).openEndDrawer(),
              ),
            ),
          ],
          bottom: PreferredSize(preferredSize: const Size.fromHeight(52), child: _Toolbar(_toolbox)),
        ),
        endDrawer: Drawer(
          width: 360,
          child: ListenableBuilder(
            listenable: _annotator,
            builder: (context, _) => _HighlightsList(
              highlights: [..._annotator.visible.highlights]..sort((a, b) => a.page.compareTo(b.page)),
              onItemTap: (d) {
                Navigator.pop(context);
                _controller.goToPage(pageNumber: d.page + 1);
                _highlight(d);
              },
            ),
          ),
        ),
        body: LayoutBuilder(
          builder: (context, area) => Stack(
            children: [
              Positioned.fill(child: _withPanel(area, _visor())),
              Positioned(
                left: 12,
                right: 12,
                // above the small translation bar over the page
                bottom: _mode.value == TranslationMode.overPage ? 72 : 12,
                child: ListenableBuilder(
                  listenable: _guide,
                  builder: (context, _) => !_guide.active
                      ? const SizedBox.shrink()
                      : Center(child: GuidedReadingPanel(guide: _guide, onMark: _markLookup)),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  /// PDF and, with the translation in the panel, it beside (wide screen) or below (phone); over the page,
  /// only the small floating bar. The
  /// [_viewerKey] keeps the PdfViewer (page, zoom) when the panel opens or closes.
  Widget _withPanel(BoxConstraints area, Widget visor) {
    visor = KeyedSubtree(key: _viewerKey, child: visor);
    if (_mode.value == TranslationMode.off) return visor;
    if (_mode.value == TranslationMode.overPage) {
      return Stack(
        children: [
          Positioned.fill(child: visor),
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Center(
              child: ListenableBuilder(
                listenable: Listenable.merge([_translator, _currentPage]),
                builder: (context, _) => TranslationBar(
                  translator: _translator,
                  page: _currentPage.value,
                  onResume: _resumeTranslation,
                  onClose: () => _translate(TranslationMode.off),
                ),
              ),
            ),
          ),
        ],
      );
    }
    final panel = ListenableBuilder(
      listenable: Listenable.merge([_translator, _annotator, _currentPage]),
      builder: (context, _) {
        final page = _currentPage.value;
        return TranslationPanel(
          translator: _translator,
          page: page,
          highlights: [
            for (final d in _annotator.visible.highlights)
              if (d.page == page) d,
          ],
          onMark: (p, sentences) => _markTranslation(page, p, sentences),
          onResume: _resumeTranslation,
          onClose: () => _translate(TranslationMode.off),
        );
      },
    );
    return area.maxWidth >= 900
        ? Row(
            children: [
              Expanded(child: visor),
              const VerticalDivider(width: 1),
              SizedBox(width: area.maxWidth * 0.42, child: panel),
            ],
          )
        : Column(
            children: [
              Expanded(child: visor),
              const Divider(height: 1),
              SizedBox(height: area.maxHeight * 0.45, child: panel),
            ],
          );
  }

  Widget _visor() => FutureBuilder(
    future: _pdf,
    builder: (context, s) {
      if (s.hasError) return Center(child: Text('Não deu para abrir: ${s.error}'));
      if (!s.hasData) return const Center(child: CircularProgressIndicator());
      return PdfViewer.data(
        s.data!,
        sourceName: widget.file.id,
        controller: _controller,
        initialPageNumber: widget.initialPage,
        params: PdfViewerParams(
          backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
          onPageChanged: _pageChanged,
          onViewerReady: _pronto,
          pageOverlaysBuilder: (context, area, page) => [
            Positioned.fill(
              child: TranslationLayer(
                key: ValueKey('traducao ${page.pageNumber}'),
                page: page,
                translator: _translator,
                mode: _mode,
              ),
            ),
            Positioned.fill(
              child: PageLayer(
                key: ValueKey(page.pageNumber),
                page: page,
                annotator: _annotator,
                toolbox: _toolbox,
                texts: _strings,
                onCreateText: _text,
                onTextTap: (t) => _text(t.page, t.position, t),
                onHighlightTap: _highlight,
              ),
            ),
            Positioned.fill(
              child: ReadingLayer(
                key: ValueKey('leitura ${page.pageNumber}'),
                page: page,
                guide: _guide,
                texts: _strings,
              ),
            ),
          ],
        ),
      );
    },
  );

  void _pageChanged(int? n) {
    if (n != null) _currentPage.value = n - 1;
  }

  void _pronto(PdfDocument _, PdfViewerController _) {
    if (_mode.value != TranslationMode.off) _resumeTranslation();
  }
}

class _SaveIcon extends StatelessWidget {
  const _SaveIcon(this.annotator);

  final Annotator annotator;

  @override
  Widget build(BuildContext context) {
    final (icone, hint) = switch (annotator.status) {
      SaveStatus.saved => (Icons.cloud_done_outlined, 'Anotações salvas'),
      SaveStatus.pending => (Icons.cloud_queue, 'Salvando em instantes'),
      SaveStatus.saving => (Icons.cloud_upload_outlined, 'Salvando…'),
      SaveStatus.error => (Icons.cloud_off, 'Falhou: ${annotator.error}. Tento de novo sozinho.'),
      SaveStatus.onDevice => (Icons.save_outlined, 'Sem conexão: salvo no aparelho. Sobe quando voltar.'),
    };
    return IconButton(
      tooltip: hint,
      onPressed: annotator.save,
      icon: Icon(icone, color: annotator.status == SaveStatus.error ? Theme.of(context).colorScheme.error : null),
    );
  }
}

/// Tools, color, thickness, ruler and "só caneta", in a strip that scrolls horizontally on the phone.
class _Toolbar extends StatelessWidget {
  const _Toolbar(this.toolbox);

  final ReaderToolbox toolbox;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: toolbox,
    builder: (context, _) {
      final f = toolbox.tool;
      final (min, max) = toolbox.band;
      return SizedBox(
        height: 52,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          children: [
            for (final option in Tool.values)
              IconButton(
                tooltip: option.label,
                isSelected: f == option,
                icon: Icon(
                  option.icone,
                  color: option.usesColor && f == option ? toolbox.colorOf(option).withValues(alpha: 1) : null,
                ),
                onPressed: () => toolbox.tool = option,
                style: IconButton.styleFrom(
                  backgroundColor: f == option ? Theme.of(context).colorScheme.secondaryContainer : null,
                ),
              ),
            const VerticalDivider(indent: 10, endIndent: 10),
            if (f.usesColor) ...[
              for (final c in {...toolbox.recent.take(3), ...quickColors.take(5)})
                _ColorDot(color: c, selected: c == toolbox.color, onItemTap: () => toolbox.color = c),
              IconButton(
                tooltip: 'Qualquer cor',
                icon: const Icon(Icons.palette_outlined),
                onPressed: () async {
                  final c = await escolherCor(context, toolbox.color, toolbox.recent, paleta: quickColors);
                  if (c != null) toolbox.color = c;
                },
              ),
            ],
            if (f != Tool.pan)
              SizedBox(
                width: 170,
                child: Row(
                  children: [
                    SizedBox(
                      width: 34,
                      child: Text(
                        toolbox.thickness.toStringAsFixed(toolbox.thickness < 10 ? 1 : 0),
                        textAlign: TextAlign.end,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                    Expanded(
                      child: Slider(
                        value: toolbox.thickness.clamp(min, max),
                        min: min,
                        max: max,
                        onChanged: (v) => toolbox.thickness = v,
                      ),
                    ),
                  ],
                ),
              ),
            const VerticalDivider(indent: 10, endIndent: 10),
            IconButton(
              tooltip: 'Linhas retas (ou segure a caneta parada no fim do traço)',
              isSelected: toolbox.straightLines,
              icon: const Icon(Icons.straighten),
              onPressed: toolbox.toggleStraightLines,
              style: IconButton.styleFrom(
                backgroundColor: toolbox.straightLines ? Theme.of(context).colorScheme.secondaryContainer : null,
              ),
            ),
            IconButton(
              tooltip: toolbox.penOnly
                  ? 'Só a caneta desenha (o dedo rola e dá zoom)'
                  : 'Caneta, dedo e mouse desenham',
              isSelected: toolbox.penOnly,
              icon: Icon(toolbox.penOnly ? Icons.draw_outlined : Icons.touch_app_outlined),
              onPressed: toolbox.togglePenOnly,
            ),
          ],
        ),
      );
    },
  );
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.color, required this.selected, required this.onItemTap});

  final Color color;
  final bool selected;
  final VoidCallback onItemTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 3),
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onItemTap,
      child: Container(
        width: 26,
        height: 26,
        margin: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outlineVariant,
            width: selected ? 3 : 1,
          ),
        ),
      ),
    ),
  );
}

class _HighlightsList extends StatelessWidget {
  const _HighlightsList({required this.highlights, required this.onItemTap});

  final List<Highlight> highlights;
  final ValueChanged<Highlight> onItemTap;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: highlights.isEmpty
        ? const Padding(
            padding: EdgeInsets.all(24),
            child: Text('Nenhum destaque ainda. Use o marca-texto que salva o texto para marcar trechos.'),
          )
        : ListView(
            children: [
              ListTile(title: Text('${highlights.length} destaques', style: Theme.of(context).textTheme.titleMedium)),
              for (final d in highlights)
                ListTile(
                  leading: CircleAvatar(radius: 6, backgroundColor: d.color.withValues(alpha: 1)),
                  title: Text(d.text, maxLines: 3, overflow: TextOverflow.ellipsis),
                  subtitle: Text(['p. ${d.page + 1}', if (d.comment.isNotEmpty) d.comment].join(' · ')),
                  onTap: () => onItemTap(d),
                ),
            ],
          ),
  );
}
