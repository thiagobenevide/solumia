import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'capture_api.dart';

const sourceKinds = {
  'screen': ('Tela', Icons.monitor),
  'phone': ('Câmera do celular', Icons.phone_android),
  'webcam': ('Webcam', Icons.videocam),
  'image': ('Imagem', Icons.image_outlined),
  'text': ('Texto', Icons.title),
  'color': ('Cor sólida', Icons.format_color_fill),
  'microphone': ('Microfone', Icons.mic),
  'output': ('Áudio do PC', Icons.speaker),
};

/// Source list and the audio mixer (meters, volume, mute). Each audio source is also recorded on its
/// own track, before the volume, so the voice stays clean for editing.
class StudioSourcesPanel extends StatelessWidget {
  const StudioSourcesPanel({
    super.key,
    required this.state,
    required this.onAdd,
    required this.onEdit,
    required this.onRemove,
    required this.onReload,
    required this.onConfig,
  });

  final CaptureState state;
  final VoidCallback onAdd;
  final ValueChanged<CaptureSource> onEdit;
  final ValueChanged<CaptureSource> onRemove;
  final ValueChanged<CaptureSource> onReload;
  final void Function(String sourceId, Map<String, Object?> config) onConfig;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      _header(context, 'Fontes', IconButton(
        tooltip: 'Nova fonte',
        icon: const Icon(Icons.add),
        onPressed: state.recording ? null : onAdd,
      )),
    ];
    for (final source in state.sources) {
      children.add(_sourceTile(context, source));
    }
    children.add(const Divider(height: 24));
    children.add(_header(context, 'Mixer (cada fonte vira uma faixa)', null));
    children.add(_meter('Mix', state.level('master')));
    for (final source in state.sources) {
      if (!source.video) children.addAll(_audioControls(source));
    }
    return ListView(padding: const EdgeInsets.all(12), children: children);
  }

  Widget _header(BuildContext context, String title, Widget? action) {
    final row = <Widget>[Expanded(child: Text(title, style: Theme.of(context).textTheme.titleSmall))];
    if (action != null) row.add(action);
    return Row(children: row);
  }

  Widget _sourceTile(BuildContext context, CaptureSource source) {
    final failure = state.failures[source.id];
    final kind = sourceKinds[source.kind];
    final actions = <Widget>[];
    if (failure != null) {
      actions.add(IconButton(
        tooltip: 'Tentar de novo',
        icon: const Icon(Icons.refresh, size: 18),
        onPressed: () => onReload(source),
      ));
    }
    actions.add(IconButton(
      tooltip: 'Editar',
      icon: const Icon(Icons.edit_outlined, size: 18),
      onPressed: () => onEdit(source),
    ));
    actions.add(IconButton(
      tooltip: 'Remover',
      icon: const Icon(Icons.delete_outline, size: 18),
      onPressed: state.recording ? null : () => onRemove(source),
    ));
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(kind?.$2 ?? Icons.help_outline, color: failure != null ? Theme.of(context).colorScheme.error : null),
      title: Text(source.name),
      subtitle: Text(failure ?? kind?.$1 ?? source.kind, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: actions),
    );
  }

  List<Widget> _audioControls(CaptureSource source) {
    final muted = source.config['muted'] == true;
    final volume = ((source.config['volume'] as num?)?.toDouble() ?? 1).clamp(0.0, 2.0);
    return [
      Row(
        children: [
          Expanded(child: Text(source.name, overflow: TextOverflow.ellipsis)),
          IconButton(
            tooltip: muted ? 'Ligar' : 'Silenciar no mix',
            icon: Icon(muted ? Icons.volume_off : Icons.volume_up, size: 18),
            onPressed: () => onConfig(source.id, {'muted': !muted}),
          ),
        ],
      ),
      _meter(null, state.failures.containsKey(source.id) ? -100 : state.level(source.id)),
      _VolumeSlider(value: volume, onEnd: (v) => onConfig(source.id, {'volume': v})),
    ];
  }

  Widget _meter(String? label, double db) {
    final value = ((db + 60) / 60).clamp(0.0, 1.0);
    var color = Colors.green;
    if (db > -3) {
      color = Colors.red;
    } else if (db > -12) {
      color = Colors.amber;
    }
    final row = <Widget>[];
    if (label != null) row.add(SizedBox(width: 40, child: Text(label, style: const TextStyle(fontSize: 12))));
    row.add(Expanded(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LinearProgressIndicator(value: value, minHeight: 8, color: color),
      ),
    ));
    row.add(SizedBox(
      width: 52,
      child: Text(db <= -60 ? '-∞' : '${db.toStringAsFixed(0)} dB',
          textAlign: TextAlign.right, style: const TextStyle(fontSize: 11)),
    ));
    return Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Row(children: row));
  }
}

class _VolumeSlider extends StatefulWidget {
  const _VolumeSlider({required this.value, required this.onEnd});

  final double value;
  final ValueChanged<double> onEnd;

  @override
  State<_VolumeSlider> createState() => _VolumeSliderState();
}

class _VolumeSliderState extends State<_VolumeSlider> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final value = _dragging ?? widget.value;
    return Slider(
      max: 2,
      divisions: 40,
      value: value,
      label: '${(value * 100).round()}%',
      onChanged: (v) => setState(() => _dragging = v),
      onChangeEnd: _end,
    );
  }

  void _end(double value) {
    setState(() => _dragging = null);
    widget.onEnd(value);
  }
}

/// Source form: kind (only when creating), name and the kind's own configuration.
class SourceDialog extends StatefulWidget {
  const SourceDialog({super.key, required this.existing, required this.devices});

  final CaptureSource? existing;
  final Map<String, dynamic> devices;

  @override
  State<SourceDialog> createState() => _SourceDialogState();
}

class _SourceDialogState extends State<SourceDialog> {
  late String _kind = widget.existing?.kind ?? 'screen';
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final Map<String, Object?> _config = {...?widget.existing?.config};
  late final _text = TextEditingController(text: _config['text'] as String? ?? 'Texto');
  late final _font = TextEditingController(text: _config['font'] as String? ?? 'Sans Bold 48');
  late final _color = TextEditingController(text: _config['color'] as String? ?? '#FFFFFF');

  List<Map<String, dynamic>> _list(String key) {
    final result = <Map<String, dynamic>>[];
    for (final item in (widget.devices[key] as List? ?? const [])) {
      result.add(Map<String, dynamic>.from(item as Map));
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    if (widget.existing == null) children.add(_kindPicker());
    children.add(TextField(
      controller: _name,
      decoration: InputDecoration(labelText: 'Nome', hintText: sourceKinds[_kind]?.$1),
    ));
    children.add(const SizedBox(height: 8));
    children.addAll(_fields());
    return AlertDialog(
      title: Text(widget.existing == null ? 'Nova fonte' : 'Editar fonte'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: children),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: _confirm, child: const Text('Salvar')),
      ],
    );
  }

  Widget _kindPicker() {
    final items = <DropdownMenuItem<String>>[];
    for (final entry in sourceKinds.entries) {
      items.add(DropdownMenuItem(
        value: entry.key,
        child: Row(children: [Icon(entry.value.$2, size: 18), const SizedBox(width: 8), Text(entry.value.$1)]),
      ));
    }
    return DropdownButton<String>(
      isExpanded: true,
      value: _kind,
      items: items,
      onChanged: (v) => setState(() => _kind = v ?? _kind),
    );
  }

  List<Widget> _fields() {
    switch (_kind) {
      case 'screen':
        return _screenFields();
      case 'phone':
        return const [
          Text('Recebe a câmera do celular pelo receptor do app (aba Câmera). Abra a câmera no celular e '
              'toque em Gravar/transmitir; o vídeo entra aqui sem passar pela webcam virtual.'),
        ];
      case 'webcam':
        return _webcamFields();
      case 'image':
        return _imageFields();
      case 'text':
        return [
          TextField(controller: _text, decoration: const InputDecoration(labelText: 'Texto'), maxLines: 2),
          TextField(controller: _font, decoration: const InputDecoration(labelText: 'Fonte (ex.: Sans Bold 48)')),
          TextField(controller: _color, decoration: const InputDecoration(labelText: 'Cor (#RRGGBB)')),
        ];
      case 'color':
        return [TextField(controller: _color, decoration: const InputDecoration(labelText: 'Cor (#RRGGBB)'))];
      case 'microphone':
      case 'output':
        return _audioFields(_kind == 'output');
    }
    return const [];
  }

  List<Widget> _screenFields() {
    final monitors = _list('monitors');
    final items = <DropdownMenuItem<int>>[];
    for (final m in monitors) {
      items.add(DropdownMenuItem(value: m['index'] as int, child: Text('${m['name']} (${m['w']}×${m['h']})')));
    }
    if (items.isEmpty) items.add(const DropdownMenuItem(value: 0, child: Text('Monitor 0')));
    return [
      DropdownButton<int>(
        isExpanded: true,
        value: _config['monitor'] as int? ?? 0,
        items: items,
        onChanged: (v) => setState(() => _config['monitor'] = v),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Mostrar cursor'),
        value: _config['cursor'] as bool? ?? true,
        onChanged: (v) => setState(() => _config['cursor'] = v),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Seguir o mouse'),
        subtitle: const Text('Zoom dinâmico: preenche o quadro e acompanha o cursor'),
        value: _config['follow_mouse'] as bool? ?? true,
        onChanged: (v) => setState(() => _config['follow_mouse'] = v),
      ),
    ];
  }

  List<Widget> _webcamFields() {
    final cams = <String>[];
    for (final w in (widget.devices['webcams'] as List? ?? const [])) {
      cams.add(w as String);
    }
    final items = <DropdownMenuItem<String>>[];
    for (final c in cams) {
      items.add(DropdownMenuItem(value: c, child: Text(c)));
    }
    final current = _config['device'];
    return [
      DropdownButton<String>(
        isExpanded: true,
        value: cams.contains(current) ? current as String : cams.firstOrNull,
        items: items,
        onChanged: (v) => setState(() => _config['device'] = v),
      ),
    ];
  }

  List<Widget> _imageFields() {
    return [
      Text((_config['file'] as String?) ?? 'Nenhuma imagem escolhida'),
      TextButton.icon(icon: const Icon(Icons.image_search), label: const Text('Escolher imagem'), onPressed: _pickImage),
    ];
  }

  Future<void> _pickImage() async {
    final picked = await FilePicker.pickFiles(type: FileType.image);
    final path = picked.firstOrNull?.path;
    if (path != null) setState(() => _config['file'] = path);
  }

  List<Widget> _audioFields(bool output) {
    final items = <DropdownMenuItem<String>>[const DropdownMenuItem(value: '', child: Text('Padrão do sistema'))];
    var known = false;
    for (final d in _list('audio')) {
      if (d['output'] != output) continue;
      if (d['name'] == _config['device']) known = true;
      items.add(DropdownMenuItem(
        value: d['name'] as String,
        child: Text(d['description'] as String, overflow: TextOverflow.ellipsis),
      ));
    }
    return [
      DropdownButton<String>(
        isExpanded: true,
        value: known ? _config['device'] as String : '',
        items: items,
        onChanged: (v) => setState(() => _config['device'] = v ?? ''),
      ),
    ];
  }

  void _confirm() {
    if (_kind == 'text') {
      _config['text'] = _text.text;
      _config['font'] = _font.text;
      _config['color'] = _color.text;
    } else if (_kind == 'color') {
      _config['color'] = _color.text;
    } else if (_kind == 'webcam' && _config['device'] == null) {
      final cams = widget.devices['webcams'] as List? ?? const [];
      if (cams.isNotEmpty) _config['device'] = cams.first;
    } else if (_kind == 'screen' && widget.existing == null) {
      _config['follow_mouse'] ??= true;
    }
    var name = _name.text.trim();
    if (name.isEmpty) name = sourceKinds[_kind]?.$1 ?? _kind;
    Navigator.pop(context, (_kind, name, _config));
  }
}
