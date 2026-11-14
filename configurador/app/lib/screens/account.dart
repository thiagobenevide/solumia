import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../l10n/app_text.dart';
import '../core.dart';
import '../theme.dart';
import '../plan.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, required this.core});
  final Core core;
  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _user = TextEditingController(text: 'admin');
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _code = TextEditingController();
  String? _totpUri;
  bool? _codeOk;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    widget.core.manifest().then((m) {
      if (mounted) _user.text = (m['conta'] as Map)['usuario'] as String;
    });
  }

  Future<void> _save() async {
    if (_password.text != _confirm.text) {
      notify(context, AppText.of(context).passwordsDoNotMatch, error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      final r = await widget.core.post('/conta', {'usuario': _user.text.trim(), 'senha': _password.text});
      _password.clear();
      _confirm.clear();
      setState(() => _totpUri = r['totp_uri'] as String?);
      if (mounted) notify(context, AppText.of(context).accountSaved);
    } on CoreError catch (e) {
      if (mounted) notify(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _check() async {
    final r = await widget.core.post('/conta/totp/conferir', {'codigo': _code.text.trim()});
    setState(() => _codeOk = r['ok'] as bool);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppText.of(context);
    final colors = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.all(24), children: [
      Text(t.accountTitle, style: Theme.of(context).textTheme.headlineSmall),
      Text(t.accountDescription),
      const SizedBox(height: 16),
      SizedBox(
        width: 420,
        child: Column(children: [
          TextField(controller: _user, decoration: InputDecoration(labelText: t.user)),
          TextField(
              controller: _password,
              obscureText: true,
              decoration: InputDecoration(labelText: t.password, helperText: t.passwordHelp)),
          TextField(controller: _confirm, obscureText: true, decoration: InputDecoration(labelText: t.confirmPassword)),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(onPressed: _saving ? null : _save, child: Text(t.saveAccount)),
          ),
        ]),
      ),
      if (_totpUri != null) ...[
        const Divider(height: 40),
        Text(t.qrInstruction),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.all(12),
            child: QrImageView(data: _totpUri!, size: 220),
          ),
        ),
        SizedBox(
          width: 260,
          child: Row(children: [
            Expanded(
                child: TextField(
                    controller: _code,
                    maxLength: 6,
                    decoration: InputDecoration(labelText: t.code6))),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: _check, child: Text(t.check)),
          ]),
        ),
        if (_codeOk != null)
          Text(_codeOk! ? t.totpOk : t.totpFailed,
              style: TextStyle(color: _codeOk! ? colors.success : colors.error)),
      ],
    ]);
  }
}
