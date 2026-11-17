import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'capture_api.dart';
import 'receiver.dart';
import 'studio_item_panel.dart';
import 'studio_sources_panel.dart';

/// Capture studio (OBS style) on the PC: scenes with animated transitions and ready-made layouts, live
/// preview with draggable items, framing/masks, dynamic screen zoom, on-screen drawing, mixer and REC.
/// The heavy work belongs to the GStreamer engine (`modulos/empreendimento/capture`).
class CaptureStudioScreen extends StatefulWidget {
  const CaptureStudioScreen({super.key});

  @override
  State<CaptureStudioScreen> createState() => _CaptureStudioScreenState();
}

const _transitions = [('cut', 'Corte'), ('fade', 'Fade'), ('move', 'Mover'), ('slide', 'Deslizar'), ('zoom', 'Zoom')];
const _tools = [
  ('pen', 'Caneta', Icons.edit),
  ('highlighter', 'Marca-texto', Icons.highlight),
  ('arrow', 'Seta', Icons.north_east),
  ('rectangle', 'Retângulo', Icons.crop_square),
  ('ellipse', 'Elipse', Icons.circle_outlined),
  ('laser', 'Laser', Icons.flare),
];
const _drawColors = ['#FF3B30', '#FFCC00', '#34C759', '#0A84FF', '#FFFFFF', '#000000'];

class _CaptureStudioScreenState extends State<CaptureStudioScreen> {
  final _api = CaptureApi();
  Timer? _clock;
  CaptureState? _state;
  bool _offline = false;
  bool _starting = false;
  bool _polling = false; // one state request at a time: a busy engine must not pile them up
  bool _launched = false; // the app launches the engine once; after that it only waits for it
  String? _notice;
  String _transition = 'move';
  int _ms = 500;
  String? _selected;
  List<SceneItem>? _dragging; // local copy while dragging on the preview
  Map<String, String> _templates = const {};
  Player? _player;
  VideoController? _video;

  @override
  void initState() {
    super.initState();
    MediaKit.ensureInitialized();
    Receiver.instance.listen(); // the phone can join as a source without opening the Camera tab
    _refresh();
    _clock = Timer.periodic(const Duration(milliseconds: 500), _onTick);
  }

  @override
  void dispose() {
    _clock?.cancel();
    _player?.dispose();
    super.dispose();
  }

  void _onTick(Timer _) => _refresh();

  Future<void> _refresh() async {
    if (_polling) return;
    _polling = true;
    try {
      await _poll();
    } finally {
      _polling = false;
    }
  }

  Future<void> _poll() async {
    try {
      final state = CaptureState(await _api.state());
      if (!mounted) return;
      final cameBack = _offline || _state == null;
      setState(() {
        _state = state;
        _offline = false;
      });
      if (cameBack) await _onEngineUp(state);
    } on Exception {
      if (!mounted) return;
      setState(() => _offline = true);
      if (!_starting && !_launched && _state == null) _startEngine();
    }
  }

  Future<void> _onEngineUp(CaptureState state) async {
    await _openPreview(state.previewPort);
    final templates = await _api.templates();
    final names = <String, String>{};
    for (final entry in templates.entries) {
      names[entry.key] = entry.value as String;
    }
    if (mounted) setState(() => _templates = names);
  }

  Future<void> _startEngine() async {
    setState(() => _starting = true);
    final error = await CaptureApi.startEngine();
    if (!mounted) return;
    // a second engine would fight the first for the GPU and the ports; it is retried only when
    // launching failed (the engine takes a while to build the GL pipeline)
    _launched = error == null;
    setState(() => _notice = error);
    await Future<void>.delayed(const Duration(seconds: 15));
    if (mounted) setState(() => _starting = false);
  }

  Future<void> _openPreview(int port) async {
    var player = _player;
    if (player == null) {
      player = Player();
      _player = player;
      _video = VideoController(player);
      final native = player.platform;
      if (native is NativePlayer) {
        await native.setProperty('profile', 'low-latency');
        // media_kit opens through a playlist and mpv refuses udp:// there without this:
        // the preview stayed black with no error on screen
        await native.setProperty('load-unsafe-playlists', 'yes');
        await native.setProperty('untimed', 'yes');
        await native.setProperty('cache', 'no');
      }
      await player.setVolume(0);
    }
    await player.open(Media('udp://127.0.0.1:$port'));
    if (mounted) setState(() {});
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
      await _refresh();
    } on CaptureError catch (e) {
      if (mounted) setState(() => _notice = e.message);
    } on Exception catch (e) {
      if (mounted) setState(() => _notice = '$e');
    }
  }

  // ================================================================== layout

  @override
  Widget build(BuildContext context) {
    final state = _state;
    if (state == null) return _waiting();
    return LayoutBuilder(builder: (context, box) => _layout(state, box));
  }

  Widget _waiting() {
    final children = <Widget>[
      const CircularProgressIndicator(),
      const SizedBox(height: 12),
      Text(_starting ? 'Iniciando o motor do estúdio…' : 'Procurando o motor do estúdio…'),
    ];
    if (_notice != null) children.add(Padding(padding: const EdgeInsets.all(8), child: Text(_notice!)));
    children.add(const SizedBox(height: 8));
    children.add(OutlinedButton(onPressed: _starting ? null : _startEngine, child: const Text('Iniciar motor')));
    return Center(child: Column(mainAxisSize: MainAxisSize.min, children: children));
  }

  Widget _layout(CaptureState state, BoxConstraints box) {
    final center = _center(state);
    final sources = StudioSourcesPanel(
      state: state,
      onAdd: () => _sourceDialog(null),
      onEdit: _sourceDialog,
      onRemove: (s) => _run(() => _api.removeSource(s.id)),
      onReload: (s) => _run(() => _api.reloadSource(s.id)),
      onConfig: _sourceConfig,
    );
    if (box.maxWidth < 1200) {
      return ListView(children: [
        SizedBox(height: 760, child: center),
        _scenes(state),
        SizedBox(height: 600, child: sources),
        _recordings(state),
      ]);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: 250, child: ListView(children: [_scenes(state), _recordings(state)])),
        const VerticalDivider(width: 1),
        Expanded(child: center),
        const VerticalDivider(width: 1),
        SizedBox(width: 330, child: sources),
      ],
    );
  }

  Widget _center(CaptureState state) {
    final children = <Widget>[_toolbar(state)];
    final warning = _warningText(state);
    if (warning != null) children.add(_warning(warning));
    children.add(Expanded(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Center(child: AspectRatio(aspectRatio: state.width / state.height, child: _preview(state))),
      ),
    ));
    children.add(SizedBox(
      height: 300,
      child: StudioItemPanel(
        state: state,
        selected: _selected,
        onSelect: (id) => setState(() => _selected = id),
        onItems: (items) => _saveItems(state, items),
        onSourceConfig: _sourceConfig,
      ),
    ));
    return Column(children: children);
  }

  String? _warningText(CaptureState state) {
    if (_notice != null) return _notice;
    if (state.error != null) return state.error;
    if (state.udpWarning) {
      return 'Buffer UDP pequeno para a câmera do celular em alto bitrate: '
          'sudo sysctl -w net.core.rmem_max=33554432';
    }
    return null;
  }

  Widget _warning(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Material(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(6),
        child: ListTile(
          dense: true,
          title: Text(text),
          trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _notice = null)),
        ),
      ),
    );
  }

  // ================================================================== toolbar

  Widget _toolbar(CaptureState state) {
    final bitrate = ((state.config['bitrate_kbps'] as int? ?? 0) / 1000).round();
    var recordLabel = 'Gravar';
    if (state.recording) recordLabel = 'Parar  ${_clockText(state.seconds)}';
    if (state.stopping) recordLabel = 'Finalizando…';
    final drawing = state.drawing;
    final drawingActive = drawing['active'] == true;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: state.recording ? Colors.red : null),
            onPressed: state.stopping ? null : () => _run(state.recording ? _api.stopRecording : _api.startRecording),
            icon: Icon(state.recording ? Icons.stop : Icons.fiber_manual_record),
            label: Text(recordLabel),
          ),
          Text(
            _offline
                ? 'Motor sem resposta'
                : '${state.width}×${state.height} · ${state.fps.toStringAsFixed(0)}/${state.config['fps']} fps · '
                    '${state.config['encoder']} $bitrate Mb/s',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(width: 8),
          IconButton(tooltip: 'Zoom na tela −', icon: const Icon(Icons.zoom_out), onPressed: () => _run(() => _api.zoom('out'))),
          IconButton(tooltip: 'Zoom na tela +', icon: const Icon(Icons.zoom_in), onPressed: () => _run(() => _api.zoom('in'))),
          IconButton(
            tooltip: 'Zoom original',
            icon: const Icon(Icons.fit_screen),
            onPressed: () => _run(() => _api.zoom('reset')),
          ),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: drawing['available'] == true ? () => _drawing({'active': !drawingActive}) : null,
            icon: Icon(drawingActive ? Icons.edit_off : Icons.draw),
            label: Text(drawingActive ? 'Parar desenho (Esc)' : 'Desenhar na tela'),
          ),
          _toolMenu(drawing),
          _colorMenu(drawing),
          IconButton(tooltip: 'Apagar desenhos', icon: const Icon(Icons.layers_clear), onPressed: () => _drawing({'action': 'clear'})),
          FilterChip(
            label: const Text('Traço some'),
            selected: (drawing['fade'] as num? ?? 0) > 0,
            onSelected: (v) => _drawing({'fade': v ? 3.0 : 0.0}),
          ),
          IconButton(
            tooltip: 'Canvas e gravação',
            icon: const Icon(Icons.settings),
            onPressed: state.recording ? null : () => _configDialog(state),
          ),
        ],
      ),
    );
  }

  Widget _toolMenu(Map<String, dynamic> drawing) {
    final items = <PopupMenuEntry<String>>[];
    var icon = Icons.edit;
    for (final (key, label, toolIcon) in _tools) {
      if (drawing['tool'] == key) icon = toolIcon;
      items.add(PopupMenuItem(value: key, child: Row(children: [Icon(toolIcon, size: 18), const SizedBox(width: 8), Text(label)])));
    }
    return PopupMenuButton<String>(
      tooltip: 'Ferramenta (teclas 1–6 no modo desenho)',
      icon: Icon(icon),
      itemBuilder: (_) => items,
      onSelected: (tool) => _drawing({'tool': tool}),
    );
  }

  Widget _colorMenu(Map<String, dynamic> drawing) {
    final items = <PopupMenuEntry<String>>[];
    for (final color in _drawColors) {
      items.add(PopupMenuItem(value: color, child: _swatch(color, 20)));
    }
    return PopupMenuButton<String>(
      tooltip: 'Cor (X no modo desenho)',
      itemBuilder: (_) => items,
      onSelected: (color) => _drawing({'color': color}),
      child: Padding(padding: const EdgeInsets.all(8), child: _swatch(drawing['color'] as String? ?? '#FF3B30', 22)),
    );
  }

  Widget _swatch(String hex, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Color(0xFF000000 | int.parse(hex.substring(1), radix: 16)),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.grey),
      ),
    );
  }

  void _drawing(Map<String, Object?> body) => _run(() => _api.drawing(body));

  // ================================================================== preview with draggable items

  Widget _preview(CaptureState state) {
    return LayoutBuilder(builder: (context, box) => _previewStack(state, box.maxWidth / state.width));
  }

  Widget _previewStack(CaptureState state, double scale) {
    final scene = state.scene;
    var items = _dragging;
    items ??= scene?.items ?? const <SceneItem>[];
    Widget video = const SizedBox();
    if (_video != null) video = Video(controller: _video!, controls: NoVideoControls);
    // tap outside every item: clears the selection (no outline left on the preview)
    final children = <Widget>[
      Positioned.fill(
        child: GestureDetector(
          onTap: () => setState(() => _selected = null),
          child: ColoredBox(color: Colors.black, child: video),
        ),
      ),
    ];
    if (scene != null) {
      for (final item in items) {
        if (!item.visible) continue;
        children.add(Positioned(
          left: item.x * scale,
          top: item.y * scale,
          width: item.w * scale,
          height: item.h * scale,
          child: _ItemBox(
            name: state.source(item.source)?.name ?? '?',
            selected: _selected == item.source,
            circle: item.circle,
            radius: item.radius * scale,
            onTap: () => setState(() => _selected = item.source),
            onMoveStart: () => _beginDrag(scene, item.source),
            onMove: (delta) => _moveItem(item.source, delta, scale),
            onResize: (delta) => _resizeItem(item.source, delta, scale, state.width),
            onEnd: () => _endDrag(state),
          ),
        ));
      }
    }
    return Stack(clipBehavior: Clip.hardEdge, children: children);
  }

  void _beginDrag(CaptureScene scene, String sourceId) {
    final copies = <SceneItem>[];
    for (final item in scene.items) {
      copies.add(item.copy());
    }
    setState(() {
      _selected = sourceId;
      _dragging = copies;
    });
  }

  SceneItem? _draggedItem(String sourceId) {
    for (final item in _dragging ?? const <SceneItem>[]) {
      if (item.source == sourceId) return item;
    }
    return null;
  }

  void _moveItem(String sourceId, Offset delta, double scale) {
    final item = _draggedItem(sourceId);
    if (item == null) return;
    setState(() {
      item.x += (delta.dx / scale).round();
      item.y += (delta.dy / scale).round();
    });
  }

  /// Corner handle: resizes keeping the item aspect (a circle stays a circle).
  void _resizeItem(String sourceId, Offset delta, double scale, int canvasWidth) {
    final item = _draggedItem(sourceId);
    if (item == null) return;
    final ratio = item.h / item.w;
    final wasCircle = item.circle;
    setState(() {
      item.w = (item.w + delta.dx / scale).round().clamp(32, canvasWidth * 2);
      item.h = (item.w * ratio).round();
      if (wasCircle) item.radius = item.w / 2;
    });
  }

  void _endDrag(CaptureState state) {
    final items = _dragging;
    if (items == null) return;
    _saveItems(state, items).whenComplete(_clearDrag);
  }

  void _clearDrag() {
    if (mounted) setState(() => _dragging = null);
  }

  Future<void> _saveItems(CaptureState state, List<SceneItem> items) {
    final scene = state.scene;
    if (scene == null) return Future.value();
    final json = <Map<String, Object?>>[];
    for (final item in items) {
      json.add(item.toJson());
    }
    return _run(() => _api.editScene(scene.id, items: json));
  }

  void _sourceConfig(String sourceId, Map<String, Object?> config) {
    _run(() => _api.editSource(sourceId, config: config));
  }

  // ================================================================== scenes

  Widget _scenes(CaptureState state) {
    final children = <Widget>[
      Row(
        children: [
          Expanded(child: Text('Cenas', style: Theme.of(context).textTheme.titleSmall)),
          _templateMenu(),
          IconButton(tooltip: 'Nova cena vazia', icon: const Icon(Icons.add), onPressed: () => _newScene(state)),
        ],
      ),
    ];
    for (final scene in state.scenes) {
      children.add(_sceneTile(state, scene));
    }
    children.add(const Divider());
    children.add(const Text('Transição'));
    children.add(const SizedBox(height: 4));
    children.add(Wrap(spacing: 4, runSpacing: 4, children: _transitionChips()));
    if (_transition != 'cut') {
      children.add(Row(
        children: [
          Expanded(
            child: Slider(
              min: 100,
              max: 2000,
              divisions: 19,
              value: _ms.toDouble(),
              onChanged: (v) => setState(() => _ms = v.round()),
            ),
          ),
          Text('$_ms ms'),
        ],
      ));
    }
    children.add(Text(
      'Atalhos (teclado/mesa): infra/scripts/capture_ctl scene NOME | draw | zoom-in | record',
      style: Theme.of(context).textTheme.bodySmall,
    ));
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }

  Widget _templateMenu() {
    final items = <PopupMenuEntry<String>>[];
    for (final entry in _templates.entries) {
      items.add(PopupMenuItem(value: entry.key, child: Text(_templateLabel(entry.key, entry.value))));
    }
    return PopupMenuButton<String>(
      tooltip: 'Nova cena a partir de um modelo',
      icon: const Icon(Icons.auto_awesome_mosaic_outlined),
      enabled: items.isNotEmpty,
      itemBuilder: (_) => items,
      onSelected: (template) => _run(() => _api.addTemplate(template)),
    );
  }

  static String _templateLabel(String key, String fallback) {
    switch (key) {
      case 'screen_cam_circle':
        return 'Tela + rosto no círculo';
      case 'screen_cam_rounded':
        return 'Tela + câmera horizontal';
      case 'screen_cam_vertical':
        return 'Tela + câmera vertical';
      case 'side_by_side':
        return 'Tela e câmera lado a lado';
      case 'cam_only':
        return 'Só o rosto';
      case 'screen_only':
        return 'Só a tela';
    }
    return fallback;
  }

  Widget _sceneTile(CaptureState state, CaptureScene scene) {
    final current = scene.id == state.currentScene;
    return ListTile(
      dense: true,
      selected: current,
      leading: Icon(current ? Icons.play_arrow : Icons.crop_landscape),
      title: Text(scene.name),
      onTap: () => _run(() => _api.activateScene(scene.id, _transition, _ms)),
      trailing: PopupMenuButton<String>(
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'rename', child: Text('Renomear')),
          PopupMenuItem(value: 'remove', child: Text('Remover')),
        ],
        onSelected: (action) => _sceneAction(scene, action),
      ),
    );
  }

  Future<void> _sceneAction(CaptureScene scene, String action) async {
    if (action == 'remove') {
      await _run(() => _api.removeScene(scene.id));
      return;
    }
    final name = await _askText('Renomear cena', scene.name);
    if (name != null) await _run(() => _api.editScene(scene.id, name: name));
  }

  Future<void> _newScene(CaptureState state) async {
    final name = await _askText('Nova cena', 'Cena ${state.scenes.length + 1}');
    if (name != null) await _run(() => _api.addScene(name));
  }

  List<Widget> _transitionChips() {
    final result = <Widget>[];
    for (final (key, label) in _transitions) {
      result.add(ChoiceChip(
        label: Text(label),
        selected: _transition == key,
        onSelected: (_) => setState(() => _transition = key),
      ));
    }
    return result;
  }

  // ================================================================== sources, recordings, config

  Future<void> _sourceDialog(CaptureSource? existing) async {
    Map<String, dynamic> devices = const {};
    try {
      devices = await _api.devices();
    } on Exception {
      // the dialog still works with empty lists
    }
    if (!mounted) return;
    final result = await showDialog<(String, String, Map<String, Object?>)>(
      context: context,
      builder: (_) => SourceDialog(existing: existing, devices: devices),
    );
    if (result == null) return;
    final (kind, name, config) = result;
    if (existing == null) {
      await _run(() => _api.addSource(kind, name, config));
      return;
    }
    // only what changed: text/color/volume change live, the rest rebuilds the pipeline
    final changed = <String, Object?>{};
    for (final key in config.keys) {
      if (config[key] != existing.config[key]) changed[key] = config[key];
    }
    await _run(() => _api.editSource(
          existing.id,
          name: name != existing.name ? name : null,
          config: changed.isEmpty ? null : changed,
        ));
  }

  Widget _recordings(CaptureState state) {
    final home = Platform.environment['HOME'];
    final folder = '${Platform.environment['AGENT_DATA'] ?? '$home/agent-data'}/recordings/studio';
    final children = <Widget>[
      Row(
        children: [
          Expanded(child: Text('Gravações', style: Theme.of(context).textTheme.titleSmall)),
          IconButton(tooltip: 'Abrir pasta', icon: const Icon(Icons.folder_open), onPressed: () => Process.run('xdg-open', [folder])),
        ],
      ),
    ];
    final list = state.recordings;
    if (list.isEmpty) children.add(const Text('Nenhuma nesta sessão.'));
    for (final r in list) {
      final tracks = (r['tracks'] as List? ?? const []).join(', ');
      children.add(ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(r['ready'] == true ? Icons.movie_outlined : Icons.hourglass_top),
        title: Text((r['file'] as String).split('/').last),
        subtitle: Text('${_clockText(r['seconds'] as int? ?? 0)} · $tracks'),
        onTap: () => Process.run('xdg-open', [r['file'] as String]),
      ));
    }
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }

  Future<void> _configDialog(CaptureState state) async {
    final result = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (_) => _ConfigDialog(initial: Map<String, Object?>.from(state.config)),
    );
    if (result != null) await _run(() => _api.config(result));
  }

  Future<String?> _askText(String title, String initial) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(controller: controller, autofocus: true, onSubmitted: (v) => Navigator.pop(context, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('OK')),
        ],
      ),
    );
  }
}

/// Item frame on the preview: drag to move, red corner to resize.
class _ItemBox extends StatelessWidget {
  const _ItemBox({
    required this.name,
    required this.selected,
    required this.circle,
    required this.radius,
    required this.onTap,
    required this.onMoveStart,
    required this.onMove,
    required this.onResize,
    required this.onEnd,
  });

  final String name;
  final bool selected;
  final bool circle;

  /// Corner radius in screen pixels: the outline follows the rounded item instead of hiding it.
  final double radius;
  final VoidCallback onTap;
  final VoidCallback onMoveStart;
  final ValueChanged<Offset> onMove;
  final ValueChanged<Offset> onResize;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    // only the selected item shows its name and outline: the preview stays as clean as the recording
    // (these marks are drawn by the app, they never go into the recorded video)
    const color = Colors.redAccent;
    final children = <Widget>[];
    if (selected) {
      children.add(Positioned(
        left: 2,
        top: 2,
        child: Text(name, style: const TextStyle(color: color, fontSize: 11, shadows: [Shadow(blurRadius: 2)])),
      ));
      children.add(Positioned(
        right: 0,
        bottom: 0,
        child: GestureDetector(
          onPanStart: (_) => onMoveStart(),
          onPanUpdate: (d) => onResize(d.delta),
          onPanEnd: (_) => onEnd(),
          child: Container(width: 14, height: 14, color: Colors.redAccent),
        ),
      ));
    }
    return GestureDetector(
      onTap: onTap,
      onPanStart: (_) => onMoveStart(),
      onPanUpdate: (d) => onMove(d.delta),
      onPanEnd: (_) => onEnd(),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.transparent,
          border: selected ? Border.all(color: color, width: 2) : null,
          shape: circle ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: circle ? null : BorderRadius.circular(radius),
        ),
        child: Stack(children: children),
      ),
    );
  }
}

class _ConfigDialog extends StatefulWidget {
  const _ConfigDialog({required this.initial});

  final Map<String, Object?> initial;

  @override
  State<_ConfigDialog> createState() => _ConfigDialogState();
}

class _ConfigDialogState extends State<_ConfigDialog> {
  late final Map<String, Object?> _config = widget.initial;

  static const _sizes = [
    (1920, 1080, '1080p'),
    (2560, 1440, '1440p'),
    (3840, 2160, '4K'),
    (1080, 1920, 'Vertical 1080×1920'),
  ];
  static const _encoders = [('nvh264', 'NVENC H.264'), ('nvh265', 'NVENC HEVC'), ('x264', 'x264 (CPU)')];

  @override
  Widget build(BuildContext context) {
    final bitrate = (_config['bitrate_kbps'] as int? ?? 40000).toDouble().clamp(10000.0, 150000.0);
    return AlertDialog(
      title: const Text('Canvas e gravação'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Resolução'),
            Wrap(spacing: 6, runSpacing: 6, children: _sizeChips()),
            const SizedBox(height: 8),
            const Text('Quadros por segundo'),
            Wrap(spacing: 6, children: _fpsChips()),
            const SizedBox(height: 8),
            const Text('Encoder'),
            Wrap(spacing: 6, children: _encoderChips()),
            const SizedBox(height: 8),
            Text('Bitrate: ${(bitrate / 1000).round()} Mb/s'),
            Slider(
              min: 10000,
              max: 150000,
              divisions: 28,
              value: bitrate,
              onChanged: (v) => setState(() => _config['bitrate_kbps'] = v.round()),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Converter para MOV ao parar'),
              subtitle: const Text('Grava em MKV (não corrompe se cair) e troca o contêiner sem recodificar'),
              value: _config['remux_mov'] == true,
              onChanged: (v) => setState(() => _config['remux_mov'] = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(context, _config), child: const Text('Aplicar')),
      ],
    );
  }

  List<Widget> _sizeChips() {
    final result = <Widget>[];
    for (final (w, h, label) in _sizes) {
      result.add(ChoiceChip(
        label: Text(label),
        selected: _config['width'] == w && _config['height'] == h,
        onSelected: (_) => setState(() {
          _config['width'] = w;
          _config['height'] = h;
        }),
      ));
    }
    return result;
  }

  List<Widget> _fpsChips() {
    final result = <Widget>[];
    for (final f in const [30, 60]) {
      result.add(ChoiceChip(
        label: Text('$f'),
        selected: _config['fps'] == f,
        onSelected: (_) => setState(() => _config['fps'] = f),
      ));
    }
    return result;
  }

  List<Widget> _encoderChips() {
    final result = <Widget>[];
    for (final (key, label) in _encoders) {
      result.add(ChoiceChip(
        label: Text(label),
        selected: _config['encoder'] == key,
        onSelected: (_) => setState(() => _config['encoder'] = key),
      ));
    }
    return result;
  }
}

String _clockText(int s) => '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
