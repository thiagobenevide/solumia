import 'package:flutter/material.dart';

/// Azul de destaque, base da paleta do app.
const corDestaque = Color(0xFF2F6FED);

/// Verde-água e violeta que acompanham o azul (secundária e terciária).
const _corSecundaria = Color(0xFF14B8A6);
const _corTerciaria = Color(0xFF8B5CF6);

/// Superfícies: no escuro, azul-noite em vez de cinza chapado; no claro, branco levemente azulado.
ColorScheme _esquema(Brightness brilho) {
  final base = ColorScheme.fromSeed(
    seedColor: corDestaque,
    brightness: brilho,
    dynamicSchemeVariant: DynamicSchemeVariant.vibrant,
  );
  if (brilho == Brightness.dark) {
    return base.copyWith(
      secondary: const Color(0xFF5EEAD4),
      tertiary: const Color(0xFFC4B5FD),
      surface: const Color(0xFF0E131C),
      surfaceContainerLowest: const Color(0xFF0A0E15),
      surfaceContainerLow: const Color(0xFF141A25),
      surfaceContainer: const Color(0xFF18202D),
      surfaceContainerHigh: const Color(0xFF1E2735),
      surfaceContainerHighest: const Color(0xFF253041),
      outlineVariant: const Color(0xFF2C3747),
    );
  }
  return base.copyWith(
    secondary: _corSecundaria,
    tertiary: _corTerciaria,
    surface: const Color(0xFFF7F9FD),
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: const Color(0xFFF1F4FA),
    surfaceContainer: const Color(0xFFEBEFF7),
    surfaceContainerHigh: const Color(0xFFE5EAF3),
    surfaceContainerHighest: const Color(0xFFDDE3EE),
  );
}

ThemeData temaAgent(Brightness brilho) {
  final esquema = _esquema(brilho);
  final cantos = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
  const botao = EdgeInsets.symmetric(horizontal: 18, vertical: 14);
  return ThemeData(
    colorScheme: esquema,
    useMaterial3: true,
    scaffoldBackgroundColor: esquema.surface,
    visualDensity: VisualDensity.standard,
    cardTheme: CardThemeData(
      elevation: 0,
      color: esquema.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: esquema.outlineVariant.withValues(alpha: 0.5)),
      ),
      clipBehavior: Clip.antiAlias,
    ),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(shape: cantos, padding: botao)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(shape: cantos, padding: botao)),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: cantos)),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: esquema.surfaceContainerHigh.withValues(alpha: 0.5),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: esquema.outlineVariant.withValues(alpha: 0.6)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: esquema.primary, width: 1.6),
      ),
    ),
    chipTheme: ChipThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
    tabBarTheme: TabBarThemeData(
      dividerColor: Colors.transparent,
      indicatorSize: TabBarIndicatorSize.label,
      labelStyle: const TextStyle(fontWeight: FontWeight.w600),
      indicator: UnderlineTabIndicator(
        borderSide: BorderSide(color: esquema.primary, width: 3),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: esquema.surfaceContainerLow,
      indicatorColor: esquema.primaryContainer,
    ),
    dialogTheme: DialogThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    listTileTheme: ListTileThemeData(shape: cantos),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 400),
      decoration: BoxDecoration(color: esquema.inverseSurface, borderRadius: BorderRadius.circular(8)),
    ),
    // transição animada entre telas também no PC (o padrão do desktop é sem animação)
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
      },
    ),
  );
}

/// Cores por estado de etapa/tarefa, iguais em todos os módulos.
Color corDoEstado(ColorScheme c, String estado) => switch (estado) {
  'ok' => Colors.green,
  'rodando' => c.primary,
  'na fila' => c.tertiary,
  'erro' || 'interrompido' => c.error,
  _ => c.outline,
};
