import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../l10n/textos.dart';
import '../nucleo.dart';
import '../tema.dart';
import '../plano.dart';

class TelaConta extends StatefulWidget {
  const TelaConta({super.key, required this.nucleo});
  final Nucleo nucleo;
  @override
  State<TelaConta> createState() => _TelaContaEstado();
}

class _TelaContaEstado extends State<TelaConta> {
  final _usuario = TextEditingController(text: 'admin');
  final _senha = TextEditingController();
  final _confirma = TextEditingController();
  final _codigo = TextEditingController();
  String? _uriTotp;
  bool? _codigoOk;
  bool _salvando = false;

  @override
  void initState() {
    super.initState();
    widget.nucleo.manifesto().then((m) {
      if (mounted) _usuario.text = (m['conta'] as Map)['usuario'] as String;
    });
  }

  Future<void> _salvar() async {
    if (_senha.text != _confirma.text) {
      avisar(context, Textos.of(context).senhasNaoConferem, erro: true);
      return;
    }
    setState(() => _salvando = true);
    try {
      final r = await widget.nucleo.post('/conta', {'usuario': _usuario.text.trim(), 'senha': _senha.text});
      _senha.clear();
      _confirma.clear();
      setState(() => _uriTotp = r['totp_uri'] as String?);
      if (mounted) avisar(context, Textos.of(context).contaSalva);
    } on ErroNucleo catch (e) {
      if (mounted) avisar(context, e.mensagem, erro: true);
    } finally {
      if (mounted) setState(() => _salvando = false);
    }
  }

  Future<void> _conferir() async {
    final r = await widget.nucleo.post('/conta/totp/conferir', {'codigo': _codigo.text.trim()});
    setState(() => _codigoOk = r['ok'] as bool);
  }

  @override
  Widget build(BuildContext context) {
    final t = Textos.of(context);
    final cores = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.all(24), children: [
      Text(t.contaTitulo, style: Theme.of(context).textTheme.headlineSmall),
      Text(t.contaDescricao),
      const SizedBox(height: 16),
      SizedBox(
        width: 420,
        child: Column(children: [
          TextField(controller: _usuario, decoration: InputDecoration(labelText: t.usuario)),
          TextField(
              controller: _senha,
              obscureText: true,
              decoration: InputDecoration(labelText: t.senha, helperText: t.senhaAjuda)),
          TextField(controller: _confirma, obscureText: true, decoration: InputDecoration(labelText: t.confirmarSenha)),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(onPressed: _salvando ? null : _salvar, child: Text(t.salvarConta)),
          ),
        ]),
      ),
      if (_uriTotp != null) ...[
        const Divider(height: 40),
        Text(t.qrInstrucao),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.all(12),
            child: QrImageView(data: _uriTotp!, size: 220),
          ),
        ),
        SizedBox(
          width: 260,
          child: Row(children: [
            Expanded(
                child: TextField(
                    controller: _codigo,
                    maxLength: 6,
                    decoration: InputDecoration(labelText: t.codigo6))),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: _conferir, child: Text(t.conferir)),
          ]),
        ),
        if (_codigoOk != null)
          Text(_codigoOk! ? t.totpOk : t.totpFalhou,
              style: TextStyle(color: _codigoOk! ? cores.sucesso : cores.error)),
      ],
    ]);
  }
}
