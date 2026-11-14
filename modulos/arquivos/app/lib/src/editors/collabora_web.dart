import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';

/// Iframe (`srcdoc` with the WOPI form) inside the web app. Collabora talks to the app
/// window through postMessage (the backend returns the app origin in `PostMessageOrigin`).
Widget collaboraIframe(String html, {required VoidCallback onClose}) =>
    _CollaboraIframe(html: html, onClose: onClose);

int _seq = 0;

class _CollaboraIframe extends StatefulWidget {
  const _CollaboraIframe({required this.html, required this.onClose});

  final String html;
  final VoidCallback onClose;

  @override
  State<_CollaboraIframe> createState() => _CollaboraIframeState();
}

class _CollaboraIframeState extends State<_CollaboraIframe> {
  final _type = 'collabora-${_seq++}';
  JSObject? _iframe;
  late final JSFunction _listener = _onMessage.toJS;

  @override
  void initState() {
    super.initState();
    ui_web.platformViewRegistry.registerViewFactory(_type, (int _) {
      final documentItem = globalContext['document'] as JSObject;
      final iframe = documentItem.callMethod<JSObject>('createElement'.toJS, 'iframe'.toJS);
      iframe['srcdoc'] = widget.html.toJS;
      iframe['allow'] = 'clipboard-read; clipboard-write; fullscreen'.toJS;
      final estilo = iframe['style'] as JSObject;
      estilo['border'] = 'none'.toJS;
      estilo['width'] = '100%'.toJS;
      estilo['height'] = '100%'.toJS;
      return _iframe = iframe;
    });
    globalContext.callMethod<JSAny?>('addEventListener'.toJS, 'message'.toJS, _listener);
  }

  @override
  void dispose() {
    globalContext.callMethod<JSAny?>('removeEventListener'.toJS, 'message'.toJS, _listener);
    super.dispose();
  }

  void _onMessage(JSObject event) {
    final window = _iframe?['contentWindow'];
    final data = event['data'];
    // Only messages from our iframe, as JSON text (Collabora format).
    if (window == null || event['source'] != window || data == null || !data.isA<JSString>()) return;
    final Object? msg;
    try {
      msg = jsonDecode((data as JSString).toDart);
    } on FormatException {
      return;
    }
    if (msg is! Map) return;
    final valueList = msg['Values'];
    if (msg['MessageId'] == 'App_LoadingStatus' && valueList is Map && valueList['Status'] == 'Frame_Ready') {
      // Tells Collabora the app listens to the messages (needed for UI_Close).
      (window as JSObject).callMethod<JSAny?>(
        'postMessage'.toJS,
        jsonEncode({'MessageId': 'Host_PostmessageReady', 'SendTime': DateTime.now().millisecondsSinceEpoch}).toJS,
        event['origin'],
      );
    } else if (msg['MessageId'] == 'UI_Close') {
      widget.onClose();
    }
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(viewType: _type);
}
