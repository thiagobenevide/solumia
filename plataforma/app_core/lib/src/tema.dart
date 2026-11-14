import 'package:flutter/material.dart';

/// Azul de destaque, base da paleta do app.
const corDestaque = Color(0xFF2F6FED);

ThemeData temaAgent(Brightness brilho) {
  final esquema = ColorScheme.fromSeed(seedColor: corDestaque, brightness: brilho);
  return ThemeData(
    colorScheme: esquema,
    useMaterial3: true,
    cardTheme: CardThemeData(
      elevation: 0,
      color: esquema.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
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
