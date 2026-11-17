// Solumia visual identity (the same blue-violet palette as the Solumia app, light and dark) and the
// person's theme and language preferences.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Accent blue, the seed of the Solumia app palette (plataforma/app_core/lib/src/tema.dart).
const accentColor = Color(0xFF2F6FED);

ColorScheme solumiaScheme(Brightness b) => ColorScheme.fromSeed(seedColor: accentColor, brightness: b);

ThemeData solumiaTheme(Brightness b) {
  final c = solumiaScheme(b);
  return ThemeData(
    useMaterial3: true,
    colorScheme: c,
    scaffoldBackgroundColor: c.surface,
    cardTheme: CardThemeData(
      elevation: 0,
      color: c.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: c.outlineVariant),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: c.surfaceContainer,
      indicatorColor: c.secondaryContainer,
      selectedIconTheme: IconThemeData(color: c.onSecondaryContainer),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

/// State colors Material does not have (success and warning), in both brightness variants.
extension StateColors on ColorScheme {
  Color get success => brightness == Brightness.light ? const Color(0xFF1B7F4B) : const Color(0xFF7FD8A4);
  Color get warning => brightness == Brightness.light ? const Color(0xFF9A6700) : const Color(0xFFF5C25B);
}

const languages = [('pt', 'Português'), ('en', 'English'), ('es', 'Español')];

class Preferences extends ChangeNotifier {
  Preferences._(this._p);
  final SharedPreferences? _p;

  ThemeMode theme = ThemeMode.system;
  Locale? language; // null = the system one

  static Future<Preferences> load() async {
    SharedPreferences? p;
    try {
      p = await SharedPreferences.getInstance();
    } catch (_) {
      // no storage: use the defaults for this session only
    }
    final r = Preferences._(p);
    r.theme = ThemeMode.values.asNameMap()[p?.getString('tema')] ?? ThemeMode.system;
    final i = p?.getString('idioma');
    if (i != null && languages.any((e) => e.$1 == i)) r.language = Locale(i);
    return r;
  }

  void setTheme(ThemeMode t) {
    theme = t;
    _p?.setString('tema', t.name);
    notifyListeners();
  }

  void setLanguage(Locale? l) {
    language = l;
    l == null ? _p?.remove('idioma') : _p?.setString('idioma', l.languageCode);
    notifyListeners();
  }
}
