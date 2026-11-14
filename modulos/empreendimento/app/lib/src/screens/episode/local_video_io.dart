import 'dart:io';

import 'package:video_player/video_player.dart';

VideoPlayerController localController(String caminho) => VideoPlayerController.file(File(caminho));
