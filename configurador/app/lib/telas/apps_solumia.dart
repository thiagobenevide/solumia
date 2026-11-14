import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/textos.dart';
import '../nucleo.dart';
import '../plano.dart';

/// Apps do Solumia para celular/tablet, relógio, PC e notebook (GitHub Releases, com verificação).
class TelaAppsSolumia extends StatefulWidget {
  const TelaAppsSolumia({super.key, required this.nucleo});
  final Nucleo nucleo;
  @override
  State<TelaAppsSolumia> createState() => _TelaAppsSolumiaEstado();
}

class _TelaAppsSolumiaEstado extends State<TelaAppsSolumia> {
  Map<String, dynamic>? _dados;
  String? _erro;
  String? _ocupado;
  final Set<String> _qr = {};

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _carregar() async {
    try {
      final r = await widget.nucleo.get('/apps-solumia') as Map<String, dynamic>;
      if (mounted) setState(() => _dados = r);
    } on ErroNucleo catch (e) {
      if (mounted) setState(() => _erro = e.mensagem);
    }
  }

  Future<void> _baixar(String id, {required bool instalar}) async {
    setState(() => _ocupado = id);
    try {
      final plano = await widget.nucleo.post('/apps-solumia/$id/plano', {'versao': 'ultima', 'instalar': instalar})
          as Map<String, dynamic>;
      if (mounted) await mostrarPlano(context, widget.nucleo, plano);
    } on ErroNucleo catch (e) {
      if (mounted) avisar(context, e.mensagem, erro: true);
    } finally {
      if (mounted) setState(() => _ocupado = null);
    }
  }

  (IconData, String, String) _info(Textos t, String id) => switch (id) {
        'android' => (Icons.phone_android, t.appCelular, t.appCelularDetalhe),
        'wear' => (Icons.watch, t.appRelogio, t.appRelogioDetalhe),
        'linux' => (Icons.laptop, t.appLinux, t.appLinuxDetalhe),
        'windows' => (Icons.desktop_windows, t.appWindows, t.appWindowsDetalhe),
        _ => (Icons.apps, id, ''),
      };

  @override
  Widget build(BuildContext context) {
    final t = Textos.of(context);
    final tema = Theme.of(context);
    final d = _dados;
    if (d == null) {
      return Center(child: _erro == null ? const CircularProgressIndicator() : Text(_erro!));
    }
    final assinada = d['assinatura_fixada'] == true;
    final apps = (d['apps'] as List).cast<Map<String, dynamic>>();
    return RefreshIndicator(
      onRefresh: _carregar,
      child: ListView(padding: const EdgeInsets.all(24), children: [
        Text(t.appsTitulo, style: tema.textTheme.headlineSmall),
        Text(t.appsDescricao),
        const SizedBox(height: 8),
        Wrap(spacing: 16, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(d['versao'] == null ? t.appsSemRelease : t.appsVersao('${d['versao']}'),
              style: tema.textTheme.titleSmall),
          TextButton.icon(
            onPressed: () => launchUrl(Uri.parse(d['releases'] as String)),
            icon: const Icon(Icons.open_in_new),
            label: Text(t.abrirReleases),
          ),
        ]),
        if (!assinada)
          Card(
            color: tema.colorScheme.errorContainer,
            child: ListTile(
              leading: Icon(Icons.lock, color: tema.colorScheme.onErrorContainer),
              title: Text(t.appsSemAssinatura, style: TextStyle(color: tema.colorScheme.onErrorContainer)),
            ),
          ),
        Text(t.appsPasta('${d['pasta']}'), style: tema.textTheme.bodySmall),
        const SizedBox(height: 16),
        Wrap(spacing: 16, runSpacing: 16, children: [
          for (final a in apps) _cartao(a, t, tema, assinada),
        ]),
      ]),
    );
  }

  Widget _cartao(Map<String, dynamic> a, Textos t, ThemeData tema, bool assinada) {
    final id = a['id'] as String;
    final (icone, titulo, detalhe) = _info(t, id);
    final url = a['url'] as String?;
    final pode = assinada && url != null && _ocupado == null;
    final celular = id == 'android';
    return SizedBox(
      width: 340,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CircleAvatar(
                backgroundColor: tema.colorScheme.primaryContainer,
                foregroundColor: tema.colorScheme.onPrimaryContainer,
                child: Icon(icone),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(titulo, style: tema.textTheme.titleMedium),
                  Text(detalhe, style: tema.textTheme.bodySmall),
                ]),
              ),
            ]),
            const SizedBox(height: 12),
            Text(url == null ? t.arquivoIndisponivel : '${a['arquivo']}',
                style: tema.textTheme.bodySmall),
            if (id == 'wear') Text(t.relogioInstrucao, style: tema.textTheme.bodySmall),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (a['instala_aqui'] == true)
                FilledButton.icon(
                  onPressed: pode ? () => _baixar(id, instalar: true) : null,
                  icon: const Icon(Icons.install_desktop),
                  label: Text(t.instalarNestePc),
                ),
              OutlinedButton.icon(
                onPressed: pode ? () => _baixar(id, instalar: false) : null,
                icon: const Icon(Icons.download),
                label: Text(t.baixarParaEstePc),
              ),
              if (celular)
                OutlinedButton.icon(
                  onPressed: url == null ? null : () => setState(() => _qr.contains(id) ? _qr.remove(id) : _qr.add(id)),
                  icon: const Icon(Icons.qr_code),
                  label: Text(t.mostrarQr),
                ),
            ]),
            if (celular && url != null && _qr.contains(id)) ...[
              const SizedBox(height: 12),
              Container(
                color: Colors.white, // QR precisa de fundo claro nos dois temas
                padding: const EdgeInsets.all(8),
                child: QrImageView(data: url, size: 180),
              ),
              const SizedBox(height: 4),
              Text(t.qrCelular, style: tema.textTheme.bodySmall),
            ],
          ]),
        ),
      ),
    );
  }
}
