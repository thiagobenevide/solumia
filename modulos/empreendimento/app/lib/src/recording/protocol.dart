/// Protocol between the phone (camera) and the PC (receiver), platform independent.
///
/// - PC UDP announcement, every second, broadcast on [announcePort]: `SOLUMIA-CAM-PC 1 <port> <name>`.
/// - Phone TCP connection: one line `SOLUMIA-CAM 1 <hevc|avc> <W>x<H> <fps> <hlg 0|1>` and then the raw
///   Annex-B stream (the same one written to the phone MP4).
library;

class PcAnnouncement {
  const PcAnnouncement(this.port, this.name);

  final int port;
  final String name;

  String encode() => 'SOLUMIA-CAM-PC 1 $port $name';

  static PcAnnouncement? parse(String text) {
    final parts = text.trim().split(' ');
    if (parts.length < 3 || parts[0] != 'SOLUMIA-CAM-PC' || parts[1] != '1') return null;
    final port = int.tryParse(parts[2]);
    if (port == null) return null;
    return PcAnnouncement(port, parts.skip(3).join(' '));
  }
}

class StreamHeader {
  const StreamHeader({
    required this.codec,
    required this.width,
    required this.height,
    required this.fps,
    required this.hlg,
  });

  final String codec;
  final int width;
  final int height;
  final int fps;
  final bool hlg;

  /// ffmpeg demuxer for the raw stream.
  String get ffmpegFormat => codec == 'avc' ? 'h264' : 'hevc';

  String get description => '${codec.toUpperCase()} ${width}x$height $fps fps${hlg ? ' HLG' : ''}';

  static StreamHeader? parse(String line) {
    final p = line.trim().split(' ');
    if (p.length < 6 || p[0] != 'SOLUMIA-CAM' || p[1] != '1') return null;
    if (p[2] != 'hevc' && p[2] != 'avc') return null;
    final size = p[3].split('x');
    if (size.length != 2) return null;
    final width = int.tryParse(size[0]);
    final height = int.tryParse(size[1]);
    final fps = int.tryParse(p[4]);
    if (width == null || height == null || fps == null || fps <= 0) return null;
    return StreamHeader(codec: p[2], width: width, height: height, fps: fps, hlg: p[5] == '1');
  }
}

/// ffmpeg arguments that take the stream on stdin: record the take without re-encoding, send a copy
/// over UDP to the preview and to the capture studio and, if asked, decode into the virtual webcam.
List<String> ffmpegArguments(
  StreamHeader header, {
  String? file,
  required int previewPort,
  int? studioPort = 5602,
  String? webcam,
}) {
  final args = <String>['-hide_banner', '-loglevel', 'error', '-nostats'];
  if (webcam != null) args.addAll(['-hwaccel', 'auto']);
  args.addAll(['-fflags', '+genpts+nobuffer', '-flags', 'low_delay', '-probesize', '2M']);
  args.addAll(['-analyzeduration', '500000']);
  args.addAll(['-f', header.ffmpegFormat, '-framerate', '${header.fps}', '-i', 'pipe:0']);
  if (file != null) args.addAll(['-map', '0:v', '-c', 'copy', '-f', 'matroska', file]);
  args.addAll(['-map', '0:v', '-c', 'copy', '-f', 'mpegts', 'udp://127.0.0.1:$previewPort?pkt_size=1316']);
  if (studioPort != null) {
    args.addAll(['-map', '0:v', '-c', 'copy', '-f', 'mpegts', 'udp://127.0.0.1:$studioPort?pkt_size=1316']);
  }
  if (webcam != null) {
    args.addAll(['-map', '0:v', '-vf', 'scale=-2:min(ih\\,1080),format=yuv420p', '-f', 'v4l2', webcam]);
  }
  return args;
}

/// Remux of a finished take: MKV (crash-safe while recording) -> MOV for the editors, no re-encoding.
List<String> remuxArguments(String mkv, String mov, {required bool hevc}) {
  final args = <String>['-y', '-loglevel', 'error', '-i', mkv, '-map', '0', '-c', 'copy'];
  if (hevc) args.addAll(['-tag:v', 'hvc1']);
  args.add(mov);
  return args;
}
