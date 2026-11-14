import 'package:flutter/widgets.dart';

/// Outside the web there is no iframe; the [CollaboraScreen] uses a webview or the browser.
Widget collaboraIframe(String html, {required VoidCallback onClose}) => const SizedBox.shrink();
