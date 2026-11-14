import 'package:flutter/services.dart';

/// Dart side of the native pro camera (Android, `recording/CameraProPlugin.kt`). The image never goes
/// through Dart: the preview arrives as a texture and the video goes from the encoder straight to the
/// network and the MP4.
class CameraPro {
  static const _channel = MethodChannel('agent/empreendimento/camera');
  static const _events = EventChannel('agent/empreendimento/camera/events');

  Stream<Map<String, dynamic>> events() {
    return _events.receiveBroadcastStream().map(_toMap);
  }

  static Map<String, dynamic> _toMap(Object? event) => Map<String, dynamic>.from(event as Map);

  Future<bool> requestPermission() async => await _channel.invokeMethod<bool>('requestPermission') ?? false;

  Future<List<CameraInfo>> cameras() async {
    final raw = await _channel.invokeListMethod<Object?>('cameras') ?? const [];
    final result = <CameraInfo>[];
    for (final item in raw) {
      result.add(CameraInfo.fromJson(Map<String, dynamic>.from(item as Map)));
    }
    return result;
  }

  /// Opens the camera and returns the preview texture id.
  Future<int> open({
    required String id,
    required int width,
    required int height,
    required int fps,
    bool hlg = false,
  }) async {
    final arguments = {'id': id, 'width': width, 'height': height, 'fps': fps, 'hlg': hlg};
    return await _channel.invokeMethod<int>('open', arguments) ?? -1;
  }

  Future<void> adjust(CameraSettings settings) => _channel.invokeMethod('adjust', settings.toMap());

  Future<void> start({
    String? host,
    int port = videoPort,
    String codec = 'hevc',
    int bitrateMbps = 80,
    bool recordLocal = true,
    bool audio = true,
  }) {
    return _channel.invokeMethod('start', {
      'host': host,
      'port': port,
      'codec': codec,
      'bitrateMbps': bitrateMbps,
      'recordLocal': recordLocal,
      'audio': audio,
    });
  }

  /// Stops streaming; returns the name of the MP4 recorded on the phone (Movies/Solumia), if any.
  Future<String?> stop() => _channel.invokeMethod<String>('stop');

  Future<void> close() => _channel.invokeMethod('close');
}

/// TCP port of the video (phone -> PC) and UDP port where the PC announces itself.
const videoPort = 5600;
const announcePort = 5599;

class VideoSize {
  const VideoSize(this.width, this.height, this.maxFps);

  final int width;
  final int height;
  final int maxFps;

  String get label {
    switch (width) {
      case 3840:
        return '4K';
      case 2560:
        return '1440p';
      case 1920:
        return '1080p';
      case 1280:
        return '720p';
    }
    return '${height}p';
  }
}

class CameraInfo {
  const CameraInfo({
    required this.id,
    required this.focal,
    required this.external,
    required this.sizes,
    required this.fps,
    required this.manual,
    required this.isoMin,
    required this.isoMax,
    required this.exposureMinNs,
    required this.exposureMaxNs,
    required this.evMin,
    required this.evMax,
    required this.evStep,
    required this.focusMin,
    required this.zoomMin,
    required this.zoomMax,
    required this.ois,
    required this.eis,
    required this.hlg,
    required this.hevc,
  });

  factory CameraInfo.fromJson(Map<String, dynamic> j) {
    final sizes = <VideoSize>[];
    for (final s in (j['sizes'] as List? ?? const [])) {
      final m = s as Map;
      sizes.add(VideoSize(m['width'] as int, m['height'] as int, m['maxFps'] as int? ?? 30));
    }
    final fps = <int>[];
    for (final f in (j['fps'] as List? ?? const [30])) {
      fps.add(f as int);
    }
    return CameraInfo(
      id: j['id'] as String,
      focal: (j['focal'] as num?)?.toDouble() ?? 0,
      external: j['external'] as bool? ?? false,
      sizes: sizes,
      fps: fps,
      manual: j['manual'] as bool? ?? false,
      isoMin: j['isoMin'] as int? ?? 100,
      isoMax: j['isoMax'] as int? ?? 100,
      exposureMinNs: (j['exposureMinNs'] as num?)?.toInt() ?? 0,
      exposureMaxNs: (j['exposureMaxNs'] as num?)?.toInt() ?? 0,
      evMin: j['evMin'] as int? ?? 0,
      evMax: j['evMax'] as int? ?? 0,
      evStep: (j['evStep'] as num?)?.toDouble() ?? 0,
      focusMin: (j['focusMin'] as num?)?.toDouble() ?? 0,
      zoomMin: (j['zoomMin'] as num?)?.toDouble() ?? 1,
      zoomMax: (j['zoomMax'] as num?)?.toDouble() ?? 1,
      ois: j['ois'] as bool? ?? false,
      eis: j['eis'] as bool? ?? false,
      hlg: j['hlg'] as bool? ?? false,
      hevc: j['hevc'] as bool? ?? true,
    );
  }

  final String id;
  final double focal;
  final bool external;
  final List<VideoSize> sizes;
  final List<int> fps;
  final bool manual;
  final int isoMin;
  final int isoMax;
  final int exposureMinNs;
  final int exposureMaxNs;
  final int evMin;
  final int evMax;
  final double evStep;
  final double focusMin;
  final double zoomMin;
  final double zoomMax;
  final bool ois;
  final bool eis;
  final bool hlg;
  final bool hevc;

  String get label => '${external ? 'Externa' : 'Traseira'} $id · ${focal.toStringAsFixed(1)} mm';

  /// Shutter speeds (ns) that fit the sensor and the frame: never longer than 1/fps.
  List<int> shutterSpeeds(int currentFps) {
    const denominators = [24, 25, 30, 48, 50, 60, 100, 120, 125, 250, 500, 1000, 2000, 4000, 8000];
    final limit = 1000000000 ~/ currentFps;
    final result = <int>[];
    for (final d in denominators) {
      final ns = 1000000000 ~/ d;
      final fitsFrame = ns <= limit;
      final fitsSensor = ns >= exposureMinNs && (exposureMaxNs == 0 || ns <= exposureMaxNs);
      if (fitsFrame && fitsSensor) result.add(ns);
    }
    return result;
  }
}

/// Settings sent to the camera repeating request (same keys the Kotlin side reads).
class CameraSettings {
  bool manualExposure = false;
  int iso = 100;
  int exposureNs = 1000000000 ~/ 120;
  int compensation = 0;
  bool lockAe = false;
  String awb = 'auto';
  bool lockAwb = false;
  bool manualFocus = false;
  double focus = 0;
  double zoom = 1;
  bool stabilization = false;
  bool torch = false;
  String noise = 'fast';
  String edge = 'fast';

  Map<String, Object?> toMap() => {
        'manualExposure': manualExposure,
        'iso': iso,
        'exposureNs': exposureNs,
        'compensation': compensation,
        'lockAe': lockAe,
        'awb': awb,
        'lockAwb': lockAwb,
        'manualFocus': manualFocus,
        'focus': focus,
        'zoom': zoom,
        'stabilization': stabilization,
        'torch': torch,
        'noise': noise,
        'edge': edge,
      };
}
