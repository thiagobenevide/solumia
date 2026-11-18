import 'dart:async';

import 'package:agent_arquivos/agent_arquivos.dart';
import 'package:agent_codigo/agent_codigo.dart';
import 'package:agent_core/agent_core.dart';
import 'package:agent_design/agent_design.dart';
import 'package:agent_eletronica/agent_eletronica.dart';
import 'package:agent_empreendimento/agent_empreendimento.dart';
import 'package:agent_financas/agent_financas.dart';
import 'package:agent_notas/agent_notas.dart';
import 'package:agent_painel/agent_painel.dart';
import 'package:agent_estudos/agent_estudos.dart';
import 'package:agent_saude/agent_saude.dart';
import 'package:agent_rotinas/agent_rotinas.dart';
import 'package:flutter/material.dart';

import 'atualizacao.dart';
import 'modulos.dart';
import 'shell.dart';

/// Backend da plataforma (`/api/*`): `--dart-define=API_URL=https://...`. O acesso é pelo login
/// (senha + Google Authenticator); nenhuma chave fica embutida no app.
const urlApi = String.fromEnvironment('API_URL', defaultValue: 'http://localhost:48080');

/// Endereço do painel da esteira. Com API_URL da VPS, o padrão é o túnel `<API_URL>/esteira/`
/// (`infra/scripts/tunel_esteira` no PC); sem ele, o painel local. Outro: `--dart-define=ESTEIRA_URL=...`.
const urlEsteira = String.fromEnvironment(
  'ESTEIRA_URL',
  defaultValue: urlApi == 'http://localhost:48080' ? 'http://localhost:8765' : '$urlApi/esteira/',
);

void main() => runApp(const AgentApp());

/// Módulos montados com o token da sessão aberta no login.
List<Modulo> modulosDaSessao(String token) {
  final arquivos = FilesModule(url: urlApi, token: token);
  return [
    PanelModule(url: urlApi, token: token),
    BusinessModule(pipelineUrl: urlEsteira, url: urlApi, token: token),
    NotesModule(url: urlApi, token: token),
    arquivos,
    HealthModule(url: urlApi, token: token),
    // Projetos de leitura abrem o trecho na página do PDF, no leitor de Arquivos.
    StudiesModule(
      url: urlApi,
      token: token,
      openInFile: (context, id, pagina) async {
        final arquivo = await arquivos.api.fetch(id);
        if (context.mounted) await openFile(context, arquivos.api, arquivo, page: pagina, read: true);
      },
    ),
    RoutinesModule(url: urlApi, token: token),
    FinanceModule(url: urlApi, token: token),
    ModuloDesign(url: urlApi, token: token),
    ElectronicsModule(url: urlApi, token: token),
    CodeModule(url: urlApi, token: token),
    ...modulosEmBreve,
  ];
}

class AgentApp extends StatefulWidget {
  const AgentApp({super.key});

  @override
  State<AgentApp> createState() => _AgentAppState();
}

class _AgentAppState extends State<AgentApp> {
  /// Com "Manter conectado" a sessão fica guardada no aparelho até sair, ficar 30 dias sem abrir o
  /// app (renova ao abrir e a cada dia) ou o app ser atualizado (outro build pede o login completo).
  Sessao? _sessao;
  String? _aviso;
  bool _restaurando = true;
  bool _lembrar = false;
  Timer? _renovacao;
  Future<bool>? _pedindoCodigo;

  @override
  void initState() {
    super.initState();
    NomeUsuario.carregar();
    ApiCliente.aoNaoAutorizado = () {
      if (_sessao != null) _sair('Sessão expirada. Entre de novo.');
    };
    ApiCliente.aoPedirCodigo = () => _pedindoCodigo ??= _pedirCodigo().whenComplete(() => _pedindoCodigo = null);
    Sessao.restaurar(buildAtual).then((r) {
      if (mounted) {
        setState(() {
          _sessao = r.$1;
          _aviso = r.$2;
          _restaurando = false;
        });
        if (r.$1 != null) _comecarRenovacao(r.$1!);
      }
    });
  }

  @override
  void dispose() {
    _renovacao?.cancel();
    super.dispose();
  }

  void _entrar(Sessao s, bool lembrar) {
    lembrar ? s.guardar(buildAtual) : Sessao.esquecer();
    setState(() => _sessao = s);
    if (lembrar) _comecarRenovacao(s);
  }

  /// Renova o token guardado agora e a cada 24 h. O app aberto segue com o token atual (que ainda
  /// vale): trocar o da tela recarregaria os módulos; o renovado serve na próxima abertura.
  void _comecarRenovacao(Sessao s) {
    _lembrar = true;
    var atual = s;
    Future<void> renovar() async {
      final nova = await atual.renovar(urlApi);
      if (nova == null || !_lembrar) return;
      atual = nova;
      await nova.guardar(buildAtual);
    }

    _renovacao?.cancel();
    unawaited(renovar());
    _renovacao = Timer.periodic(const Duration(hours: 24), (_) => renovar());
  }

  /// O Código (comandos no PC) pede um código do Authenticator digitado nas últimas 12 h.
  Future<bool> _pedirCodigo() async {
    final ctx = Tarefas.navegador.currentContext;
    final s = _sessao;
    if (ctx == null || s == null) return false;
    final codigo = await showDialog<String>(context: ctx, builder: (_) => const _DialogoCodigo());
    if (codigo == null) return false;
    try {
      await ApiCliente(urlApi, cabecalhos: {'Authorization': 'Bearer ${s.token}'})
          .post('/api/auth/confirmar', {'codigo': codigo});
      return true;
    } on ApiErro catch (e) {
      Tarefas.mensagens.currentState?.showSnackBar(SnackBar(content: Text(e.mensagem)));
      return false;
    }
  }

  void _sair([String? aviso]) {
    _lembrar = false;
    _renovacao?.cancel();
    Sessao.esquecer();
    setState(() {
      _sessao = null;
      _aviso = aviso;
    });
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Solumia',
    debugShowCheckedModeBanner: false,
    navigatorKey: Tarefas.navegador,
    scaffoldMessengerKey: Tarefas.mensagens,
    theme: temaAgent(Brightness.light),
    darkTheme: temaAgent(Brightness.dark),
    themeMode: ThemeMode.dark,
    // Android 15+ desenha atrás das barras do sistema: laterais (recorte da câmera deitado) e rodapé (barra
    // de gestos) ficam livres em todas as telas; o topo fica com a AppBar de cada uma.
    builder: (context, filho) => SafeArea(top: false, child: filho!),
    home: _restaurando
        ? const Scaffold(body: Center(child: CircularProgressIndicator()))
        : _sessao == null
        ? TelaLogin(urlApi: urlApi, aviso: _aviso, aoEntrar: _entrar)
        // A chave nova recria os módulos a cada login, já com o token novo.
        : Shell(
            key: ValueKey(_sessao!.token),
            modulos: modulosDaSessao(_sessao!.token),
            aoSair: _sair,
            usuario: _sessao!.usuario,
            api: ApiCliente(urlApi, cabecalhos: {'Authorization': 'Bearer ${_sessao!.token}'}),
          ),
  );
}

class _DialogoCodigo extends StatefulWidget {
  const _DialogoCodigo();

  @override
  State<_DialogoCodigo> createState() => _DialogoCodigoState();
}

class _DialogoCodigoState extends State<_DialogoCodigo> {
  final _campo = TextEditingController();

  @override
  void dispose() {
    _campo.dispose();
    super.dispose();
  }

  void _confirmar() {
    final codigo = _campo.text.trim();
    if (RegExp(r'^\d{6}$').hasMatch(codigo)) Navigator.of(context).pop(codigo);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Código do Authenticator'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('O Código roda comandos no PC: confirme com o código de 6 dígitos (vale 12 h).'),
        const SizedBox(height: 12),
        TextField(
          controller: _campo,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          decoration: const InputDecoration(counterText: '', hintText: '000000'),
          onSubmitted: (_) => _confirmar(),
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
      FilledButton(onPressed: _confirmar, child: const Text('Confirmar')),
    ],
  );
}
