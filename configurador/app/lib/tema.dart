// Identidade visual do Solumia (sol, mar e noite) e preferências de tema e idioma da pessoa.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _sol = Color(0xFFE8772E); // primária: laranja do nascer do sol
const _mar = Color(0xFF1F7A80); // secundária: verde-azulado
const _noite = Color(0xFF4B4FA8); // terciária: anil

ColorScheme esquemaSolumia(Brightness b) {
  ColorScheme de(Color c) => ColorScheme.fromSeed(
      seedColor: c, brightness: b, dynamicSchemeVariant: DynamicSchemeVariant.fidelity);
  final base = de(_sol), mar = de(_mar), noite = de(_noite);
  return base.copyWith(
    secondary: mar.primary,
    onSecondary: mar.onPrimary,
    secondaryContainer: mar.primaryContainer,
    onSecondaryContainer: mar.onPrimaryContainer,
    tertiary: noite.primary,
    onTertiary: noite.onPrimary,
    tertiaryContainer: noite.primaryContainer,
    onTertiaryContainer: noite.onPrimaryContainer,
  );
}

ThemeData temaSolumia(Brightness b) {
  final c = esquemaSolumia(b);
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

/// Cores de estado que o Material não tem (sucesso e atenção), nas duas variações.
extension CoresEstado on ColorScheme {
  Color get sucesso => brightness == Brightness.light ? const Color(0xFF1B7F4B) : const Color(0xFF7FD8A4);
  Color get atencao => brightness == Brightness.light ? const Color(0xFF9A6700) : const Color(0xFFF5C25B);
}

const idiomas = [('pt', 'Português'), ('en', 'English'), ('es', 'Español')];

class Preferencias extends ChangeNotifier {
  Preferencias._(this._p);
  final SharedPreferences? _p;

  ThemeMode tema = ThemeMode.system;
  Locale? idioma; // null = o do sistema

  static Future<Preferencias> carregar() async {
    SharedPreferences? p;
    try {
      p = await SharedPreferences.getInstance();
    } catch (_) {
      // sem armazenamento: usa os padrões só nesta sessão
    }
    final r = Preferencias._(p);
    r.tema = ThemeMode.values.asNameMap()[p?.getString('tema')] ?? ThemeMode.system;
    final i = p?.getString('idioma');
    if (i != null && idiomas.any((e) => e.$1 == i)) r.idioma = Locale(i);
    return r;
  }

  void definirTema(ThemeMode t) {
    tema = t;
    _p?.setString('tema', t.name);
    notifyListeners();
  }

  void definirIdioma(Locale? l) {
    idioma = l;
    l == null ? _p?.remove('idioma') : _p?.setString('idioma', l.languageCode);
    notifyListeners();
  }
}
