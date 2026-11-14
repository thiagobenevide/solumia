import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solumia_configurador/l10n/textos.dart';
import 'package:solumia_configurador/nucleo.dart';
import 'package:solumia_configurador/tema.dart';

void main() {
  test('ErroNucleo mostra a mensagem', () {
    expect(ErroNucleo('falhou', 422).toString(), 'falhou');
  });

  test('três idiomas com textos próprios', () {
    final inicio = {for (final (c, _) in idiomas) c: lookupTextos(Locale(c)).navInicio};
    expect(inicio, {'pt': 'Início', 'en': 'Home', 'es': 'Inicio'});
  });

  test('paleta clara e escura distintas', () {
    expect(esquemaSolumia(Brightness.light).surface, isNot(esquemaSolumia(Brightness.dark).surface));
  });
}
