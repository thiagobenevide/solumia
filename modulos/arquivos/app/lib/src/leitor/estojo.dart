import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../modelos.dart';

/// Ferramentas da barra do leitor, na ordem em que aparecem.
enum Ferramenta {
  navegar('Navegar', Icons.pan_tool_outlined),
  caneta('Caneta', Icons.edit_outlined),
  lapis('Lápis', Icons.create_outlined),
  caligrafia('Pincel', Icons.brush_outlined),
  marcador('Marca-texto livre', Icons.format_paint_outlined),
  marcaTexto('Marca-texto (salva o texto)', Icons.border_color_outlined),
  borracha('Borracha', Icons.auto_fix_normal_outlined),
  texto('Texto', Icons.title);

  const Ferramenta(this.rotulo, this.icone);

  final String rotulo;
  final IconData icone;

  Pincel? get pincel => switch (this) {
    caneta => Pincel.caneta,
    lapis => Pincel.lapis,
    caligrafia => Pincel.caligrafia,
    marcador => Pincel.marcador,
    _ => null,
  };

  bool get usaCor => this != navegar && this != borracha;
}

const coresRapidas = [
  Color(0xFF111111),
  Color(0xFF1E5EFF),
  Color(0xFFE53935),
  Color(0xFF2E7D32),
  Color(0xFF8E24AA),
  Color(0xFFFFEB3B),
  Color(0xFF7CF29C),
  Color(0xFFFF9EC8),
  Color(0xFF80D8FF),
  Color(0xFFFFB74D),
];

/// Ferramenta escolhida e a cor/espessura de cada uma (trocar de ferramenta não perde o ajuste da
/// outra, como no Samsung Notes).
class Estojo extends ChangeNotifier {
  Ferramenta _ferramenta = Ferramenta.caneta;
  final Map<Ferramenta, Color> _cores = {
    Ferramenta.caneta: const Color(0xFF111111),
    Ferramenta.lapis: const Color(0xFF424242),
    Ferramenta.caligrafia: const Color(0xFF1E5EFF),
    Ferramenta.marcador: const Color(0xFFFFEB3B),
    Ferramenta.marcaTexto: const Color(0xFFFFEB3B),
    Ferramenta.texto: const Color(0xFFE53935),
  };
  final Map<Ferramenta, double> _espessuras = {
    Ferramenta.caneta: 2.0,
    Ferramenta.lapis: 1.2,
    Ferramenta.caligrafia: 5.0,
    Ferramenta.marcador: 14.0,
    Ferramenta.marcaTexto: 14.0,
    Ferramenta.borracha: 10.0,
    Ferramenta.texto: 14.0,
  };

  /// Força todo traço a sair reto (régua). Sem isso, segurar a caneta parada no fim do traço por
  /// um instante também o endireita.
  bool retas = false;

  /// Só a caneta desenha; o dedo rola e dá zoom (rejeição da palma). Padrão ligado no Android/iOS.
  bool soCaneta = defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

  final List<Color> recentes = [];

  Ferramenta get ferramenta => _ferramenta;
  Color get cor => corDe(_ferramenta);
  double get espessura => espessuraDe(_ferramenta);

  Color corDe(Ferramenta f) => _cores[f] ?? const Color(0xFF111111);

  double espessuraDe(Ferramenta f) => _espessuras[f] ?? 2;

  /// Limites do controle de espessura (em pontos PDF; tamanho da fonte para o texto).
  (double, double) get faixa => switch (_ferramenta) {
    Ferramenta.marcador || Ferramenta.marcaTexto => (4, 40),
    Ferramenta.borracha => (2, 60),
    Ferramenta.texto => (6, 48),
    Ferramenta.caligrafia => (1, 30),
    _ => (0.3, 20),
  };

  set ferramenta(Ferramenta f) {
    _ferramenta = f;
    notifyListeners();
  }

  set cor(Color c) {
    _cores[_ferramenta] = c;
    recentes
      ..remove(c)
      ..insert(0, c);
    if (recentes.length > 6) recentes.removeLast();
    notifyListeners();
  }

  set espessura(double v) {
    _espessuras[_ferramenta] = v;
    notifyListeners();
  }

  void alternarRetas() {
    retas = !retas;
    notifyListeners();
  }

  void alternarSoCaneta() {
    soCaneta = !soCaneta;
    notifyListeners();
  }
}
