import 'package:flutter/material.dart';

import '../modelos.dart';

/// Ferramentas da barra do quadro, na ordem em que aparecem; [atalho] é a tecla no teclado.
enum Ferramenta {
  mao('Mover (H / espaço)', Icons.pan_tool_outlined, 'h'),
  selecao('Selecionar com laço (V)', Icons.highlight_alt, 'v'),
  caneta('Caneta (P)', Icons.edit_outlined, 'p'),
  marcador('Marcador (M)', Icons.format_paint_outlined, 'm'),
  borracha('Borracha (E)', Icons.auto_fix_normal_outlined, 'e'),
  reta('Reta (L)', Icons.horizontal_rule, 'l'),
  seta('Seta (A)', Icons.arrow_right_alt, 'a'),
  retangulo('Retângulo (R)', Icons.crop_square, 'r'),
  elipse('Elipse (O)', Icons.circle_outlined, 'o'),
  texto('Texto (T)', Icons.title, 't'),
  laser('Laser (K)', Icons.highlight, 'k');

  const Ferramenta(this.rotulo, this.icone, this.atalho);

  final String rotulo;
  final IconData icone;
  final String atalho;

  TipoForma? get forma => switch (this) {
    reta => TipoForma.reta,
    seta => TipoForma.seta,
    retangulo => TipoForma.retangulo,
    elipse => TipoForma.elipse,
    _ => null,
  };

  bool get usaCor => this != mao && this != borracha && this != laser && this != selecao;

  bool get usaEspessura => this != mao && this != laser && this != selecao;
}

const coresRapidas = [
  Color(0xFF111111),
  Color(0xFF1E5EFF),
  Color(0xFFE53935),
  Color(0xFF2E7D32),
  Color(0xFF8E24AA),
  Color(0xFFFF9800),
  Color(0xFFFFEB3B),
  Color(0xFF80D8FF),
];

/// Ferramenta escolhida, cor/espessura de cada uma e como o dedo se comporta.
class Estojo extends ChangeNotifier {
  Ferramenta _ferramenta = Ferramenta.caneta;
  final Map<Ferramenta, Color> _cores = {Ferramenta.marcador: const Color(0xFFFFEB3B)};
  final Map<Ferramenta, double> _espessuras = {
    Ferramenta.caneta: 3,
    Ferramenta.marcador: 18,
    Ferramenta.borracha: 12,
    Ferramenta.texto: 28,
  };
  Color _corFormas = const Color(0xFF111111);
  bool? _dedoDesenha;
  final List<Color> recentes = [];
  bool _canetaVista = false;

  Ferramenta get ferramenta => _ferramenta;
  set ferramenta(Ferramenta f) {
    _ferramenta = f;
    notifyListeners();
  }

  // Formas e caneta dividem a cor: desenhar um esquema não pede trocar de cor a cada ferramenta.
  Color corDe(Ferramenta f) => _cores[f] ?? _corFormas;
  Color get cor => corDe(_ferramenta);
  set cor(Color c) {
    lembrarCor(c);
    if (_ferramenta == Ferramenta.marcador) {
      _cores[Ferramenta.marcador] = c;
    } else {
      _corFormas = c;
    }
    notifyListeners();
  }

  // Formas usam a espessura da caneta, pelo mesmo motivo da cor.
  static Ferramenta _chave(Ferramenta f) => f.forma != null ? Ferramenta.caneta : f;
  double espessuraDe(Ferramenta f) => _espessuras[_chave(f)] ?? 3;
  double get espessura => espessuraDe(_ferramenta);
  set espessura(double v) {
    _espessuras[_chave(_ferramenta)] = v;
    notifyListeners();
  }

  /// O dedo desenha? Automático até o usuário escolher: desenha até aparecer uma caneta (S-Pen,
  /// mesa digitalizadora); daí em diante o dedo só move e dá zoom (a palma não risca).
  bool get dedoDesenha => _dedoDesenha ?? !_canetaVista;
  set dedoDesenha(bool v) {
    _dedoDesenha = v;
    notifyListeners();
  }

  /// Cores fora da paleta usadas por último (até 6), para o seletor completo.
  void lembrarCor(Color c) {
    if (coresRapidas.contains(c)) return;
    recentes
      ..remove(c)
      ..insert(0, c);
    if (recentes.length > 6) recentes.removeLast();
  }

  void canetaVista() {
    if (_canetaVista) return;
    _canetaVista = true;
    notifyListeners();
  }
}
