import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

Future<Source> fonteDe(Uint8List bytes, String mime) async =>
    UrlSource('data:$mime;base64,${base64Encode(bytes)}', mimeType: mime);
