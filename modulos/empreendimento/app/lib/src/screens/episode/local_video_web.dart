import 'package:video_player/video_player.dart';

VideoPlayerController localController(String caminho) => VideoPlayerController.networkUrl(Uri.parse(caminho));
