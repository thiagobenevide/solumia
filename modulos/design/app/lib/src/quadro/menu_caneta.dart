import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'estojo.dart';

/// Clique rápido no botão lateral da caneta com ela pairando (sem encostar): abre o menu circular,
/// como no Samsung Notes. Segurar o botão e encostar continua sendo a borracha (`classificar`).
/// O Android manda o estado do botão nos eventos de pairar (`kPrimaryStylusButton`).
class CliqueDoBotao {
  CliqueDoBotao({DateTime Function()? relogio}) : _agora = relogio ?? DateTime.now;

  final DateTime Function() _agora;

  /// Até quanto tempo apertado ainda conta como clique (mais que isso é segurar).
  static const limite = Duration(milliseconds: 450);

  DateTime? _apertou;

  /// Encostou com o botão apertado (borracha): ao levantar ainda segurando, soltar o botão não é
  /// clique. Só volta a valer depois que o botão for solto.
  var _bloqueado = false;

  /// Devolve a posição do clique quando o botão solta a tempo; senão, null.
  Offset? pairar(PointerHoverEvent e) {
    if (e.kind != PointerDeviceKind.stylus) return null;
    final apertado = e.buttons & kPrimaryStylusButton != 0;
    if (_bloqueado) {
      if (!apertado) _bloqueado = false;
      _apertou = null;
      return null;
    }
    if (apertado) {
      _apertou ??= _agora();
      return null;
    }
    final inicio = _apertou;
    _apertou = null;
    if (inicio == null || _agora().difference(inicio) > limite) return null;
    return e.localPosition;
  }

  /// A caneta encostou: o botão apertado agora é borracha, não clique.
  void cancelar() {
    _apertou = null;
    _bloqueado = true;
  }
}

/// Menu circular em volta de [centro]: ferramentas, desfazer/refazer no anel de dentro, cores no
/// de fora e a espessura (− / +) no meio. Tocar fora fecha.
class MenuRadialCaneta extends StatelessWidget {
  const MenuRadialCaneta({
    super.key,
    required this.centro,
    required this.estojo,
    required this.desfazer,
    required this.refazer,
    required this.maisCores,
    required this.fechar,
  });

  final Offset centro;
  final Estojo estojo;
  final VoidCallback? desfazer, refazer;
  final VoidCallback maisCores, fechar;

  static const raio = 150.0;
  static const _ferramentas = [
    Ferramenta.caneta,
    Ferramenta.marcador,
    Ferramenta.borracha,
    Ferramenta.selecao,
    Ferramenta.texto,
    Ferramenta.reta,
    Ferramenta.retangulo,
    Ferramenta.laser,
  ];

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      // O menu inteiro cabe na tela, mesmo clicando perto da borda.
      final x = centro.dx.clamp(raio, max(raio, c.maxWidth - raio));
      final y = centro.dy.clamp(raio, max(raio, c.maxHeight - raio));
      return Stack(
        children: [
          Positioned.fill(
            child: Listener(behavior: HitTestBehavior.opaque, onPointerDown: (_) => fechar()),
          ),
          Positioned(
            left: x - raio,
            top: y - raio,
            width: raio * 2,
            height: raio * 2,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.6, end: 1),
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutBack,
              builder: (context, t, filho) =>
                  Opacity(opacity: ((t - 0.6) / 0.4).clamp(0, 1), child: Transform.scale(scale: t, child: filho)),
              child: ListenableBuilder(listenable: estojo, builder: (context, _) => _roda(context)),
            ),
          ),
        ],
      );
    },
  );

  Widget _roda(BuildContext context) {
    final esquema = Theme.of(context).colorScheme;
    final itens = <Widget>[];
    // Anel de fora: cores (a última abre o seletor completo).
    final cores = [...coresRapidas, null];
    for (var i = 0; i < cores.length; i++) {
      final cor = cores[i];
      final atual = cor != null && estojo.cor == cor;
      itens.add(
        _noAnel(
          i,
          cores.length,
          raio - 24,
          cor == null
              ? _botaoRedondo(esquema, Icons.palette_outlined, 'Mais cores', () {
                  fechar();
                  maisCores();
                })
              : Tooltip(
                  message: 'Cor',
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => estojo.cor = cor,
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: cor,
                        shape: BoxShape.circle,
                        border: Border.all(color: atual ? esquema.primary : Colors.black26, width: atual ? 3 : 1),
                      ),
                    ),
                  ),
                ),
        ),
      );
    }
    // Anel de dentro: ferramentas, desfazer e refazer.
    final acoes = <Widget>[
      for (final f in _ferramentas)
        _botaoRedondo(
          esquema,
          f.icone,
          f.rotulo,
          () {
            estojo.ferramenta = f;
            fechar();
          },
          ativo: estojo.ferramenta == f,
        ),
      _botaoRedondo(esquema, Icons.undo, 'Desfazer', desfazer),
      _botaoRedondo(esquema, Icons.redo, 'Refazer', refazer),
    ];
    for (var i = 0; i < acoes.length; i++) {
      itens.add(_noAnel(i, acoes.length, raio - 76, acoes[i]));
    }
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: esquema.surface.withValues(alpha: 0.96),
                boxShadow: const [BoxShadow(blurRadius: 18, color: Colors.black26)],
                border: Border.all(color: esquema.outlineVariant),
              ),
            ),
          ),
          Center(
            child: Container(
              width: 52 * 2 - 8,
              height: 52 * 2 - 8,
              decoration: BoxDecoration(shape: BoxShape.circle, color: esquema.surfaceContainerHighest),
            ),
          ),
          ...itens,
          Center(child: _espessura(esquema)),
        ],
      ),
    );
  }

  /// Meio: amostra do traço com a cor e a espessura atuais, − e + para afinar/engrossar.
  Widget _espessura(ColorScheme esquema) {
    final e = estojo.espessura;
    final (minimo, maximo) = estojo.ferramenta == Ferramenta.marcador ? (6.0, 48.0) : (1.0, 24.0);
    void mudar(double fator) => estojo.espessura = (e * fator).clamp(minimo, maximo).roundToDouble().clamp(minimo, maximo);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _mini(Icons.add, 'Mais grosso', e < maximo ? () => mudar(1.3) : null),
        Container(
          width: min(30, e + 4),
          height: min(30, e + 4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: estojo.ferramenta.usaCor ? estojo.cor : esquema.onSurfaceVariant,
          ),
        ),
        Text('${e.round()}', style: const TextStyle(fontSize: 11)),
        _mini(Icons.remove, 'Mais fino', e > minimo ? () => mudar(1 / 1.3) : null),
      ],
    );
  }

  Widget _mini(IconData icone, String dica, VoidCallback? aoTocar) => IconButton(
    tooltip: dica,
    visualDensity: VisualDensity.compact,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(width: 26, height: 22),
    iconSize: 18,
    onPressed: aoTocar,
    icon: Icon(icone),
  );

  Widget _noAnel(int i, int total, double r, Widget filho) {
    final a = -pi / 2 + i * 2 * pi / total;
    return Positioned(
      left: raio + cos(a) * r - 20,
      top: raio + sin(a) * r - 20,
      width: 40,
      height: 40,
      child: Center(child: filho),
    );
  }

  Widget _botaoRedondo(ColorScheme esquema, IconData icone, String dica, VoidCallback? aoTocar, {bool ativo = false}) =>
      IconButton(
        tooltip: dica,
        isSelected: ativo,
        style: IconButton.styleFrom(
          backgroundColor: ativo ? esquema.primaryContainer : null,
          foregroundColor: ativo ? esquema.onPrimaryContainer : null,
        ),
        onPressed: aoTocar,
        icon: Icon(icone, size: 22),
      );
}
