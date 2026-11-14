import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../l10n/textos.dart';
import '../nucleo.dart';
import '../plano.dart';

/// Pastas de mídia deste computador (Linux ou Windows).
class TelaPastas extends StatefulWidget {
  const TelaPastas({super.key, required this.nucleo});
  final Nucleo nucleo;
  @override
  State<TelaPastas> createState() => _TelaPastasEstado();
}

class _TelaPastasEstado extends State<TelaPastas> {
  static const _ordem = ['imagens', 'videos', 'audio', 'producao', 'produzidos'];
  final Map<String, TextEditingController> _c = {for (final k in _ordem) k: TextEditingController()};
  Map<String, List<String>> _erros = {};
  Map<String, List<String>> _avisos = {};
  Map<String, dynamic> _m = {};

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _carregar() async {
    final padrao = await widget.nucleo.get('/pastas/padrao') as Map<String, dynamic>;
    final m = await widget.nucleo.manifesto();
    final salvas = ((m['nos'] as Map)['casa'] as Map?)?['pastas'] as Map?;
    setState(() {
      _m = m;
      for (final k in _ordem) {
        final v = (salvas?[k] as String?) ?? '';
        _c[k]!.text = v.isNotEmpty ? v : (padrao['pastas'] as Map)[k] as String;
      }
    });
  }

  Map<String, String> get _pastas => {for (final k in _ordem) k: _c[k]!.text.trim()};

  Future<bool> _validar() async {
    final r = await widget.nucleo.post('/pastas/validar', {'pastas': _pastas}) as Map<String, dynamic>;
    setState(() {
      _erros = (r['erros'] as Map).map((k, v) => MapEntry(k as String, (v as List).cast<String>()));
      _avisos = (r['avisos'] as Map).map((k, v) => MapEntry(k as String, (v as List).cast<String>()));
    });
    return r['ok'] as bool;
  }

  Future<void> _escolher(String chave) async {
    final atual = _c[chave]!.text;
    final inicial = Directory(atual).existsSync() ? atual : null;
    final escolhida = await getDirectoryPath(initialDirectory: inicial, confirmButtonText: Textos.of(context).usarEstaPasta);
    if (escolhida != null) setState(() => _c[chave]!.text = escolhida);
  }

  Future<void> _salvarECriar() async {
    if (!await _validar()) {
      if (mounted) avisar(context, Textos.of(context).corrijaPastas, erro: true);
      return;
    }
    try {
      final m = Map<String, dynamic>.from(_m);
      final nos = Map<String, dynamic>.from(m['nos'] as Map);
      final casa = Map<String, dynamic>.from((nos['casa'] as Map?) ?? {'endereco': 'local', 'papeis': <String>[]});
      casa['pastas'] = _pastas;
      nos['casa'] = casa;
      m['nos'] = nos;
      _m = await widget.nucleo.salvarManifesto(m);
      final plano = await widget.nucleo.post('/pastas/casa/plano') as Map<String, dynamic>;
      if (mounted) await mostrarPlano(context, widget.nucleo, plano);
      await _validar();
    } on ErroNucleo catch (e) {
      if (mounted) avisar(context, e.mensagem, erro: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Textos.of(context);
    final rotulos = {
      'imagens': (t.pastaImagens, t.ajudaImagens),
      'videos': (t.pastaVideos, t.ajudaVideos),
      'audio': (t.pastaAudio, t.ajudaAudio),
      'producao': (t.pastaProducao, t.ajudaProducao),
      'produzidos': (t.pastaProduzidos, t.ajudaProduzidos),
    };
    return ListView(padding: const EdgeInsets.all(24), children: [
      Text(t.pastasTitulo, style: Theme.of(context).textTheme.headlineSmall),
      Text(t.pastasDescricao(Platform.isWindows ? 'Windows' : 'Linux')),
      const SizedBox(height: 16),
      for (final k in _ordem)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: TextField(
                controller: _c[k],
                decoration: InputDecoration(
                  labelText: rotulos[k]!.$1,
                  helperText: _avisos[k]?.join('; ') ?? rotulos[k]!.$2,
                  errorText: _erros[k]?.join('; '),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: IconButton.outlined(
                tooltip: t.escolherPasta,
                onPressed: () => _escolher(k),
                icon: const Icon(Icons.folder_open),
              ),
            ),
          ]),
        ),
      const SizedBox(height: 12),
      Row(children: [
        OutlinedButton(onPressed: _validar, child: Text(t.validar)),
        const SizedBox(width: 12),
        FilledButton(onPressed: _salvarECriar, child: Text(t.salvarECriar)),
      ]),
    ]);
  }
}
