import 'package:agent_core/agent_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import 'editor.dart';
import 'toolbox.dart';
import 'flow.dart';
import 'painting.dart';

/// Shapes to insert on the board, like the draw.io side library: search and categories. Tapping
/// inserts in the center of the screen; dragging drops it wherever you want.
class ShapesPanel extends StatefulWidget {
  const ShapesPanel({super.key, required this.insert, required this.tool, this.onDrag});

  final ValueChanged<NodeKind> insert;
  final ValueChanged<Tool> tool;

  /// Called when a shape starts being dragged.
  final VoidCallback? onDrag;

  @override
  State<ShapesPanel> createState() => _ShapesPanelState();
}

class _ShapesPanelState extends State<ShapesPanel> {
  String _search = '';

  static const _flowchart = [
    NodeKind.inicio,
    NodeKind.processo,
    NodeKind.decisao,
    NodeKind.dado,
    NodeKind.subprocesso,
    NodeKind.documento,
    NodeKind.banco,
    NodeKind.quadrado,
    NodeKind.circulo,
    NodeKind.hexagono,
    NodeKind.nota,
    NodeKind.container,
  ];
  static const _general = [Tool.text, Tool.retangulo, Tool.elipse, Tool.seta, Tool.reta];

  bool _bate(String name) => _search.isEmpty || name.toLowerCase().contains(_search.toLowerCase());

  @override
  Widget build(BuildContext context) {
    final flow = [
      for (final t in _flowchart)
        if (_bate(t.label)) t,
    ];
    final general = [
      for (final f in _general)
        if (_bate(f.label)) f,
    ];
    return ListView(
      padding: const EdgeInsets.all(10),
      children: [
        TextField(
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.search, size: 20),
            hintText: 'Procurar formas',
          ),
          onChanged: (v) => setState(() => _search = v),
        ),
        if (flow.isNotEmpty) ...[
          const _Heading('Fluxograma'),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in flow)
                _DraggableShape(type: t, onItemTap: () => widget.insert(t), onDrag: widget.onDrag),
            ],
          ),
        ],
        if (general.isNotEmpty) ...[
          const _Heading('Geral (desenhar)'),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final f in general)
                Tooltip(
                  message: f.label,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(56, 48), padding: EdgeInsets.zero),
                    onPressed: () => widget.tool(f),
                    child: Icon(f.icone),
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        Text(
          'Toque para inserir no centro ou arraste para o quadro. Selecione um bloco e puxe as alças ⊕ para ligar.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 8),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}

/// Thumbnail of a block type (the same drawing as the board, scaled).
class BlockThumbnail extends StatelessWidget {
  const BlockThumbnail(this.type, {super.key, this.size = const Size(56, 40)});

  final NodeKind type;
  final Size size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: size, painter: _ThumbnailPainter(type, Theme.of(context).brightness == Brightness.dark));
}

class _ThumbnailPainter extends CustomPainter {
  _ThumbnailPainter(this.type, this.dark);

  final NodeKind type;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final quadrado = type == NodeKind.circulo || type == NodeKind.banco;
    final w = quadrado ? size.height : size.width;
    final no = FlowNode(
      '_',
      type: type,
      text: '',
      a: Offset((size.width - w) / 2 + 2, 2),
      b: Offset((size.width + w) / 2 - 2, size.height - 2),
      color: flowColors[type]!,
    );
    paintElement(canvas, no, dark: dark);
  }

  @override
  bool shouldRepaint(_ThumbnailPainter old) => old.type != type || old.dark != dark;
}

class _DraggableShape extends StatelessWidget {
  const _DraggableShape({required this.type, required this.onItemTap, this.onDrag});

  final NodeKind type;
  final VoidCallback onItemTap;
  final VoidCallback? onDrag;

  @override
  Widget build(BuildContext context) {
    final card = Tooltip(
      message: type.label,
      child: InkWell(
        onTap: onItemTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 64,
          height: 52,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          ),
          child: BlockThumbnail(type),
        ),
      ),
    );
    return Draggable<NodeKind>(
      data: type,
      onDragStarted: onDrag,
      feedback: Material(
        color: Colors.transparent,
        child: Opacity(opacity: 0.8, child: BlockThumbnail(type, size: const Size(110, 70))),
      ),
      child: card,
    );
  }
}

/// Selection style, like the draw.io "Style" tab: block shape, border, background and text colors,
/// alignment, label and arrow stroke. No selection: the "Diagrama" (background and export).
class StylePanel extends StatelessWidget {
  const StylePanel({
    super.key,
    required this.selectedItems,
    required this.apply,
    required this.editText,
    this.format,
    required this.recent,
    required this.background,
    required this.changeBackground,
    required this.export,
  });

  final List<Elemento> selectedItems;
  final void Function(Map<String, Elemento>) apply;
  final VoidCallback editText;

  /// With text being typed on the board: wraps the selected excerpt in the mark (`**`, `*`, `__`, `==`).
  final ValueChanged<String>? format;
  final List<Color> recent;
  final Background background;
  final ValueChanged<Background> changeBackground;
  final List<(String, IconData, VoidCallback)> export;

  /// Formatting buttons for the text being typed. They stay in the field's region, otherwise a tap here
  /// would count as "outside" and end the typing.
  Widget _formatting(BuildContext context) => TextFieldTapRegion(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Heading('Texto'),
        Wrap(
          children: [
            IconButton(tooltip: 'Negrito', onPressed: () => format!('**'), icon: const Icon(Icons.format_bold)),
            IconButton(tooltip: 'Itálico', onPressed: () => format!('*'), icon: const Icon(Icons.format_italic)),
            IconButton(
              tooltip: 'Sublinhado',
              onPressed: () => format!('__'),
              icon: const Icon(Icons.format_underlined),
            ),
            IconButton(tooltip: 'Marcador', onPressed: () => format!('=='), icon: const Icon(Icons.border_color)),
          ],
        ),
        Text(
          'Selecione um trecho e toque no botão. Esc ou clique fora para concluir.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final blocks = selectedItems.whereType<FlowNode>().toList();
    final arrows = selectedItems.whereType<Connector>().toList();
    final texts = selectedItems.whereType<BoardText>().toList();
    if (selectedItems.isEmpty && format == null) return _diagram(context);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (format != null) _formatting(context),
        if (selectedItems.isNotEmpty)
          Text(
            '${selectedItems.length} selecionado${selectedItems.length == 1 ? '' : 's'}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        if (format == null &&
            selectedItems.length == 1 &&
            (blocks.isNotEmpty || arrows.isNotEmpty || texts.isNotEmpty))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton.icon(
              onPressed: editText,
              icon: const Icon(Icons.edit_note),
              label: const Text('Editar texto'),
            ),
          ),
        if (blocks.isNotEmpty) ...[
          const _Heading('Forma'),
          DropdownButtonFormField<NodeKind>(
            initialValue: blocks.map((b) => b.type).toSet().length == 1 ? blocks.first.type : null,
            isExpanded: true,
            decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
            items: [
              for (final t in NodeKind.values)
                if (t != NodeKind.fim)
                  DropdownMenuItem(
                    value: t,
                    child: Row(
                      spacing: 8,
                      children: [
                        BlockThumbnail(t, size: const Size(28, 20)),
                        Expanded(child: Text(t.label)),
                      ],
                    ),
                  ),
            ],
            onChanged: (t) => t == null ? null : apply({for (final b in blocks) b.id: b.copy(type: t)}),
          ),
          _ColorDot('Borda', blocks.first.color, recent, (c) => apply({for (final b in blocks) b.id: b.copy(color: c)})),
          _ColorDot(
            'Preenchimento',
            blocks.first.background,
            recent,
            (c) => apply({for (final b in blocks) b.id: b.copy(background: c)}),
            clear: () => apply({for (final b in blocks) b.id: b.copy(noBackground: true)}),
          ),
          _ColorDot(
            'Texto',
            blocks.first.textColor,
            recent,
            (c) => apply({for (final b in blocks) b.id: b.copy(textColor: c)}),
            clear: () => apply({for (final b in blocks) b.id: b.copy(noTextColor: true)}),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Texto à esquerda'),
            value: blocks.every((b) => b.esquerda),
            onChanged: (v) => apply({for (final b in blocks) b.id: b.copy(esquerda: v)}),
          ),
        ],
        if (arrows.isNotEmpty) ...[
          const _Heading('Seta'),
          _ColorDot('Cor', arrows.first.color, recent, (c) => apply({for (final s in arrows) s.id: s.copy(color: c)})),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Em ângulo reto'),
            value: arrows.every((s) => s.orthogonal),
            onChanged: (v) => apply({for (final s in arrows) s.id: s.copy(orthogonal: v)}),
          ),
          const _Heading('Linha'),
          SegmentedButton<LineKind>(
            showSelectedIcon: false,
            segments: [for (final t in LineKind.values) ButtonSegment(value: t, label: Text(t.label))],
            selected: {if (arrows.map((s) => s.line).toSet().length == 1) arrows.first.line},
            emptySelectionAllowed: true,
            onSelectionChanged: (v) {
              if (v.isNotEmpty) apply({for (final s in arrows) s.id: s.copy(line: v.first)});
            },
          ),
          Row(
            children: [
              Text('Espessura ${arrows.first.thickness.round()}'),
              Expanded(
                child: Slider(
                  min: 1,
                  max: 10,
                  divisions: 9,
                  value: arrows.first.thickness.clamp(1, 10),
                  onChanged: (v) => apply({for (final s in arrows) s.id: s.copy(thickness: v)}),
                ),
              ),
            ],
          ),
          _Choice<TipKind>(
            'Ponta no início',
            arrows.map((s) => s.startTip).toSet().length == 1 ? arrows.first.startTip : null,
            {for (final t in TipKind.values) t: t.label},
            (t) => apply({for (final s in arrows) s.id: s.copy(startTip: t)}),
          ),
          _Choice<TipKind>(
            'Ponta no fim',
            arrows.map((s) => s.endTip).toSet().length == 1 ? arrows.first.endTip : null,
            {for (final t in TipKind.values) t: t.label},
            (t) => apply({for (final s in arrows) s.id: s.copy(endTip: t)}),
          ),
          _Choice<int>(
            'Sai pelo lado',
            arrows.map((s) => s.sideOf).toSet().length == 1 ? arrows.first.sideOf ?? -1 : null,
            {-1: 'Automático', for (final (i, l) in blockSides.indexed) i: l},
            (i) => apply({for (final s in arrows) s.id: s.copy(sideOf: i, autoSideOf: i < 0)}),
          ),
          _Choice<int>(
            'Chega pelo lado',
            arrows.map((s) => s.sideTo).toSet().length == 1 ? arrows.first.sideTo ?? -1 : null,
            {-1: 'Automático', for (final (i, l) in blockSides.indexed) i: l},
            (i) => apply({for (final s in arrows) s.id: s.copy(sideTo: i, autoSideTo: i < 0)}),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton.icon(
              onPressed: () => apply({for (final s in arrows) s.id: s.inverted()}),
              icon: const Icon(Icons.swap_horiz),
              label: const Text('Inverter sentido'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Para ligar em outro bloco, arraste a bolinha da ponta da seta até ele: o lado mais perto de onde soltar vira o ponto de ligação.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
        if (texts.isNotEmpty) ...[
          const _Heading('Texto'),
          _ColorDot(
            'Cor',
            texts.first.color,
            recent,
            (c) => apply({for (final t in texts) t.id: t.transform((q) => q, color: c)}),
          ),
          Row(
            children: [
              const Text('Tamanho'),
              Expanded(
                child: Slider(
                  min: 10,
                  max: 72,
                  value: texts.first.size.clamp(10, 72),
                  onChanged: (v) => apply({
                    for (final t in texts)
                      t.id: BoardText(t.id, position: t.position, text: t.text, color: t.color, size: v),
                  }),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _diagram(BuildContext context) => ListView(
    padding: const EdgeInsets.all(12),
    children: [
      Text('Diagrama', style: Theme.of(context).textTheme.titleSmall),
      const _Heading('Fundo'),
      Wrap(
        spacing: 6,
        children: [
          for (final f in Background.values)
            ChoiceChip(label: Text(f.label), selected: background == f, onSelected: (_) => changeBackground(f)),
        ],
      ),
      const _Heading('Exportar'),
      for (final (label, icone, action) in export)
        ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(icone), title: Text(label), onTap: action),
      const SizedBox(height: 8),
      Text('Selecione um elemento para mudar forma, cores e texto.', style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

/// Label + compact dropdown ([current] null = mixed values in the selection).
class _Choice<T> extends StatelessWidget {
  const _Choice(this.label, this.current, this.options, this.pick);

  final String label;
  final T? current;
  final Map<T, String> options;
  final ValueChanged<T> pick;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Row(
      spacing: 8,
      children: [
        Expanded(child: Text(label)),
        DropdownButton<T>(
          value: current,
          isDense: true,
          items: [
            for (final MapEntry(:key, :value) in options.entries) DropdownMenuItem(value: key, child: Text(value)),
          ],
          onChanged: (v) => v == null ? null : pick(v),
        ),
      ],
    ),
  );
}

/// Page layers, from top (front) to bottom: tapping selects (Ctrl adds), dragging changes the order.
class LayersPanel extends StatelessWidget {
  const LayersPanel({
    super.key,
    required this.elements,
    required this.selectedItems,
    required this.select,
    required this.reorder,
    required this.moveLayer,
  });

  final List<Elemento> elements;
  final Set<String> selectedItems;
  final void Function(String id, bool add) select;

  /// New order from bottom to top (the last one stays in front).
  final ValueChanged<List<String>> reorder;
  final ValueChanged<int> moveLayer;

  static (IconData, String) _describe(Elemento e) => switch (e) {
    Traco() => (Icons.gesture, 'Traço'),
    Forma(:final shape) => (
      Icons.crop_square,
      switch (shape) {
        ShapeKind.reta => 'Reta',
        ShapeKind.seta => 'Seta solta',
        ShapeKind.retangulo => 'Retângulo',
        ShapeKind.elipse => 'Elipse',
      },
    ),
    BoardText(:final text) => (Icons.title, text),
    FlowNode(:final type, :final text) => (Icons.widgets_outlined, text.isEmpty ? type.label : text),
    Connector(:final label) => (Icons.trending_flat, label.isEmpty ? 'Seta' : 'Seta: $label'),
    BoardTable(:final linhas, :final columns) => (Icons.table_chart_outlined, 'Tabela $linhas × $columns'),
    BoardImage(:final title) => (Icons.image_outlined, title.isEmpty ? 'Imagem' : title),
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final items = elements.reversed.toList();
    final hasSelection = selectedItems.isNotEmpty;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final (step, icone, hint) in [
                (2, Icons.flip_to_front, 'Trazer para a frente (Ctrl+Shift+])'),
                (1, Icons.arrow_upward, 'Uma camada para a frente (Ctrl+])'),
                (-1, Icons.arrow_downward, 'Uma camada para trás (Ctrl+[)'),
                (-2, Icons.flip_to_back, 'Enviar para trás (Ctrl+Shift+[)'),
              ])
                IconButton(tooltip: hint, onPressed: hasSelection ? () => moveLayer(step) : null, icon: Icon(icone)),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: items.isEmpty
              ? const Center(child: Text('Página vazia'))
              : ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: items.length,
                  onReorderItem: (de, to) {
                    final ids = [for (final e in items) e.id];
                    ids.insert(to, ids.removeAt(de));
                    reorder(ids.reversed.toList());
                  },
                  itemBuilder: (context, i) {
                    final e = items[i];
                    final (icone, name) = _describe(e);
                    return ListTile(
                      key: ValueKey(e.id),
                      dense: true,
                      selected: selectedItems.contains(e.id),
                      selectedTileColor: colors.primaryContainer,
                      leading: Icon(
                        icone,
                        size: 18,
                        color: switch (e) {
                          Traco(:final color) || Forma(:final color) || BoardText(:final color) => color,
                          FlowNode(:final color) || Connector(:final color) || BoardTable(:final color) => color,
                          BoardImage() => null,
                        },
                      ),
                      title: Text(name.replaceAll('\n', ' '), maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: e.group.isEmpty ? null : const Text('em grupo'),
                      trailing: ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle)),
                      onTap: () => select(e.id, HardwareKeyboard.instance.isControlPressed),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot(this.label, this.current, this.recent, this.pick, {this.clear});

  final String label;
  final Color? current;
  final List<Color> recent;
  final ValueChanged<Color> pick;
  final VoidCallback? clear;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Row(
      spacing: 8,
      children: [
        Expanded(child: Text(label)),
        if (clear != null)
          IconButton(
            tooltip: 'Automático',
            visualDensity: VisualDensity.compact,
            onPressed: clear,
            icon: const Icon(Icons.format_color_reset, size: 20),
          ),
        InkWell(
          onTap: () async {
            final c = await escolherCor(context, current ?? const Color(0xFF1565C0), recent, paleta: quickColors);
            if (c != null) pick(c);
          },
          child: Container(
            width: 36,
            height: 28,
            decoration: BoxDecoration(
              color: current,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Theme.of(context).colorScheme.outline),
            ),
            child: current == null ? const Icon(Icons.auto_awesome, size: 16) : null,
          ),
        ),
      ],
    ),
  );
}

/// Page tabs in the footer (like draw.io): tapping opens, ⋮ (or right button) renames, colors or
/// deletes, + creates. The mouse wheel over the tabs scrolls the bar sideways.
class PagesBar extends StatefulWidget {
  const PagesBar({super.key, required this.editor});

  final BoardEditor editor;

  @override
  State<PagesBar> createState() => _PagesBarState();
}

class _PagesBarState extends State<PagesBar> {
  final _scroll = ScrollController();

  BoardEditor get editor => widget.editor;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _mouseWheel(PointerSignalEvent e) {
    if (e is! PointerScrollEvent || !_scroll.hasClients) return;
    GestureBinding.instance.pointerSignalResolver.register(e, (_) {
      final d = e.scrollDelta.dy.abs() > e.scrollDelta.dx.abs() ? e.scrollDelta.dy : e.scrollDelta.dx;
      final pos = _scroll.position;
      _scroll.jumpTo((pos.pixels + d).clamp(pos.minScrollExtent, pos.maxScrollExtent));
    });
  }

  Future<String?> _nome(BuildContext context, String title, String initial) =>
      editFormattedText(context, title: title, initial: initial, confirm: 'OK', format: false);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainer,
      child: SizedBox(
        height: 42,
        child: Row(
          children: [
            Expanded(
              child: Listener(
                onPointerSignal: _mouseWheel,
                child: ListView(
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  children: [
                    for (final (i, p) in editor.pages.indexed)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
                        child: GestureDetector(onSecondaryTap: () => _menu(context, p), child: _tab(context, i, p)),
                      ),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: 'Nova página',
              icon: const Icon(Icons.add),
              onPressed: () async {
                final n = await _nome(context, 'Nova página', 'Página ${editor.pages.length + 1}');
                if (n != null && n.trim().isNotEmpty) await editor.newPage(n.trim());
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _tab(BuildContext context, int i, BoardPage p) {
    final current = p.id == editor.currentPage;
    final color = p.color;
    final text = color == null ? null : (color.computeLuminance() > 0.5 ? Colors.black : Colors.white);
    return InputChip(
      label: Text(p.name.isEmpty ? 'Página ${i + 1}' : p.name, style: TextStyle(color: text)),
      selected: current,
      showCheckmark: false,
      backgroundColor: color,
      selectedColor: color,
      side: current && color != null ? BorderSide(color: Theme.of(context).colorScheme.primary, width: 2.5) : null,
      onPressed: () => editor.goTo(p.id),
      deleteIcon: Icon(Icons.more_vert, size: 16, color: text),
      onDeleted: current ? () => _menu(context, p) : null,
    );
  }

  Future<void> _menu(BuildContext context, BoardPage p) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Renomear página'),
              onTap: () => Navigator.pop(c, 'renomear'),
            ),
            ListTile(
              leading: Icon(Icons.format_color_fill, color: p.color),
              title: const Text('Cor da aba'),
              onTap: () => Navigator.pop(c, 'cor'),
            ),
            if (p.color != null)
              ListTile(
                leading: const Icon(Icons.format_color_reset),
                title: const Text('Tirar a cor da aba'),
                onTap: () => Navigator.pop(c, 'sem cor'),
              ),
            if (editor.pages.length > 1)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Excluir página e o que tem nela'),
                onTap: () => Navigator.pop(c, 'excluir'),
              ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 'renomear') {
      final n = await _nome(context, 'Renomear página', p.name);
      if (n != null && n.trim().isNotEmpty) await editor.renamePage(p.id, n.trim());
    } else if (action == 'cor') {
      final c = await escolherCor(context, p.color ?? const Color(0xFFFFE082), const [], paleta: quickColors);
      if (c != null) await editor.colorPage(p.id, c);
    } else if (action == 'sem cor') {
      await editor.colorPage(p.id, null);
    } else if (action == 'excluir') {
      await editor.deletePage(p.id);
    }
  }
}
