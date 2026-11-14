import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';

import '../util.dart';
import 'video_local_web.dart' if (dart.library.io) 'video_local_io.dart';

/// Player do `final.mp4` dentro do app, em todas as plataformas: web, Android e iOS pelo `video_player`;
/// Linux e Windows pelo mesmo `video_player` com a libmpv por baixo (`video_player_media_kit`).
class VideoFinal extends StatefulWidget {
  const VideoFinal({super.key, required this.url, required this.vertical});

  final String url;
  final bool vertical;

  static bool _desktopPronto = false;

  /// Liga a libmpv no desktop antes do primeiro player (no resto não faz nada).
  static void _prepararDesktop() {
    if (_desktopPronto) return;
    VideoPlayerMediaKit.ensureInitialized(linux: true, windows: true);
    _desktopPronto = true;
  }

  @override
  State<VideoFinal> createState() => _VideoFinalState();
}

class _VideoFinalState extends State<VideoFinal> {
  late VideoPlayerController _c;
  Object? _erro;

  /// Cópia baixada no aparelho (toca sem depender da conexão com o PC).
  String? _local;
  TarefaFundo? _baixando;

  /// Um arquivo por render (`?v=`): render novo baixa de novo.
  String get _nome {
    final u = Uri.parse(widget.url);
    final segmentos = u.pathSegments;
    final i = segmentos.indexOf('arq');
    final ep = i >= 0 && i + 1 < segmentos.length ? segmentos[i + 1] : 'video';
    // formato e prévia/final entram no nome: cada vídeo tem a sua cópia no aparelho
    final arquivo = (i >= 0 ? segmentos.skip(i + 2) : segmentos.skip(segmentos.length - 1)).join('-').replaceAll('.mp4', '');
    return 'videos/$ep-$arquivo-${u.queryParameters['v'] ?? '0'}.mp4';
  }

  @override
  void initState() {
    super.initState();
    VideoFinal._prepararDesktop();
    _abrir();
  }

  @override
  void didUpdateWidget(VideoFinal antigo) {
    super.didUpdateWidget(antigo);
    if (antigo.url != widget.url) {
      _c.dispose();
      _abrir();
    }
  }

  void _abrir() {
    _erro = null;
    _local = null;
    _iniciar(VideoPlayerController.networkUrl(Uri.parse(widget.url)));
    if (discoDisponivel) {
      caminhoNoAparelho(_nome).then((caminho) {
        if (caminho == null || !mounted) return;
        _c
          ..removeListener(_atualizar)
          ..dispose();
        setState(() => _local = caminho);
        _iniciar(controladorLocal(caminho));
      });
    }
  }

  void _iniciar(VideoPlayerController c) {
    _c = c
      ..addListener(_atualizar)
      ..initialize().catchError((Object e) {
        if (mounted) setState(() => _erro = e);
      });
  }

  /// Download em pedaços como tarefa (sino): continua se cair e não prende a tela.
  void _baixar() {
    final nome = _nome;
    final url = Uri.parse(widget.url);
    final t = Tarefas.instancia.rodar<String>(
      'Vídeo ${nome.split('/').last}',
      (t) => baixarParaAparelho(ApiCliente(url.origin), url.toString(), nome, tarefa: t),
      abrir: (c, caminho) async => ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('Salvo no aparelho: $caminho'))),
    );
    setState(() => _baixando = t);
    Tarefas.instancia.addListener(_aoMudarTarefa);
  }

  void _aoMudarTarefa() {
    final t = _baixando;
    if (t == null || t.estado == EstadoTarefa.rodando) return;
    Tarefas.instancia.removeListener(_aoMudarTarefa);
    if (!mounted) return;
    setState(() => _baixando = null);
    if (t.estado == EstadoTarefa.pronta) {
      _c
        ..removeListener(_atualizar)
        ..dispose();
      _abrir();
    }
  }

  void _atualizar() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    Tarefas.instancia.removeListener(_aoMudarTarefa);
    _c
      ..removeListener(_atualizar)
      ..dispose();
    super.dispose();
  }

  Future<void> _telaCheia() => Navigator.of(context).push(
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
          child: _Player(c: _c, proporcao: _proporcao),
        ),
      ),
    ),
  );

  double get _proporcao =>
      _c.value.isInitialized ? _c.value.aspectRatio : (widget.vertical ? 9 / 16 : 16 / 9);

  @override
  Widget build(BuildContext context) => Card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_erro != null)
          AspectRatio(
            aspectRatio: _proporcao,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Não consegui tocar o vídeo aqui: $_erro', textAlign: TextAlign.center),
              ),
            ),
          )
        else
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: widget.vertical ? 640 : double.infinity),
            child: _Player(c: _c, proporcao: _proporcao),
          ),
        ListTile(
          dense: true,
          title: const Text('final.mp4'),
          subtitle: Text(
            _local != null
                ? 'Tocando a cópia do aparelho'
                : _baixando != null
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
                  onPressed: _baixando == null ? _baixar : null,
                ),
              IconButton(
                tooltip: 'Tela cheia',
                icon: const Icon(Icons.fullscreen),
                onPressed: _c.value.isInitialized ? _telaCheia : null,
              ),
              IconButton(
                tooltip: 'Abrir / baixar no navegador',
                icon: const Icon(Icons.open_in_new),
                onPressed: () => abrirUrl(context, widget.url),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Vídeo com tocar/pausar no centro, barra de progresso arrastável e o tempo.
class _Player extends StatelessWidget {
  const _Player({required this.c, required this.proporcao});

  final VideoPlayerController c;
  final double proporcao;

  static String _tempo(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: proporcao,
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
                        '${_tempo(v.position)} / ${_tempo(v.duration)}',
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
