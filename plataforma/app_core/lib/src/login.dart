import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// Sessão aberta pelo login: o token vai em `Authorization: Bearer` em todo pedido ao backend.
class Sessao {
  const Sessao(this.token, this.usuario, this.expiraEm);

  final String token;
  final String usuario;
  final DateTime expiraEm;

  /// Faz o login (senha + código do Google Authenticator) em `POST /api/auth/login`. [lembrar] pede
  /// o token longo do "manter conectado".
  static Future<Sessao> entrar(
    String urlApi,
    String usuario,
    String senha,
    String codigo, {
    bool lembrar = false,
  }) async {
    final r = await ApiCliente(urlApi).post('/api/auth/login', {
      'usuario': usuario,
      'senha': senha,
      'codigo': codigo,
      'lembrar': lembrar,
    });
    return Sessao(
      r['token'] as String,
      r['usuario'] as String,
      DateTime.fromMillisecondsSinceEpoch((r['expira_em'] as int) * 1000),
    );
  }

  static const _chave = 'agent.sessao';

  /// Token novo com a mesma validade (`POST /api/auth/renovar`): com "manter conectado", a sessão
  /// só vence depois de 30 dias sem abrir o app. Null sem rede ou erro (segue a atual).
  Future<Sessao?> renovar(String urlApi) async {
    try {
      final r = await ApiCliente(urlApi, cabecalhos: {'Authorization': 'Bearer $token'}).post('/api/auth/renovar');
      return Sessao(
        r['token'] as String,
        r['usuario'] as String,
        DateTime.fromMillisecondsSinceEpoch((r['expira_em'] as int) * 1000),
      );
    } catch (_) {
      return null;
    }
  }

  // O token fica no cofre do sistema (Keystore no Android, Keychain, libsecret no Linux). Sem cofre
  // disponível, cai nas preferências comuns, como era antes.
  static const _cofre = FlutterSecureStorage();

  /// Guarda a sessão no aparelho, marcada com o [build] do app: outra versão não a aproveita.
  Future<void> guardar(int build) async {
    final bruto = jsonEncode({
      'token': token,
      'usuario': usuario,
      'expira_em': expiraEm.millisecondsSinceEpoch,
      'build': build,
    });
    try {
      await _cofre.write(key: _chave, value: bruto);
      await _removerDasPreferencias();
      return;
    } catch (_) {
      // sem cofre: preferências comuns
    }
    try {
      await (await SharedPreferences.getInstance()).setString(_chave, bruto);
    } catch (_) {
      // sem armazenamento: só não lembra no próximo uso
    }
  }

  /// Sessão guardada que ainda vale e é deste mesmo [build]; senão apaga e devolve null com o motivo
  /// (login completo de novo: depois de atualizar o app, ou com o token vencido).
  static Future<(Sessao?, String?)> restaurar(int build) async {
    try {
      final bruto = await _lerGuardada();
      if (bruto == null) return (null, null);
      final j = jsonDecode(bruto) as Map<String, dynamic>;
      final expira = DateTime.fromMillisecondsSinceEpoch(j['expira_em'] as int);
      final motivo = j['build'] != build
          ? 'O app foi atualizado: entre de novo.'
          : expira.isBefore(DateTime.now().add(const Duration(minutes: 5)))
          ? 'A sessão venceu: entre de novo.'
          : null;
      if (motivo != null) {
        await esquecer();
        return (null, motivo);
      }
      return (Sessao(j['token'] as String, j['usuario'] as String, expira), null);
    } catch (_) {
      return (null, null);
    }
  }

  /// Do cofre; a sessão de antes do cofre (nas preferências) passa para ele na primeira leitura.
  static Future<String?> _lerGuardada() async {
    String? doCofre;
    var cofreOk = true;
    try {
      doCofre = await _cofre.read(key: _chave);
    } catch (_) {
      cofreOk = false;
    }
    if (doCofre != null) return doCofre;
    final prefs = await SharedPreferences.getInstance();
    final antiga = prefs.getString(_chave);
    if (antiga != null && cofreOk) {
      try {
        await _cofre.write(key: _chave, value: antiga);
        await prefs.remove(_chave);
      } catch (_) {
        // continua nas preferências
      }
    }
    return antiga;
  }

  static Future<void> _removerDasPreferencias() async {
    try {
      await (await SharedPreferences.getInstance()).remove(_chave);
    } catch (_) {}
  }

  static Future<void> esquecer() async {
    try {
      await _cofre.delete(key: _chave);
    } catch (_) {}
    await _removerDasPreferencias();
  }
}

/// Tela de entrada: usuário, senha e o código de 6 dígitos do Google Authenticator.
class TelaLogin extends StatefulWidget {
  const TelaLogin({super.key, required this.urlApi, required this.aoEntrar, this.aviso});

  final String urlApi;

  /// Sessão aberta e se é para mantê-la no aparelho ("Manter conectado").
  final void Function(Sessao sessao, bool lembrar) aoEntrar;

  /// Mensagem inicial (ex.: "Sessão expirada").
  final String? aviso;

  @override
  State<TelaLogin> createState() => _TelaLoginState();
}

class _TelaLoginState extends State<TelaLogin> {
  final _form = GlobalKey<FormState>();
  final _usuario = TextEditingController();
  final _senha = TextEditingController();
  final _codigo = TextEditingController();
  bool _enviando = false;
  bool _verSenha = false;
  bool _lembrar = true;
  late String? _erro = widget.aviso;

  @override
  void dispose() {
    _usuario.dispose();
    _senha.dispose();
    _codigo.dispose();
    super.dispose();
  }

  Future<void> _entrar() async {
    if (_enviando || !_form.currentState!.validate()) return;
    setState(() {
      _enviando = true;
      _erro = null;
    });
    try {
      final sessao = await Sessao.entrar(
        widget.urlApi,
        _usuario.text.trim(),
        _senha.text,
        _codigo.text.trim(),
        lembrar: _lembrar,
      );
      widget.aoEntrar(sessao, _lembrar);
    } on ApiErro catch (e) {
      // Senha e código não ficam na tela depois de uma tentativa.
      _senha.clear();
      _codigo.clear();
      setState(() => _erro = e.mensagem);
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Form(
              key: _form,
              child: AutofillGroup(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 16,
                  children: [
                    Image.asset('assets/logo.png', package: 'agent_core', width: 72, height: 72),
                    Text('Agent', textAlign: TextAlign.center, style: tema.textTheme.headlineMedium),
                    TextFormField(
                      controller: _usuario,
                      autofillHints: const [AutofillHints.username],
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(labelText: 'Usuário', prefixIcon: Icon(Icons.person)),
                      validator: (v) => (v ?? '').trim().isEmpty ? 'Informe o usuário' : null,
                    ),
                    TextFormField(
                      controller: _senha,
                      obscureText: !_verSenha,
                      enableSuggestions: false,
                      autocorrect: false,
                      autofillHints: const [AutofillHints.password],
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: 'Senha',
                        prefixIcon: const Icon(Icons.key),
                        suffixIcon: IconButton(
                          tooltip: _verSenha ? 'Ocultar' : 'Mostrar',
                          icon: Icon(_verSenha ? Icons.visibility_off : Icons.visibility),
                          onPressed: () => setState(() => _verSenha = !_verSenha),
                        ),
                      ),
                      validator: (v) => (v ?? '').isEmpty ? 'Informe a senha' : null,
                    ),
                    TextFormField(
                      controller: _codigo,
                      keyboardType: TextInputType.number,
                      autofillHints: const [AutofillHints.oneTimeCode],
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _entrar(),
                      decoration: const InputDecoration(
                        labelText: 'Código do Google Authenticator',
                        prefixIcon: Icon(Icons.verified_user),
                      ),
                      validator: (v) => (v ?? '').length != 6 ? 'Código de 6 dígitos' : null,
                    ),
                    CheckboxListTile(
                      value: _lembrar,
                      onChanged: (v) => setState(() => _lembrar = v ?? false),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('Manter conectado'),
                      subtitle: const Text('Até atualizar o app ou sair (no máximo 90 dias)'),
                    ),
                    if (_erro != null)
                      Text(_erro!, textAlign: TextAlign.center, style: TextStyle(color: tema.colorScheme.error)),
                    FilledButton(
                      onPressed: _enviando ? null : _entrar,
                      child: _enviando
                          ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Entrar'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
