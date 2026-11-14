import 'package:flutter/material.dart';

import '../l10n/app_text.dart';
import '../core.dart';
import '../theme.dart';
import '../plan.dart';

/// VPS screen: everything that used to be done in the terminal (instalar_vps, endurecer_vps) happens here.
class VpsScreen extends StatefulWidget {
  const VpsScreen({super.key, required this.core});
  final Core core;
  @override
  State<VpsScreen> createState() => _VpsScreenState();
}

class _VpsScreenState extends State<VpsScreen> {
  final _domain = TextEditingController();
  final _email = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _user = TextEditingController(text: 'root');
  final _password = TextEditingController();
  final _sudoPassword = TextEditingController();
  String _topology = 'hibrida';
  bool _cloudflare = false;
  bool _disablePassword = true;
  String _nginx = 'auto';
  String _savedFingerprint = '';
  Map<String, dynamic>? _readFingerprint;
  bool _busy = false;
  Map<String, dynamic> _m = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _password.clear();
    _sudoPassword.clear();
    super.dispose();
  }

  Future<void> _load() async {
    final m = await widget.core.manifest();
    final t = m['topologia'] as Map<String, dynamic>;
    final vps = (m['nos'] as Map)['vps'] as Map<String, dynamic>?;
    final ssh = vps?['ssh'] as Map<String, dynamic>?;
    setState(() {
      _m = m;
      _topology = t['tipo'] == 'local' ? 'hibrida' : t['tipo'] as String;
      _domain.text = t['dominio'] as String;
      _email.text = t['email_tls'] as String;
      _cloudflare = t['cloudflare'] as bool;
      if (ssh != null) {
        _host.text = ssh['host'] as String;
        _port.text = '${ssh['porta']}';
        _user.text = ssh['usuario'] as String;
        _savedFingerprint = ssh['impressao_host'] as String;
      }
    });
  }

  Map<String, dynamic> _buildManifest({String? fingerprint}) {
    final m = Map<String, dynamic>.from(_m);
    m['topologia'] = {
      ...(m['topologia'] as Map<String, dynamic>),
      'tipo': _topology,
      'dominio': _domain.text.trim(),
      'email_tls': _email.text.trim(),
      'cloudflare': _cloudflare,
    };
    final nodes = Map<String, dynamic>.from(m['nos'] as Map);
    final hostChanged = (nodes['vps']?['ssh']?['host'] ?? '') != _host.text.trim();
    nodes['vps'] = {
      ...((nodes['vps'] as Map<String, dynamic>?) ?? {}),
      'endereco': 'ssh',
      'entrega': 'ssh',
      'ssh': {
        'usuario': _user.text.trim(),
        'host': _host.text.trim(),
        'porta': int.tryParse(_port.text.trim()) ?? 22,
        // New host = the old fingerprint is no longer valid.

        'impressao_host': fingerprint ?? (hostChanged ? '' : _savedFingerprint),
      },
      'papeis': _topology == 'nuvem' ? ['gateway', 'worker', 'collabora'] : ['gateway', 'tunnel', 'collabora'],
    };
    if (_topology == 'hibrida') {
      final home = Map<String, dynamic>.from((nodes['casa'] as Map<String, dynamic>?) ?? {'endereco': 'local'});
      home['papeis'] = ['worker', 'pipeline'];
      nodes['casa'] = home;
    } else if (nodes['casa'] != null) {
      final home = Map<String, dynamic>.from(nodes['casa'] as Map);
      home['papeis'] = <String>[];
      nodes['casa'] = home;
    }
    m['nos'] = nodes;
    if (_topology == 'nuvem') {
      m['ia'] = {
        ...(m['ia'] as Map<String, dynamic>),
        'local': {...((m['ia'] as Map)['local'] as Map<String, dynamic>), 'ativa': false},
      };
    }
    return m;
  }

  Future<void> _save({String? fingerprint}) async {
    try {
      final m = await widget.core.saveManifest(_buildManifest(fingerprint: fingerprint));
      setState(() {
        _m = m;
        _savedFingerprint = (((m['nos'] as Map)['vps'] as Map)['ssh'] as Map)['impressao_host'] as String;
      });
      if (mounted) notify(context, AppText.of(context).vpsSaved);
    } on CoreError catch (e) {
      if (mounted) notify(context, e.message, error: true);
    }
  }

  Future<void> _fetchFingerprint() async {
    setState(() {
      _busy = true;
      _readFingerprint = null;
    });
    try {
      final r = await widget.core.post('/vps/impressao', {
        'host': _host.text.trim(),
        'porta': int.tryParse(_port.text.trim()) ?? 22,
      });
      setState(() => _readFingerprint = (r as Map).cast<String, dynamic>());
    } on CoreError catch (e) {
      if (mounted) notify(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _install() async {
    await _save();
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final plan = await widget.core.post('/vps/plano', {
        'senha': _password.text.isEmpty ? null : _password.text,
        'senha_sudo': _sudoPassword.text.isEmpty ? null : _sudoPassword.text,
        'desativar_login_por_senha': _disablePassword,
        'nginx': _nginx,
      }) as Map<String, dynamic>;
      if (!mounted) return;
      final ok = await showPlan(context, widget.core, plan);
      if (ok) {
        _password.clear();
        _sudoPassword.clear();
      }
    } on CoreError catch (e) {
      if (mounted) notify(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _keyFile(String kind) => kind.contains('ed25519')
      ? 'ed25519'
      : kind.startsWith('ecdsa')
          ? 'ecdsa'
          : 'rsa';

  Widget _field(TextEditingController c, String label, {String? help, bool password = false, double fieldWidth = 420}) =>
      SizedBox(
        width: fieldWidth,
        child: TextField(
          controller: c,
          obscureText: password,
          autocorrect: false,
          enableSuggestions: !password,
          decoration: InputDecoration(labelText: label, helperText: help),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final t = AppText.of(context);
    final colors = Theme.of(context).colorScheme;
    final confirmed = _savedFingerprint.isNotEmpty;
    return ListView(padding: const EdgeInsets.all(24), children: [
      Text(t.navVps, style: tt.headlineSmall),
      Text(t.vpsDescription),
      const SizedBox(height: 16),
      Text(t.topology, style: tt.titleMedium),
      SegmentedButton<String>(
        segments: [
          ButtonSegment(value: 'hibrida', label: Text(t.topologyHybrid)),
          ButtonSegment(value: 'nuvem', label: Text(t.topologyCloud)),
        ],
        selected: {_topology},
        onSelectionChanged: (s) => setState(() => _topology = s.first),
      ),
      const SizedBox(height: 16),
      Text(t.domain, style: tt.titleMedium),
      _field(_domain, t.domain, help: t.domainHelp),
      _field(_email, t.emailTls, help: t.emailTlsHelp),
      SizedBox(
        width: 420,
        child: CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _cloudflare,
          onChanged: (v) => setState(() => _cloudflare = v ?? false),
          title: Text(t.cloudflare),
        ),
      ),
      const SizedBox(height: 16),
      Text(t.sshAccess, style: tt.titleMedium),
      Wrap(spacing: 16, children: [
        _field(_host, t.vpsHost, fieldWidth: 260),
        _field(_port, t.port, fieldWidth: 80),
        _field(_user, t.user, fieldWidth: 140),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        OutlinedButton.icon(
          onPressed: _busy ? null : _fetchFingerprint,
          icon: const Icon(Icons.fingerprint),
          label: Text(t.readFingerprint),
        ),
        const SizedBox(width: 12),
        if (confirmed)
          Flexible(child: Text(t.fingerprintConfirmed(_savedFingerprint), style: TextStyle(color: colors.success))),
      ]),
      if (_readFingerprint != null)
        Card(
          margin: const EdgeInsets.only(top: 12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.checkFingerprint),
              SelectableText('ssh-keygen -lf /etc/ssh/ssh_host_${_keyFile(_readFingerprint!['tipo'] as String)}_key.pub',
                  style: const TextStyle(fontFamily: 'monospace')),
              const SizedBox(height: 8),
              SelectableText('${_readFingerprint!['tipo']}  ${_readFingerprint!['impressao']}',
                  style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () {
                  final i = _readFingerprint!['impressao'] as String;
                  setState(() => _readFingerprint = null);
                  _save(fingerprint: i);
                },
                child: Text(t.confirmVps),
              ),
            ]),
          ),
        ),
      const SizedBox(height: 16),
      Text(t.firstAccess, style: tt.titleMedium),
      Text(t.firstAccessDescription),
      _field(_password, t.vpsPassword, password: true),
      _field(_sudoPassword, t.sudoPassword, password: true),
      SizedBox(
        width: 520,
        child: CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _disablePassword,
          onChanged: (v) => setState(() => _disablePassword = v ?? true),
          title: Text(t.disablePassword),
          subtitle: Text(t.disablePasswordHelp),
        ),
      ),
      Row(children: [
        const Text('nginx: '),
        DropdownButton<String>(
          value: _nginx,
          items: [
            DropdownMenuItem(value: 'auto', child: Text(t.nginxAuto)),
            DropdownMenuItem(value: 'docker', child: Text(t.nginxDocker)),
            DropdownMenuItem(value: 'host', child: Text(t.nginxHost)),
          ],
          onChanged: (v) => setState(() => _nginx = v ?? 'auto'),
        ),
      ]),
      const SizedBox(height: 24),
      Row(children: [
        OutlinedButton(onPressed: _busy ? null : _save, child: Text(t.save)),
        const SizedBox(width: 12),
        FilledButton.icon(
          onPressed: _busy || !confirmed ? null : _install,
          icon: const Icon(Icons.cloud_upload),
          label: Text(t.viewPlan),
        ),
        if (!confirmed)
          Padding(padding: const EdgeInsets.only(left: 12), child: Text(t.confirmFingerprint)),
      ]),
    ]);
  }
}
