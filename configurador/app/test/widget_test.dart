import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solumia_configurador/l10n/app_text.dart';
import 'package:solumia_configurador/core.dart';
import 'package:solumia_configurador/theme.dart';

void main() {
  test('CoreError shows the message', () {
    expect(CoreError('falhou', 422).toString(), 'falhou');
  });

  test('three languages with their own texts', () {
    final home = {for (final (c, _) in languages) c: lookupAppText(Locale(c)).navHome};
    expect(home, {'pt': 'Início', 'en': 'Home', 'es': 'Inicio'});
  });

  test('light and dark palettes differ', () {
    expect(solumiaScheme(Brightness.light).surface, isNot(solumiaScheme(Brightness.dark).surface));
  });
}
