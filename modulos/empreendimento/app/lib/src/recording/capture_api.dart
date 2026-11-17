import 'dart:convert';
import 'dart:io';

/// Client of the studio engine local API (`modulos/empreendimento/capture`, 127.0.0.1:5620).
class CaptureApi {
  CaptureApi({this.port = 5620});

  final int port;
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 2);

  Future<dynamic> _request(String method, String path, [Object? body]) async {
    final request = await _http.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
    if (body != null) {
      // explicit length: without it the body goes chunked and the engine (http.server) reads nothing
      final bytes = utf8.encode(jsonEncode(body));
      request.headers.contentType = ContentType.json;
      request.contentLength = bytes.length;
      request.add(bytes);
    }
    final response = await request.close().timeout(const Duration(seconds: 20));
    final text = await response.transform(utf8.decoder).join();
    final data = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
    if (response.statusCode >= 400) {
      final message = data is Map ? data['error'] as String? : null;
      throw CaptureError(message ?? 'error ${response.statusCode}');
    }
    return data;
  }

  Future<Map<String, dynamic>> _map(String method, String path, [Object? body]) async {
    return Map<String, dynamic>.from(await _request(method, path, body) as Map);
  }

  Future<Map<String, dynamic>> state() => _map('GET', '/state');
  Future<Map<String, dynamic>> devices() => _map('GET', '/devices');
  Future<Map<String, dynamic>> templates() => _map('GET', '/templates');
  Future<void> config(Map<String, Object?> config) => _request('PATCH', '/config', config);

  Future<String> addSource(String kind, String name, Map<String, Object?> config) async {
    final data = await _map('POST', '/sources', {'kind': kind, 'name': name, 'config': config});
    return data['id'] as String;
  }

  Future<void> editSource(String id, {String? name, Map<String, Object?>? config}) {
    return _request('PATCH', '/sources/$id', {'name': ?name, 'config': ?config});
  }

  Future<void> removeSource(String id) => _request('DELETE', '/sources/$id');
  Future<void> reloadSource(String id) => _request('POST', '/sources/$id/reload');
  Future<void> zoom(String action) => _request('POST', '/zoom', {'action': action});

  Future<String> addScene(String name) async => (await _map('POST', '/scenes', {'name': name}))['id'] as String;

  Future<String> addTemplate(String template) async {
    return (await _map('POST', '/scenes/template', {'template': template}))['id'] as String;
  }

  Future<void> editScene(String id, {String? name, List<Map<String, Object?>>? items}) {
    return _request('PATCH', '/scenes/$id', {'name': ?name, 'items': ?items});
  }

  Future<void> removeScene(String id) => _request('DELETE', '/scenes/$id');

  Future<void> activateScene(String id, String transition, int ms) {
    return _request('POST', '/scenes/$id/activate', {'transition': transition, 'ms': ms});
  }

  Future<Map<String, dynamic>> drawing(Map<String, Object?> body) => _map('POST', '/drawing', body);

  Future<void> startRecording() => _request('POST', '/recording/start');
  Future<void> stopRecording() => _request('POST', '/recording/stop');

  /// Starts the engine from the repository: the capture venv (OpenCV for face tracking) when present,
  /// otherwise the system Python (PyGObject/GStreamer from apt).
  static Future<String?> startEngine() async {
    final home = Platform.environment['HOME'];
    final repo = Platform.environment['SOLUMIA_REPO'] ?? '$home/Documents/github/solumia';
    final folder = '$repo/modulos/empreendimento/capture';
    if (!Directory(folder).existsSync()) return 'Motor não encontrado em $folder (defina SOLUMIA_REPO).';
    var python = '$folder/.venv/bin/python';
    if (!File(python).existsSync()) python = '/usr/bin/python3';
    try {
      await Process.start(python, ['-m', 'capture'], workingDirectory: folder, mode: ProcessStartMode.detached);
      return null;
    } on ProcessException catch (e) {
      return 'Não consegui iniciar o motor: ${e.message}';
    }
  }
}

class CaptureError implements Exception {
  CaptureError(this.message);

  final String message;

  @override
  String toString() => message;
}

// ------------------------------------------------------------------ models (mirror of capture/model.py)

class CaptureSource {
  CaptureSource(this.id, this.kind, this.name, this.config);

  factory CaptureSource.fromJson(Map<String, dynamic> j) {
    final config = Map<String, dynamic>.from(j['config'] as Map? ?? const {});
    return CaptureSource(j['id'] as String, j['kind'] as String, j['name'] as String, config);
  }

  final String id;
  final String kind;
  final String name;
  final Map<String, dynamic> config;

  bool get video => kind != 'microphone' && kind != 'output';
  bool get framed => kind == 'screen' || kind == 'phone' || kind == 'webcam' || kind == 'image';
  bool get camera => kind == 'phone' || kind == 'webcam';
}

class SceneItem {
  SceneItem({
    required this.source,
    this.x = 0,
    this.y = 0,
    this.w = 1920,
    this.h = 1080,
    this.alpha = 1,
    this.visible = true,
    this.zoom = 1,
    this.cx = 0.5,
    this.cy = 0.5,
    this.radius = 0,
    this.border = 0,
    this.borderColor = '#FFFFFF',
    this.fit = 'cover',
  });

  factory SceneItem.fromJson(Map<String, dynamic> j) {
    return SceneItem(
      source: j['source'] as String,
      x: j['x'] as int? ?? 0,
      y: j['y'] as int? ?? 0,
      w: j['w'] as int? ?? 1920,
      h: j['h'] as int? ?? 1080,
      alpha: (j['alpha'] as num?)?.toDouble() ?? 1,
      visible: j['visible'] as bool? ?? true,
      zoom: (j['zoom'] as num?)?.toDouble() ?? 1,
      cx: (j['cx'] as num?)?.toDouble() ?? 0.5,
      cy: (j['cy'] as num?)?.toDouble() ?? 0.5,
      radius: (j['radius'] as num?)?.toDouble() ?? 0,
      border: (j['border'] as num?)?.toDouble() ?? 0,
      borderColor: j['border_color'] as String? ?? '#FFFFFF',
      fit: j['fit'] as String? ?? 'cover',
    );
  }

  String source;
  int x;
  int y;
  int w;
  int h;
  double alpha;
  bool visible;
  double zoom;
  double cx;
  double cy;
  double radius;
  double border;
  String borderColor;
  String fit;

  SceneItem copy() => SceneItem.fromJson(Map<String, dynamic>.from(toJson()));

  bool get circle => w == h && radius >= w / 2 - 0.5;

  Map<String, Object?> toJson() => {
        'source': source,
        'x': x,
        'y': y,
        'w': w,
        'h': h,
        'alpha': alpha,
        'visible': visible,
        'zoom': zoom,
        'cx': cx,
        'cy': cy,
        'radius': radius,
        'border': border,
        'border_color': borderColor,
        'fit': fit,
      };
}

class CaptureScene {
  CaptureScene(this.id, this.name, this.items);

  factory CaptureScene.fromJson(Map<String, dynamic> j) {
    final items = <SceneItem>[];
    for (final i in (j['items'] as List? ?? const [])) {
      items.add(SceneItem.fromJson(Map<String, dynamic>.from(i as Map)));
    }
    return CaptureScene(j['id'] as String, j['name'] as String, items);
  }

  final String id;
  final String name;
  final List<SceneItem> items;
}

class CaptureState {
  CaptureState(this.raw) {
    final studio = Map<String, dynamic>.from(raw['studio'] as Map);
    config = Map<String, dynamic>.from(studio['config'] as Map);
    for (final s in (studio['sources'] as List)) {
      sources.add(CaptureSource.fromJson(Map<String, dynamic>.from(s as Map)));
    }
    for (final s in (studio['scenes'] as List)) {
      scenes.add(CaptureScene.fromJson(Map<String, dynamic>.from(s as Map)));
    }
    currentScene = studio['current_scene'] as String?;
    drawing = Map<String, dynamic>.from(raw['drawing'] as Map? ?? const {});
  }

  final Map<String, dynamic> raw;
  late final Map<String, dynamic> config;
  final sources = <CaptureSource>[];
  final scenes = <CaptureScene>[];
  String? currentScene;
  late final Map<String, dynamic> drawing;

  bool get recording => raw['recording'] as bool? ?? false;
  bool get stopping => raw['stopping'] as bool? ?? false;
  int get seconds => raw['seconds'] as int? ?? 0;
  String? get error => raw['error'] as String?;
  double get fps => (raw['fps'] as num?)?.toDouble() ?? 0;
  bool get faceTracking => raw['face_tracking'] as bool? ?? false;
  Map<String, String> get failures => Map<String, String>.from(raw['failures'] as Map? ?? const {});
  double level(String id) => (((raw['levels'] as Map?)?[id]) as num?)?.toDouble() ?? -100;
  int get width => config['width'] as int? ?? 1920;
  int get height => config['height'] as int? ?? 1080;
  int get previewPort => raw['preview_port'] as int? ?? 5610;
  bool get udpWarning => raw['udp_warning'] as bool? ?? false;

  List<Map<String, dynamic>> get recordings {
    final result = <Map<String, dynamic>>[];
    for (final r in (raw['recordings'] as List? ?? const [])) {
      result.add(Map<String, dynamic>.from(r as Map));
    }
    return result;
  }

  CaptureScene? get scene {
    for (final s in scenes) {
      if (s.id == currentScene) return s;
    }
    return null;
  }

  CaptureSource? source(String id) {
    for (final s in sources) {
      if (s.id == id) return s;
    }
    return null;
  }
}
