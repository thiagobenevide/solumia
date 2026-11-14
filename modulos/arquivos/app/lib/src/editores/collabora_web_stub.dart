import 'package:flutter/widgets.dart';

/// Fora da web não há iframe; a [CollaboraTela] usa webview ou o navegador.
Widget iframeCollabora(String html, {required VoidCallback aoFechar}) => const SizedBox.shrink();
