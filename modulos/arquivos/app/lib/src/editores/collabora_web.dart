import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';

/// Iframe (`srcdoc` com o formulário WOPI) dentro do app web. O Collabora fala com a janela do
/// app por postMessage (o backend devolve a origem do app em `PostMessageOrigin`).
Widget iframeCollabora(String html, {required VoidCallback aoFechar}) =>
    _IframeCollabora(html: html, aoFechar: aoFechar);

int _seq = 0;

class _IframeCollabora extends StatefulWidget {
  const _IframeCollabora({required this.html, required this.aoFechar});

  final String html;
  final VoidCallback aoFechar;

  @override
  State<_IframeCollabora> createState() => _IframeCollaboraState();
}

class _IframeCollaboraState extends State<_IframeCollabora> {
  final _tipo = 'collabora-${_seq++}';
  JSObject? _iframe;
  late final JSFunction _ouvinte = _aoMensagem.toJS;

  @override
  void initState() {
    super.initState();
    ui_web.platformViewRegistry.registerViewFactory(_tipo, (int _) {
      final documento = globalContext['document'] as JSObject;
      final iframe = documento.callMethod<JSObject>('createElement'.toJS, 'iframe'.toJS);
      iframe['srcdoc'] = widget.html.toJS;
      iframe['allow'] = 'clipboard-read; clipboard-write; fullscreen'.toJS;
      final estilo = iframe['style'] as JSObject;
      estilo['border'] = 'none'.toJS;
      estilo['width'] = '100%'.toJS;
      estilo['height'] = '100%'.toJS;
      return _iframe = iframe;
    });
    globalContext.callMethod<JSAny?>('addEventListener'.toJS, 'message'.toJS, _ouvinte);
  }

  @override
  void dispose() {
    globalContext.callMethod<JSAny?>('removeEventListener'.toJS, 'message'.toJS, _ouvinte);
    super.dispose();
  }

  void _aoMensagem(JSObject evento) {
    final janela = _iframe?['contentWindow'];
    final dados = evento['data'];
    // Só mensagens do nosso iframe, em texto JSON (formato do Collabora).
    if (janela == null || evento['source'] != janela || dados == null || !dados.isA<JSString>()) return;
    final Object? msg;
    try {
      msg = jsonDecode((dados as JSString).toDart);
    } on FormatException {
      return;
    }
    if (msg is! Map) return;
    final valores = msg['Values'];
    if (msg['MessageId'] == 'App_LoadingStatus' && valores is Map && valores['Status'] == 'Frame_Ready') {
      // Avisa o Collabora que o app ouve as mensagens (necessário para o UI_Close).
      (janela as JSObject).callMethod<JSAny?>(
        'postMessage'.toJS,
        jsonEncode({'MessageId': 'Host_PostmessageReady', 'SendTime': DateTime.now().millisecondsSinceEpoch}).toJS,
        evento['origin'],
      );
    } else if (msg['MessageId'] == 'UI_Close') {
      widget.aoFechar();
    }
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(viewType: _tipo);
}
