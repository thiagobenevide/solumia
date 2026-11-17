import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'camera_pro.dart';
import 'protocol.dart';

/// Full-screen pro camera (landscape): native preview on the left, controls on the right. Streams to
/// the PC found on the network (UDP announcement), over USB (`adb reverse` done on the PC) or only
/// records on the phone.
class PhoneCameraScreen extends StatefulWidget {
  const PhoneCameraScreen({super.key});

  @override
  State<PhoneCameraScreen> createState() => _PhoneCameraScreenState();
}

const _whiteBalances = [
  ('auto', 'Auto'),
  ('daylight', 'Luz do dia'),
  ('cloudy', 'Nublado'),
  ('shade', 'Sombra'),
  ('fluorescent', 'Fluorescente'),
  ('incandescent', 'Incandescente'),
];

/// Last IP typed by hand, kept while the app is open.
String? _lastManualAddress;

class _PhoneCameraScreenState extends State<PhoneCameraScreen> {
  final _camera = CameraPro();
  final _settings = CameraSettings();
  StreamSubscription<Map<String, dynamic>>? _subscription;
  RawDatagramSocket? _listener;

  List<CameraInfo> _cameras = const [];
  CameraInfo? _info;
  VideoSize? _size;
  int _fps = 60;
  bool _hlg = false;
  String _codec = 'hevc';
  /// Ceiling for the VBR encoder (Mb/s): it spends less on calm scenes and has room for motion.
  int _bitrate = 200;
  /// `record` only on the phone, `stream` only to the PC, `both` records and streams.
  String _mode = 'both';
  bool _audio = true;

  /// ip -> announcement of the PCs heard; `usb` uses 127.0.0.1; null while no PC was chosen.
  final _pcs = <String, PcAnnouncement>{};
  String? _target;

  int? _texture;
  bool _streaming = false;
  Map<String, dynamic> _state = const {};
  String? _message;
  String? _error;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _subscription = _camera.events().listen(_onEvent);
    _listenAnnouncements();
    _prepare();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _listener?.close();
    _camera.close();
    SystemChrome.setPreferredOrientations(const []);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _prepare() async {
    try {
      if (!await _camera.requestPermission()) {
        setState(() => _error = 'Sem permissão de câmera/microfone.');
        return;
      }
      final list = await _camera.cameras();
      if (list.isEmpty) {
        setState(() => _error = 'Nenhuma câmera traseira encontrada.');
        return;
      }
      _cameras = list;
      _chooseCamera(list.first);
      await _reopen();
    } on PlatformException catch (e) {
      setState(() => _error = e.message);
    }
  }

  void _chooseCamera(CameraInfo camera) {
    _info = camera;
    // default: the largest size that still delivers 60 fps (4K60 on the S23)
    VideoSize? best;
    for (final size in camera.sizes) {
      if (size.maxFps >= 60 && (best == null || size.width > best.width)) best = size;
    }
    _size = best ?? camera.sizes.first;
    _fps = _pickFps(camera, _size!.maxFps);
    _hlg = _hlg && camera.hlg;
    if (!camera.hevc) _codec = 'avc';
    _settings.iso = camera.isoMin.clamp(100, camera.isoMax);
    _settings.zoom = 1.0.clamp(camera.zoomMin, camera.zoomMax);
  }

  /// 60 when the camera and the size allow it, otherwise the highest available.
  int _pickFps(CameraInfo camera, int maxFps) {
    var result = 30;
    for (final f in camera.fps) {
      if (f <= maxFps && f <= 60 && f > result) result = f;
    }
    return result;
  }

  Future<void> _reopen() async {
    final camera = _info;
    final size = _size;
    if (camera == null || size == null) return;
    try {
      final id = await _camera.open(id: camera.id, width: size.width, height: size.height, fps: _fps, hlg: _hlg);
      await _camera.adjust(_settings);
      setState(() {
        _texture = id;
        _error = null;
      });
    } on PlatformException catch (e) {
      setState(() => _error = e.message);
    }
  }

  void _adjust(VoidCallback change) {
    setState(change);
    _camera.adjust(_settings);
  }

  Future<void> _listenAnnouncements() async {
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, announcePort, reuseAddress: true);
      _listener = socket;
      socket.listen(_onDatagram);
    } on SocketException catch (e) {
      setState(() => _message = 'Não consegui ouvir a rede: ${e.message}');
    }
  }

  bool get _recordLocal => _mode != 'stream';

  bool get _sends => _mode != 'record';

  void _onDatagram(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = _listener?.receive();
    if (datagram == null) return;
    final announcement = PcAnnouncement.parse(utf8.decode(datagram.data, allowMalformed: true));
    if (announcement == null || !mounted) return;
    final ip = datagram.address.address;
    if (_pcs[ip]?.name == announcement.name) return;
    setState(() {
      _pcs[ip] = announcement;
      _target ??= ip;
    });
  }

  void _onEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    setState(() {
      switch (event['type']) {
        case 'state':
          _state = event;
          _checkFps(event['fps'] as int? ?? 0);
        case 'warning':
          _message = event['message'] as String?;
        case 'error':
          _error = event['message'] as String?;
      }
    });
  }

  int _slowSeconds = 0;

  /// The sensor may report a size as limited to 30 fps and still deliver 60 (or the other way round):
  /// the badge shows the measured value and, if it stays well below the chosen one, say so once.
  void _checkFps(int measured) {
    if (measured <= 0 || measured >= _fps * 0.85) {
      _slowSeconds = 0;
      return;
    }
    _slowSeconds++;
    if (_slowSeconds == 4) {
      _message = 'A câmera entrega $measured fps neste tamanho, não $_fps. '
          'Para $_fps fps use um tamanho menor (ex.: 1080p).';
    }
  }

  Future<void> _toggle() async {
    try {
      if (_streaming) {
        final file = await _camera.stop();
        setState(() {
          _streaming = false;
          _message = file == null ? 'Parado.' : 'Salvo no aparelho: Movies/Solumia/$file';
        });
        return;
      }
      final target = _sends ? _target : null;
      String? host = target;
      var port = videoPort;
      if (target == 'usb') {
        host = '127.0.0.1';
      } else if (target != null) {
        port = _pcs[target]?.port ?? videoPort;
      }
      if (host == null && _sends) {
        setState(() => _message = 'Escolha o PC (ou USB) para transmitir.');
        return;
      }
      await _camera.start(
        host: host,
        port: port,
        codec: _codec,
        bitrateMbps: _bitrate,
        recordLocal: _recordLocal,
        audio: _audio,
      );
      setState(() {
        _streaming = true;
        _message = null;
        _error = null;
      });
    } on PlatformException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Row(
          children: [
            Expanded(child: _preview()),
            SizedBox(
              width: 320,
              child: Theme(
                data: ThemeData.dark(useMaterial3: true),
                child: Material(color: const Color(0xFF121212), child: _panel()),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ================================================================== preview

  Widget _preview() {
    final size = _size;
    final id = _texture;
    Widget center = Text(_error ?? 'Abrindo câmera…', style: const TextStyle(color: Colors.white70));
    if (id != null && size != null) {
      // Camera2 rotates SurfaceTexture output upright for the phone's natural (portrait) orientation;
      // the screen is locked in landscapeLeft (display rotation 90°), so undo it with a quarter turn back.
      center = AspectRatio(
        aspectRatio: size.width / size.height,
        child: RotatedBox(quarterTurns: 3, child: Texture(textureId: id)),
      );
    }
    final children = <Widget>[
      Center(child: center),
      Positioned(left: 8, top: 8, right: 8, child: Wrap(spacing: 6, runSpacing: 6, children: _badges())),
    ];
    if (_message != null || _error != null) children.add(_banner());
    return Stack(children: children);
  }

  List<Widget> _badges() {
    final thermal = _state['thermal'] as int? ?? 0;
    final connected = _state['connected'] == true;
    final result = <Widget>[
      IconButton.filledTonal(
        onPressed: _streaming ? null : () => Navigator.of(context).pop(),
        icon: const Icon(Icons.arrow_back),
      ),
    ];
    if (_streaming) {
      result.add(_badge(Icons.fiber_manual_record, _clock(_state['seconds'] as int? ?? 0), Colors.red));
    }
    result.add(_badge(Icons.speed, '${_state['fps'] ?? 0} fps', Colors.black54));
    if (_streaming && _sends && _target != null) {
      final mbps = (_state['mbps'] as num? ?? 0).toStringAsFixed(0);
      final color = connected ? Colors.green.shade800 : Colors.orange.shade800;
      result.add(_badge(connected ? Icons.link : Icons.link_off, connected ? '$mbps Mb/s' : 'conectando…', color));
    }
    final exposure = _shutter(_state['exposureNs'] as int? ?? 0);
    result.add(_badge(Icons.iso, 'ISO ${_state['iso'] ?? '-'} · $exposure', Colors.black54));
    if (_state['hlg'] == true) result.add(_badge(Icons.hdr_on, 'HLG', Colors.black54));
    if (thermal >= 3) result.add(_badge(Icons.thermostat, 'Aquecendo ($thermal)', Colors.red.shade900));
    return result;
  }

  Widget _banner() {
    return Positioned(
      left: 8,
      bottom: 8,
      right: 8,
      child: Material(
        color: _error != null ? Colors.red.shade900 : Colors.black87,
        borderRadius: BorderRadius.circular(8),
        child: ListTile(
          dense: true,
          textColor: Colors.white,
          title: Text(_error ?? _message!),
          trailing: IconButton(color: Colors.white, icon: const Icon(Icons.close), onPressed: _clearBanner),
        ),
      ),
    );
  }

  void _clearBanner() => setState(() => _error = _message = null);

  Widget _badge(IconData icon, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(color: Colors.white, fontSize: 12)),
        ],
      ),
    );
  }

  // ================================================================== panel

  Widget _panel() {
    final camera = _info;
    final children = <Widget>[
      FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: _streaming ? Colors.red : null,
          minimumSize: const Size.fromHeight(52),
        ),
        onPressed: _texture == null ? null : _toggle,
        icon: Icon(_streaming ? Icons.stop : Icons.fiber_manual_record),
        label: Text(_streaming ? 'Parar' : _modeLabels[_mode]!),
      ),
      const SizedBox(height: 12),
      _title('Modo'),
      _modePicker(),
    ];
    if (_sends) {
      children.add(const SizedBox(height: 12));
      children.add(_title('Destino'));
      children.add(Wrap(spacing: 6, runSpacing: 6, children: _targetChips()));
    }
    if (_sends && _pcs.isEmpty) {
      children.add(const Padding(
        padding: EdgeInsets.only(top: 4),
        child: Text('Procurando o PC na rede… abra Gravação › Câmera no PC. Se não aparecer, use Wi‑Fi (IP do PC).',
            style: TextStyle(fontSize: 12, color: Colors.white60)),
      ));
    }
    if (camera != null) {
      children.add(_section('Exposição', Icons.exposure, _exposureControls(camera)));
      children.add(_section('Foco', Icons.center_focus_strong, _focusControls(camera)));
      children.add(_section('Balanço de branco', Icons.wb_sunny_outlined, _whiteBalanceControls()));
      children.add(_section('Zoom e imagem', Icons.zoom_in, _imageControls(camera)));
      children.add(_section('Formato', Icons.high_quality_outlined, _formatControls(camera)));
    }
    return ListView(padding: const EdgeInsets.all(12), children: children);
  }

  List<Widget> _targetChips() {
    final result = <Widget>[];
    for (final entry in _pcs.entries) {
      result.add(_targetChip('${entry.value.name} (${entry.key})', entry.key));
    }
    result.add(ActionChip(
      avatar: const Icon(Icons.wifi, size: 18),
      label: const Text('Wi‑Fi (IP do PC)'),
      onPressed: _streaming ? null : _askPcAddress,
    ));
    result.add(_targetChip('USB', 'usb'));
    return result;
  }

  static const _modeLabels = {'record': 'Gravar', 'stream': 'Transmitir', 'both': 'Gravar e transmitir'};

  Widget _modePicker() {
    final segments = <ButtonSegment<String>>[];
    for (final entry in _modeLabels.entries) {
      segments.add(ButtonSegment(value: entry.key, label: Text(entry.value, textAlign: TextAlign.center)));
    }
    return SegmentedButton<String>(
      segments: segments,
      selected: {_mode},
      showSelectedIcon: false,
      onSelectionChanged: _streaming ? null : (v) => setState(() => _mode = v.first),
    );
  }

  /// For networks where the PC announcement does not arrive (PC on cable, phone on Wi-Fi with a
  /// router that does not carry broadcasts): the IP shown in Gravação › Câmera on the PC.
  Future<void> _askPcAddress() async {
    final field = TextEditingController(text: _lastManualAddress ?? '');
    final typed = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Conectar pelo Wi‑Fi'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Digite o IP do PC que aparece em Gravação › Câmera, no PC (ex.: 192.168.3.251).'),
            TextField(
              controller: field,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'IP do PC'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, field.text.trim()), child: const Text('Usar')),
        ],
      ),
    );
    field.dispose();
    if (typed == null || typed.isEmpty || !mounted) return;
    final address = InternetAddress.tryParse(typed);
    if (address == null || address.type != InternetAddressType.IPv4) {
      setState(() => _message = 'IP inválido: $typed');
      return;
    }
    _lastManualAddress = typed;
    setState(() {
      _pcs[typed] = const PcAnnouncement(videoPort, 'PC');
      _target = typed;
      _message = null;
    });
  }

  Widget _targetChip(String label, String? value) {
    return ChoiceChip(
      label: Text(label),
      selected: _target == value,
      onSelected: _streaming ? null : (_) => setState(() => _target = value),
    );
  }

  List<Widget> _exposureControls(CameraInfo camera) {
    final result = <Widget>[
      SwitchListTile(
        dense: true,
        title: const Text('Manual (ISO + obturador)'),
        value: _settings.manualExposure,
        onChanged: camera.manual ? (v) => _setManualExposure(camera, v) : null,
      ),
    ];
    if (_settings.manualExposure) {
      result.add(_labelValue('ISO', '${_settings.iso}'));
      result.add(Slider(
        min: camera.isoMin.toDouble(),
        max: camera.isoMax.toDouble(),
        value: _settings.iso.toDouble().clamp(camera.isoMin.toDouble(), camera.isoMax.toDouble()),
        onChanged: (v) => _adjust(() => _settings.iso = (v / 10).round() * 10),
      ));
      result.add(_shutterSelector(camera));
      return result;
    }
    final ev = (_settings.compensation * camera.evStep).toStringAsFixed(1);
    result.add(_labelValue('Compensação', '$ev EV'));
    if (camera.evMax > camera.evMin) {
      result.add(Slider(
        min: camera.evMin.toDouble(),
        max: camera.evMax.toDouble(),
        divisions: camera.evMax - camera.evMin,
        value: _settings.compensation.toDouble(),
        onChanged: (v) => _adjust(() => _settings.compensation = v.round()),
      ));
    }
    result.add(SwitchListTile(
      dense: true,
      title: const Text('Travar exposição'),
      value: _settings.lockAe,
      onChanged: (v) => _adjust(() => _settings.lockAe = v),
    ));
    return result;
  }

  void _setManualExposure(CameraInfo camera, bool value) {
    _adjust(() {
      _settings.manualExposure = value;
      if (value) _settings.iso = (_state['iso'] as int? ?? _settings.iso).clamp(camera.isoMin, camera.isoMax);
    });
  }

  List<Widget> _focusControls(CameraInfo camera) {
    final result = <Widget>[
      SwitchListTile(
        dense: true,
        title: const Text('Foco manual'),
        value: _settings.manualFocus,
        onChanged: camera.focusMin > 0 ? (v) => _setManualFocus(camera, v) : null,
      ),
    ];
    if (_settings.manualFocus) {
      result.add(_labelValue('Distância', _distance(_settings.focus)));
      result.add(Slider(
        min: 0,
        max: camera.focusMin,
        value: _settings.focus.clamp(0, camera.focusMin),
        onChanged: (v) => _adjust(() => _settings.focus = v),
      ));
    }
    return result;
  }

  void _setManualFocus(CameraInfo camera, bool value) {
    _adjust(() {
      _settings.manualFocus = value;
      if (value) _settings.focus = (_state['focus'] as num? ?? 0).toDouble().clamp(0, camera.focusMin);
    });
  }

  List<Widget> _whiteBalanceControls() {
    final chips = <Widget>[];
    for (final (key, label) in _whiteBalances) {
      chips.add(ChoiceChip(
        label: Text(label),
        selected: _settings.awb == key,
        onSelected: (_) => _adjust(() => _settings.awb = key),
      ));
    }
    return [
      Wrap(spacing: 6, runSpacing: 6, children: chips),
      SwitchListTile(
        dense: true,
        title: const Text('Travar branco'),
        value: _settings.lockAwb,
        onChanged: (v) => _adjust(() => _settings.lockAwb = v),
      ),
    ];
  }

  List<Widget> _imageControls(CameraInfo camera) {
    final zoomMax = camera.zoomMax.clamp(camera.zoomMin, 10.0);
    final result = <Widget>[_labelValue('Zoom', '${_settings.zoom.toStringAsFixed(1)}×')];
    if (camera.zoomMax > camera.zoomMin) {
      result.add(Slider(
        min: camera.zoomMin,
        max: zoomMax,
        value: _settings.zoom.clamp(camera.zoomMin, zoomMax),
        onChanged: (v) => _adjust(() => _settings.zoom = (v * 10).round() / 10),
      ));
    }
    result.add(SwitchListTile(
      dense: true,
      title: const Text('Estabilização eletrônica'),
      subtitle: Text(camera.ois ? 'a óptica (OIS) já fica sempre ligada' : 'corta um pouco a imagem'),
      value: _settings.stabilization,
      onChanged: camera.eis ? (v) => _adjust(() => _settings.stabilization = v) : null,
    ));
    result.add(_qualitySelector('Redução de ruído', _settings.noise, _setNoise));
    result.add(_qualitySelector('Nitidez', _settings.edge, _setEdge));
    result.add(SwitchListTile(
      dense: true,
      title: const Text('Lanterna'),
      value: _settings.torch,
      onChanged: (v) => _adjust(() => _settings.torch = v),
    ));
    return result;
  }

  void _setNoise(String value) => _settings.noise = value;

  void _setEdge(String value) => _settings.edge = value;

  List<Widget> _formatControls(CameraInfo camera) {
    final result = <Widget>[];
    if (_streaming) {
      result.add(const Text('Pare para trocar o formato.', style: TextStyle(fontSize: 12, color: Colors.white60)));
    }
    if (_cameras.length > 1) {
      final items = <DropdownMenuItem<CameraInfo>>[];
      for (final c in _cameras) {
        items.add(DropdownMenuItem(value: c, child: Text(c.label)));
      }
      result.add(DropdownButton<CameraInfo>(
        isExpanded: true,
        value: camera,
        items: items,
        onChanged: _streaming ? null : _switchCamera,
      ));
    }
    result.add(Wrap(spacing: 6, runSpacing: 6, children: _sizeChips(camera)));
    result.add(const SizedBox(height: 6));
    result.add(Wrap(spacing: 6, children: _fpsChips(camera)));
    result.add(const SizedBox(height: 6));
    result.add(SegmentedButton<String>(
      segments: [
        ButtonSegment(value: 'hevc', label: const Text('HEVC'), enabled: camera.hevc),
        const ButtonSegment(value: 'avc', label: Text('H.264')),
      ],
      selected: {_codec},
      onSelectionChanged: _streaming ? null : _setCodec,
    ));
    result.add(_labelValue('Bitrate', '$_bitrate Mb/s'));
    result.add(Slider(
      min: 10,
      max: 200,
      divisions: 19,
      value: _bitrate.toDouble(),
      onChanged: _streaming ? null : (v) => setState(() => _bitrate = v.round()),
    ));
    result.add(SwitchListTile(
      dense: true,
      title: const Text('HDR HLG 10-bit'),
      subtitle: Text(camera.hlg ? 'precisa de HEVC' : 'este aparelho não oferece pela Camera2'),
      value: _hlg,
      onChanged: camera.hlg && _codec == 'hevc' && !_streaming ? _setHlg : null,
    ));
    result.add(SwitchListTile(
      dense: true,
      title: const Text('Áudio do celular'),
      subtitle: const Text('No MP4 (AAC 320k) e para o PC sem compressão (48 kHz)'),
      value: _audio,
      onChanged: _streaming ? null : (v) => setState(() => _audio = v),
    ));
    return result;
  }

  void _switchCamera(CameraInfo? camera) {
    if (camera == null) return;
    setState(() => _chooseCamera(camera));
    _reopen();
  }

  List<Widget> _sizeChips(CameraInfo camera) {
    final result = <Widget>[];
    for (final size in camera.sizes) {
      result.add(ChoiceChip(
        label: Text('${size.label} (até ${size.maxFps})'),
        selected: _size == size,
        onSelected: _streaming ? null : (_) => _setSize(camera, size),
      ));
    }
    return result;
  }

  void _setSize(CameraInfo camera, VideoSize size) {
    setState(() {
      _size = size;
      // each size at its best rate: 60 where the sensor delivers it (1080p/1440p), 30 in 4K
      _fps = _pickFps(camera, size.maxFps);
      _slowSeconds = 0;
    });
    _reopen();
  }

  List<Widget> _fpsChips(CameraInfo camera) {
    final result = <Widget>[];
    final maxFps = _size?.maxFps ?? 30;
    for (final f in camera.fps) {
      if (f < 24) continue;
      // above the reported limit it may still work (Samsung under-reports 4K60): try and measure
      result.add(ChoiceChip(
        label: Text(f > maxFps ? '$f fps (testar)' : '$f fps'),
        selected: _fps == f,
        onSelected: _streaming ? null : (_) => _setFps(f),
      ));
    }
    return result;
  }

  void _setFps(int fps) {
    setState(() {
      _fps = fps;
      _slowSeconds = 0;
    });
    _reopen();
  }

  void _setCodec(Set<String> selection) {
    setState(() => _codec = selection.first);
    if (_codec == 'avc' && _hlg) _setHlg(false);
  }

  void _setHlg(bool value) {
    setState(() => _hlg = value);
    _reopen();
  }

  Widget _shutterSelector(CameraInfo camera) {
    final options = camera.shutterSpeeds(_fps);
    if (options.isEmpty) return const SizedBox.shrink();
    var index = options.indexWhere((o) => o <= _settings.exposureNs);
    if (index < 0) index = options.length - 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _labelValue('Obturador', _shutter(options[index])),
        Slider(
          min: 0,
          max: (options.length - 1).toDouble(),
          divisions: options.length > 1 ? options.length - 1 : null,
          value: index.toDouble(),
          onChanged: (v) => _adjust(() => _settings.exposureNs = options[v.round()]),
        ),
      ],
    );
  }

  Widget _qualitySelector(String title, String current, void Function(String) change) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(title, style: const TextStyle(fontSize: 13))),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'off', label: Text('Off')),
              ButtonSegment(value: 'fast', label: Text('Rápido')),
              ButtonSegment(value: 'quality', label: Text('HQ')),
            ],
            selected: {current},
            onSelectionChanged: (s) => _adjust(() => change(s.first)),
          ),
        ],
      ),
    );
  }

  Widget _title(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
    );
  }

  Widget _section(String title, IconData icon, List<Widget> children) {
    return ExpansionTile(
      leading: Icon(icon, size: 20),
      title: Text(title),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _labelValue(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
          Text(value, style: const TextStyle(fontSize: 13, fontFeatures: [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }
}

String _shutter(int ns) => ns <= 0 ? '-' : '1/${(1000000000 / ns).round()}';

/// Focus distance in diopters (1/m) -> meters text; 0 = infinity.
String _distance(double diopters) {
  if (diopters <= 0.01) return '∞';
  return '${(1 / diopters).toStringAsFixed(diopters > 2 ? 2 : 1)} m';
}

String _clock(int s) => '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
