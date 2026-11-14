import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';

import '../util.dart';
import 'local_video_web.dart' if (dart.library.io) 'local_video_io.dart';

/// Player for `final.mp4` inside the app, on every platform: web, Android and iOS through `video_player`;
/// Linux and Windows through the same `video_player` with libmpv underneath (`video_player_media_kit`).
class VideoFinal extends StatefulWidget {
  const VideoFinal({super.key, required this.url, required this.vertical});

  final String url;
  final bool vertical;

  static bool _desktopReady = false;

  /// Turns libmpv on on desktop before the first player (does nothing elsewhere).
  static void _prepareDesktop() {
    if (_desktopReady) return;
    VideoPlayerMediaKit.ensureInitialized(linux: true, windows: true);
    _desktopReady = true;
  }

  @override
  State<VideoFinal> createState() => _VideoFinalState();
}

class _VideoFinalState extends State<VideoFinal> {
  late VideoPlayerController _c;
  Object? _error;

  /// Copy downloaded on the device (plays without depending on the connection to the PC).
  String? _local;
  TarefaFundo? _downloading;

  /// One file per render (`?v=`): a new render downloads again.
  String get _nome {
    final u = Uri.parse(widget.url);
    final segments = u.pathSegments;
    final i = segments.indexOf('arq');
    final ep = i >= 0 && i + 1 < segments.length ? segments[i + 1] : 'video';
    // format and preview/final go into the name: each video has its own copy on the device
    final arquivo = (i >= 0 ? segments.skip(i + 2) : segments.skip(segments.length - 1)).join('-').replaceAll('.mp4', '');
    return 'videos/$ep-$arquivo-${u.queryParameters['v'] ?? '0'}.mp4';
  }

  @override
  void initState() {
    super.initState();
    VideoFinal._prepareDesktop();
    _open();
  }

  @override
  void didUpdateWidget(VideoFinal old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _c.dispose();
      _open();
    }
  }

  void _open() {
    _error = null;
    _local = null;
    _begin(VideoPlayerController.networkUrl(Uri.parse(widget.url)));
    if (discoDisponivel) {
      caminhoNoAparelho(_nome).then((caminho) {
        if (caminho == null || !mounted) return;
        _c
          ..removeListener(_update)
          ..dispose();
        setState(() => _local = caminho);
        _begin(localController(caminho));
      });
    }
  }

  void _begin(VideoPlayerController c) {
    _c = c
      ..addListener(_update)
      ..initialize().catchError((Object e) {
        if (mounted) setState(() => _error = e);
      });
  }

  /// Chunked download as a task (bell): it resumes if it drops and does not lock the screen.
  void _download() {
    final nome = _nome;
    final url = Uri.parse(widget.url);
    final t = Tarefas.instancia.rodar<String>(
      'Vídeo ${nome.split('/').last}',
      (t) => baixarParaAparelho(ApiCliente(url.origin), url.toString(), nome, tarefa: t),
      abrir: (c, caminho) async => ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('Salvo no aparelho: $caminho'))),
    );
    setState(() => _downloading = t);
    Tarefas.instancia.addListener(_onChangeTask);
  }

  void _onChangeTask() {
    final t = _downloading;
    if (t == null || t.estado == EstadoTarefa.rodando) return;
    Tarefas.instancia.removeListener(_onChangeTask);
    if (!mounted) return;
    setState(() => _downloading = null);
    if (t.estado == EstadoTarefa.pronta) {
      _c
        ..removeListener(_update)
        ..dispose();
      _open();
    }
  }

  void _update() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    Tarefas.instancia.removeListener(_onChangeTask);
    _c
      ..removeListener(_update)
      ..dispose();
    super.dispose();
  }

  Future<void> _fullScreen() => Navigator.of(context).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: const Text('final.mp4'),
        ),
        body: Center(
          child: _Player(c: _c, ratio: _ratio),
        ),
      ),
    ),
  );

  double get _ratio =>
      _c.value.isInitialized ? _c.value.aspectRatio : (widget.vertical ? 9 / 16 : 16 / 9);

  @override
  Widget build(BuildContext context) => Card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error != null)
          AspectRatio(
            aspectRatio: _ratio,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Não consegui tocar o vídeo aqui: $_error', textAlign: TextAlign.center),
              ),
            ),
          )
        else
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: widget.vertical ? 640 : double.infinity),
            child: _Player(c: _c, ratio: _ratio),
          ),
        ListTile(
          dense: true,
          title: const Text('final.mp4'),
          subtitle: Text(
            _local != null
                ? 'Tocando a cópia do aparelho'
                : _downloading != null
                ? 'Baixando para o aparelho (acompanhe no sino)'
                : 'Tocando pela conexão',
          ),
          trailing: Wrap(
            spacing: 4,
            children: [
              if (discoDisponivel && _local == null)
                IconButton(
                  tooltip: 'Baixar para o aparelho (em partes, em segundo plano)',
                  icon: const Icon(Icons.download_for_offline_outlined),
                  onPressed: _downloading == null ? _download : null,
                ),
              IconButton(
                tooltip: 'Tela cheia',
                icon: const Icon(Icons.fullscreen),
                onPressed: _c.value.isInitialized ? _fullScreen : null,
              ),
              IconButton(
                tooltip: 'Abrir / baixar no navegador',
                icon: const Icon(Icons.open_in_new),
                onPressed: () => openUrl(context, widget.url),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Video with play/pause in the center, a draggable progress bar and the time.
class _Player extends StatelessWidget {
  const _Player({required this.c, required this.ratio});

  final VideoPlayerController c;
  final double ratio;

  static String _time(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: ratio,
    child: ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final v = c.value;
        if (!v.isInitialized) {
          return const ColoredBox(color: Colors.black, child: Center(child: CircularProgressIndicator()));
        }
        return Stack(
          alignment: Alignment.bottomCenter,
          children: [
            GestureDetector(onTap: () => v.isPlaying ? c.pause() : c.play(), child: VideoPlayer(c)),
            if (!v.isPlaying || v.isBuffering)
              Center(
                child: v.isBuffering
                    ? const CircularProgressIndicator()
                    : IconButton.filledTonal(
                        iconSize: 44,
                        icon: const Icon(Icons.play_arrow),
                        onPressed: c.play,
                      ),
              ),
            Container(
              color: Colors.black45,
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  VideoProgressIndicator(
                    c,
                    allowScrubbing: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                  ),
                  Row(
                    children: [
                      Text(
                        '${_time(v.position)} / ${_time(v.duration)}',
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                      const Spacer(),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        color: Colors.white,
                        icon: Icon(v.isPlaying ? Icons.pause : Icons.play_arrow),
                        onPressed: () => v.isPlaying ? c.pause() : c.play(),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    ),
  );
}
