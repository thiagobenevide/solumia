import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'receiver.dart';

/// PC side: turns the receiver on, shows the phone preview (mpv reading the local UDP), the recorded
/// takes and the USB and virtual webcam options.
class ReceiverScreen extends StatefulWidget {
  const ReceiverScreen({super.key});

  @override
  State<ReceiverScreen> createState() => _ReceiverScreenState();
}

class _ReceiverScreenState extends State<ReceiverScreen> {
  final _receiver = Receiver.instance;
  Player? _player;
  VideoController? _video;
  bool _playing = false;
  List<String> _addresses = const [];
  List<String> _webcams = const [];
  String? _notice;

  @override
  void initState() {
    super.initState();
    MediaKit.ensureInitialized();
    _receiver.addListener(_onChange);
    _receiver.listen();
    Receiver.addresses().then(_setAddresses);
    _webcams = Receiver.virtualWebcams();
  }

  @override
  void dispose() {
    _receiver.removeListener(_onChange);
    _player?.dispose();
    super.dispose();
  }

  void _setAddresses(List<String> value) {
    if (mounted) setState(() => _addresses = value);
  }

  void _onChange() {
    if (!mounted) return;
    if (_receiver.connected && !_playing) {
      _playing = true;
      _openPreview();
    } else if (!_receiver.connected && _playing) {
      _playing = false;
      _player?.stop();
    }
    setState(() {});
  }

  Future<void> _openPreview() async {
    var player = _player;
    if (player == null) {
      player = Player();
      _player = player;
      _video = VideoController(player);
      final native = player.platform;
      if (native is NativePlayer) {
        // monitor preview: as little buffering as possible
        await native.setProperty('profile', 'low-latency');
        await native.setProperty('untimed', 'yes');
        await native.setProperty('cache', 'no');
      }
      await player.setVolume(0);
    }
    await player.open(Media('udp://127.0.0.1:${_receiver.previewPort}'));
  }

  Future<void> _prepareUsb() async {
    final message = await _receiver.prepareUsb();
    if (mounted) setState(() => _notice = message);
  }

  void _openFolder() {
    Directory(Receiver.folder).createSync(recursive: true);
    Process.run('xdg-open', [Receiver.folder]);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: _layout);
  }

  Widget _layout(BuildContext context, BoxConstraints box) {
    final preview = Padding(padding: const EdgeInsets.all(16), child: _preview());
    if (box.maxWidth > 1000) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [Expanded(child: preview), SizedBox(width: 380, child: _panel())],
      );
    }
    return ListView(children: [preview, _panel()]);
  }

  Widget _preview() {
    final header = _receiver.header;
    final ratio = header == null ? 16 / 9 : header.width / header.height;
    Widget content = Center(
      child: Text(
        _receiver.listening ? 'Aguardando o celular…' : 'Receptor desligado',
        style: const TextStyle(color: Colors.white70),
      ),
    );
    if (_receiver.connected && _video != null) {
      content = Video(controller: _video!, controls: NoVideoControls);
    }
    return AspectRatio(
      aspectRatio: ratio,
      child: DecoratedBox(
        decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(8)),
        child: ClipRRect(borderRadius: BorderRadius.circular(8), child: content),
      ),
    );
  }

  Widget _panel() {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final children = <Widget>[_statusRow(scheme)];
    if (_receiver.connected) {
      children.add(Text('Celular: ${_receiver.origin}', style: text.bodySmall));
    }
    if (_receiver.error != null) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(_receiver.error!, style: TextStyle(color: scheme.error)),
      ));
    }
    children.add(const Divider(height: 24));
    children.addAll(_connectSection(text));
    children.add(const Divider(height: 24));
    children.addAll(_outputSection(text));
    children.add(const Divider(height: 24));
    children.addAll(_takesSection(text));
    return ListView(
      shrinkWrap: true,
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: children,
    );
  }

  Widget _statusRow(ColorScheme scheme) {
    final r = _receiver;
    var icon = Icons.portable_wifi_off;
    var label = 'Desligado';
    if (r.connected) {
      icon = Icons.videocam;
      label = '${r.header!.description} · ${r.mbps.toStringAsFixed(0)} Mb/s · ${_clock(r.duration)}';
    } else if (r.listening) {
      icon = Icons.wifi_tethering;
      label = 'Ouvindo na porta ${r.port}';
    }
    return Row(
      children: [
        Icon(icon, color: r.connected ? Colors.green : scheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(child: Text(label, style: Theme.of(context).textTheme.titleSmall)),
        Switch(value: r.listening, onChanged: _toggleListening),
      ],
    );
  }

  void _toggleListening(bool on) {
    if (on) {
      _receiver.listen();
    } else {
      _receiver.stopListening();
    }
  }

  List<Widget> _connectSection(TextTheme text) {
    final result = <Widget>[
      Text('Conectar', style: text.titleSmall),
      const SizedBox(height: 4),
      const Text('No celular: Empreendimento › Gravação › Câmera. O PC aparece sozinho na lista '
          '(mesma rede Wi-Fi). Endereços deste PC:'),
    ];
    for (final address in _addresses) {
      result.add(SelectableText('  $address'));
    }
    result.add(const SizedBox(height: 8));
    result.add(OutlinedButton.icon(
      icon: const Icon(Icons.usb),
      label: const Text('Preparar USB (adb reverse)'),
      onPressed: _prepareUsb,
    ));
    if (_notice != null) {
      result.add(Padding(padding: const EdgeInsets.only(top: 4), child: Text(_notice!)));
    }
    return result;
  }

  List<Widget> _outputSection(TextTheme text) {
    final items = <DropdownMenuItem<String?>>[const DropdownMenuItem(value: null, child: Text('desligada'))];
    for (final w in _webcams) {
      items.add(DropdownMenuItem(value: w, child: Text(w)));
    }
    final result = <Widget>[
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Gravar take no PC'),
        subtitle: Text('Sem recodificar; vira MOV ao terminar. Pasta: ${Receiver.folder}'),
        value: _receiver.record,
        onChanged: _receiver.connected ? null : _setRecord,
      ),
      Row(
        children: [
          const Expanded(child: Text('Webcam virtual')),
          DropdownButton<String?>(
            value: _receiver.webcam,
            items: items,
            onChanged: _receiver.connected ? null : _setWebcam,
          ),
          IconButton(tooltip: 'Procurar de novo', icon: const Icon(Icons.refresh), onPressed: _refreshWebcams),
        ],
      ),
    ];
    if (_webcams.isEmpty) {
      result.add(Text(
        'Para usar como webcam (Meet, Zoom, navegador): sudo apt install v4l2loopback-dkms && '
        'sudo modprobe v4l2loopback exclusive_caps=1 card_label="Solumia Cam"',
        style: text.bodySmall,
      ));
    }
    return result;
  }

  void _setRecord(bool value) => setState(() => _receiver.record = value);

  void _setWebcam(String? value) => setState(() => _receiver.webcam = value);

  void _refreshWebcams() => setState(() => _webcams = Receiver.virtualWebcams());

  List<Widget> _takesSection(TextTheme text) {
    final result = <Widget>[
      Row(
        children: [
          Expanded(child: Text('Takes', style: text.titleSmall)),
          TextButton.icon(icon: const Icon(Icons.folder_open), label: const Text('Pasta'), onPressed: _openFolder),
        ],
      ),
    ];
    if (_receiver.takes.isEmpty) result.add(const Text('Nenhum take nesta sessão.'));
    for (final take in _receiver.takes) {
      result.add(ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(take.ready ? Icons.movie_outlined : Icons.hourglass_top),
        title: Text(take.file.split('/').last),
        subtitle: Text('${take.description} · ${_clock(take.duration)}'),
        onTap: () => Process.run('xdg-open', [take.file]),
      ));
    }
    return result;
  }
}

String _clock(Duration d) =>
    '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
