/// Protocol between the phone (camera) and the PC (receiver), platform independent.
///
/// - PC UDP announcement, every second, broadcast on [announcePort]: `SOLUMIA-CAM-PC 1 <port> <name>`.
/// - Phone TCP connection: one line `SOLUMIA-CAM 1 <hevc|avc> <W>x<H> <fps> <hlg 0|1> [pcm<rate>x<channels>] [ctl]`.
///   Without extra tokens, the raw Annex-B stream follows (the same one written to the phone MP4).
///   With `pcm…` or `ctl`, the stream is framed: `V|A|C` byte + 4-byte big-endian length + payload, where
///   `V` is Annex-B video, `A` is PCM s16le audio from the phone microphone and `C` is the camera state
///   as JSON (lenses, ranges, current settings), sent again whenever it changes.
/// - With `ctl`, the PC sends commands back on the same socket, one JSON per line:
///   `{"settings": {...}}` changes camera settings (same keys as `CameraSettings`), `{"lens": "<id>"}`
///   switches the lens.
library;

import 'dart:typed_data';

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
    this.audioRate,
    this.audioChannels,
    this.control = false,
  });

  final String codec;
  final int width;
  final int height;
  final int fps;
  final bool hlg;

  /// PCM audio of the framed stream; null when the phone sends video only.
  final int? audioRate;
  final int? audioChannels;

  bool get hasAudio => audioRate != null && audioChannels != null;

  /// The phone takes remote commands and reports its camera state (`ctl` token).
  final bool control;

  /// Framed stream (`V|A|C` packets) instead of the raw Annex-B.
  bool get framed => hasAudio || control;

  /// ffmpeg demuxer for the raw stream.
  String get ffmpegFormat => codec == 'avc' ? 'h264' : 'hevc';

  String get description {
    final audio = hasAudio ? ' · áudio ${audioRate! ~/ 1000} kHz' : '';
    return '${codec.toUpperCase()} ${width}x$height $fps fps${hlg ? ' HLG' : ''}$audio';
  }

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
    int? rate;
    int? channels;
    var control = false;
    for (final token in p.skip(6)) {
      if (token == 'ctl') control = true;
      if (!token.startsWith('pcm')) continue;
      final audio = token.substring(3).split('x');
      if (audio.length == 2) {
        rate = int.tryParse(audio[0]);
        channels = int.tryParse(audio[1]);
      }
    }
    return StreamHeader(
      codec: p[2],
      width: width,
      height: height,
      fps: fps,
      hlg: p[5] == '1',
      audioRate: rate,
      audioChannels: channels,
      control: control,
    );
  }
}

/// Splits the framed stream (`V|A|C` + length + payload) into video, audio and control chunks, whatever
/// the TCP chunk boundaries are.
class FrameSplitter {
  FrameSplitter({required this.onVideo, required this.onAudio, this.onControl});

  final void Function(Uint8List) onVideo;
  final void Function(Uint8List) onAudio;
  final void Function(Uint8List)? onControl;

  static const _headerSize = 5;
  static const _maxFrame = 64 * 1024 * 1024;

  Uint8List _pending = Uint8List(0);

  /// Returns false when the stream is corrupt (unknown type or absurd length).
  bool add(Uint8List data) {
    var buffer = data;
    if (_pending.isNotEmpty) {
      final joined = Uint8List(_pending.length + data.length);
      joined.setRange(0, _pending.length, _pending);
      joined.setRange(_pending.length, joined.length, data);
      buffer = joined;
    }
    var offset = 0;
    while (buffer.length - offset >= _headerSize) {
      final type = buffer[offset];
      final length = ByteData.sublistView(buffer, offset + 1, offset + _headerSize).getUint32(0);
      if ((type != 0x56 && type != 0x41 && type != 0x43) || length > _maxFrame) return false;
      final end = offset + _headerSize + length;
      if (end > buffer.length) break;
      final payload = Uint8List.sublistView(buffer, offset + _headerSize, end);
      if (type == 0x56) {
        onVideo(payload);
      } else if (type == 0x41) {
        onAudio(payload);
      } else {
        onControl?.call(payload);
      }
      offset = end;
    }
    _pending = Uint8List.fromList(Uint8List.sublistView(buffer, offset));
    return true;
  }
}

/// Video input on stdin, shared by the live and the take processes. `-r` stamps each frame at 1/fps
/// (without it the take collapses to a fraction of a second); no `nobuffer`: it discards the frames
/// read while probing (the first second of the take).
List<String> _videoInput(StreamHeader header, {bool hwaccel = false, bool genpts = false}) {
  final args = <String>['-hide_banner', '-loglevel', 'error', '-nostats'];
  if (hwaccel) args.addAll(['-hwaccel', 'auto']);
  // genpts only for the take (exact frame count and rate in the file); live does without it
  if (genpts) args.addAll(['-fflags', '+genpts']);
  args.addAll(['-flags', 'low_delay', '-probesize', '2M']);
  args.addAll(['-analyzeduration', '500000', '-r', '${header.fps}']);
  args.addAll(['-f', header.ffmpegFormat, '-framerate', '${header.fps}', '-i', 'pipe:0']);
  return args;
}

/// Live process (video only, no re-encoding): preview, capture studio and, if asked, the virtual
/// webcam. Kept apart from the take: syncing with the phone audio added ~0.6 s to the preview.
List<String> ffmpegArguments(
  StreamHeader header, {
  required int previewPort,
  int? studioPort = 5602,
  String? webcam,
}) {
  final args = _videoInput(header, hwaccel: webcam != null);
  // no mux delay and a flush per packet: frames leave as soon as they arrive
  const live = ['-muxdelay', '0', '-muxpreload', '0', '-flush_packets', '1', '-f', 'mpegts'];
  args.addAll(['-map', '0:v', '-c', 'copy', ...live, 'udp://127.0.0.1:$previewPort?pkt_size=1316']);
  if (studioPort != null) {
    args.addAll(['-map', '0:v', '-c', 'copy', ...live, 'udp://127.0.0.1:$studioPort?pkt_size=1316']);
  }
  if (webcam != null) {
    args.addAll(['-map', '0:v', '-vf', 'scale=-2:min(ih\\,1080),format=yuv420p', '-f', 'v4l2', webcam]);
  }
  return args;
}

/// Take process: the video as it came plus the phone PCM (relayed by the receiver on a local socket,
/// lossless, timed by the sample count) into a crash-safe MKV.
List<String> takeArguments(StreamHeader header, {required String file, int? audioPort}) {
  final args = _videoInput(header, genpts: true);
  final withAudio = header.hasAudio && audioPort != null;
  if (withAudio) {
    args.addAll(['-f', 's16le', '-ar', '${header.audioRate}', '-ac', '${header.audioChannels}']);
    args.addAll(['-i', 'tcp://127.0.0.1:$audioPort']);
  }
  args.addAll(['-map', '0:v']);
  if (withAudio) args.addAll(['-map', '1:a']);
  args.addAll(['-c', 'copy', '-f', 'matroska', file]);
  return args;
}

/// Remux of a finished take: MKV (crash-safe while recording) -> MOV for the editors, no re-encoding.
List<String> remuxArguments(String mkv, String mov, {required bool hevc}) {
  final args = <String>['-y', '-loglevel', 'error', '-i', mkv, '-map', '0', '-c', 'copy'];
  if (hevc) args.addAll(['-tag:v', 'hvc1']);
  args.add(mov);
  return args;
}
