import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

int _vez = 0;

/// Arquivo temporário (o tocador nativo do Linux/Windows não toca bytes); três nomes em rodízio.
Future<Source> fonteDe(Uint8List bytes, String mime) async {
  final ext = mime.contains('wav') ? 'wav' : 'm4a';
  final arquivo = File('${Directory.systemTemp.path}/agent_fala_${_vez++ % 3}.$ext');
  await arquivo.writeAsBytes(bytes, flush: true);
  return DeviceFileSource(arquivo.path, mimeType: mime);
}
