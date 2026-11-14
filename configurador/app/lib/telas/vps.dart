import 'package:flutter/material.dart';

import '../l10n/textos.dart';
import '../nucleo.dart';
import '../tema.dart';
import '../plano.dart';

/// Tela VPS: tudo que antes era feito no terminal (instalar_vps, endurecer_vps) sai daqui.
class TelaVPS extends StatefulWidget {
  const TelaVPS({super.key, required this.nucleo});
  final Nucleo nucleo;
  @override
  State<TelaVPS> createState() => _TelaVPSEstado();
}

class _TelaVPSEstado extends State<TelaVPS> {
  final _dominio = TextEditingController();
  final _email = TextEditingController();
  final _host = TextEditingController();
  final _porta = TextEditingController(text: '22');
  final _usuario = TextEditingController(text: 'root');
  final _senha = TextEditingController();
  final _senhaSudo = TextEditingController();
  String _topologia = 'hibrida';
  bool _cloudflare = false;
  bool _desativarSenha = true;
  String _nginx = 'auto';
  String _impressaoSalva = '';
  Map<String, dynamic>? _impressaoLida;
  bool _ocupado = false;
  Map<String, dynamic> _m = {};

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  @override
  void dispose() {
    _senha.clear();
    _senhaSudo.clear();
    super.dispose();
  }

  Future<void> _carregar() async {
    final m = await widget.nucleo.manifesto();
    final t = m['topologia'] as Map<String, dynamic>;
    final vps = (m['nos'] as Map)['vps'] as Map<String, dynamic>?;
    final ssh = vps?['ssh'] as Map<String, dynamic>?;
    setState(() {
      _m = m;
      _topologia = t['tipo'] == 'local' ? 'hibrida' : t['tipo'] as String;
      _dominio.text = t['dominio'] as String;
      _email.text = t['email_tls'] as String;
      _cloudflare = t['cloudflare'] as bool;
      if (ssh != null) {
        _host.text = ssh['host'] as String;
        _porta.text = '${ssh['porta']}';
        _usuario.text = ssh['usuario'] as String;
        _impressaoSalva = ssh['impressao_host'] as String;
      }
    });
  }

  Map<String, dynamic> _montarManifesto({String? impressao}) {
    final m = Map<String, dynamic>.from(_m);
    m['topologia'] = {
      ...(m['topologia'] as Map<String, dynamic>),
      'tipo': _topologia,
      'dominio': _dominio.text.trim(),
      'email_tls': _email.text.trim(),
      'cloudflare': _cloudflare,
    };
    final nos = Map<String, dynamic>.from(m['nos'] as Map);
    final hostMudou = (nos['vps']?['ssh']?['host'] ?? '') != _host.text.trim();
    nos['vps'] = {
      ...((nos['vps'] as Map<String, dynamic>?) ?? {}),
      'endereco': 'ssh',
      'entrega': 'ssh',
      'ssh': {
        'usuario': _usuario.text.trim(),
        'host': _host.text.trim(),
        'porta': int.tryParse(_porta.text.trim()) ?? 22,
        // Host novo = impressão antiga não vale mais.
        'impressao_host': impressao ?? (hostMudou ? '' : _impressaoSalva),
      },
      'papeis': _topologia == 'nuvem' ? ['gateway', 'worker', 'collabora'] : ['gateway', 'tunnel', 'collabora'],
    };
    if (_topologia == 'hibrida') {
      final casa = Map<String, dynamic>.from((nos['casa'] as Map<String, dynamic>?) ?? {'endereco': 'local'});
      casa['papeis'] = ['worker', 'pipeline'];
      nos['casa'] = casa;
    } else if (nos['casa'] != null) {
      final casa = Map<String, dynamic>.from(nos['casa'] as Map);
      casa['papeis'] = <String>[];
      nos['casa'] = casa;
    }
    m['nos'] = nos;
    if (_topologia == 'nuvem') {
      m['ia'] = {
        ...(m['ia'] as Map<String, dynamic>),
        'local': {...((m['ia'] as Map)['local'] as Map<String, dynamic>), 'ativa': false},
      };
    }
    return m;
  }

  Future<void> _salvar({String? impressao}) async {
    try {
      final m = await widget.nucleo.salvarManifesto(_montarManifesto(impressao: impressao));
      setState(() {
        _m = m;
        _impressaoSalva = (((m['nos'] as Map)['vps'] as Map)['ssh'] as Map)['impressao_host'] as String;
      });
      if (mounted) avisar(context, Textos.of(context).vpsSalva);
    } on ErroNucleo catch (e) {
      if (mounted) avisar(context, e.mensagem, erro: true);
    }
  }

  Future<void> _lerImpressao() async {
    setState(() {
      _ocupado = true;
      _impressaoLida = null;
    });
    try {
      final r = await widget.nucleo.post('/vps/impressao', {
        'host': _host.text.trim(),
        'porta': int.tryParse(_porta.text.trim()) ?? 22,
      });
      setState(() => _impressaoLida = (r as Map).cast<String, dynamic>());
    } on ErroNucleo catch (e) {
      if (mounted) avisar(context, e.mensagem, erro: true);
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  Future<void> _instalar() async {
    await _salvar();
    if (!mounted) return;
    setState(() => _ocupado = true);
    try {
      final plano = await widget.nucleo.post('/vps/plano', {
        'senha': _senha.text.isEmpty ? null : _senha.text,
        'senha_sudo': _senhaSudo.text.isEmpty ? null : _senhaSudo.text,
        'desativar_login_por_senha': _desativarSenha,
        'nginx': _nginx,
      }) as Map<String, dynamic>;
      if (!mounted) return;
      final ok = await mostrarPlano(context, widget.nucleo, plano);
      if (ok) {
        _senha.clear();
        _senhaSudo.clear();
      }
    } on ErroNucleo catch (e) {
      if (mounted) avisar(context, e.mensagem, erro: true);
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  static String _arquivoChave(String tipo) => tipo.contains('ed25519')
      ? 'ed25519'
      : tipo.startsWith('ecdsa')
          ? 'ecdsa'
          : 'rsa';

  Widget _campo(TextEditingController c, String rotulo, {String? ajuda, bool senha = false, double largura = 420}) =>
      SizedBox(
        width: largura,
        child: TextField(
          controller: c,
          obscureText: senha,
          autocorrect: false,
          enableSuggestions: !senha,
          decoration: InputDecoration(labelText: rotulo, helperText: ajuda),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final t = Textos.of(context);
    final cores = Theme.of(context).colorScheme;
    final confirmada = _impressaoSalva.isNotEmpty;
    return ListView(padding: const EdgeInsets.all(24), children: [
      Text(t.navVps, style: tt.headlineSmall),
      Text(t.vpsDescricao),
      const SizedBox(height: 16),
      Text(t.topologia, style: tt.titleMedium),
      SegmentedButton<String>(
        segments: [
          ButtonSegment(value: 'hibrida', label: Text(t.topoHibrida)),
          ButtonSegment(value: 'nuvem', label: Text(t.topoNuvem)),
        ],
        selected: {_topologia},
        onSelectionChanged: (s) => setState(() => _topologia = s.first),
      ),
      const SizedBox(height: 16),
      Text(t.dominio, style: tt.titleMedium),
      _campo(_dominio, t.dominio, ajuda: t.dominioAjuda),
      _campo(_email, t.emailTls, ajuda: t.emailTlsAjuda),
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
      Text(t.acessoSsh, style: tt.titleMedium),
      Wrap(spacing: 16, children: [
        _campo(_host, t.hostVps, largura: 260),
        _campo(_porta, t.porta, largura: 80),
        _campo(_usuario, t.usuario, largura: 140),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        OutlinedButton.icon(
          onPressed: _ocupado ? null : _lerImpressao,
          icon: const Icon(Icons.fingerprint),
          label: Text(t.lerImpressao),
        ),
        const SizedBox(width: 12),
        if (confirmada)
          Flexible(child: Text(t.impressaoConfirmada(_impressaoSalva), style: TextStyle(color: cores.sucesso))),
      ]),
      if (_impressaoLida != null)
        Card(
          margin: const EdgeInsets.only(top: 12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.conferirImpressao),
              SelectableText('ssh-keygen -lf /etc/ssh/ssh_host_${_arquivoChave(_impressaoLida!['tipo'] as String)}_key.pub',
                  style: const TextStyle(fontFamily: 'monospace')),
              const SizedBox(height: 8),
              SelectableText('${_impressaoLida!['tipo']}  ${_impressaoLida!['impressao']}',
                  style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () {
                  final i = _impressaoLida!['impressao'] as String;
                  setState(() => _impressaoLida = null);
                  _salvar(impressao: i);
                },
                child: Text(t.confirmoVps),
              ),
            ]),
          ),
        ),
      const SizedBox(height: 16),
      Text(t.primeiroAcesso, style: tt.titleMedium),
      Text(t.primeiroAcessoDescricao),
      _campo(_senha, t.senhaVps, senha: true),
      _campo(_senhaSudo, t.senhaSudo, senha: true),
      SizedBox(
        width: 520,
        child: CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _desativarSenha,
          onChanged: (v) => setState(() => _desativarSenha = v ?? true),
          title: Text(t.desativarSenha),
          subtitle: Text(t.desativarSenhaAjuda),
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
        OutlinedButton(onPressed: _ocupado ? null : _salvar, child: Text(t.salvar)),
        const SizedBox(width: 12),
        FilledButton.icon(
          onPressed: _ocupado || !confirmada ? null : _instalar,
          icon: const Icon(Icons.cloud_upload),
          label: Text(t.verPlano),
        ),
        if (!confirmada)
          Padding(padding: const EdgeInsets.only(left: 12), child: Text(t.confirmeImpressao)),
      ]),
    ]);
  }
}
