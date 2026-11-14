import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'l10n/textos.dart';
import 'nucleo.dart';
import 'tema.dart';
import 'telas/apps_solumia.dart';
import 'telas/conta.dart';
import 'telas/craft_apps.dart';
import 'telas/inicio.dart';
import 'telas/pastas.dart';
import 'telas/registro.dart';
import 'telas/vps.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(AppConfigurador(prefs: await Preferencias.carregar()));
}

class AppConfigurador extends StatelessWidget {
  const AppConfigurador({super.key, required this.prefs});
  final Preferencias prefs;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) => MaterialApp(
        onGenerateTitle: (c) => Textos.of(c).appTitulo,
        debugShowCheckedModeBanner: false,
        theme: temaSolumia(Brightness.light),
        darkTheme: temaSolumia(Brightness.dark),
        themeMode: prefs.tema,
        locale: prefs.idioma,
        supportedLocales: Textos.supportedLocales,
        localizationsDelegates: const [
          Textos.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        // Idioma do sistema fora dos três suportados: português.
        localeResolutionCallback: (l, suportados) =>
            suportados.firstWhere((s) => s.languageCode == l?.languageCode, orElse: () => const Locale('pt')),
        home: Inicializacao(prefs: prefs),
      ),
    );
  }
}

/// Sobe o núcleo antes de qualquer tela; encerra o núcleo junto com a janela.
class Inicializacao extends StatefulWidget {
  const Inicializacao({super.key, required this.prefs});
  final Preferencias prefs;
  @override
  State<Inicializacao> createState() => _InicializacaoEstado();
}

class _InicializacaoEstado extends State<Inicializacao> {
  Nucleo? _nucleo;
  String? _erro;
  late final AppLifecycleListener _ciclo;

  @override
  void initState() {
    super.initState();
    _ciclo = AppLifecycleListener(onExitRequested: () async {
      _nucleo?.encerrar();
      return AppExitResponse.exit;
    });
    _iniciar();
  }

  Future<void> _iniciar() async {
    setState(() => _erro = null);
    try {
      final n = await Nucleo.iniciar();
      if (mounted) setState(() => _nucleo = n);
    } on ErroNucleo catch (e) {
      if (mounted) setState(() => _erro = e.mensagem);
    }
  }

  @override
  void dispose() {
    _ciclo.dispose();
    _nucleo?.encerrar();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Textos.of(context);
    final n = _nucleo;
    if (n != null) return Principal(nucleo: n, prefs: widget.prefs);
    return Scaffold(
      body: Center(
        child: _erro == null
            ? Column(mainAxisSize: MainAxisSize.min, children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(t.iniciandoNucleo),
              ])
            : Padding(
                padding: const EdgeInsets.all(32),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.error, color: Theme.of(context).colorScheme.error, size: 48),
                  const SizedBox(height: 12),
                  SelectableText(_erro!),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _iniciar, child: Text(t.tentarDeNovo)),
                ]),
              ),
      ),
    );
  }
}

class Principal extends StatefulWidget {
  const Principal({super.key, required this.nucleo, required this.prefs});
  final Nucleo nucleo;
  final Preferencias prefs;
  @override
  State<Principal> createState() => _PrincipalEstado();
}

class _PrincipalEstado extends State<Principal> {
  int _indice = 0;

  @override
  Widget build(BuildContext context) {
    final t = Textos.of(context);
    final c = Theme.of(context).colorScheme;
    final n = widget.nucleo;
    final telas = <Widget>[
      TelaInicio(key: ValueKey('inicio$_indice'), nucleo: n, irPara: (i) => setState(() => _indice = i)),
      TelaConta(nucleo: n),
      TelaVPS(nucleo: n),
      TelaPastas(nucleo: n),
      TelaCraftApps(nucleo: n),
      TelaAppsSolumia(nucleo: n),
      TelaRegistro(key: ValueKey('registro$_indice'), nucleo: n),
    ];
    return Scaffold(
      body: Row(children: [
        NavigationRail(
          selectedIndex: _indice,
          labelType: NavigationRailLabelType.all,
          onDestinationSelected: (i) => setState(() => _indice = i),
          leading: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Icon(Icons.wb_sunny_rounded, color: c.primary, size: 32),
          ),
          trailing: Expanded(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: IconButton(
                  tooltip: '${t.aparencia} · ${t.idioma}',
                  icon: const Icon(Icons.tune),
                  onPressed: () => _preferencias(context),
                ),
              ),
            ),
          ),
          destinations: [
            NavigationRailDestination(icon: const Icon(Icons.home_outlined), label: Text(t.navInicio)),
            NavigationRailDestination(icon: const Icon(Icons.person_outline), label: Text(t.navConta)),
            NavigationRailDestination(icon: const Icon(Icons.dns_outlined), label: Text(t.navVps)),
            NavigationRailDestination(icon: const Icon(Icons.folder_outlined), label: Text(t.navPastas)),
            NavigationRailDestination(icon: const Icon(Icons.apps_outlined), label: Text(t.navCraft)),
            NavigationRailDestination(icon: const Icon(Icons.devices_outlined), label: Text(t.navApps)),
            NavigationRailDestination(icon: const Icon(Icons.history), label: Text(t.navRegistro)),
          ],
        ),
        Expanded(child: telas[_indice]),
      ]),
    );
  }

  void _preferencias(BuildContext context) {
    final p = widget.prefs;
    showDialog<void>(
      context: context,
      builder: (_) => ListenableBuilder(
        listenable: p,
        builder: (context, _) {
          final t = Textos.of(context);
          return AlertDialog(
            title: Text(t.aparencia),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.tema, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              SegmentedButton<ThemeMode>(
                segments: [
                  ButtonSegment(value: ThemeMode.system, icon: const Icon(Icons.brightness_auto), label: Text(t.temaSistema)),
                  ButtonSegment(value: ThemeMode.light, icon: const Icon(Icons.light_mode), label: Text(t.temaClaro)),
                  ButtonSegment(value: ThemeMode.dark, icon: const Icon(Icons.dark_mode), label: Text(t.temaEscuro)),
                ],
                selected: {p.tema},
                onSelectionChanged: (s) => p.definirTema(s.first),
              ),
              const SizedBox(height: 20),
              Text(t.idioma, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: '', label: Text(t.temaSistema)),
                  for (final (codigo, nome) in idiomas) ButtonSegment(value: codigo, label: Text(nome)),
                ],
                selected: {p.idioma?.languageCode ?? ''},
                onSelectionChanged: (s) => p.definirIdioma(s.first.isEmpty ? null : Locale(s.first)),
              ),
            ]),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(t.fechar))],
          );
        },
      ),
    );
  }
}
