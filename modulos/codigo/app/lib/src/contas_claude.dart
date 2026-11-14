import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api_codigo.dart';

/// Contas do Claude Code no PC: trocar a ativa quando uma bate o limite da janela, sem logout/login
/// no terminal. A troca vale para os próximos pedidos (os que já estão rodando seguem na anterior).
Future<void> mostrarContasClaude(BuildContext context, ApiCodigo api) =>
    showDialog<void>(context: context, builder: (_) => _ContasDialogo(api));

class _ContasDialogo extends StatefulWidget {
  const _ContasDialogo(this.api);

  final ApiCodigo api;

  @override
  State<_ContasDialogo> createState() => _ContasDialogoState();
}

class _ContasDialogoState extends State<_ContasDialogo> {
  Map<String, dynamic>? _dados;
  String? _erro;
  bool _ocupado = false;

  @override
  void initState() {
    super.initState();
    _rodar(widget.api.contas);
  }

  Future<void> _rodar(Future<Map<String, dynamic>> Function() acao) async {
    setState(() {
      _ocupado = true;
      _erro = null;
    });
    try {
      final dados = await acao();
      if (mounted) setState(() => _dados = dados);
    } catch (e) {
      if (mounted) setState(() => _erro = '$e');
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  /// Login: o PC devolve o link, a pessoa autoriza no navegador e cola o código mostrado lá.
  Future<void> _entrar([String? nome]) async {
    nome ??= await _pedirTexto('Nova conta', 'Nome (ex.: trabalho)');
    if (nome == null || nome.isEmpty || !mounted) return;
    final String url;
    setState(() => _ocupado = true);
    try {
      url = await widget.api.entrarConta(nome);
    } catch (e) {
      if (mounted) {
        setState(() {
          _erro = '$e';
          _ocupado = false;
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => _ocupado = false);
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication).catchError((_) => false);
    if (!mounted) return;
    final codigo = await _pedirTexto(
      'Entrar como "$nome"',
      'Código mostrado depois de autorizar',
      ajuda: 'Autorize no navegador que abriu (entre com a conta desejada) e cole aqui o código.',
      link: url,
    );
    if (codigo == null || codigo.isEmpty) return;
    await _rodar(() => widget.api.codigoConta(nome!, codigo));
  }

  Future<String?> _pedirTexto(String titulo, String rotulo, {String? ajuda, String? link}) {
    final campo = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(titulo),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (ajuda != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(ajuda)),
            if (link != null)
              TextButton.icon(
                onPressed: () => Clipboard.setData(ClipboardData(text: link)),
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copiar link de autorização'),
              ),
            TextField(
              controller: campo,
              autofocus: true,
              decoration: InputDecoration(labelText: rotulo),
              onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, campo.text.trim()), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _remover(String nome) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remover a conta "$nome"?'),
        content: const Text('O login dela sai do PC. Dá para entrar de novo depois.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remover')),
        ],
      ),
    );
    if (ok == true) await _rodar(() => widget.api.removerConta(nome));
  }

  @override
  Widget build(BuildContext context) {
    final ativa = _dados?['ativa'] as String?;
    final contas = [for (final c in (_dados?['contas'] as List?) ?? const []) c as Map<String, dynamic>];
    return AlertDialog(
      title: const Text('Contas do Claude no PC'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_ocupado) const LinearProgressIndicator(),
            if (_erro != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_erro!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            for (final c in contas) _linha(c, c['nome'] == ativa),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _ocupado ? null : _entrar,
          icon: const Icon(Icons.person_add_alt),
          label: const Text('Adicionar conta'),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar')),
      ],
    );
  }

  Widget _linha(Map<String, dynamic> c, bool ativa) {
    final nome = c['nome'] as String;
    final logado = c['logado'] == true;
    final email = c['email'] as String? ?? '';
    final plano = c['plano'] as String? ?? '';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(ativa ? Icons.radio_button_checked : Icons.radio_button_unchecked),
      title: Text(nome == 'principal' ? 'principal (a do terminal)' : nome),
      subtitle: Text(logado ? [email, if (plano.isNotEmpty) plano].join(' · ') : 'não logada'),
      onTap: _ocupado || ativa || !logado ? null : () => _rodar(() => widget.api.ativarConta(nome)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: logado ? 'Entrar de novo' : 'Entrar',
            onPressed: _ocupado ? null : () => _entrar(nome),
            icon: const Icon(Icons.login),
          ),
          if (nome != 'principal')
            IconButton(
              tooltip: 'Remover',
              onPressed: _ocupado ? null : () => _remover(nome),
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
    );
  }
}
