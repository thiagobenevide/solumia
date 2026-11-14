import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../files_api.dart';
import '../models.dart';
import 'collabora_web_stub.dart' if (dart.library.js_interop) 'collabora_web.dart';

/// Full-fidelity editing (DOCX/XLSX/PPTX, ODF, DOC/XLS/PPT) in Collabora Online through WOPI.
/// Collabora saves to the backend on its own (PutFile); on closing there is nothing to do, the grid
/// atualiza pela sondagem. Web: iframe; Android/iOS/macOS: webview; Linux/Windows: navegador.
class CollaboraScreen extends StatefulWidget {
  const CollaboraScreen({super.key, required this.api, required this.file});

  final FilesApi api;
  final FileItem file;

  @override
  State<CollaboraScreen> createState() => _CollaboraScreenState();
}

enum _Mode { iframe, webview, browser }

class _CollaboraScreenState extends State<CollaboraScreen> {
  late final Future<({Uri url, String token, int ttl})> _session = widget.api.collaboraSession(widget.file.id);
  WebViewController? _webview;
  Widget? _iframe;

  static _Mode get _mode {
    if (kIsWeb) return _Mode.iframe;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.macOS => _Mode.webview,
      _ => _Mode.browser,
    };
  }

  /// Page served by the backend that POSTs the token (for the system browser).
  /// Derived from the thumbnail URL to inherit the API base (with or without a path prefix).
  Uri _openUrl(String token) => widget.api
      .thumbnailUrl(widget.file)
      .resolve('../../../wopi/abrir/${widget.file.id}')
      .replace(queryParameters: {'t': token});

  Future<void> _openInBrowser(String token) async {
    final ok = await launchUrl(_openUrl(token), mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Não consegui abrir o navegador')));
    }
  }

  Widget _content(({Uri url, String token, int ttl}) s) {
    final html = wopiForm(s.url, s.token, s.ttl, widget.file.nomeOriginal);
    switch (_mode) {
      case _Mode.iframe:
        return _iframe ??= collaboraIframe(html, onClose: () {
          if (mounted) Navigator.of(context).maybePop();
        });
      case _Mode.webview:
        _webview ??= WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..loadHtmlString(html);
        return WebViewWidget(controller: _webview!);
      case _Mode.browser:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.open_in_browser, size: 48),
                const SizedBox(height: 16),
                const Text(
                  'Nesta plataforma o app não tem navegador embutido. O documento abre no Collabora '
                  'pelo navegador do sistema; cada alteração é salva sozinha na biblioteca.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => _openInBrowser(s.token),
                  icon: const Icon(Icons.edit_document),
                  label: const Text('Abrir no navegador'),
                ),
              ],
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.file.title)),
    body: FutureBuilder(
      future: _session,
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Não foi possível abrir no Collabora: ${snap.error}', textAlign: TextAlign.center),
            ),
          );
        }
        final s = snap.data;
        return s == null ? const Center(child: CircularProgressIndicator()) : _content(s);
      },
    ),
  );
}

/// HTML with the WOPI form (`access_token`, `access_token_ttl`) that submits itself.
String wopiForm(Uri url, String token, int ttl, String title) {
  const esc = HtmlEscape();
  return '<!doctype html><html><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      '<title>${esc.convert(title)}</title>'
      '<style>html,body{margin:0;height:100%}</style></head><body>'
      '<form id="f" method="post" action="${esc.convert(url.toString())}">'
      '<input type="hidden" name="access_token" value="${esc.convert(token)}">'
      '<input type="hidden" name="access_token_ttl" value="$ttl"></form>'
      '<script>document.getElementById("f").submit()</script></body></html>';
}
