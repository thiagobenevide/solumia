import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'code_api.dart';

/// Claude Code accounts on the PC: switch the active one when one hits the window limit, without logout/login
/// in the terminal. The switch applies to the next requests (those already running keep the previous one).
Future<void> showClaudeAccounts(BuildContext context, CodeApi api) =>
    showDialog<void>(context: context, builder: (_) => _AccountsDialog(api));

class _AccountsDialog extends StatefulWidget {
  const _AccountsDialog(this.api);

  final CodeApi api;

  @override
  State<_AccountsDialog> createState() => _AccountsDialogState();
}

class _AccountsDialogState extends State<_AccountsDialog> {
  Map<String, dynamic>? _dados;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _run(widget.api.accounts);
  }

  Future<void> _run(Future<Map<String, dynamic>> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data = await action();
      if (mounted) setState(() => _dados = data);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Login: the PC returns the link, the person authorizes in the browser and pastes the code shown there.
  Future<void> _signIn([String? name]) async {
    name ??= await _askText('Nova conta', 'Nome (ex.: trabalho)');
    if (name == null || name.isEmpty || !mounted) return;
    final String url;
    setState(() => _busy = true);
    try {
      url = await widget.api.signInAccount(name);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _busy = false;
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication).catchError((_) => false);
    if (!mounted) return;
    final code = await _askText(
      'Entrar como "$name"',
      'Código mostrado depois de autorizar',
      help: 'Autorize no navegador que abriu (entre com a conta desejada) e cole aqui o código.',
      link: url,
    );
    if (code == null || code.isEmpty) return;
    await _run(() => widget.api.accountCode(name!, code));
  }

  Future<String?> _askText(String title, String label, {String? help, String? link}) {
    final input = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (help != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(help)),
            if (link != null)
              TextButton.icon(
                onPressed: () => Clipboard.setData(ClipboardData(text: link)),
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copiar link de autorização'),
              ),
            TextField(
              controller: input,
              autofocus: true,
              decoration: InputDecoration(labelText: label),
              onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, input.text.trim()), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _remover(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remover a conta "$name"?'),
        content: const Text('O login dela sai do PC. Dá para entrar de novo depois.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remover')),
        ],
      ),
    );
    if (ok == true) await _run(() => widget.api.removeAccount(name));
  }

  @override
  Widget build(BuildContext context) {
    final active = _dados?['ativa'] as String?;
    final accounts = [for (final c in (_dados?['contas'] as List?) ?? const []) c as Map<String, dynamic>];
    return AlertDialog(
      title: const Text('Contas do Claude no PC'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            for (final c in accounts) _line(c, c['nome'] == active),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _busy ? null : _signIn,
          icon: const Icon(Icons.person_add_alt),
          label: const Text('Adicionar conta'),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar')),
      ],
    );
  }

  Widget _line(Map<String, dynamic> c, bool active) {
    final name = c['nome'] as String;
    final signedIn = c['logado'] == true;
    final email = c['email'] as String? ?? '';
    final plan = c['plano'] as String? ?? '';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(active ? Icons.radio_button_checked : Icons.radio_button_unchecked),
      title: Text(name == 'principal' ? 'principal (a do terminal)' : name),
      subtitle: Text(signedIn ? [email, if (plan.isNotEmpty) plan].join(' · ') : 'não logada'),
      onTap: _busy || active || !signedIn ? null : () => _run(() => widget.api.activateAccount(name)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: signedIn ? 'Entrar de novo' : 'Entrar',
            onPressed: _busy ? null : () => _signIn(name),
            icon: const Icon(Icons.login),
          ),
          if (name != 'principal')
            IconButton(
              tooltip: 'Remover',
              onPressed: _busy ? null : () => _remover(name),
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
    );
  }
}
