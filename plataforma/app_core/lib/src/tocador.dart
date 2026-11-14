import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

import 'tocador_web.dart' if (dart.library.io) 'tocador_io.dart';

/// Toca a fala que veio do servidor em bytes (m4a ou wav do worker) e conta a posição, para quem
/// acompanha palavra por palavra (leitura guiada).
class Tocador {
  final _player = AudioPlayer();

  Stream<Duration> get posicao => _player.onPositionChanged;
  Stream<void> get terminou => _player.onPlayerComplete;

  Future<void> tocar(Uint8List bytes, String mime) async {
    await _player.stop();
    await _player.play(await fonteDe(bytes, mime));
  }

  Future<void> pausar() => _player.pause();
  Future<void> retomar() => _player.resume();
  Future<void> parar() => _player.stop();
  Future<Duration?> agora() => _player.getCurrentPosition();
  Future<void> dispose() => _player.dispose();
}
