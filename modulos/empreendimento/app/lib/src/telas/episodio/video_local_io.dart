import 'dart:io';

import 'package:video_player/video_player.dart';

VideoPlayerController controladorLocal(String caminho) => VideoPlayerController.file(File(caminho));
