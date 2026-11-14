import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Quem abre telas em abas: o app envolve as telas com este widget fora do celular. Sem ele
/// (celular, testes), [abrirTela] empilha a tela como antes.
class AbridorAbas extends InheritedWidget {
  const AbridorAbas({super.key, required this.abrir, required super.child});

  /// Abre [tela] numa aba nova ao lado da atual; completa com o resultado do `Navigator.pop` da
  /// tela ou `null` quando a aba é fechada.
  final Future<Object?> Function(String? titulo, IconData? icone, WidgetBuilder tela) abrir;

  @override
  bool updateShouldNotify(AbridorAbas oldWidget) => abrir != oldWidget.abrir;
}

/// Abre uma tela (detalhe, leitor, editor...) numa aba; no celular, por cima do módulo.
/// `Navigator.pop(context, valor)` dentro da tela fecha a aba e devolve [valor].
Future<T?> abrirTela<T>(BuildContext context, WidgetBuilder tela, {String? titulo, IconData? icone}) async {
  final abas = context.getInheritedWidgetOfExactType<AbridorAbas>();
  if (abas == null) return Navigator.of(context).push<T>(MaterialPageRoute(builder: tela));
  final r = await abas.abrir(titulo, icone, tela);
  return r is T ? r : null;
}

/// Abre um link numa aba: PDF no leitor do app, página web no WebView (Android/iOS). No desktop,
/// que não tem WebView, a página vai para o navegador do sistema.
Future<void> abrirLink(BuildContext context, String url) async {
  final texto = url.trim();
  final u = Uri.parse(texto.startsWith('http') ? texto : 'https://$texto');
  final nome = u.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? u.host;
  if (nome.toLowerCase().endsWith('.pdf')) {
    await abrirTela<void>(
      context,
      titulo: Uri.decodeComponent(nome),
      icone: Icons.picture_as_pdf_outlined,
      (_) => Scaffold(
        appBar: AppBar(title: Text(Uri.decodeComponent(nome)), actions: [_BotaoNavegador(u)]),
        body: PdfViewer.uri(u),
      ),
    );
    return;
  }
  if (Platform.isAndroid || Platform.isIOS) {
    await abrirTela<void>(
      context,
      titulo: u.host,
      icone: Icons.public,
      (_) => _PaginaWeb(url: u),
    );
    return;
  }
  if (!await _noNavegador(u) && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Não consegui abrir $u')));
  }
}

Future<bool> _noNavegador(Uri u) async {
  // Sem app que aceite o link (ou recusa do sistema), tenta o navegador embutido antes de desistir.
  for (final modo in [LaunchMode.externalApplication, LaunchMode.inAppBrowserView, LaunchMode.platformDefault]) {
    try {
      if (await launchUrl(u, mode: modo)) return true;
    } catch (_) {}
  }
  return false;
}

class _BotaoNavegador extends StatelessWidget {
  const _BotaoNavegador(this.url);

  final Uri url;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Abrir no navegador',
    icon: const Icon(Icons.open_in_browser),
    onPressed: () => _noNavegador(url),
  );
}

class _PaginaWeb extends StatefulWidget {
  const _PaginaWeb({required this.url});

  final Uri url;

  @override
  State<_PaginaWeb> createState() => _PaginaWebState();
}

class _PaginaWebState extends State<_PaginaWeb> {
  late final _web = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setNavigationDelegate(NavigationDelegate(onPageFinished: (_) => _titulo()))
    ..loadRequest(widget.url);
  String? _nome;

  Future<void> _titulo() async {
    final t = await _web.getTitle();
    if (mounted && t != null && t.isNotEmpty) setState(() => _nome = t);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    // voltar navega dentro da página antes de fechar a aba
    canPop: false,
    onPopInvokedWithResult: (saiu, _) async {
      if (saiu) return;
      final nav = Navigator.of(context);
      if (await _web.canGoBack()) return _web.goBack();
      nav.pop();
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(_nome ?? widget.url.host, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(tooltip: 'Recarregar', icon: const Icon(Icons.refresh), onPressed: _web.reload),
          _BotaoNavegador(widget.url),
        ],
      ),
      body: WebViewWidget(controller: _web),
    ),
  );
}
