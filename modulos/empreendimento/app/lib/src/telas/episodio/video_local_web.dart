import 'package:video_player/video_player.dart';

VideoPlayerController controladorLocal(String caminho) => VideoPlayerController.networkUrl(Uri.parse(caminho));
