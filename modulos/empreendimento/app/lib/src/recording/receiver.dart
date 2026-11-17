import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'camera_pro.dart';
import 'protocol.dart';

/// Take recorded on the PC.
class Take {
  Take(this.file, this.description, this.duration);

  String file;
  final String description;
  final Duration duration;
  bool ready = false;
}

/// Phone camera receiver on the PC (Linux): announces the PC on the network, takes ONE connection at a
/// time, reads the header and hands the raw stream to ffmpeg, which records the take without
/// re-encoding (MKV, then MOV), sends the preview over local UDP, feeds the capture studio and, if
/// chosen, the virtual webcam (v4l2loopback).
class Receiver extends ChangeNotifier {
  Receiver({this.port = videoPort, this.previewPort = 5601, this.studioPort = 5602, this.announce = true});

  /// One per app: stays on across tabs so the studio keeps receiving the phone.
  static final instance = Receiver();

  final int port;
  final int previewPort;

  /// Capture studio input (null: do not feed it) and whether to announce this PC on the network;
  /// the live test bench turns both off so it never disturbs the real phone.
  final int? studioPort;
  final bool announce;

  ServerSocket? _server;
  RawDatagramSocket? _announcer;
  Timer? _clock;
  _Connection? _connection;
  List<int> _announcement = const [];

  bool get listening => _server != null;
  bool get connected => _connection?.header != null;
  StreamHeader? get header => _connection?.header;
  String? get origin => _connection?.socket.remoteAddress.address;
  Duration get duration => _connection?.elapsed ?? Duration.zero;
  double mbps = 0;
  int _bytesThisSecond = 0;

  bool record = true;
  String? webcam;
  String? error;
  final takes = <Take>[];

  static String get folder {
    final home = Platform.environment['HOME'];
    final base = Platform.environment['AGENT_DATA'] ?? '$home/agent-data';
    return '$base/recordings/camera';
  }

  Future<void> listen() async {
    if (listening) return;
    try {
      final server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      _server = server;
      server.listen(_onClient);
      final announcer = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      announcer.broadcastEnabled = true;
      _announcer = announcer;
      _announcement = utf8.encode(PcAnnouncement(port, Platform.localHostname).encode());
      await _refreshBroadcasts();
      _clock = Timer.periodic(const Duration(seconds: 1), _onTick);
      error = null;
    } on SocketException catch (e) {
      error = 'Porta $port ocupada? ${e.message}';
      await stopListening();
    }
    notifyListeners();
  }

  void _onTick(Timer _) {
    _announce();
    mbps = _bytesThisSecond * 8 / 1e6;
    _bytesThisSecond = 0;
    notifyListeners();
  }

  /// Directed broadcasts (192.168.3.255…) of each local network: many routers do not carry the
  /// global 255.255.255.255 from the cable to the Wi-Fi, and with virtual interfaces (virbr0,
  /// docker0) the global one may leave through the wrong one. Assumes /24, the home default.
  List<InternetAddress> _broadcasts = [InternetAddress('255.255.255.255')];

  Future<void> _refreshBroadcasts() async {
    final result = <InternetAddress>[InternetAddress('255.255.255.255')];
    for (final interface in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final address in interface.addresses) {
        if (address.isLoopback) continue;
        final parts = address.address.split('.');
        result.add(InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255'));
      }
    }
    _broadcasts = result;
  }

  void _announce() {
    final announcer = _announcer;
    if (announcer == null || !announce) return;
    for (final target in _broadcasts) {
      try {
        announcer.send(_announcement, target, announcePort);
      } on SocketException {
        // one unreachable network does not stop the others
      }
    }
  }

  Future<void> stopListening() async {
    _clock?.cancel();
    _clock = null;
    _announcer?.close();
    _announcer = null;
    await _server?.close();
    _server = null;
    _connection?.socket.destroy();
    notifyListeners();
  }

  void _onClient(Socket socket) {
    if (_connection != null) {
      socket.destroy(); // one camera at a time
      return;
    }
    socket.setOption(SocketOption.tcpNoDelay, true);
    _connection = _Connection(this, socket);
  }

  void _countBytes(int count) {
    _bytesThisSecond += count;
  }

  void _connectionStarted() {
    error = null;
    notifyListeners();
  }

  void _connectionEnded(_Connection connection, Take? take, String? failure) {
    if (failure != null) error = failure;
    if (take != null) {
      takes.insert(0, take);
      _remux(take, connection.header?.codec == 'hevc');
    }
    if (_connection == connection) _connection = null;
    notifyListeners();
  }

  String takeName(StreamHeader header) {
    final d = DateTime.now();
    final stamp = '${d.year}-${_two(d.month)}-${_two(d.day)}_${_two(d.hour)}${_two(d.minute)}${_two(d.second)}';
    return '$folder/${stamp}_${header.height}p${header.fps}.mkv';
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// MKV -> MOV without re-encoding; the MKV is deleted only if the MOV came out whole.
  Future<void> _remux(Take take, bool hevc) async {
    final mkv = take.file;
    final mov = mkv.replaceAll(RegExp(r'\.mkv$'), '.mov');
    try {
      final result = await Process.run('ffmpeg', remuxArguments(mkv, mov, hevc: hevc));
      final out = File(mov);
      if (result.exitCode == 0 && out.existsSync() && out.lengthSync() > 0) {
        File(mkv).deleteSync();
        take.file = mov;
      } else {
        error = 'Conversão para MOV falhou; o MKV ficou: ${(result.stderr as String).trim()}';
      }
    } on ProcessException catch (e) {
      error = 'ffmpeg não encontrado: ${e.message}';
    }
    take.ready = true;
    notifyListeners();
  }

  /// `adb reverse`: the phone plugged over USB reaches the PC at 127.0.0.1.
  Future<String> prepareUsb() async {
    try {
      final r = await Process.run('adb', ['reverse', 'tcp:$port', 'tcp:$port']);
      if (r.exitCode == 0) return 'USB pronto: no celular escolha "USB".';
      return 'adb: ${(r.stderr as String).trim()}';
    } on ProcessException {
      return 'adb não encontrado no PATH.';
    }
  }

  /// Opens the video port in the OS firewall for the local networks, asking for the admin password
  /// through the system's own dialog (pkexec on Linux, UAC on Windows). Without it the phone gets
  /// "connection refused" even with the PC listening.
  Future<String> allowFirewall() async {
    try {
      if (Platform.isWindows) return await _allowWindowsFirewall();
      if (Platform.isLinux) return await _allowLinuxFirewall();
      return 'Firewall: sistema não suportado.';
    } on ProcessException catch (e) {
      return 'Firewall: ${e.message}';
    }
  }

  /// UDP receive buffer for the local preview (4K at 40+ Mb/s): the 208 KB default drops packets and
  /// the HEVC preview stays black.
  static const _udpBuffer = 33554432;

  static const _sysctlScript = 'echo net.core.rmem_max=$_udpBuffer > /etc/sysctl.d/90-solumia.conf && '
      'sysctl -q -w net.core.rmem_max=$_udpBuffer';

  Future<String> _allowLinuxFirewall() async {
    var script = _sysctlScript;
    if (await _serviceActive('ufw')) {
      script += ' && for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do '
          'ufw allow proto tcp from \$net to any port $port comment Solumia || exit 1; done';
    } else if (await _serviceActive('firewalld')) {
      script += ' && firewall-cmd --permanent --add-port=$port/tcp && firewall-cmd --reload';
    }
    final r = await Process.run('pkexec', ['sh', '-c', script]);
    if (r.exitCode == 0) return _markAllowed();
    if (r.exitCode == 126 || r.exitCode == 127) return 'Firewall: senha cancelada.';
    return 'Firewall: ${(r.stderr as String).trim()}';
  }

  static File get _allowedMarker => File('$folder/.firewall_allowed');

  /// True once the firewall was opened (or none was active): the screen only asks on first use.
  static bool get firewallAllowed {
    if (!_allowedMarker.existsSync()) return false;
    if (!Platform.isLinux) return true;
    return _rmemMax() >= _udpBuffer;
  }

  static int _rmemMax() {
    try {
      return int.parse(File('/proc/sys/net/core/rmem_max').readAsStringSync().trim());
    } on Exception {
      return 0;
    }
  }

  String _markAllowed() {
    _allowedMarker.createSync(recursive: true);
    return 'Firewall liberado: o celular já pode conectar na porta $port.';
  }

  Future<bool> _serviceActive(String name) async {
    final r = await Process.run('systemctl', ['is-active', '--quiet', name]);
    return r.exitCode == 0;
  }

  Future<String> _allowWindowsFirewall() async {
    final rule = 'advfirewall firewall add rule name=Solumia dir=in action=allow protocol=TCP '
        'localport=$port profile=private';
    final r = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      "Start-Process netsh -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList '$rule'",
    ]);
    if (r.exitCode == 0) return _markAllowed();
    return 'Firewall: permissão negada.';
  }

  static Future<List<String>> addresses() async {
    final result = <String>[];
    for (final interface in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final address in interface.addresses) {
        if (!address.isLoopback) result.add('${address.address} (${interface.name})');
      }
    }
    return result;
  }

  /// v4l2loopback devices (they live under /sys/devices/virtual).
  static List<String> virtualWebcams() {
    final dir = Directory('/sys/class/video4linux');
    if (!dir.existsSync()) return const [];
    final result = <String>[];
    for (final entry in dir.listSync()) {
      if (entry.resolveSymbolicLinksSync().contains('/virtual/')) {
        result.add('/dev/${entry.uri.pathSegments.lastWhere(_notEmpty)}');
      }
    }
    result.sort();
    return result;
  }

  static bool _notEmpty(String segment) => segment.isNotEmpty;
}

/// One phone connection: header line, then the stream piped into ffmpeg.
class _Connection {
  _Connection(this.receiver, this.socket) {
    _subscription = socket.listen(_onData, onDone: _finish, onError: _onError, cancelOnError: true);
  }

  final Receiver receiver;
  final Socket socket;
  late final StreamSubscription<Uint8List> _subscription;
  final _line = BytesBuilder(copy: false);
  final _stderr = <String>[];
  StreamHeader? header;
  /// Live (preview, studio, webcam) and take (MKV with the phone audio) run apart so the preview
  /// never waits for the audio.
  Process? _ffmpeg;
  Process? _take;
  String? _file;
  DateTime? _startedAt;
  bool _finishing = false;

  /// Framed stream (video + phone audio): the audio goes to ffmpeg through a local socket.
  FrameSplitter? _splitter;
  ServerSocket? _audioServer;
  Socket? _audioSink;
  final _audioBacklog = BytesBuilder(copy: false);
  int _audioBytes = 0;
  DateTime? _firstFrameAt;

  Duration get elapsed => _startedAt == null ? Duration.zero : DateTime.now().difference(_startedAt!);

  Future<void> _onData(Uint8List data) async {
    var payload = data;
    if (header == null) {
      final end = data.indexOf(10);
      if (end < 0) {
        _line.add(data);
        if (_line.length > 512) socket.destroy();
        return;
      }
      _line.add(data.sublist(0, end));
      payload = data.sublist(end + 1);
      // hold the next chunks until ffmpeg exists
      _subscription.pause();
      final ok = await _startFfmpeg(utf8.decode(_line.takeBytes(), allowMalformed: true));
      _subscription.resume();
      if (!ok) return;
    }
    receiver._countBytes(payload.length);
    final splitter = _splitter;
    if (splitter == null) {
      _writeVideo(payload);
    } else if (!splitter.add(payload)) {
      socket.destroy();
    }
  }

  void _writeVideo(Uint8List data) {
    try {
      _ffmpeg?.stdin.add(data);
      _take?.stdin.add(data);
    } on Exception {
      socket.destroy();
    }
  }

  /// HEVC/H.264 access unit delimiters: ffmpeg only releases a frame when it sees the start of the
  /// next one, so the live process gets the delimiter right after each frame (one frame less delay).
  static final _hevcDelimiter = Uint8List.fromList([0, 0, 0, 1, 0x46, 0x01, 0x50]);
  static final _avcDelimiter = Uint8List.fromList([0, 0, 0, 1, 0x09, 0xF0]);

  /// Framed stream: each video packet is one whole encoded frame. The take gets it untouched.
  void _writeFrame(Uint8List data) {
    try {
      final live = _ffmpeg;
      if (live != null) {
        live.stdin.add(data);
        // the tiny packets are codec parameters, not a picture: nothing to close
        if (data.length > 512) live.stdin.add(header?.codec == 'avc' ? _avcDelimiter : _hevcDelimiter);
      }
      _take?.stdin.add(data);
      _padAudio();
    } on Exception {
      socket.destroy();
    }
  }

  /// The take reads video and audio together: if the phone microphone stops (or never starts), the
  /// take would stall and the video would pile up in memory. Fills the gap with silence when the
  /// audio falls more than a second behind the clock.
  void _padAudio() {
    final parsed = header;
    if (_audioServer == null || parsed == null || !parsed.hasAudio) return;
    final first = _firstFrameAt ??= DateTime.now();
    final bytesPerSecond = parsed.audioRate! * parsed.audioChannels! * 2;
    final expected = DateTime.now().difference(first).inMilliseconds * bytesPerSecond ~/ 1000;
    final missing = expected - _audioBytes;
    if (missing < bytesPerSecond) return;
    // whole sample frames, leaving half a second of slack for audio still on its way
    final frame = parsed.audioChannels! * 2;
    final fill = (missing - bytesPerSecond ~/ 2) ~/ frame * frame;
    _writeAudio(Uint8List(fill));
  }

  void _writeAudio(Uint8List data) {
    // no take being recorded: the audio has nowhere to go
    if (_audioServer == null) return;
    _audioBytes += data.length;
    final sink = _audioSink;
    if (sink == null) {
      // ffmpeg connects only after probing the video: keep the audio from the start
      _audioBacklog.add(data);
      return;
    }
    sink.add(data);
  }

  void _onAudioClient(Socket client) {
    if (_audioSink != null) {
      client.destroy();
      return;
    }
    client.setOption(SocketOption.tcpNoDelay, true);
    client.done.catchError(_ignore);
    if (_audioBacklog.isNotEmpty) client.add(_audioBacklog.takeBytes());
    _audioSink = client;
  }

  static void _ignore(Object _) {}

  Future<int?> _openAudio(StreamHeader parsed) async {
    if (!parsed.hasAudio) return null;
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_onAudioClient);
    _audioServer = server;
    return server.port;
  }

  Future<void> _closeAudio() async {
    await _audioServer?.close();
    try {
      await _audioSink?.close();
    } on Exception {
      // ffmpeg already gone
    }
  }

  Future<bool> _startFfmpeg(String line) async {
    final parsed = StreamHeader.parse(line);
    if (parsed == null) {
      socket.destroy();
      return false;
    }
    if (receiver.record) {
      Directory(Receiver.folder).createSync(recursive: true);
      _file = receiver.takeName(parsed);
    }
    try {
      // framed stream (video + audio) whenever the phone sends audio, recording or not
      if (parsed.hasAudio) _splitter = FrameSplitter(onVideo: _writeFrame, onAudio: _writeAudio);
      final args = ffmpegArguments(
        parsed,
        previewPort: receiver.previewPort,
        studioPort: receiver.studioPort,
        webcam: receiver.webcam,
      );
      _ffmpeg = await _startProcess(args);
      final file = _file;
      if (file != null) {
        final audioPort = await _openAudio(parsed);
        _take = await _startProcess(takeArguments(parsed, file: file, audioPort: audioPort));
      }
    } on ProcessException catch (e) {
      receiver._connectionEnded(this, null, 'ffmpeg não encontrado: ${e.message}');
      socket.destroy();
      return false;
    }
    header = parsed;
    _startedAt = DateTime.now();
    receiver._connectionStarted();
    return true;
  }

  Future<Process> _startProcess(List<String> args) async {
    final process = await Process.start('ffmpeg', args);
    process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(_onStderr);
    process.stdout.drain<void>();
    process.exitCode.then(_onFfmpegExit);
    return process;
  }

  void _onStderr(String line) {
    _stderr.add(line);
    if (_stderr.length > 20) _stderr.removeAt(0);
  }

  void _onFfmpegExit(int _) => socket.destroy();

  void _onError(Object _) => _finish();

  Future<void> _finish() async {
    if (_finishing) return;
    _finishing = true;
    final duration = elapsed;
    // together: the take only drains the rest of the video once it sees the end of the audio, and
    // closing one after the other left it waiting (take never finalized, stuck as MKV)
    await Future.wait([_closeInput(_ffmpeg), _closeInput(_take), _closeAudio()]);
    await _ffmpeg?.exitCode.timeout(const Duration(seconds: 10), onTimeout: _killFfmpeg);
    // the take decides the result: it is the file the user keeps
    final code = await _take?.exitCode.timeout(const Duration(seconds: 10), onTimeout: _killTake);
    String? failure;
    if (code != null && code != 0 && _stderr.isNotEmpty) failure = 'ffmpeg: ${_stderr.last}';
    Take? take;
    final file = _file;
    final parsed = header;
    if (file != null && parsed != null && File(file).existsSync()) {
      take = Take(file, parsed.description, duration);
    }
    receiver._connectionEnded(this, take, failure);
  }

  Future<void> _closeInput(Process? process) async {
    try {
      await process?.stdin.close();
    } on Exception {
      // ffmpeg already gone
    }
  }

  int _killFfmpeg() {
    _ffmpeg?.kill();
    return -1;
  }

  int _killTake() {
    _take?.kill();
    return -1;
  }
}
