import 'package:flutter/material.dart';

import 'capture_api.dart';

/// Items of the current scene (bottom = on top) and the editor of the selected one: shape (rectangle,
/// rounded, circle, vertical, horizontal), position, framing (fit, zoom, center), border and the
/// automatic behaviors of the source (follow the mouse, track the face).
class StudioItemPanel extends StatelessWidget {
  const StudioItemPanel({
    super.key,
    required this.state,
    required this.selected,
    required this.onSelect,
    required this.onItems,
    required this.onSourceConfig,
  });

  final CaptureState state;
  final String? selected;
  final ValueChanged<String> onSelect;
  final ValueChanged<List<SceneItem>> onItems;
  final void Function(String sourceId, Map<String, Object?> config) onSourceConfig;

  CaptureScene? get scene => state.scene;

  @override
  Widget build(BuildContext context) {
    final current = scene;
    if (current == null) return const Center(child: Text('Crie uma cena.'));
    SceneItem? item;
    for (final i in current.items) {
      if (i.source == selected) item = i;
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _list(context, current)),
        const VerticalDivider(width: 1),
        Expanded(child: item == null ? const Center(child: Text('Selecione um item')) : _editor(context, item)),
      ],
    );
  }

  // ================================================================== list

  Widget _list(BuildContext context, CaptureScene current) {
    final outside = <CaptureSource>[];
    for (final s in state.sources) {
      if (!s.video) continue;
      var inScene = false;
      for (final i in current.items) {
        if (i.source == s.id) inScene = true;
      }
      if (!inScene) outside.add(s);
    }
    final menu = <PopupMenuEntry<CaptureSource>>[];
    for (final s in outside) {
      menu.add(PopupMenuItem(value: s, child: Text(s.name)));
    }
    final rows = <Widget>[];
    for (var index = 0; index < current.items.length; index++) {
      rows.add(_row(context, current, index));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: Text('Itens de "${current.name}" (o de baixo fica por cima)',
                    style: Theme.of(context).textTheme.titleSmall, overflow: TextOverflow.ellipsis),
              ),
              PopupMenuButton<CaptureSource>(
                enabled: outside.isNotEmpty,
                tooltip: 'Pôr fonte nesta cena',
                icon: const Icon(Icons.add_box_outlined),
                itemBuilder: (_) => menu,
                onSelected: (s) => _addToScene(current, s),
              ),
            ],
          ),
        ),
        Expanded(child: ListView(padding: const EdgeInsets.symmetric(horizontal: 12), children: rows)),
      ],
    );
  }

  void _addToScene(CaptureScene current, CaptureSource source) {
    final items = _copies(current);
    items.add(SceneItem(source: source.id, w: state.width, h: state.height));
    onItems(items);
  }

  List<SceneItem> _copies(CaptureScene current) {
    final result = <SceneItem>[];
    for (final i in current.items) {
      result.add(i.copy());
    }
    return result;
  }

  Widget _row(BuildContext context, CaptureScene current, int index) {
    final item = current.items[index];
    final isSelected = selected == item.source;
    return Material(
      color: isSelected ? Theme.of(context).colorScheme.secondaryContainer : null,
      child: Row(
        children: [
          IconButton(
            icon: Icon(item.visible ? Icons.visibility : Icons.visibility_off, size: 18),
            onPressed: () => _change(current, index, _toggleVisible),
          ),
          Expanded(
            child: InkWell(
              onTap: () => onSelect(item.source),
              child: Text(state.source(item.source)?.name ?? item.source, overflow: TextOverflow.ellipsis),
            ),
          ),
          IconButton(
            tooltip: 'Para trás',
            icon: const Icon(Icons.arrow_upward, size: 18),
            onPressed: index == 0 ? null : () => _move(current, index, -1),
          ),
          IconButton(
            tooltip: 'Para frente',
            icon: const Icon(Icons.arrow_downward, size: 18),
            onPressed: index == current.items.length - 1 ? null : () => _move(current, index, 1),
          ),
          IconButton(
            tooltip: 'Tirar da cena',
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => _remove(current, index),
          ),
        ],
      ),
    );
  }

  static void _toggleVisible(SceneItem item) => item.visible = !item.visible;

  void _change(CaptureScene current, int index, void Function(SceneItem) edit) {
    final items = _copies(current);
    edit(items[index]);
    onItems(items);
  }

  void _move(CaptureScene current, int index, int delta) {
    final items = _copies(current);
    final item = items.removeAt(index);
    items.insert(index + delta, item);
    onItems(items);
  }

  void _remove(CaptureScene current, int index) {
    final items = _copies(current);
    items.removeAt(index);
    onItems(items);
  }

  // ================================================================== editor

  Widget _editor(BuildContext context, SceneItem item) {
    final source = state.source(item.source);
    final children = <Widget>[
      Text(source?.name ?? item.source, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 6),
      const Text('Formato'),
      Wrap(spacing: 6, runSpacing: 6, children: _shapeChips(item)),
      const SizedBox(height: 6),
      const Text('Posição'),
      Wrap(spacing: 6, runSpacing: 6, children: _positionChips(item)),
      _slider('Opacidade', item.alpha, 0, 1, (v) => _editItem(item, (i) => i.alpha = v)),
    ];
    if (source != null && source.framed) children.addAll(_framing(item, source));
    children.addAll(_border(item));
    return ListView(padding: const EdgeInsets.all(12), children: children);
  }

  List<Widget> _shapeChips(SceneItem item) {
    const shapes = [
      ('rect', 'Retângulo'),
      ('rounded', 'Arredondado'),
      ('circle', 'Círculo'),
      ('vertical', 'Vertical 9:16'),
      ('horizontal', 'Horizontal 16:9'),
      ('square', 'Quadrado'),
    ];
    final result = <Widget>[];
    for (final (key, label) in shapes) {
      result.add(ActionChip(label: Text(label), onPressed: () => _editItem(item, (i) => applyShape(i, key))));
    }
    return result;
  }

  List<Widget> _positionChips(SceneItem item) {
    const positions = [
      ('full', 'Tela cheia'),
      ('bottom_right', 'Canto ↘'),
      ('bottom_left', 'Canto ↙'),
      ('top_right', 'Canto ↗'),
      ('left_half', 'Metade esq.'),
      ('right_half', 'Metade dir.'),
      ('center', 'Centro'),
    ];
    final result = <Widget>[];
    for (final (key, label) in positions) {
      result.add(ActionChip(
        label: Text(label),
        onPressed: () => _editItem(item, (i) => applyPosition(i, key, state.width, state.height)),
      ));
    }
    return result;
  }

  List<Widget> _framing(SceneItem item, CaptureSource source) {
    final following = source.config['follow_mouse'] == true;
    final tracking = source.config['track_face'] == true;
    final result = <Widget>[
      const Divider(),
      const Text('Enquadramento'),
      SegmentedButton<String>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: 'cover', label: Text('Preencher')),
          ButtonSegment(value: 'contain', label: Text('Caber')),
          ButtonSegment(value: 'stretch', label: Text('Esticar')),
        ],
        selected: {item.fit},
        onSelectionChanged: (s) => _editItem(item, (i) => i.fit = s.first),
      ),
      _slider('Zoom', item.zoom, 1, 4, (v) => _editItem(item, (i) => i.zoom = v)),
    ];
    if (!following && !tracking) {
      result.add(_slider('Centro X', item.cx, 0, 1, (v) => _editItem(item, (i) => i.cx = v)));
      result.add(_slider('Centro Y', item.cy, 0, 1, (v) => _editItem(item, (i) => i.cy = v)));
    }
    if (source.kind == 'screen') {
      result.add(SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: const Text('Seguir o mouse'),
        subtitle: const Text('Recorta a tela no formato do item e acompanha o cursor (ultrawide sem barras)'),
        value: following,
        onChanged: (v) => onSourceConfig(source.id, {'follow_mouse': v}),
      ));
    }
    if (source.camera) {
      result.add(SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: const Text('Rastrear o rosto'),
        subtitle: Text(state.faceTracking ? 'Centraliza o rosto (OpenCV)' : 'Rode infra/scripts/install_capture'),
        value: tracking,
        onChanged: state.faceTracking ? (v) => onSourceConfig(source.id, {'track_face': v}) : null,
      ));
      result.add(SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: const Text('Zoom automático no rosto'),
        value: source.config['auto_zoom'] == true,
        onChanged: tracking ? (v) => onSourceConfig(source.id, {'auto_zoom': v}) : null,
      ));
    }
    return result;
  }

  List<Widget> _border(SceneItem item) {
    const colors = ['#FFFFFF', '#000000', '#FF3B30', '#FFCC00', '#34C759', '#0A84FF'];
    final chips = <Widget>[];
    for (final color in colors) {
      chips.add(InkWell(
        onTap: () => _editItem(item, (i) => i.borderColor = color),
        child: Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: _color(color),
            shape: BoxShape.circle,
            border: Border.all(color: item.borderColor == color ? Colors.redAccent : Colors.grey, width: 2),
          ),
        ),
      ));
    }
    return [
      const Divider(),
      _slider('Borda', item.border, 0, 24, (v) => _editItem(item, (i) => i.border = v.roundToDouble())),
      Wrap(spacing: 8, children: chips),
      _slider('Cantos', item.radius, 0, (item.w < item.h ? item.w : item.h) / 2,
          (v) => _editItem(item, (i) => i.radius = v.roundToDouble())),
    ];
  }

  Widget _slider(String label, double value, double min, double max, ValueChanged<double> onEnd) {
    return Row(
      children: [
        SizedBox(width: 80, child: Text(label, style: const TextStyle(fontSize: 13))),
        Expanded(
          child: _LiveSlider(value: value.clamp(min, max), min: min, max: max, onEnd: onEnd),
        ),
      ],
    );
  }

  void _editItem(SceneItem item, void Function(SceneItem) edit) {
    final current = scene;
    if (current == null) return;
    final items = <SceneItem>[];
    for (final i in current.items) {
      final copy = i.copy();
      if (i.source == item.source) edit(copy);
      items.add(copy);
    }
    onItems(items);
  }
}

/// Slider that moves locally and only sends the value when released.
class _LiveSlider extends StatefulWidget {
  const _LiveSlider({required this.value, required this.min, required this.max, required this.onEnd});

  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onEnd;

  @override
  State<_LiveSlider> createState() => _LiveSliderState();
}

class _LiveSliderState extends State<_LiveSlider> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    return Slider(
      value: _dragging ?? widget.value,
      min: widget.min,
      max: widget.max <= widget.min ? widget.min + 1 : widget.max,
      onChanged: (v) => setState(() => _dragging = v),
      onChangeEnd: _end,
    );
  }

  void _end(double value) {
    setState(() => _dragging = null);
    widget.onEnd(value);
  }
}

Color _color(String hex) => Color(0xFF000000 | int.parse(hex.substring(1), radix: 16));

/// Item shape keeping its center: circle and square use the smaller side; vertical/horizontal keep one
/// side and change the other.
void applyShape(SceneItem item, String shape) {
  final centerX = item.x + item.w / 2;
  final centerY = item.y + item.h / 2;
  final shorter = item.w < item.h ? item.w : item.h;
  switch (shape) {
    case 'rect':
      item.radius = 0;
    case 'rounded':
      item.radius = 24;
    case 'circle':
      item.w = shorter;
      item.h = shorter;
      item.radius = shorter / 2;
    case 'square':
      item.w = shorter;
      item.h = shorter;
      item.radius = 0;
    case 'vertical':
      item.w = (item.h * 9 / 16).round();
      item.radius = item.radius > item.w / 2 ? 24 : item.radius;
    case 'horizontal':
      item.h = (item.w * 9 / 16).round();
      item.radius = item.radius > item.h / 2 ? 24 : item.radius;
  }
  item.x = (centerX - item.w / 2).round();
  item.y = (centerY - item.h / 2).round();
}

/// Ready positions on the canvas; the corners use 30% of the width keeping the item aspect.
void applyPosition(SceneItem item, String position, int width, int height) {
  final aspect = item.h / item.w;
  final margin = ((width < height ? width : height) * 0.035).round();
  if (position == 'full') {
    item.x = 0;
    item.y = 0;
    item.w = width;
    item.h = height;
    return;
  }
  if (position == 'center') {
    item.x = (width - item.w) ~/ 2;
    item.y = (height - item.h) ~/ 2;
    return;
  }
  if (position == 'left_half' || position == 'right_half') {
    item.w = width ~/ 2;
    item.h = height;
    item.x = position == 'left_half' ? 0 : width ~/ 2;
    item.y = 0;
    return;
  }
  item.w = (width * 0.3).round();
  item.h = (item.w * aspect).round();
  item.x = position == 'bottom_left' ? margin : width - item.w - margin;
  item.y = position == 'top_right' ? margin : height - item.h - margin;
  if (item.radius > 0 && item.w == item.h) item.radius = item.w / 2;
}
