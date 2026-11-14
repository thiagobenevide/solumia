import 'package:flutter/widgets.dart';

/// Faixas de largura (dp) usadas por todo o app, nos aparelhos de referência:
/// - compacto (< 600): celular em pé (Galaxy S23 ≈ 360 dp);
/// - medio (600–1199): tablet em pé (Tab S9 FE ≈ 800 dp), celular deitado;
/// - expandido (1200–1799): tablet deitado (≈ 1280), notebook (1366–1536), monitor Full HD (1920 com a
///   barra lateral fica perto de 1800);
/// - amplo (≥ 1800): Full HD em tela cheia, ultrawide (2560–3440).
enum Faixa {
  compacto,
  medio,
  expandido,
  amplo;

  static Faixa daLargura(double largura) => largura < 600
      ? compacto
      : largura < 1200
      ? medio
      : largura < 1800
      ? expandido
      : amplo;

  static Faixa de(BuildContext context) => daLargura(MediaQuery.sizeOf(context).width);

  bool get celular => this == compacto;
  bool get pc => index >= expandido.index;
}

/// Limita a largura do conteúdo e o centraliza: texto e formulários não esticam por 3000 px no ultrawide.
class LarguraMaxima extends StatelessWidget {
  const LarguraMaxima({super.key, this.largura = 1400, required this.child});

  final double largura;
  final Widget child;

  // Margem em vez de Align: o filho continua com largura e altura justas (ListView, Column esticada).
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, area) {
      final sobra = area.maxWidth.isFinite ? (area.maxWidth - largura).clamp(0.0, double.infinity) / 2 : 0.0;
      return Padding(padding: EdgeInsets.symmetric(horizontal: sobra), child: child);
    },
  );
}
