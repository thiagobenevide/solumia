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
  Receiver({this.port = videoPort, this.previewPort = 5601});

  /// One per app: stays on across tabs so the studio keeps receiving the phone.
  static final instance = Receiver();

  final int port;
  final int previewPort;

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
      _clock = Timer.periodic(const Duration(seconds: 1), _onTick);
      error = null;
    } on SocketException catch (e) {
      error = 'Porta $port ocupada? ${e.message}';
      await stopListening();
    }
    notifyListeners();
  }

  void _onTick(Timer _) {
    _announcer?.send(_announcement, InternetAddress('255.255.255.255'), announcePort);
    mbps = _bytesThisSecond * 8 / 1e6;
    _bytesThisSecond = 0;
    notifyListeners();
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
  Process? _ffmpeg;
  String? _file;
  DateTime? _startedAt;
  bool _finishing = false;

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
    try {
      _ffmpeg?.stdin.add(payload);
    } on Exception {
      socket.destroy();
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
      final args = ffmpegArguments(parsed, file: _file, previewPort: receiver.previewPort, webcam: receiver.webcam);
      final process = await Process.start('ffmpeg', args);
      _ffmpeg = process;
      process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(_onStderr);
      process.stdout.drain<void>();
      process.exitCode.then(_onFfmpegExit);
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
    try {
      await _ffmpeg?.stdin.close();
    } on Exception {
      // ffmpeg already gone
    }
    final code = await _ffmpeg?.exitCode.timeout(const Duration(seconds: 10), onTimeout: _killFfmpeg);
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

  int _killFfmpeg() {
    _ffmpeg?.kill();
    return -1;
  }
}
