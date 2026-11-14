import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../files_api.dart';
import '../reader/data_screen.dart';
import '../models.dart';
import '../screens/highlight_actions.dart';
import 'export.dart';
import 'pptx.dart';

const _textColors = ['000000', 'FFFFFF', '1F3864', '2E75B6', 'C00000', 'FF6600', '00B050', '7030A0', '7F7F7F'];

/// PowerPoint-style PPTX editor: thumbnails (duplicate, new, move, delete), slide with the
/// boxes in place (drag moves, corner resizes, double tap edits the text) and style bar.
class PresentationScreen extends StatefulWidget {
  const PresentationScreen({super.key, required this.api, required this.file});

  final FilesApi api;
  final FileItem file;

  @override
  State<PresentationScreen> createState() => _PresentationScreenState();
}

class _PresentationScreenState extends State<PresentationScreen> {
  late final Future<void> _load = _read();
  Presentation? _ap;
  int _current = 0;
  SlideShape? _sel;
  bool _editing = false;
  bool _isSaving = false;
  final _text = TextEditingController();

  bool get _dirty => (_ap?.changedFlag ?? false) || _editing;
  Slide get _slide => _ap!.slides[_current];

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _read() async {
    final id = widget.file.id;
    final bytes = await widget.api.offline.original(id) ?? await widget.api.original(id);
    _ap = Presentation.read(bytes);
    if (_ap!.slides.isEmpty) throw InvalidPptx('A apresentação não tem slides.');
  }

  void _finishText() {
    if (_editing && _sel != null && _sel!.text != _text.text) _sel!.text = _text.text;
    _editing = false;
  }

  void _select(SlideShape? f, {bool edit = false}) {
    setState(() {
      _finishText();
      _sel = f;
      if (edit && f != null && f.hasText) {
        _text.text = f.text;
        _editing = true;
      }
    });
  }

  void _goTo(int i) => setState(() {
    _finishText();
    _sel = null;
    _current = i.clamp(0, _ap!.slides.length - 1);
  });

  void _slideAction(String action, int i) {
    setState(() {
      _finishText();
      _sel = null;
      final ap = _ap!;
      switch (action) {
        case 'duplicar':
          ap.duplicate(i);
          _current = i + 1;
        case 'novo':
          ap.duplicate(i, empty: true);
          _current = i + 1;
        case 'acima':
          ap.move(i, i - 1);
          _current = (i - 1).clamp(0, ap.slides.length - 1);
        case 'abaixo':
          ap.move(i, i + 1);
          _current = (i + 1).clamp(0, ap.slides.length - 1);
        case 'excluir':
          ap.delete(i);
          _current = _current.clamp(0, ap.slides.length - 1);
      }
    });
  }

  Future<bool> _save() async {
    setState(_finishText);
    setState(() => _isSaving = true);
    try {
      final isNew = await widget.api.offline.saveOriginal(widget.file, _ap!.save());
      if (mounted) notify(context, isNew == null ? 'Sem conexão: salvo no aparelho; sobe quando a conexão voltar.' : 'Salvo.');
      return true;
    } on ApiErro catch (e) {
      if (mounted) notify(context, 'Não consegui salvar: ${e.mensagem}');
      return false;
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _export() async {
    if (_dirty && !await _save()) return;
    final ap = _ap!;
    final md = [
      for (final (i, s) in ap.slides.indexed) ...[
        '## Slide ${i + 1}',
        for (final f in s.shapes)
          if (f.hasText && f.text.trim().isNotEmpty) f.title ? '**${f.text.trim()}**' : f.text.trim(),
        '',
      ],
    ].join('\n\n');
    if (mounted) await exportFile(context, widget.api, widget.file, markdown: md);
  }

  @override
  Widget build(BuildContext context) => ExitGuard(
    dirty: _dirty,
    child: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
          if (_dirty && !_isSaving) _save();
        },
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.file.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(tooltip: 'Exportar', onPressed: _ap == null ? null : _export, icon: const Icon(Icons.ios_share)),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.icon(
                onPressed: _dirty && !_isSaving ? _save : null,
                icon: _isSaving
                    ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.save_outlined),
                label: const Text('Salvar'),
              ),
            ),
          ],
        ),
        body: FutureBuilder(
          future: _load,
          builder: (context, s) {
            if (s.hasError) {
              final e = s.error;
              final msg = e is ApiErro ? e.mensagem : (e is InvalidPptx ? e.mensagem : '$e');
              return Center(child: Text('Não consegui abrir: $msg'));
            }
            if (s.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
            return LayoutBuilder(
              builder: (context, c) {
                final largo = c.maxWidth >= 720;
                final stage = Column(
                  children: [
                    _bar(),
                    const Divider(height: 1),
                    Expanded(child: _stage()),
                  ],
                );
                if (largo) {
                  return Row(
                    children: [
                      SizedBox(width: 190, child: _thumbnails(Axis.vertical)),
                      const VerticalDivider(width: 1),
                      Expanded(child: stage),
                    ],
                  );
                }
                return Column(
                  children: [
                    Expanded(child: stage),
                    const Divider(height: 1),
                    SizedBox(height: 96, child: _thumbnails(Axis.horizontal)),
                  ],
                );
              },
            );
          },
        ),
      ),
    ),
  );

  Widget _thumbnails(Axis axis) {
    final ap = _ap!;
    final ratio = ap.width / ap.height;
    return ListView.builder(
      scrollDirection: axis,
      padding: const EdgeInsets.all(8),
      itemCount: ap.slides.length,
      itemBuilder: (context, i) {
        final current = i == _current;
        return Padding(
          padding: const EdgeInsets.all(4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(width: 18, child: Text('${i + 1}', style: Theme.of(context).textTheme.labelSmall)),
              SizedBox(
                width: axis == Axis.vertical ? 140 : 80 * ratio,
                child: AspectRatio(
                  aspectRatio: ratio,
                  child: GestureDetector(
                    onTap: () => _goTo(i),
                    onSecondaryTapUp: (d) => _menuSlide(context, i, d.globalPosition),
                    onLongPressStart: (d) => _menuSlide(context, i, d.globalPosition),
                    child: DecoratedBox(
                      position: DecorationPosition.foreground,
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: current ? Theme.of(context).colorScheme.primary : Colors.black26,
                          width: current ? 2 : 1,
                        ),
                      ),
                      child: IgnorePointer(child: _SlideVista(ap: ap, slide: ap.slides[i])),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _menuSlide(BuildContext context, int i, Offset pos) async {
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: [
        const PopupMenuItem(value: 'novo', child: Text('Novo slide depois')),
        const PopupMenuItem(value: 'duplicar', child: Text('Duplicar')),
        if (i > 0) const PopupMenuItem(value: 'acima', child: Text('Mover para cima')),
        if (i < _ap!.slides.length - 1) const PopupMenuItem(value: 'abaixo', child: Text('Mover para baixo')),
        if (_ap!.slides.length > 1) const PopupMenuItem(value: 'excluir', child: Text('Excluir slide')),
      ],
    );
    if (action != null) _slideAction(action, i);
  }

  Widget _bar() {
    final f = _sel;
    final text = f != null && f.hasText;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: () => setState(() {
              _finishText();
              _sel = _slide.newBox();
            }),
            icon: const Icon(Icons.text_fields),
            label: const Text('Caixa de texto'),
          ),
          TextButton.icon(
            onPressed: () => _slideAction('novo', _current),
            icon: const Icon(Icons.add_box_outlined),
            label: const Text('Novo slide'),
          ),
          TextButton.icon(
            onPressed: () => _slideAction('duplicar', _current),
            icon: const Icon(Icons.copy_all_outlined),
            label: const Text('Duplicar'),
          ),
          const SizedBox(height: 32, child: VerticalDivider()),
          if (text) ...[
            IconButton(
              tooltip: 'Diminuir fonte',
              onPressed: () => setState(() => f.estilo(size: (f.size - 2).clamp(6, 200))),
              icon: const Icon(Icons.text_decrease),
            ),
            SizedBox(width: 36, child: Text('${f.size.round()}', textAlign: TextAlign.center)),
            IconButton(
              tooltip: 'Aumentar fonte',
              onPressed: () => setState(() => f.estilo(size: (f.size + 2).clamp(6, 200))),
              icon: const Icon(Icons.text_increase),
            ),
            IconButton(
              tooltip: 'Negrito',
              isSelected: f.bold,
              onPressed: () => setState(() => f.estilo(bold: !f.bold)),
              icon: const Icon(Icons.format_bold),
            ),
            IconButton(
              tooltip: 'Itálico',
              isSelected: f.italic,
              onPressed: () => setState(() => f.estilo(italic: !f.italic)),
              icon: const Icon(Icons.format_italic),
            ),
            IconButton(
              tooltip: 'Sublinhado',
              isSelected: f.underline,
              onPressed: () => setState(() => f.estilo(underline: !f.underline)),
              icon: const Icon(Icons.format_underline),
            ),
            for (final (algn, icone) in [
              ('l', Icons.format_align_left),
              ('ctr', Icons.format_align_center),
              ('r', Icons.format_align_right),
              ('just', Icons.format_align_justify),
            ])
              IconButton(
                isSelected: f.alignmentMode == algn,
                onPressed: () => setState(() => f.estilo(alignmentMode: algn)),
                icon: Icon(icone),
              ),
            PopupMenuButton<String>(
              tooltip: 'Cor do texto',
              icon: Icon(Icons.format_color_text, color: _color(f.color)),
              onSelected: (c) => setState(() => f.estilo(color: c)),
              itemBuilder: (_) => [
                for (final c in _textColors)
                  PopupMenuItem(
                    value: c,
                    child: Row(
                      children: [
                        Container(width: 18, height: 18, color: _color(c), margin: const EdgeInsets.only(right: 8)),
                        Text('#$c'),
                      ],
                    ),
                  ),
              ],
            ),
            IconButton(
              tooltip: _editing ? 'Concluir texto' : 'Editar texto',
              onPressed: () => _editing ? setState(_finishText) : _select(f, edit: true),
              icon: Icon(_editing ? Icons.check : Icons.edit_outlined),
            ),
          ],
          if (f != null)
            IconButton(
              tooltip: 'Excluir forma',
              onPressed: () => setState(() {
                _editing = false;
                _slide.delete(f);
                _sel = null;
              }),
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
    );
  }

  Widget _stage() {
    final ap = _ap!;
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: GestureDetector(
        onTap: () => _select(null),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: AspectRatio(
              aspectRatio: ap.width / ap.height,
              child: Material(
                elevation: 3,
                child: _SlideVista(
                  ap: ap,
                  slide: _slide,
                  selected: _sel,
                  editor: _editing ? _text : null,
                  onItemTap: (f) => _select(f),
                  onDoubleTap: (f) => _select(f, edit: true),
                  aoMudar: () => setState(() {}),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Color _color(String? hex) => hex == null ? Colors.black : Color(int.parse('FF$hex', radix: 16));

/// Drawing of a slide at the available size; interactive when it gets [onItemTap].
class _SlideVista extends StatelessWidget {
  const _SlideVista({
    required this.ap,
    required this.slide,
    this.selected,
    this.editor,
    this.onItemTap,
    this.onDoubleTap,
    this.aoMudar,
  });

  final Presentation ap;
  final Slide slide;
  final SlideShape? selected;
  final TextEditingController? editor;
  final void Function(SlideShape)? onItemTap;
  final void Function(SlideShape)? onDoubleTap;
  final VoidCallback? aoMudar;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final k = c.maxWidth / ap.width;
      final background = slide.background;
      return ClipRect(
        child: ColoredBox(
          color: background == null ? Colors.white : _color(background),
          child: Stack(
            children: [
              for (final f in slide.shapes)
                Positioned(
                  left: f.x * k,
                  top: f.y * k,
                  width: f.w * k,
                  height: f.h * k,
                  child: _shape(context, f, k),
                ),
            ],
          ),
        ),
      );
    },
  );

  TextStyle _style(SlideShape f, double k) => TextStyle(
    fontSize: (f.size * emuPerPoint * k).clamp(1, 400),
    fontWeight: f.bold ? FontWeight.bold : FontWeight.normal,
    fontStyle: f.italic ? FontStyle.italic : FontStyle.normal,
    decoration: f.underline ? TextDecoration.underline : null,
    color: _color(f.color),
    height: 1.15,
  );

  TextAlign _align(SlideShape f) => switch (f.alignmentMode) {
    'ctr' => TextAlign.center,
    'r' => TextAlign.right,
    'just' => TextAlign.justify,
    _ => TextAlign.left,
  };

  Widget _shape(BuildContext context, SlideShape f, double k) {
    final image = f.image == null ? null : ap.bytes(f.image!);
    final Widget content;
    if (image != null) {
      content = Image.memory(image, fit: BoxFit.fill, errorBuilder: (_, _, _) => const Placeholder());
    } else if (f.another != null) {
      content = Container(
        color: Colors.black12,
        alignment: Alignment.center,
        child: Text(f.another!, style: TextStyle(fontSize: (12 * emuPerPoint * k).clamp(6, 24), color: Colors.black54)),
      );
    } else if (editor != null && identical(f, selected)) {
      content = Material(
        color: Colors.white.withValues(alpha: 0.9),
        child: TextField(
          controller: editor,
          autofocus: true,
          maxLines: null,
          expands: true,
          textAlign: _align(f),
          style: _style(f, k),
          decoration: const InputDecoration(border: InputBorder.none, isCollapsed: true),
        ),
      );
    } else {
      final t = f.text;
      content = Align(
        alignment: f.title ? Alignment.center : Alignment.topLeft,
        child: Text(
          t.isEmpty && f.placeholder && onItemTap != null ? (f.title ? 'Clique duas vezes para o título' : 'Clique duas vezes para o texto') : t,
          textAlign: _align(f),
          overflow: TextOverflow.clip,
          style: t.isEmpty ? _style(f, k).copyWith(color: Colors.black38) : _style(f, k),
        ),
      );
    }
    if (onItemTap == null) return content;
    final sel = identical(f, selected);
    return GestureDetector(
      onTap: () => onItemTap!(f),
      onDoubleTap: () => onDoubleTap?.call(f),
      onPanUpdate: sel && editor == null
          ? (d) {
              f.placeAt(f.x + d.delta.dx / k, f.y + d.delta.dy / k, f.w, f.h);
              aoMudar?.call();
            }
          : null,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: content),
          if (sel)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(decoration: BoxDecoration(border: Border.all(color: Colors.blue, width: 1.5))),
              ),
            ),
          if (sel && editor == null)
            Positioned(
              right: -6,
              bottom: -6,
              child: GestureDetector(
                onPanUpdate: (d) {
                  f.placeAt(f.x, f.y, f.w + d.delta.dx / k, f.h + d.delta.dy / k);
                  aoMudar?.call();
                },
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Colors.blue, width: 2)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
