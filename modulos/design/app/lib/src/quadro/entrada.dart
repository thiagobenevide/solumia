import 'dart:math';
import 'dart:ui' show Rect, Size;

import 'package:flutter/gestures.dart';

import 'estojo.dart';

/// O que um ponteiro que encostou vai fazer.
enum Gesto { desenhar, apagar, navegar }

/// Regras de entrada para todos os aparelhos:
/// - caneta (S-Pen, Apple Pencil, mesa Wacom/Huion): desenha com a ferramenta; a ponta de borracha
///   ou o botão lateral apagam;
/// - mouse: botão esquerdo usa a ferramenta; do meio, direito ou espaço apertado movem o quadro;
/// - dedo: desenha só enquanto [Estojo.dedoDesenha]; senão move (um dedo) e dá zoom (pinça).
Gesto classificar({
  required PointerDeviceKind tipo,
  required int botoes,
  required Ferramenta ferramenta,
  required bool dedoDesenha,
  bool espaco = false,
}) {
  if (tipo == PointerDeviceKind.invertedStylus) return Gesto.apagar;
  if (tipo == PointerDeviceKind.stylus && botoes & kPrimaryStylusButton != 0) return Gesto.apagar;
  if (tipo == PointerDeviceKind.mouse && botoes & (kMiddleMouseButton | kSecondaryMouseButton) != 0) {
    return Gesto.navegar;
  }
  if (espaco) return Gesto.navegar;
  if (tipo == PointerDeviceKind.touch && !dedoDesenha) return Gesto.navegar;
  return switch (ferramenta) {
    Ferramenta.mao => Gesto.navegar,
    Ferramenta.borracha => Gesto.apagar,
    _ => Gesto.desenhar,
  };
}

bool ehCaneta(PointerDeviceKind tipo) => tipo == PointerDeviceKind.stylus || tipo == PointerDeviceKind.invertedStylus;

/// Pressão normalizada 0–1. Mouse e dedo não têm pressão útil: 0,5 (traço de espessura média).
double pressao(PointerEvent e) {
  if (!ehCaneta(e.kind)) return 0.5;
  final faixa = e.pressureMax - e.pressureMin;
  if (faixa <= 0) return 0.5;
  return ((e.pressure - e.pressureMin) / faixa).clamp(0.05, 1.0);
}

/// Câmera do quadro infinito: tela = mundo × [escala] + [deslocamento].
class Camera {
  Offset deslocamento = Offset.zero;
  double escala = 1;

  static const minimo = 0.1, maximo = 8.0;

  Offset paraMundo(Offset tela) => (tela - deslocamento) / escala;

  Offset paraTela(Offset mundo) => mundo * escala + deslocamento;

  /// Multiplica o zoom por [fator] mantendo parado o ponto da tela [foco].
  void zoom(double fator, Offset foco) {
    final nova = (escala * fator).clamp(minimo, maximo);
    final mundo = paraMundo(foco);
    escala = nova;
    deslocamento = foco - mundo * escala;
  }

  /// Enquadra [area] (mundo) na [tela], com margem; área vazia volta à origem em 100%.
  void enquadrar(Rect? area, Size tela) {
    if (area == null || area.isEmpty || tela.isEmpty) {
      escala = 1;
      deslocamento = Offset.zero;
      return;
    }
    escala = min(tela.width / area.width, tela.height / area.height).clamp(minimo, 2.0) * 0.9;
    deslocamento = tela.center(Offset.zero) - area.center * escala;
  }
}
