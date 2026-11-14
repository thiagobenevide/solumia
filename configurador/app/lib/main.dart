import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'l10n/app_text.dart';
import 'core.dart';
import 'theme.dart';
import 'screens/solumia_apps.dart';
import 'screens/account.dart';
import 'screens/assistant.dart';
import 'screens/craft_apps.dart';
import 'screens/home.dart';
import 'screens/folders.dart';
import 'screens/run_log.dart';
import 'screens/vps.dart';
import 'screens/worker.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ConfiguratorApp(prefs: await Preferences.load()));
}

class ConfiguratorApp extends StatelessWidget {
  const ConfiguratorApp({super.key, required this.prefs});
  final Preferences prefs;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) => MaterialApp(
        onGenerateTitle: (c) => AppText.of(c).appTitle,
        debugShowCheckedModeBanner: false,
        theme: solumiaTheme(Brightness.light),
        darkTheme: solumiaTheme(Brightness.dark),
        themeMode: prefs.theme,
        locale: prefs.language,
        supportedLocales: AppText.supportedLocales,
        localizationsDelegates: const [
          AppText.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        // System language outside the three supported ones: Portuguese.
        localeResolutionCallback: (l, supported) =>
            supported.firstWhere((s) => s.languageCode == l?.languageCode, orElse: () => const Locale('pt')),
        home: Startup(prefs: prefs),
      ),
    );
  }
}

/// Starts the core before any screen; shuts the core down together with the window.
class Startup extends StatefulWidget {
  const Startup({super.key, required this.prefs});
  final Preferences prefs;
  @override
  State<Startup> createState() => _StartupState();
}

class _StartupState extends State<Startup> {
  Core? _core;
  String? _error;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onExitRequested: () async {
      _core?.shutdown();
      return AppExitResponse.exit;
    });
    _start();
  }

  Future<void> _start() async {
    setState(() => _error = null);
    try {
      final n = await Core.start();
      if (mounted) setState(() => _core = n);
    } on CoreError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _core?.shutdown();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppText.of(context);
    final n = _core;
    if (n != null) return MainShell(core: n, prefs: widget.prefs);
    return Scaffold(
      body: Center(
        child: _error == null
            ? Column(mainAxisSize: MainAxisSize.min, children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(t.startingCore),
              ])
            : Padding(
                padding: const EdgeInsets.all(32),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.error, color: Theme.of(context).colorScheme.error, size: 48),
                  const SizedBox(height: 12),
                  SelectableText(_error!),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _start, child: Text(t.tryAgain)),
                ]),
              ),
      ),
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key, required this.core, required this.prefs});
  final Core core;
  final Preferences prefs;
  @override
  State<MainShell> createState() => _MainShellState();
}

// Screen ids the assistant may suggest, in the order of the navigation rail.
const _screenIds = ['inicio', 'conta', 'vps', 'pastas', 'craft_apps', 'apps', 'worker', 'registro', 'assistente'];

class _MainShellState extends State<MainShell> {
  int _index = 0;

  void _openScreen(String id) {
    final i = _screenIds.indexOf(id);
    if (i >= 0) setState(() => _index = i);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppText.of(context);
    final c = Theme.of(context).colorScheme;
    final n = widget.core;
    final screens = <Widget>[
      HomeScreen(key: ValueKey('inicio$_index'), core: n, goTo: (i) => setState(() => _index = i)),
      AccountScreen(core: n),
      VpsScreen(core: n),
      FoldersScreen(core: n),
      CraftAppsScreen(core: n),
      SolumiaAppsScreen(core: n),
      WorkerScreen(core: n),
      RunLogScreen(key: ValueKey('registro$_index'), core: n),
      AssistantScreen(core: n, openScreen: _openScreen),
    ];
    return Scaffold(
      body: Row(children: [
        NavigationRail(
          selectedIndex: _index,
          labelType: NavigationRailLabelType.all,
          onDestinationSelected: (i) => setState(() => _index = i),
          leading: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.asset('assets/logo.png', width: 40, height: 40),
              ),
              const SizedBox(height: 6),
              Text('Solumia', style: TextStyle(color: c.onSurface, fontWeight: FontWeight.w600)),
            ]),
          ),
          trailing: Expanded(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: IconButton(
                  tooltip: '${t.appearance} · ${t.language}',
                  icon: const Icon(Icons.tune),
                  onPressed: () => _preferences(context),
                ),
              ),
            ),
          ),
          destinations: [
            NavigationRailDestination(icon: const Icon(Icons.home_outlined), label: Text(t.navHome)),
            NavigationRailDestination(icon: const Icon(Icons.person_outline), label: Text(t.navAccount)),
            NavigationRailDestination(icon: const Icon(Icons.dns_outlined), label: Text(t.navVps)),
            NavigationRailDestination(icon: const Icon(Icons.folder_outlined), label: Text(t.navFolders)),
            NavigationRailDestination(icon: const Icon(Icons.apps_outlined), label: Text(t.navCraft)),
            NavigationRailDestination(icon: const Icon(Icons.devices_outlined), label: Text(t.navApps)),
            NavigationRailDestination(icon: const Icon(Icons.memory), label: Text(t.navWorker)),
            NavigationRailDestination(icon: const Icon(Icons.history), label: Text(t.navRunLog)),
            NavigationRailDestination(icon: const Icon(Icons.auto_awesome_outlined), label: Text(t.navAssistant)),
          ],
        ),
        Expanded(child: screens[_index]),
      ]),
    );
  }

  void _preferences(BuildContext context) {
    final p = widget.prefs;
    showDialog<void>(
      context: context,
      builder: (_) => ListenableBuilder(
        listenable: p,
        builder: (context, _) {
          final t = AppText.of(context);
          return AlertDialog(
            title: Text(t.appearance),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.theme, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              SegmentedButton<ThemeMode>(
                segments: [
                  ButtonSegment(value: ThemeMode.system, icon: const Icon(Icons.brightness_auto), label: Text(t.themeSystem)),
                  ButtonSegment(value: ThemeMode.light, icon: const Icon(Icons.light_mode), label: Text(t.themeLight)),
                  ButtonSegment(value: ThemeMode.dark, icon: const Icon(Icons.dark_mode), label: Text(t.themeDark)),
                ],
                selected: {p.theme},
                onSelectionChanged: (s) => p.setTheme(s.first),
              ),
              const SizedBox(height: 20),
              Text(t.language, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: '', label: Text(t.themeSystem)),
                  for (final (code, name) in languages) ButtonSegment(value: code, label: Text(name)),
                ],
                selected: {p.language?.languageCode ?? ''},
                onSelectionChanged: (s) => p.setLanguage(s.first.isEmpty ? null : Locale(s.first)),
              ),
            ]),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(t.close))],
          );
        },
      ),
    );
  }
}
