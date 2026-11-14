import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/textos.dart';
import '../nucleo.dart';
import '../plano.dart';

/// Craft Apps: botão de download para cada app, direto do GitHub Releases, com verificação.
class TelaCraftApps extends StatefulWidget {
  const TelaCraftApps({super.key, required this.nucleo});
  final Nucleo nucleo;
  @override
  State<TelaCraftApps> createState() => _TelaCraftAppsEstado();
}

class _TelaCraftAppsEstado extends State<TelaCraftApps> {
  List<Map<String, dynamic>> _apps = [];
  final Map<String, Map<String, dynamic>> _releases = {};
  final Map<String, String> _formatos = {};
  final Map<String, String> _erros = {};
  String? _ocupado;

  List<(String, String)> _opcoesFormato(Textos t) => Platform.isWindows
      ? [('auto', t.formatoPortatil), ('msi', t.formatoMsi)]
      : [('auto', t.formatoAppimage), ('tar.gz', '.tar.gz'), ('deb', t.formatoDeb)];

  static String _descricao(Textos t, String id, String padrao) => switch (id) {
        'filmcraft' => t.craftFilmcraft,
        'soundcraft' => t.craftSoundcraft,
        'effectcraft' => t.craftEffectcraft,
        'photocraft' => t.craftPhotocraft,
        _ => padrao,
      };

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _carregar() async {
    final r = await widget.nucleo.get('/craft-apps') as Map<String, dynamic>;
    setState(() => _apps = (r['apps'] as List).cast<Map<String, dynamic>>());
    for (final a in _apps) {
      final id = a['id'] as String;
      widget.nucleo.get('/craft-apps/$id/release').then((rel) {
        if (mounted) setState(() => _releases[id] = (rel as Map).cast<String, dynamic>());
      }).catchError((Object e) {
        if (mounted) setState(() => _erros[id] = '$e');
      });
    }
  }

  Future<void> _instalar(String id) async {
    setState(() => _ocupado = id);
    try {
      final plano = await widget.nucleo.post('/craft-apps/$id/plano', {
        'versao': 'ultima',
        'formato': _formatos[id] ?? 'auto',
      }) as Map<String, dynamic>;
      if (mounted) await mostrarPlano(context, widget.nucleo, plano);
      await _carregar();
    } on ErroNucleo catch (e) {
      if (mounted) avisar(context, e.mensagem, erro: true);
    } finally {
      if (mounted) setState(() => _ocupado = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final t = Textos.of(context);
    return ListView(padding: const EdgeInsets.all(24), children: [
      Text(t.navCraft, style: tt.headlineSmall),
      Text(t.craftDescricao),
      const SizedBox(height: 16),
      Wrap(spacing: 16, runSpacing: 16, children: [
        for (final a in _apps) _cartao(a, tt, t),
      ]),
    ]);
  }

  Widget _cartao(Map<String, dynamic> a, TextTheme tt, Textos t) {
    final id = a['id'] as String;
    final rel = _releases[id];
    final inst = a['instalado'] as Map<String, dynamic>?;
    final atualizar = inst != null && rel != null && inst['versao'] != rel['versao'];
    return SizedBox(
      width: 360,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(a['nome'] as String, style: tt.titleLarge),
            Text(_descricao(t, id, a['descricao'] as String)),
            const SizedBox(height: 8),
            InkWell(
              onTap: () => launchUrl(Uri.parse(a['github'] as String)),
              child: Text(a['github'] as String,
                  style: TextStyle(decoration: TextDecoration.underline, color: Theme.of(context).colorScheme.primary)),
            ),
            const SizedBox(height: 8),
            Text(rel == null
                ? (_erros[id] ?? t.consultandoVersao)
                : t.ultimaVersao('${rel['versao']}', '${rel['arquivo']}')),
            Text(inst == null ? t.naoInstalado : t.instaladoEm('${inst['versao']}', '${inst['caminho']}'),
                style: tt.bodySmall),
            const SizedBox(height: 8),
            DropdownButton<String>(
              value: _formatos[id] ?? 'auto',
              isExpanded: true,
              items: [for (final (v, r) in _opcoesFormato(t)) DropdownMenuItem(value: v, child: Text(r))],
              onChanged: (v) => setState(() => _formatos[id] = v ?? 'auto'),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _ocupado != null || rel == null || rel['disponivel'] != true ? null : () => _instalar(id),
              icon: const Icon(Icons.download),
              label: Text(inst == null ? t.baixarInstalar : (atualizar ? t.atualizar : t.reinstalar)),
            ),
          ]),
        ),
      ),
    );
  }
}
