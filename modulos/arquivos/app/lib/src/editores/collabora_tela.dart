import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../api_arquivos.dart';
import '../modelos.dart';
import 'collabora_web_stub.dart' if (dart.library.js_interop) 'collabora_web.dart';

/// Edição com fidelidade total (DOCX/XLSX/PPTX, ODF, DOC/XLS/PPT) no Collabora Online por WOPI.
/// O Collabora salva sozinho no backend (PutFile); ao fechar não há nada a fazer, a grade
/// atualiza pela sondagem. Web: iframe; Android/iOS/macOS: webview; Linux/Windows: navegador.
class CollaboraTela extends StatefulWidget {
  const CollaboraTela({super.key, required this.api, required this.arquivo});

  final ApiArquivos api;
  final Arquivo arquivo;

  @override
  State<CollaboraTela> createState() => _CollaboraTelaState();
}

enum _Modo { iframe, webview, navegador }

class _CollaboraTelaState extends State<CollaboraTela> {
  late final Future<({Uri url, String token, int ttl})> _sessao = widget.api.sessaoCollabora(widget.arquivo.id);
  WebViewController? _webview;
  Widget? _iframe;

  static _Modo get _modo {
    if (kIsWeb) return _Modo.iframe;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.macOS => _Modo.webview,
      _ => _Modo.navegador,
    };
  }

  /// Página servida pelo backend que faz o POST do token (para o navegador do sistema).
  /// Sai da URL da miniatura para herdar a base da API (com ou sem prefixo de caminho).
  Uri _urlAbrir(String token) => widget.api
      .urlMiniatura(widget.arquivo)
      .resolve('../../../wopi/abrir/${widget.arquivo.id}')
      .replace(queryParameters: {'t': token});

  Future<void> _abrirNoNavegador(String token) async {
    final ok = await launchUrl(_urlAbrir(token), mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Não consegui abrir o navegador')));
    }
  }

  Widget _conteudo(({Uri url, String token, int ttl}) s) {
    final html = formularioWopi(s.url, s.token, s.ttl, widget.arquivo.nomeOriginal);
    switch (_modo) {
      case _Modo.iframe:
        return _iframe ??= iframeCollabora(html, aoFechar: () {
          if (mounted) Navigator.of(context).maybePop();
        });
      case _Modo.webview:
        _webview ??= WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..loadHtmlString(html);
        return WebViewWidget(controller: _webview!);
      case _Modo.navegador:
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
                  onPressed: () => _abrirNoNavegador(s.token),
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
    appBar: AppBar(title: Text(widget.arquivo.titulo)),
    body: FutureBuilder(
      future: _sessao,
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
        return s == null ? const Center(child: CircularProgressIndicator()) : _conteudo(s);
      },
    ),
  );
}

/// HTML com o formulário WOPI (`access_token`, `access_token_ttl`) que se envia sozinho.
String formularioWopi(Uri url, String token, int ttl, String titulo) {
  const esc = HtmlEscape();
  return '<!doctype html><html><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      '<title>${esc.convert(titulo)}</title>'
      '<style>html,body{margin:0;height:100%}</style></head><body>'
      '<form id="f" method="post" action="${esc.convert(url.toString())}">'
      '<input type="hidden" name="access_token" value="${esc.convert(token)}">'
      '<input type="hidden" name="access_token_ttl" value="$ttl"></form>'
      '<script>document.getElementById("f").submit()</script></body></html>';
}
